import AVFoundation
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class MicrophoneInput {
    private let engine = AVAudioEngine()
    private var track: PCMTrack?
    private var observation: (any NSObjectProtocol)?

    var reading: TrackReading { track?.reading ?? TrackReading() }

    static func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
        default:
            break
        }
        throw CaptureError("Allow microphone access for Audio Capture in System Settings → Privacy & Security → Microphone.")
    }

    func start(url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw CaptureError("No microphone input is available.")
        }
        let track = try PCMTrack(url: url, format: format.streamDescription.pointee)
        self.track = track
        let receive: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            guard track.accepts(buffer.format.streamDescription.pointee) else {
                track.fail("The microphone format changed. Start a new recording.")
                return
            }
            track.write(buffer.audioBufferList, frames: buffer.frameLength)
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil, block: receive)
        observation = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            track.fail("The microphone device changed. Start a new recording.")
        }
        try engine.start()
    }

    func stop() -> String? {
        if let observation {
            NotificationCenter.default.removeObserver(observation)
            self.observation = nil
        }
        if let track {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            return track.close()
        }
        return nil
    }
}

@MainActor
final class ScreenAudioInput {
    private var stream: SCStream?
    private var output: ScreenAudioOutput?
    private var started = false

    var reading: TrackReading { output?.reading ?? TrackReading() }

    func start(url: URL) async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError("Allow Screen & System Audio Recording for Audio Capture in System Settings, then reopen the app if macOS asks.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw CaptureError("ScreenCaptureKit needs an available display.")
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = false
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 320
        configuration.height = 180
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let output = ScreenAudioOutput(url: url)
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: output
        )
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        self.output = output
        self.stream = stream
        try await stream.startCapture()
        started = true
    }

    func stop() async -> String? {
        var failure: String?
        if let stream, let output {
            if started {
                do {
                    try await stream.stopCapture()
                } catch {
                    failure = error.localizedDescription
                }
            }
            try? stream.removeStreamOutput(output, type: .audio)
        }
        stream = nil
        started = false
        return output?.finish() ?? failure
    }
}

private final class ScreenAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "AudioCapture.ScreenCaptureKit", qos: .userInitiated)
    private let url: URL

    // Read and write these fields on the sample handler queue.
    private var track: PCMTrack?
    private var failure: String?
    private var finished = false

    init(url: URL) {
        self.url = url
    }

    var reading: TrackReading {
        queue.sync {
            var reading = track?.reading ?? TrackReading()
            reading.error = reading.error ?? failure
            return reading
        }
    }

    func finish() -> String? {
        queue.sync {
            finished = true
            return track?.close() ?? failure
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async {
            self.failure = "ScreenCaptureKit stopped. \(error.localizedDescription)"
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !finished, failure == nil, sample.isValid, CMSampleBufferDataIsReady(sample),
              sample.numSamples > 0, let format = sample.formatDescription?.audioStreamBasicDescription else {
            return
        }
        do {
            if track == nil { track = try PCMTrack(url: url, format: format) }
            guard let track, track.accepts(format) else {
                throw CaptureError("The ScreenCaptureKit audio format changed. Start a new recording.")
            }
            try sample.withAudioBufferList { buffers, _ in
                track.write(buffers.unsafePointer, frames: UInt32(sample.numSamples))
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}
