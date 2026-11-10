import AppKit
import CoreAudio
import Foundation

struct AudioApplication: Identifiable {
    let id: String
    let name: String
    let processes: [AudioObjectID]
    let playing: Bool
}

private let audioSystem = AudioObjectID(kAudioObjectSystemObject)

private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

private func readAudioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  into value: inout T) -> OSStatus {
    var address = property(selector)
    return withUnsafeMutableBytes(of: &value) { bytes in
        var size = UInt32(bytes.count)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
    }
}

private func bundleID(of object: AudioObjectID) -> String? {
    var bundle: Unmanaged<CFString>?
    guard readAudioProperty(object, kAudioProcessPropertyBundleID, into: &bundle) == noErr else {
        return nil
    }
    return bundle?.takeRetainedValue() as String?
}

private func executablePath(for pid: pid_t) -> String? {
    var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = bytes.withUnsafeMutableBytes { buffer in
        proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
    }
    guard length > 0 else { return nil }
    return bytes.withUnsafeBufferPointer { String(validatingCString: $0.baseAddress!) }
}

@MainActor
func audioApplications() throws -> [AudioApplication] {
    var address = property(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    try checkAudio(AudioObjectGetPropertyDataSize(audioSystem, &address, 0, nil, &size),
                   "Finding Core Audio processes")
    guard size > 0 else { return [] }
    let stride = MemoryLayout<AudioObjectID>.stride
    var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / stride)
    let status = objects.withUnsafeMutableBytes { buffer in
        AudioObjectGetPropertyData(audioSystem, &address, 0, nil, &size, buffer.baseAddress!)
    }
    try checkAudio(status, "Reading Core Audio processes")

    let apps = NSWorkspace.shared.runningApplications
    let appPaths = apps.compactMap { app -> (path: String, app: NSRunningApplication)? in
        guard let path = app.bundleURL?.path, path.hasSuffix(".app") else { return nil }
        return (path, app)
    }.sorted { $0.path.count < $1.path.count }
    var groups: [String: AudioApplication] = [:]

    for object in objects.prefix(Int(size) / stride) {
        var pid: pid_t = 0
        guard readAudioProperty(object, kAudioProcessPropertyPID, into: &pid) == noErr,
              pid > 0, pid != getpid() else { continue }
        var active: UInt32 = 0
        _ = readAudioProperty(object, kAudioProcessPropertyIsRunningOutput, into: &active)
        let path = executablePath(for: pid)
        let bundle = bundleID(of: object)
        let owner = path.flatMap { path in appPaths.first { path.hasPrefix($0.path + "/") }?.app }
            ?? apps.first { $0.processIdentifier == pid }
            ?? bundle.flatMap { bundle in apps.first { $0.bundleIdentifier == bundle } }
        let key = owner?.bundleURL?.path ?? bundle ?? "pid:\(pid)"
        let name = owner?.localizedName ?? bundle ?? path.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? "Process \(pid)"
        let existing = groups[key]
        groups[key] = AudioApplication(id: key, name: name,
                                       processes: (existing?.processes ?? []) + [object],
                                       playing: active != 0 || existing?.playing == true)
    }
    return groups.values.sorted {
        let order = $0.name.localizedStandardCompare($1.name)
        return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
}

final class ProcessTap: @unchecked Sendable {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var io: AudioDeviceIOProcID?
    private var started = false
    private var track: PCMTrack?

    var reading: TrackReading { track?.reading ?? TrackReading() }

    // Lifecycle calls are serialized by the controller. The IO block owns only the track.
    func start(processes: [AudioObjectID]?, url: URL) throws {
        let description: CATapDescription
        if let processes {
            description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.isProcessRestoreEnabled = true
        } else {
            var address = property(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var pid = getpid()
            var object = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = AudioObjectGetPropertyData(
                audioSystem, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
            )
            let exclusions = status == noErr && object != kAudioObjectUnknown ? [object] : []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclusions)
        }
        description.name = "Audio Capture"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try checkAudio(AudioHardwareCreateProcessTap(description, &tap), "Creating the process tap")
        var uid: Unmanaged<CFString>?
        try checkAudio(readAudioProperty(tap, kAudioTapPropertyUID, into: &uid), "Reading the process tap ID")
        guard let uid else { throw CaptureError("Core Audio did not provide a tap identifier.") }
        let tapUID = uid.takeRetainedValue() as String
        var format = AudioStreamBasicDescription()
        try checkAudio(readAudioProperty(tap, kAudioTapPropertyFormat, into: &format),
                       "Reading the process tap format")
        let track = try PCMTrack(url: url, format: format)
        self.track = track

        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Audio Capture Input",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try checkAudio(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &device),
                       "Creating the private audio device")
        try checkAudio(AudioDeviceCreateIOProcIDWithBlock(&io, device, nil) { _, input, _, _, _ in
            track.write(input)
        }, "Connecting the process tap")
        guard let io else { throw CaptureError("Core Audio did not provide an input callback.") }
        let status = AudioDeviceStart(device, io)
        guard status == noErr else {
            throw CaptureError("The process tap could not start (Core Audio \(status)). Check System Audio Recording permission in System Settings.")
        }
        started = true
    }

    func stop() -> String? {
        var errors: [String] = []
        func clean(_ status: OSStatus, _ operation: String) {
            if status != noErr { errors.append("\(operation) failed (Core Audio \(status)).") }
        }

        if let io {
            if started { clean(AudioDeviceStop(device, io), "Stopping the process tap") }
            clean(AudioDeviceDestroyIOProcID(device, io), "Removing the audio callback")
        }
        if device != kAudioObjectUnknown {
            clean(AudioHardwareDestroyAggregateDevice(device), "Removing the private audio device")
        }
        if tap != kAudioObjectUnknown {
            clean(AudioHardwareDestroyProcessTap(tap), "Removing the process tap")
        }
        if let error = track?.close() { errors.append(error) }
        io = nil
        started = false
        device = kAudioObjectUnknown
        tap = kAudioObjectUnknown
        return errors.isEmpty ? nil : errors.joined(separator: " ")
    }

    deinit {
        _ = stop()
    }
}
