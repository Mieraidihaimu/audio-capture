import SwiftUI

@main
struct AudioCaptureApp: App {
    @NSApplicationDelegateAdaptor(CaptureAppDelegate.self) private var appDelegate
    @State private var selectedTranscript: SavedTranscript.ID?
    @State private var transcriptFilter = TranscriptFilter.all

    private var recorder: Recorder { appDelegate.recorder }

    var body: some Scene {
        MenuBarExtra {
            CapturePanel(recorder: recorder, selectedTranscript: $selectedTranscript, transcriptFilter: $transcriptFilter)
        } label: {
            CaptureStatusLabel(recorder: recorder)
        }
        .menuBarExtraStyle(.window)

        Settings {
            CaptureSettingsView(recorder: recorder)
        }

        Window("Transcripts", id: "transcripts") {
            TranscriptsView(library: recorder.transcriptLibrary, selection: $selectedTranscript, filter: $transcriptFilter)
        }
        .defaultSize(width: 860, height: 560)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
private final class CaptureAppDelegate: NSObject, NSApplicationDelegate {
    let recorder = Recorder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        recorder.installDictationShortcut()
    }
}

private struct CaptureStatusLabel: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        Image(systemName: statusIcon)
            .accessibilityLabel(statusDescription)
    }

    private var statusIcon: String {
        if recorder.isDictating { return "mic.fill" }
        return switch recorder.phase {
        case .ready, .choosingSession: "waveform"
        case .starting, .recording, .stopping: "record.circle.fill"
        case .transcribing: "text.bubble"
        }
    }

    private var statusDescription: String {
        if recorder.isDictating { return "Audio Capture dictating" }
        switch recorder.phase {
        case .ready, .choosingSession: return "Audio Capture"
        case .starting: return "Audio Capture starting"
        case .recording: return "Audio Capture recording"
        case .stopping: return "Audio Capture saving"
        case .transcribing: return "Audio Capture transcribing"
        }
    }
}

private struct CapturePanel: View {
    @ObservedObject var recorder: Recorder
    @Binding var selectedTranscript: SavedTranscript.ID?
    @Binding var transcriptFilter: TranscriptFilter
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            controls
            messages
            Divider()
            RecentTranscripts(library: recorder.transcriptLibrary, selection: $selectedTranscript, filter: $transcriptFilter)
        }
        .padding(14)
        .frame(width: 328)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Audio Capture").font(.headline)
            Spacer()
            if recorder.phase == .recording {
                Label(elapsedTime, systemImage: recorder.isDictating ? "mic.fill" : "record.circle.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.red)
                    .accessibilityLabel("\(recorder.isDictating ? "Dictating" : "Recording"), \(elapsedTime) elapsed")
            }
            Button("Settings", systemImage: "gearshape", action: showSettings)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.large)
                .help("Settings")
        }
    }

    private var elapsedTime: String {
        let seconds = Int(recorder.elapsed.components.seconds)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder private var controls: some View {
        switch recorder.phase {
        case .ready:
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if recorder.canStart {
                        primaryButton("Start Recording", symbol: "record.circle", action: recorder.start)
                    } else {
                        primaryButton("Set Up Recording", symbol: "sliders.horizontal.3", action: showSettings)
                    }
                    Button("Dictate", systemImage: "mic", action: recorder.toggleDictation)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                if let key = recorder.activeDictationKey {
                    Text("Hold \(key.symbols) to dictate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Hold \(key.name) to dictate")
                } else {
                    Button("Dictation shortcut unavailable", systemImage: "exclamationmark.triangle",
                           action: showSettings)
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Open Settings to change the dictation shortcut.")
                }
            }
        case .recording:
            if recorder.isDictating {
                primaryButton("Finish & Copy", symbol: "stop.fill", tint: .red, action: recorder.stop)
            } else {
                levels
                primaryButton("Stop Recording", symbol: "stop.fill", tint: .red, action: recorder.stop)
            }
        case .starting:
            progress(recorder.isDictating ? "Preparing microphone…" : "Starting recording…")
        case .stopping:
            progress("Saving recording…")
        case .choosingSession:
            progress("Choose a recording session…")
        case .transcribing:
            HStack(spacing: 8) {
                progress(recorder.transcriptionStage ?? "Transcribing…")
                Spacer(minLength: 0)
                Button("Cancel", action: recorder.cancelTranscription)
            }
        }
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }

    private func primaryButton(
        _ title: String, symbol: String, tint: Color = .accentColor, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var levels: some View {
        VStack(spacing: 6) {
            meter("System", symbol: "speaker.wave.2", reading: recorder.systemReading)
            if recorder.includeMic {
                meter("Mic", symbol: "mic", reading: recorder.micReading)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func meter(_ name: String, symbol: String, reading: TrackReading) -> some View {
        HStack(spacing: 8) {
            Label(name, systemImage: symbol)
                .font(.caption.weight(.medium))
                .frame(width: 65, alignment: .leading)

            GeometryReader { geometry in
                Capsule().fill(.secondary.opacity(0.16))
                Capsule().fill(Color.accentColor)
                    .frame(width: geometry.size.width * reading.level)
                    .animation(.easeOut(duration: 0.16), value: reading.level)
            }
            .frame(height: 5)

            if reading.frames == 0 {
                Text("Waiting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) audio level")
        .accessibilityValue(reading.frames == 0 ? "Waiting for audio" : "\(Int(reading.level * 100)) percent")
    }

    @ViewBuilder private var messages: some View {
        ForEach([recorder.problem, recorder.transcriptionProblem].compactMap { $0 }, id: \.self) { problem in
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if recorder.phase == .ready, let status = recorder.status {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RecentTranscripts: View {
    @ObservedObject var library: TranscriptLibrary
    @Binding var selection: SavedTranscript.ID?
    @Binding var filter: TranscriptFilter
    @Environment(\.openWindow) private var openWindow

    private var recent: ArraySlice<SavedTranscript> {
        library.transcripts(matching: filter).prefix(3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Transcripts")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                TranscriptFilterMenu(filter: $filter)
                Button("Open Library") { openTranscript() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if recent.isEmpty, library.problem == nil {
                Text(filter.emptyTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(recent) { entry in
                HStack(spacing: 8) {
                    Button {
                        openTranscript(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.preview.isEmpty ? entry.source : entry.preview)
                                .font(.subheadline)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                Text(entry.source)
                                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Opens in Transcripts")

                    TranscriptStarButton(library: library, entry: entry)
                    Button("Copy Text", systemImage: "doc.on.doc") { library.copy(entry) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Copy transcript text")
                }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
            }
            if let message = library.problem ?? library.notice {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(library.problem == nil ? Color.secondary : .orange)
            }
        }
        .onAppear(perform: library.reload)
    }

    private func openTranscript(_ entry: SavedTranscript? = nil) {
        if let entry { selection = entry.id }
        openWindow(id: "transcripts")
        NSApp.activate()
    }
}
