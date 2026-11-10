import AppKit
import CoreAudio
import Foundation

enum CaptureSource: String, CaseIterable, Identifiable {
    case application = "Selected app"
    case system = "All output · Core Audio"
    case screenKit = "ScreenCaptureKit"

    var id: Self { self }
}

@MainActor
final class Recorder: ObservableObject {
    enum Phase { case ready, starting, recording, stopping, choosingSession, transcribing }

    @Published var source: CaptureSource = .application
    @Published var selectedApp: String?
    @Published var includeMic = false
    @Published var autoTranscribe = true

    @Published private(set) var phase = Phase.ready
    @Published private(set) var apps: [AudioApplication] = []
    @Published private(set) var status: String?
    @Published private(set) var problem: String?
    @Published private(set) var lastSession: URL?
    @Published private(set) var systemReading = TrackReading()
    @Published private(set) var micReading = TrackReading()
    @Published private(set) var elapsed = Duration.zero
    @Published private(set) var transcriptionStage: String?
    @Published private(set) var transcriptionProblem: String?
    @Published private(set) var isDictating = false
    @Published private(set) var shortcutProblem: String?

    private var monitor: Task<Void, Never>?
    private var transcription: Task<Void, Never>?
    private var dictationShortcut: DictationShortcut?
    private var readSystem: (() -> TrackReading)?
    private var stopSystem: (() async -> String?)?
    private var mic: MicrophoneInput?
    private var folder: URL?

    private static let supportFolder = URL.applicationSupportDirectory
        .appendingPathComponent("Audio Capture", isDirectory: true)

    private let recordings = supportFolder.appendingPathComponent("Recordings", isDirectory: true)
    private let transcriber = SessionTranscriber()

    var canStart: Bool { phase == .ready && (source != .application || selectedApp != nil) }
    var canDictate: Bool { phase == .ready || phase == .recording && isDictating }

    init() {
        do {
            dictationShortcut = try DictationShortcut { [weak self] in
                self?.toggleDictation()
            }
        } catch {
            shortcutProblem = error.localizedDescription
        }
    }

    func toggleDictation() {
        switch phase {
        case .ready:
            start(dictation: true)
        case .recording where isDictating:
            stop()
        default:
            break
        }
    }

    func refreshApps() {
        guard phase == .ready else { return }
        do {
            let available = try audioApplications()
            apps = available.filter { $0.playing || $0.id == selectedApp }
            if !apps.contains(where: { $0.id == selectedApp }) { selectedApp = nil }
            problem = nil
        } catch {
            apps = []
            selectedApp = nil
            problem = error.localizedDescription
        }
    }

    func start() {
        start(dictation: false)
    }

    private func start(dictation: Bool) {
        guard phase == .ready, dictation || canStart else { return }
        phase = .starting
        isDictating = dictation
        status = nil
        problem = nil
        transcriptionProblem = nil
        systemReading = TrackReading()
        micReading = TrackReading()
        elapsed = .zero

        Task {
            do {
                if dictation || includeMic { try await MicrophoneInput.authorize() }
                let folder = try makeSessionFolder()
                self.folder = folder
                if !dictation {
                    let systemURL = RecordingTrack.system.audioURL(in: folder)
                    switch source {
                    case .screenKit:
                        let input = ScreenAudioInput()
                        readSystem = { input.reading }
                        stopSystem = { await input.stop() }
                        try await input.start(url: systemURL)
                    case .application, .system:
                        var processes: [AudioObjectID]?
                        if source == .application {
                            guard let app = try audioApplications().first(where: { $0.id == selectedApp }) else {
                                throw CaptureError("The selected app disconnected from Core Audio. Play audio in it and refresh the list.")
                            }
                            processes = app.processes
                        }
                        let tap = ProcessTap()
                        readSystem = { tap.reading }
                        stopSystem = { await Task.detached { tap.stop() }.value }
                        let selection = processes
                        try await Task.detached(priority: .userInitiated) {
                            try tap.start(processes: selection, url: systemURL)
                        }.value
                    }
                }
                if dictation || includeMic {
                    let input = MicrophoneInput()
                    mic = input
                    try input.start(url: RecordingTrack.microphone.audioURL(in: folder))
                }

                phase = .recording
                startMonitor()
            } catch {
                await finish(reason: error.localizedDescription)
            }
        }
    }

    func stop() {
        guard phase == .recording else { return }
        phase = .stopping
        let dictation = isDictating
        Task {
            await finish(transcribeAfterSaving: dictation || autoTranscribe, copyToClipboard: dictation)
        }
    }

