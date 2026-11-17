import Carbon

enum DictationKey: String, CaseIterable {
    case optionSpace
    case controlShiftSpace

    var name: String {
        switch self {
        case .optionSpace: "Option–Space"
        case .controlShiftSpace: "Control–Shift–Space"
        }
    }

    var symbols: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlShiftSpace: "⌃⇧ Space"
        }
    }

    fileprivate var modifiers: UInt32 {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlShiftSpace: UInt32(controlKey | shiftKey)
        }
    }
}

@MainActor
final class DictationShortcut {
    let key: DictationKey
    private var identifier: EventHotKeyID { EventHotKeyID(signature: 0x41436170, id: key.modifiers) }
    private let onPress: @MainActor () -> Void
    private let onRelease: @MainActor () -> Void
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var isPressed = false

    init(
        key: DictationKey,
        onPress: @escaping @MainActor () -> Void,
        onRelease: @escaping @MainActor () -> Void
    ) throws {
        self.key = key
        self.onPress = onPress
        self.onRelease = onRelease
        let target = GetEventDispatcherTarget()
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let handlerStatus = InstallEventHandler(
            target,
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                // The AppKit event loop calls the dispatcher on the main thread.
                return MainActor.assumeIsolated {
                    let shortcut = Unmanaged<DictationShortcut>.fromOpaque(context).takeUnretainedValue()
                    return shortcut.handle(event)
                }
            },
            eventTypes.count, &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard handlerStatus == noErr else {
            throw CaptureError("Could not set up \(key.name) (macOS \(handlerStatus)).")
        }

        let keyStatus = RegisterEventHotKey(
            UInt32(kVK_Space), key.modifiers, identifier, target,
            OptionBits(kEventHotKeyExclusive), &hotKey
        )
        guard keyStatus == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            if keyStatus == eventHotKeyExistsErr {
                throw CaptureError("\(key.name) is already in use. Choose another shortcut.")
            }
            throw CaptureError("\(key.name) could not be registered (macOS \(keyStatus)).")
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var eventIdentifier = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &eventIdentifier
        )
        guard status == noErr, eventIdentifier.signature == identifier.signature,
              eventIdentifier.id == identifier.id else { return OSStatus(eventNotHandledErr) }

        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            guard !isPressed else { return noErr }
            isPressed = true
            onPress()
        case UInt32(kEventHotKeyReleased):
            guard isPressed else { return noErr }
            isPressed = false
            onRelease()
        default:
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
