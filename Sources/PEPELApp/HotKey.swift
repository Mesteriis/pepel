import AppKit
import Carbon.HIToolbox

/// One global shortcut, Control-Option-Command-M, registered through the system hot key service.
/// That service needs no Accessibility permission and never sees other keystrokes.
@MainActor
final class HotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    nonisolated(unsafe) private static var action: (@MainActor @Sendable () -> Void)?

    var isRegistered: Bool { hotKey != nil }

    func register(_ action: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard hotKey == nil else { return true }
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
                return noErr
            }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x5045_504C), id: 1)  // "PEPL"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { unregister() }
        return status == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
