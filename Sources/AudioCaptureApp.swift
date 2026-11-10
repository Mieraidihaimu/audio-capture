import SwiftUI

@main
struct AudioCaptureApp: App {
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        MenuBarExtra {
            CapturePanel(recorder: recorder)
        } label: {
            Image(systemName: statusIcon)
                .accessibilityLabel(statusDescription)
        }
        .menuBarExtraStyle(.window)

        Window("Transcripts", id: "transcripts") {
            TranscriptsView(library: recorder.transcriptLibrary)
        }
        .defaultSize(width: 860, height: 560)
        .defaultLaunchBehavior(.suppressed)
    }

    private var statusIcon: String {
        switch recorder.phase {
        case .ready, .choosingSession: "waveform"
        case .starting, .recording, .stopping: "record.circle.fill"
        case .transcribing: "text.bubble"
        }
    }

    private var statusDescription: String {
        if recorder.isDictating { return "Audio Capture dictating" }
        return recorder.phase == .transcribing ? "Audio Capture transcribing" : "Audio Capture"
    }
}

private struct CapturePanel: View {
    @ObservedObject var recorder: Recorder
    @Environment(\.openWindow) private var openWindow

    private var idle: Bool { recorder.phase == .ready }
    private var recording: Bool { recorder.phase == .recording }
    private var transitioning: Bool { !idle && !recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            configuration
                .disabled(!idle)
            levels
            if recorder.phase == .transcribing {
                transcriptionControls
            } else {
                captureButton
                if !recorder.isDictating {
                    Button("Dictate", action: recorder.toggleDictation)
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)
                        .disabled(!recorder.canDictate)
                        .help("Click to start dictation, or hold Option–Space from any app and release to finish.")
                    Button("Transcribe a Session…", action: recorder.chooseSessionToTranscribe)
                        .buttonStyle(.link)
                        .font(.subheadline)
                        .disabled(!idle)
                }
            }
            messages
            Button("Transcripts…", systemImage: "text.bubble") {
                recorder.transcriptLibrary.reload()
                openWindow(id: "transcripts")
                NSApp.activate()
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
            Divider()
            HStack(spacing: 12) {
                Button(action: recorder.showRecordings) {
                    Label("Recordings", systemImage: "folder")
                }
                if recorder.lastSession != nil {
                    Button("Last session", action: recorder.showLastSession)
                }
                Spacer()
                Button(recording ? "Stop & Quit" : "Quit", action: recorder.quit)
                    .disabled(transitioning)
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
        }
        .padding(18)
        .frame(width: 340)
        .onAppear {
            if idle, recorder.source == .application, recorder.apps.isEmpty { recorder.refreshApps() }
        }
        .onChange(of: recorder.source) { _, source in
            if source == .application { recorder.refreshApps() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio Capture").font(.headline)
                Text(recorder.isDictating ? "Microphone dictation" : "Local audio and transcription")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Label(phaseLabel, systemImage: "circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(recording ? Color.red : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.45), in: Capsule())
                .accessibilityLabel(recording ? "Recording, \(phaseLabel) elapsed" : phaseLabel)
        }
    }

    private var phaseLabel: String {
        switch recorder.phase {
        case .ready: return "Ready"
        case .starting: return "Starting"
        case .recording:
            let seconds = Int(recorder.elapsed.components.seconds)
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        case .stopping: return "Saving"
        case .choosingSession: return "Choose session"
        case .transcribing: return "Transcribing"
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("System audio", selection: $recorder.source) {
                ForEach(CaptureSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.menu)

            if recorder.source == .application {
                HStack(spacing: 8) {
                    Picker("App", selection: $recorder.selectedApp) {
                        Text("Choose an app").tag(String?.none)
                        ForEach(recorder.apps) { app in
                            Text(app.name).tag(Optional(app.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(recorder.apps.isEmpty)

                    Button(action: recorder.refreshApps) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh audio apps")
                    .accessibilityLabel("Refresh audio apps")
                }
            }

            Text(sourceDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Include microphone", isOn: $recorder.includeMic)
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle("Transcribe after recording", isOn: $recorder.autoTranscribe)
                .toggleStyle(.switch)
                .controlSize(.small)

            if recorder.autoTranscribe {
                Text("Transcription runs offline on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sourceDescription: String {
        switch recorder.source {
        case .application:
            return "Play audio in the target app, then refresh the list. The tap includes its current audio processes."
        case .system:
            return "Capture playback across apps through a private Core Audio tap."
        case .screenKit:
            return "Capture system audio through ScreenCaptureKit. macOS asks for screen recording access."
        }
    }

    private var levels: some View {
        VStack(spacing: 8) {
            meter("System", symbol: "speaker.wave.2", reading: recorder.systemReading, enabled: !recorder.isDictating)
            meter("Mic", symbol: "mic", reading: recorder.micReading, enabled: recorder.includeMic || recorder.isDictating)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func meter(_ name: String, symbol: String, reading: TrackReading, enabled: Bool) -> some View {
        let level = recording && enabled ? reading.level : 0
        return HStack(spacing: 8) {
            Label(name, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .frame(width: 65, alignment: .leading)

            GeometryReader { geometry in
                Capsule().fill(.secondary.opacity(0.16))
                Capsule().fill(Color.accentColor)
                    .frame(width: geometry.size.width * level)
                    .animation(.easeOut(duration: 0.16), value: level)
            }
            .frame(height: 5)

            Text(!enabled ? "Off" : recording && reading.frames == 0 ? "Waiting" : "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) audio level")
        .accessibilityValue(enabled ? "\(Int(level * 100)) percent" : "Off")
    }

    private var captureButton: some View {
        Button {
            if recording { recorder.stop() } else { recorder.start() }
        } label: {
            Label(captureTitle,
                  systemImage: recording ? "stop.fill" : "record.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(recording ? Color.red : Color.accentColor)
        .controlSize(.large)
        .disabled(!recorder.canStart && !recording)
    }

    private var captureTitle: String {
        if recorder.isDictating { return "Finish & Copy" }
        return recording ? "Stop Recording" : "Start Recording"
    }

    private var transcriptionControls: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text(recorder.transcriptionStage ?? "Transcribing…")
                .font(.subheadline)
            Spacer(minLength: 4)
            Button("Cancel", action: recorder.cancelTranscription)
        }
    }

    @ViewBuilder private var messages: some View {
        ForEach([recorder.problem, recorder.transcriptionProblem, recorder.shortcutProblem].compactMap { $0 }, id: \.self) { problem in
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let status = recorder.status {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
