import Foundation
import WhisperKit

enum RecordingTrack: String, CaseIterable {
    case system
    case microphone

    var title: String {
        switch self {
        case .system: "System audio"
        case .microphone: "Microphone"
        }
    }

    func audioURL(in session: URL) -> URL {
        session.appendingPathComponent(rawValue + ".caf")
    }

    func transcriptURL(in session: URL) -> URL {
        session.appendingPathComponent(rawValue + ".txt")
    }
}

struct TranscriptionSummary {
    var savedCount = 0
    var errors: [String] = []
}

actor SessionTranscriber {
    private let resources: URL?
    private var pipeline: WhisperKit?

    init(resources: URL? = Bundle.main.resourceURL?.appending(path: "WhisperKit")) {
        self.resources = resources
    }

    func transcribe(
        session: URL,
        progress: @MainActor @Sendable (String) -> Void
    ) async throws -> TranscriptionSummary {
        let tracks = RecordingTrack.allCases.filter { track in
            let values = try? track.audioURL(in: session).resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
        guard !tracks.isEmpty else {
            throw CaptureError("Choose a session folder containing system.caf or microphone.caf.")
        }
        let pending = tracks.filter { !FileManager.default.fileExists(atPath: $0.transcriptURL(in: session).path) }
        guard !pending.isEmpty else { return TranscriptionSummary() }

        await progress("Preparing Whisper Base model…")
        let pipeline = try await prepareModel()
        let inputOptions = AudioInputOptions(audioLoadingMode: .incremental)
        let decodingOptions = DecodingOptions(
            detectLanguage: true,
            skipSpecialTokens: true,
            chunkingStrategy: .vad
        )

        var summary = TranscriptionSummary()
        for track in pending {
            try Task.checkCancellation()
            await progress("Transcribing \(track.title.lowercased())…")
            do {
                let results = try await pipeline.transcribe(
                    audioPath: track.audioURL(in: session).path,
                    audioInputOptions: inputOptions,
                    decodeOptions: decodingOptions
                )
                try Task.checkCancellation()
                let lines = results.flatMap(\.segments).compactMap { segment -> String? in
                    let speech = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !speech.isEmpty else { return nil }
                    return "[\(timestamp(segment.start))] \(speech)"
                }
                let text = lines.isEmpty ? "No speech detected.\n" : lines.joined(separator: "\n") + "\n"

                // Move a complete file into place without replacing an existing transcript.
                let temporary = session.appendingPathComponent(".\(UUID().uuidString).transcript")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try text.write(to: temporary, atomically: true, encoding: .utf8)
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: temporary, to: track.transcriptURL(in: session))
                summary.savedCount += 1
            } catch {
                try Task.checkCancellation()
                summary.errors.append("\(track.title) transcription failed. \(error.localizedDescription)")
            }
        }
        return summary
    }

    private func prepareModel() async throws -> WhisperKit {
        if let pipeline { return pipeline }
        try Task.checkCancellation()
        guard let resources else {
            throw CaptureError("Whisper Base files are missing. Extract a fresh copy of Audio Capture.")
        }
        let modelFolder = resources.appending(path: "models/argmaxinc/whisperkit-coreml/openai_whisper-base")
        let tokenizerFolder = resources.appending(path: "models/openai/whisper-base")
        let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]
        guard tokenizerFiles.allSatisfy({
            FileManager.default.fileExists(atPath: tokenizerFolder.appending(path: $0).path)
        }) else {
            throw CaptureError("Whisper Base tokenizer files are missing. Extract a fresh copy of Audio Capture.")
        }

        #if arch(x86_64)
        let compute = ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly,
                                          textDecoderCompute: .cpuOnly)
        #else
        let compute = ModelComputeOptions()
        #endif

        do {
            let loaded = try await WhisperKit(WhisperKitConfig(
                modelFolder: modelFolder.path,
                tokenizerFolder: tokenizerFolder,
                computeOptions: compute,
                verbose: false,
                load: true,
                download: false
            ))
            try Task.checkCancellation()
            pipeline = loaded
            return loaded
        } catch {
            try Task.checkCancellation()
            throw CaptureError("Could not load the bundled Whisper Base files. \(error.localizedDescription)")
        }
    }

    private func timestamp(_ offset: Float) -> String {
        let seconds = Int64(offset.isFinite ? max(0, offset) : 0)
        return String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
