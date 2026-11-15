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

        Settings {
            CaptureSettingsView(recorder: recorder)
        }

        Window("Transcripts", id: "transcripts") {
            TranscriptsView(library: recorder.transcriptLibrary)
        }
        .defaultSize(width: 860, height: 560)
        .defaultLaunchBehavior(.suppressed)
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
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            controls
            messages
        }
        .padding(14)
        .frame(width: 292)
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
            HStack(spacing: 8) {
                if recorder.canStart {
                    primaryButton("Start Recording", symbol: "record.circle", action: recorder.start)
                } else {
                    primaryButton("Set Up Recording", symbol: "sliders.horizontal.3", action: showSettings)
                }
                Button("Dictate", systemImage: "mic", action: recorder.toggleDictation)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help(recorder.shortcutProblem ?? "Hold Option–Space from any app and release to finish.")
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