    func quit() {
        switch phase {
        case .ready:
            NSApp.terminate(nil)
        case .recording:
            phase = .stopping
            Task {
                await finish()
                NSApp.terminate(nil)
            }
        case .starting, .stopping, .choosingSession, .transcribing:
            break
        }
    }

    func showRecordings() {
        do {
            try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
            NSWorkspace.shared.open(recordings)
        } catch {
            problem = error.localizedDescription
        }
    }

    func showLastSession() {
        if let lastSession { NSWorkspace.shared.open(lastSession) }
    }

    func chooseSessionToTranscribe() {
        guard phase == .ready else { return }
        phase = .choosingSession
        let panel = NSOpenPanel()
        panel.title = "Choose a Recording Session"
        panel.message = "Select a folder containing system.caf or microphone.caf."
        panel.prompt = "Transcribe"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = lastSession ?? recordings
        NSApp.activate()
        panel.begin { [weak self] response in
            guard let self else { return }
            phase = .ready
            if response == .OK, let session = panel.url {
                problem = nil
                status = nil
                transcribe(session: session)
            }
        }
    }

    func cancelTranscription() {
        guard let transcription, !transcription.isCancelled else { return }
        transcription.cancel()
        transcriptionStage = "Canceling transcription…"
    }

    private func transcribe(session: URL, copyToClipboard: Bool = false) {
        phase = .transcribing
        transcriptionProblem = nil
        transcriptionStage = "Preparing transcription…"
        transcription = Task {
            defer {
                transcription = nil
                transcriptionStage = nil
                phase = .ready
            }
            do {
                let summary = try await transcriber.transcribe(session: session) { [weak self] stage in
                    if self?.transcription?.isCancelled == false { self?.transcriptionStage = stage }
                }
                try Task.checkCancellation()
                lastSession = session
                switch summary.savedCount {
                case 0 where summary.errors.isEmpty:
                    status = "This session already has transcripts."
                case 1:
                    status = "Transcript saved."
                case 2...:
                    status = "\(summary.savedCount) transcripts saved."
                default:
                    status = nil
                }
                if !summary.errors.isEmpty {
                    transcriptionProblem = summary.errors.joined(separator: " ")
                } else if copyToClipboard {
                    let speech = summary.microphoneText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if speech.isEmpty {
                        status = "No speech detected."
                    } else {
                        NSPasteboard.general.clearContents()
                        if NSPasteboard.general.setString(speech, forType: .string) {
                            status = "Dictation copied to clipboard."
                        } else {
                            transcriptionProblem = "Transcript saved. Could not copy it to the clipboard."
                        }
                    }
                }
            } catch {
                if Task.isCancelled {
                    status = "Transcription canceled."
                } else {
                    transcriptionProblem = error.localizedDescription
                }
            }
        }
    }

    private func makeSessionFolder() throws -> URL {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "\(formatter.string(from: .now))_\(UUID().uuidString.prefix(8))"
        let folder = recordings.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return folder
    }

    private func startMonitor() {
        let start = ContinuousClock.now
        monitor = Task { [weak self] in
            while let self, !Task.isCancelled {
                systemReading = readSystem?() ?? TrackReading()
                micReading = mic?.reading ?? TrackReading()
                elapsed = start.duration(to: .now)
                if let error = systemReading.error ?? micReading.error {
                    phase = .stopping
                    Task { await finish(reason: error) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func finish(
        reason: String? = nil, transcribeAfterSaving: Bool = false, copyToClipboard: Bool = false
    ) async {
        phase = .stopping
        monitor?.cancel()
        monitor = nil

        let micError = mic?.stop()
        let systemError = await stopSystem?()
        mic = nil
        readSystem = nil
        stopSystem = nil

        var errors = [reason, micError, systemError].compactMap { $0 }
        var savedSession: URL?
        if let folder {
            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                if files.isEmpty {
                    try FileManager.default.removeItem(at: folder)
                    status = errors.isEmpty ? "No audio samples were saved." : nil
                } else {
                    savedSession = folder
                    lastSession = folder
                    status = errors.isEmpty ? "Recording saved." : "Audio captured before the error was kept."
                }
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        self.folder = nil
        problem = NSOrderedSet(array: errors).array.compactMap { $0 as? String }.joined(separator: " ")
        if problem?.isEmpty == true { problem = nil }
        isDictating = false
        phase = .ready
        if transcribeAfterSaving, let savedSession {
            transcribe(session: savedSession, copyToClipboard: copyToClipboard && errors.isEmpty)
        }
    }
}
