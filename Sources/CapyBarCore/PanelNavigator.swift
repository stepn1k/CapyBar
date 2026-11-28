import Foundation

/// Everything the keyboard does in the panel, as plain state: the view sends keys in and
/// acts on what comes back. Kept out of SwiftUI so every path can be tested.
///
/// The icons sit in a grid of `columns`; the selection moves with the arrow keys. Typing
/// (or ⌘F) opens the search field; the text filters the icons (`PanelSearch`) and selects
/// the best match. Return opens the selection. Escape closes the search first and the
/// panel second.
public struct PanelNavigator: Equatable, Sendable {

    public enum Key: Equatable, Sendable {
        /// Printable text; anything else (control characters) is ignored.
        case text(String)
        case deleteBackward
        case left, right, up, down
        case returnKey
        case escape
    }

    public enum Effect: Equatable, Sendable {
        /// The key changed the state (or was deliberately swallowed).
        case handled
        /// Not ours: let the system have it.
        case ignored
        /// Open the icon at this index of the full, unfiltered list.
        case open(Int)
        case close
    }

    public static let maxQueryLength = 64

    /// The titles of every icon in the panel, in panel order.
    public private(set) var titles: [String]
    public private(set) var query = ""
    /// Indices into `titles` that match the query, best first: what the panel shows.
    public private(set) var results: [Int]
    /// Position in `results`; nil until the keyboard is used.
    public private(set) var selection: Int?
    /// The search field is showing (typing or ⌘F opened it), possibly still empty.
    public private(set) var isSearchFieldOpen = false
    public var columns: Int

    public init(titles: [String] = [], columns: Int = 1) {
        self.titles = titles
        self.columns = max(1, columns)
        results = Array(titles.indices)
    }

    /// The full-list index of the selected icon.
    public var selectedIndex: Int? { selection.map { results[$0] } }

    public var isSearching: Bool { !query.isEmpty }

    /// The panel's icons changed (an app quit, a scan finished): keep the query and,
    /// if it is still there, the selected icon.
    public mutating func update(titles newTitles: [String]) {
        let selectedTitle = selectedIndex.map { titles[$0] }
        titles = newTitles
        refilter(keeping: selectedTitle)
    }

    /// Back to the start, for a panel that closed.
    public mutating func reset() {
        query = ""
        selection = nil
        isSearchFieldOpen = false
        results = Array(titles.indices)
    }

    /// ⌘F: show the search field without typing anything yet.
    public mutating func openSearch() {
        isSearchFieldOpen = true
        beginKeyboardUse()
    }

    /// Escape or the field's close button: every icon is back, the selected one stays.
    public mutating func closeSearch() {
        let selectedTitle = selectedIndex.map { titles[$0] }
        query = ""
        isSearchFieldOpen = false
        refilter(keeping: selectedTitle)
    }

    /// ⌘V: the pasted text is added to the query.
    public mutating func paste(_ text: String) {
        isSearchFieldOpen = true
        setQuery(query + text)
    }

    /// The panel opened from the keyboard: show where Return would go.
    public mutating func beginKeyboardUse() {
        if selection == nil, !results.isEmpty { selection = 0 }
    }

    /// The search field was edited directly (typing in it, pasting, deleting a range).
    public mutating func setQuery(_ text: String) {
        var clean = String(text.filter(Self.isPrintable).prefix(Self.maxQueryLength))
        if clean.allSatisfy(\.isWhitespace) { clean = "" }
        guard clean != query else { return }
        query = clean
        refilter(keeping: nil)
    }

