import SwiftUI

struct CaptureSettingsView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var updater: UpdaterService

    var body: some View {
        Form {
            Section("Recording") {
                Picker("System audio", selection: $recorder.source) {
                    ForEach(CaptureSource.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }

                if recorder.source == .application {
                    appSelection
                }

                Text(sourceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Include microphone", isOn: $recorder.includeMic)
                Toggle("Transcribe after recording", isOn: $recorder.autoTranscribe)
            }
            .disabled(recorder.phase != .ready)

            Section("Dictation") {
                Picker("Hold to dictate", selection: Binding(
                    get: { recorder.dictationKey },
                    set: recorder.changeDictationKey
                )) {
                    ForEach(DictationKey.allCases, id: \.self) { key in
                        Text(key.name).tag(key)
                    }
                }
                .disabled(recorder.phase != .ready)
                if let problem = recorder.shortcutProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if recorder.activeDictationKey == nil {
                        Button("Retry Shortcut", action: recorder.installDictationShortcut)
                            .disabled(recorder.phase != .ready)
                    }
                }
            }

            Section("Updates") {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }

            Section {
                Button("Transcribe a Session…", systemImage: "text.badge.plus", action: recorder.chooseSessionToTranscribe)
                    .disabled(recorder.phase != .ready)
                Button("Show Recordings in Finder", systemImage: "folder", action: recorder.showRecordings)
                Button("Show Last Session in Finder", systemImage: "clock", action: recorder.showLastSession)
                    .disabled(recorder.lastSession == nil)
            } header: {
                Text("Library")
            } footer: {
                Text("Transcription runs offline on this Mac.")
            }
            .buttonStyle(.link)

            Section {
                Button(recorder.phase == .recording ? "Stop & Quit" : "Quit Audio Capture", action: recorder.quit)
                    .disabled(recorder.phase != .ready && recorder.phase != .recording)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(width: 460, height: 520)
        .onChange(of: recorder.source, initial: true) { _, source in
            if source == .application { recorder.refreshApps() }
        }
    }

    @ViewBuilder private var appSelection: some View {
        HStack(spacing: 8) {
            Picker("App", selection: $recorder.selectedApp) {
                Text(recorder.apps.isEmpty ? "No audio apps found" : "Choose an app").tag(String?.none)
                ForEach(recorder.apps) { app in
                    Text(app.name).tag(Optional(app.id))
                }
            }
            .disabled(recorder.apps.isEmpty)

            Button("Refresh audio apps", systemImage: "arrow.clockwise", action: recorder.refreshApps)
                .labelStyle(.iconOnly)
                .help("Refresh audio apps")
        }
        if let problem = recorder.appListProblem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var sourceDescription: String {
        switch recorder.source {
        case .application:
            return "Play audio in the app, then refresh the list."
        case .system:
            return "Record playback from all apps using Core Audio."
        case .screenKit:
            return "Record playback using ScreenCaptureKit. Requires screen recording access."
        }
    }
}
