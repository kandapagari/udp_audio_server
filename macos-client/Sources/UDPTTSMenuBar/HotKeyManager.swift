import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hotkey via Carbon's `RegisterEventHotKey`.
///
/// Unlike `NSEvent.addGlobalMonitorForEvents`, this needs no Accessibility
/// permission and fires whether or not the app is frontmost. The default
/// combination is ⌃⌥S (Control-Option-S).
final class HotKeyManager {
    static let defaultDescription = "⌃⌥S"

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    /// `keyCode` is a virtual key code (e.g. `kVK_ANSI_S`); `modifiers` is a
    /// Carbon mask (`controlKey`, `optionKey`, …). Returns nil if registration
    /// fails (e.g. the combo is already taken).
    init?(keyCode: UInt32 = UInt32(kVK_ANSI_S),
          modifiers: UInt32 = UInt32(controlKey | optionKey),
          action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData = userData else { return noErr }
                Unmanaged<HotKeyManager>.fromOpaque(userData)
                    .takeUnretainedValue().action()
                return noErr
            },
            1, &eventType, selfPtr, &eventHandler)
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x55545453) /* 'UTTS' */, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef = hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) }
    }
}
