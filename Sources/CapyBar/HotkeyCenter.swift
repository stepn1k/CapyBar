import AppKit
import CapyBarCore
import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "app.capybar.CapyBar", category: "hotkey")

/// The global shortcut, through Carbon's `RegisterEventHotKey`: it needs no Input
/// Monitoring or Accessibility permission and never sees any other keystroke.
@MainActor
final class HotkeyCenter {

    static let shared = HotkeyCenter()

    /// Runs on the main thread when the shortcut is pressed.
    var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature = OSType(0x4361_7079)  // 'Capy'

    /// Replaces the registered shortcut; nil unregisters it. Returns false when macOS
    /// refuses the combination (the system or this app already uses it).
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        unregister()
        guard let combo else { return true }
        guard installHandler() else { return false }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode), combo.carbonModifiers, EventHotKeyID(signature: Self.signature, id: 1),
            GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            logger.error("shortcut \(combo.displayString, privacy: .public) refused: \(status, privacy: .public)")
            return false
        }
        hotKey = ref
        logger.info("shortcut \(combo.displayString, privacy: .public) registered")
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ in
                // Carbon calls this on the main thread, from the main event loop.
                Task { @MainActor in
                    logger.info("shortcut pressed")
                    HotkeyCenter.shared.onPress?()
                }
                return noErr
            }, 1, &spec, nil, &handler)
        return status == noErr
    }
}

extension KeyCombo.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}

extension KeyCombo {
    /// For `NSMenuItem.keyEquivalentModifierMask`.
    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    /// The combination of a key-down event, if it is allowed as a shortcut.
    init?(event: NSEvent) {
        self.init(
            keyCode: event.keyCode, modifiers: Modifiers(event.modifierFlags),
            key: event.charactersIgnoringModifiers ?? "")
    }
}
