import Carbon

@MainActor
final class DictationShortcut {
    private static let identifier = EventHotKeyID(signature: 0x41436170, id: 1)
    private let action: @MainActor () -> Void
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var isPressed = false

    init(action: @escaping @MainActor () -> Void) throws {
        self.action = action
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                // Application event handlers run on the main thread.
                return MainActor.assumeIsolated {
                    let shortcut = Unmanaged<DictationShortcut>.fromOpaque(context).takeUnretainedValue()
                    return shortcut.handle(event)
                }
            },
            eventTypes.count, &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard handlerStatus == noErr else {
            throw CaptureError("Could not set up Option–Space (macOS \(handlerStatus)).")
        }

        let keyStatus = RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(optionKey), Self.identifier, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &hotKey
        )
        guard keyStatus == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            throw CaptureError("Option–Space is unavailable (macOS \(keyStatus)). Close another app using that shortcut, then reopen Audio Capture.")
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
        )
        guard status == noErr, identifier.signature == Self.identifier.signature,
              identifier.id == Self.identifier.id else { return OSStatus(eventNotHandledErr) }

        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            guard !isPressed else { return noErr }
            isPressed = true
            action()
        case UInt32(kEventHotKeyReleased):
            isPressed = false
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