    public mutating func handle(_ key: Key) -> Effect {
        switch key {
        case .text(let text):
            let printable = text.filter(Self.isPrintable)
            guard !printable.isEmpty else { return .ignored }
            // A leading space would only hide everything; ignore it like Spotlight does.
            guard !(query.isEmpty && printable.allSatisfy(\.isWhitespace)) else { return .handled }
            guard query.count + printable.count <= Self.maxQueryLength else { return .handled }
            query += printable
            isSearchFieldOpen = true
            refilter(keeping: nil)
            return .handled
        case .deleteBackward:
            guard !query.isEmpty else { return isSearchFieldOpen ? .handled : .ignored }
            query.removeLast()
            refilter(keeping: nil)
            return .handled
        case .left: return move(by: -1)
        case .right: return move(by: 1)
        case .up: return move(by: -columns)
        case .down: return move(by: columns)
        case .returnKey:
            guard !results.isEmpty else { return .handled }
            return .open(results[selection ?? 0])
        case .escape:
            guard isSearchFieldOpen || isSearching else { return .close }
            closeSearch()
            return .handled
        }
    }

    private static func isPrintable(_ character: Character) -> Bool {
        !character.isNewline && !character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Left and right step through the icons and wrap around; up and down move a whole
    /// row and stop at the edges, like any grid.
    private mutating func move(by step: Int) -> Effect {
        guard !results.isEmpty else { return .handled }
        guard let current = selection else {
            selection = step < 0 ? results.count - 1 : 0
            return .handled
        }
        if abs(step) == 1 {
            selection = (current + step + results.count) % results.count
        } else {
            let target = current + step
            // Down from the row above a short last row lands on its last icon.
            if target >= results.count {
                let lastRowStart = (results.count - 1) / columns * columns
                if current < lastRowStart { selection = results.count - 1 }
            } else if target >= 0 {
                selection = target
            }
        }
        return .handled
    }

    private mutating func refilter(keeping title: String?) {
        results = PanelSearch.matches(query, in: titles)
        if let title, let position = results.firstIndex(where: { titles[$0] == title }) {
            selection = position
        } else if isSearching {
            selection = results.isEmpty ? nil : 0  // the best match is what Return opens
        } else {
            selection = selection.flatMap { $0 < results.count ? $0 : (results.isEmpty ? nil : results.count - 1) }
        }
    }
}

/// What a key-down means while the panel is open. Kept apart from AppKit so it can be
/// tested: the app passes the event's key code, characters and modifiers.
public enum PanelKeyRoute: Equatable, Sendable {
    /// For `PanelNavigator.handle`.
    case key(PanelNavigator.Key)
    /// ⌘F.
    case openSearch
    /// ⌘V.
    case paste
    /// Not the panel's: menus, other shortcuts, keys with no meaning here.
    case passThrough

    /// Key codes are layout-independent, so ⌘F works with any keyboard layout.
    public init(keyCode: UInt16, characters: String, modifiers: KeyCombo.Modifiers) {
        if modifiers.contains(.command) {
            switch keyCode {
            case 3 where modifiers == [.command]: self = .openSearch
            case 9 where modifiers == [.command]: self = .paste
            default: self = .passThrough
            }
            return
        }
        // ⌃ and ⌥ combinations type symbols or belong to other shortcuts.
        guard modifiers.isDisjoint(with: [.control, .option]) else {
            self = .passThrough
            return
        }
        switch keyCode {
        case 126: self = .key(.up)
        case 125: self = .key(.down)
        case 123: self = .key(.left)
        case 124: self = .key(.right)
        case 36, 76: self = .key(.returnKey)
        case 53: self = .key(.escape)
        case 51: self = .key(.deleteBackward)
        // Tab, forward delete, Home/End, Page Up/Down, F-keys: nothing here.
        case 48, 117, 115, 119, 116, 121, 114: self = .passThrough
        case _ where KeyCombo.functionKeys.contains(keyCode): self = .passThrough
        default:
            // Function-key characters (arrows on other keyboards and the like) are in
            // Unicode's private-use area: not text.
            let isText =
                !characters.isEmpty && !characters.unicodeScalars.contains { (0xF700...0xF8FF).contains($0.value) }
            self = isText ? .key(.text(characters)) : .passThrough
        }
    }
}

/// How many fixed-size cells fit in a row.
public enum GridLayout {
    public static func columns(width: Double, cell: Double, spacing: Double) -> Int {
        guard cell > 0, width >= cell else { return 1 }
        return max(1, Int(((width + spacing) / (cell + spacing)).rounded(.down)))
    }
}
