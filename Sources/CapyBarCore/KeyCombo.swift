import Foundation

/// The global shortcut that opens the panel: a virtual key code plus modifiers.
///
/// Kept free of AppKit and Carbon so it can be stored, validated and shown in tests;
/// the app converts `NSEvent` modifier flags into `Modifiers` and registers the
/// combination with `carbonModifiers`.
public struct KeyCombo: Equatable, Sendable {

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        static let all: Modifiers = [.control, .option, .shift, .command]
    }

    /// Virtual key code (`kVK_*`), layout-independent.
    public let keyCode: UInt16
    public let modifiers: Modifiers
    /// What the key printed when it was recorded ("B", "7"); special keys get their
    /// symbol from `keyCode` instead. Kept so the label matches the user's layout.
    public let key: String

    public init?(keyCode: UInt16, modifiers: Modifiers, key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isAllowed(keyCode: keyCode, modifiers: modifiers),
            Self.specialKeys[keyCode] != nil || (!key.isEmpty && key.count <= Self.maxKeyLength)
        else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.all)
        self.key = Self.specialKeys[keyCode] ?? key
    }

    static let maxKeyLength = 4

    /// A shortcut must not swallow ordinary typing: it needs Command, Control or Option
    /// (Shift alone only changes the letter), except for F-keys. Escape is left alone,
    /// it closes things.
    public static func isAllowed(keyCode: UInt16, modifiers: Modifiers) -> Bool {
        guard keyCode < 128, keyCode != KeyCode.escape else { return false }
        if functionKeys.contains(keyCode) { return true }
        return !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    /// "⌃⌥⇧⌘B", the order macOS menus use.
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }

    /// Modifier mask for Carbon's `RegisterEventHotKey` (`cmdKey`, `shiftKey`, ...).
    public var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= 1 << 8 }
        if modifiers.contains(.shift) { mask |= 1 << 9 }
        if modifiers.contains(.option) { mask |= 1 << 11 }
        if modifiers.contains(.control) { mask |= 1 << 12 }
        return mask
    }

    /// What `NSMenuItem.keyEquivalent` needs to show this shortcut beside a menu item,
    /// the way macOS shows every shortcut: letters in lower case, special keys as the
    /// private-use characters AppKit draws as ←, F5 and so on.
    public var menuKeyEquivalent: String {
        if let scalar = Self.menuScalars[keyCode].flatMap(Unicode.Scalar.init) { return String(Character(scalar)) }
        return key.lowercased()
    }

    static let menuScalars: [UInt16: UInt32] = {
        var map: [UInt16: UInt32] = [
            36: 0x0D, 48: 0x09, 49: 0x20, 51: 0x08, 117: 0xF728, 115: 0xF729, 119: 0xF72B, 116: 0xF72C,
            121: 0xF72D, 126: 0xF700, 125: 0xF701, 123: 0xF702, 124: 0xF703,
        ]
        // F1–F20 in order: NSF1FunctionKey is 0xF704.
        let fKeys: [UInt16] = [
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        ]
        for (offset, code) in fKeys.enumerated() { map[code] = 0xF704 + UInt32(offset) }
        return map
    }()

    // MARK: - Storage

    /// Plist form; read back with `init?(plist:)`, which re-validates everything.
    public var plist: [String: Any] {
        ["keyCode": Int(keyCode), "modifiers": modifiers.rawValue, "key": key]
    }

    public init?(plist: [String: Any]) {
        guard let code = plist["keyCode"] as? Int, (0..<128).contains(code),
            let raw = plist["modifiers"] as? Int, let key = plist["key"] as? String
        else { return nil }
        self.init(keyCode: UInt16(code), modifiers: Modifiers(rawValue: raw), key: key)
    }

    // MARK: - Keys

    public enum KeyCode {
        public static let escape: UInt16 = 53
        public static let delete: UInt16 = 51
        public static let forwardDelete: UInt16 = 117
    }

    static let functionKeys: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,  // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90,  // F13–F20
    ]

    /// Keys whose printed character is empty or misleading.
    static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}
