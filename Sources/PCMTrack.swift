import Accelerate
import AudioToolbox
import Foundation
import os

struct CaptureError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

func checkAudio(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw CaptureError("\(operation) failed (Core Audio \(status)).")
    }
}

struct TrackReading {
    var frames: UInt64 = 0
    var peak: Float = 0
    var lastBuffer: UInt64 = 0
    var error: String?

    var level: Double {
        guard peak.isFinite, peak > 0,
              DispatchTime.now().uptimeNanoseconds &- lastBuffer < 500_000_000 else { return 0 }
        let decibels = 20 * log10(Double(peak))
        return max(0, min(1, (decibels + 60) / 60))
    }
}

// One producer per track. The lock also protects closure and UI reads.
final class PCMTrack: @unchecked Sendable {
    private struct State {
        var file: ExtAudioFileRef?
        var reading = TrackReading()
    }

    private let state: OSAllocatedUnfairLock<State>
    private let url: URL
    private let format: AudioStreamBasicDescription
    private let bufferCount: Int
    private let channelsPerBuffer: UInt32

    init(url: URL, format: AudioStreamBasicDescription) throws {
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = planar ? 1 : format.mChannelsPerFrame
        guard format.mSampleRate > 0, format.mSampleRate.isFinite,
              format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= 64,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32, format.mBytesPerFrame == channels * 4 else {
            throw CaptureError("This input uses an unsupported PCM format.")
        }

        self.url = url
        self.format = format
        bufferCount = planar ? Int(format.mChannelsPerFrame) : 1
        channelsPerBuffer = channels
        let frameSize = format.mChannelsPerFrame * 4
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: frameSize,
            mFramesPerPacket: 1,
            mBytesPerFrame: frameSize,
            mChannelsPerFrame: format.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var file: ExtAudioFileRef?
        try checkAudio(ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileCAFType, &fileFormat, nil, 0, &file
        ), "Creating \(url.lastPathComponent)")
        guard let file else { throw CaptureError("Could not create \(url.lastPathComponent).") }

        do {
            var clientFormat = format
            try checkAudio(ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat
            ), "Configuring \(url.lastPathComponent)")
            // Prime Core Audio's asynchronous writer before any real-time callbacks.
            try checkAudio(ExtAudioFileWriteAsync(file, 0, nil), "Preparing \(url.lastPathComponent)")
        } catch {
            ExtAudioFileDispose(file)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        state = OSAllocatedUnfairLock(uncheckedState: State(file: file))
    }

    var reading: TrackReading {
        state.withLockUnchecked { $0.reading }
    }

    func accepts(_ candidate: AudioStreamBasicDescription) -> Bool {
        format.mSampleRate == candidate.mSampleRate &&
        format.mFormatID == candidate.mFormatID &&
        format.mFormatFlags == candidate.mFormatFlags &&
        format.mChannelsPerFrame == candidate.mChannelsPerFrame &&
        format.mBytesPerFrame == candidate.mBytesPerFrame &&
        format.mBitsPerChannel == candidate.mBitsPerChannel
    }

    func fail(_ message: String) {
        state.withLockUnchecked { state in
            if state.reading.error == nil { state.reading.error = message }
        }
    }

    func write(_ list: UnsafePointer<AudioBufferList>, frames: UInt32? = nil) {
        guard list.pointee.mNumberBuffers > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let first = buffers[0]
        let frameCount = frames ?? first.mDataByteSize / format.mBytesPerFrame
        guard frameCount > 0 else { return }

        let byteCount = UInt64(frameCount) * UInt64(format.mBytesPerFrame)
        guard buffers.count == bufferCount,
              buffers.allSatisfy({ buffer in
                  buffer.mNumberChannels == channelsPerBuffer &&
                  buffer.mDataByteSize == byteCount && buffer.mData != nil
              }) else {
            fail("The audio buffer layout changed. Start a new recording.")
            return
        }

        var peak: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            var channelPeak: Float = 0
            vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &channelPeak,
                        vDSP_Length(buffer.mDataByteSize / 4))
            peak = max(peak, channelPeak)
        }

        state.withLockUnchecked { state in
            guard let file = state.file, state.reading.error == nil else { return }
            let status = ExtAudioFileWriteAsync(file, frameCount, list)
            guard status == noErr else {
                state.reading.error = "Writing \(url.lastPathComponent) failed (Core Audio \(status))."
                return
            }
            state.reading.frames += UInt64(frameCount)
            state.reading.peak = peak
            state.reading.lastBuffer = DispatchTime.now().uptimeNanoseconds
        }
    }

    @discardableResult
    func close() -> String? {
        let file = state.withLockUnchecked { state in
            let file = state.file
            state.file = nil
            return file
        }
        guard let file else { return reading.error }
        let status = ExtAudioFileDispose(file)
        if status != noErr {
            fail("Closing \(url.lastPathComponent) failed (Core Audio \(status)).")
        } else if reading.frames == 0 {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                fail("Removing the empty \(url.lastPathComponent) failed. \(error.localizedDescription)")
            }
        }
        return reading.error
    }

    deinit {
        close()
    }
}
