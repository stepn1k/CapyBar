import CapyBarCore
import Foundation

// The panel driven only from the keyboard: arrows, typing, Return, Escape, Delete.

@MainActor
func keyboardTests() {
    let titles = ["Raycast", "Dropbox", "iStat Menus", "1Password", "Slack", "Stats", "Shottr", "LuLu", "Codex"]
    func navigator(columns: Int = 4) -> PanelNavigator { PanelNavigator(titles: titles, columns: columns) }
    func type(_ text: String, into nav: inout PanelNavigator) {
        for character in text { _ = nav.handle(.text(String(character))) }
    }
    func title(_ nav: PanelNavigator) -> String? { nav.selectedIndex.map { titles[$0] } }

    section("Keyboard: opening the panel")
    do {
        var nav = navigator()
        check(nav.selection == nil, "opened by a click: nothing is selected")
        nav.beginKeyboardUse()
        check(title(nav) == "Raycast", "opened by the shortcut: the first icon is selected")
        check(nav.handle(.returnKey) == .open(0), "Return right away opens the first icon")
        var empty = PanelNavigator(titles: [], columns: 4)
        empty.beginKeyboardUse()
        check(empty.selection == nil, "an empty panel selects nothing")
        check(
            empty.handle(.returnKey) == .handled && empty.handle(.down) == .handled, "keys on an empty panel do nothing"
        )
    }

    section("Keyboard: arrows move through the grid (4 columns, 9 icons)")
    do {
        var nav = navigator()
        check(nav.handle(.right) == .handled && title(nav) == "Raycast", "first arrow selects the first icon")
        _ = nav.handle(.right)
        check(title(nav) == "Dropbox", "→ next icon")
        _ = nav.handle(.left)
        _ = nav.handle(.left)
        check(title(nav) == "Codex", "← from the first wraps to the last")
        _ = nav.handle(.right)
        check(title(nav) == "Raycast", "→ from the last wraps to the first")
        _ = nav.handle(.down)
        check(title(nav) == "Slack", "↓ one row down")
        _ = nav.handle(.down)
        check(title(nav) == "Codex", "↓ again into the last row")
        _ = nav.handle(.down)
        check(title(nav) == "Codex", "↓ in the last row stays")
        _ = nav.handle(.up)
        _ = nav.handle(.up)
        _ = nav.handle(.up)
        check(title(nav) == "Raycast", "↑ stops at the top row")

        var short = navigator()
        for _ in 0..<7 { _ = short.handle(.right) }  // index 6, Shottr, middle row
        check(title(short) == "Shottr", "set up: third icon of the second row")
        _ = short.handle(.down)
        check(title(short) == "Codex", "↓ above the short last row lands on its last icon")
        var fresh = navigator()
        _ = fresh.handle(.left)
        check(title(fresh) == "Codex", "a first ← selects the last icon")
        var up = navigator()
        _ = up.handle(.up)
        check(title(up) == "Codex", "a first ↑ selects the last icon too")
    }

    section("Keyboard: typing filters")
    do {
        var nav = navigator()
        type("st", into: &nav)
        check(nav.query == "st" && nav.isSearching, "typed text becomes the query")
        // "Stats" starts with it; the two that only contain it keep their panel order.
        check(nav.results.map { titles[$0] } == ["Stats", "Raycast", "iStat Menus"], "only matches, best first")
        check(title(nav) == "Stats", "the best match is selected")
        check(nav.handle(.returnKey) == .open(5), "Return opens it by its index in the full list")
        _ = nav.handle(.right)
        check(title(nav) == "Raycast", "arrows move among the matches")
        check(nav.handle(.returnKey) == .open(0), "Return opens the selected match")

        type("x", into: &nav)
        check(nav.results.isEmpty && nav.selection == nil, "no match: nothing selected")
        check(nav.handle(.returnKey) == .handled, "Return with no match does nothing")
        check(nav.handle(.deleteBackward) == .handled && nav.query == "st", "Delete removes the last letter")
        check(title(nav) == "Stats", "matches are back, best one selected")
        _ = nav.handle(.deleteBackward)
        _ = nav.handle(.deleteBackward)
        check(nav.query.isEmpty && nav.results.count == titles.count, "deleting everything shows every icon again")
        check(nav.handle(.deleteBackward) == .handled, "Delete in the emptied field is swallowed, no beep")
        var closed = navigator()
        check(closed.handle(.deleteBackward) == .ignored, "Delete with no search at all is not ours")
    }

    section("Keyboard: text that is not a search")
    do {
        var nav = navigator()
        check(nav.handle(.text(" ")) == .handled && nav.query.isEmpty, "a leading space is ignored")
        check(nav.handle(.text("\u{7F}")) == .ignored, "control characters are not typed")
        check(nav.handle(.text("\r")) == .ignored, "a newline is not typed")
        type("ray cast", into: &nav)
        check(nav.query == "ray cast", "spaces inside the query are kept")
        var long = navigator()
        type(String(repeating: "a", count: 100), into: &long)
        check(long.query.count == PanelNavigator.maxQueryLength, "the query has a length limit")
    }

    section("Keyboard: editing the search field directly")
    do {
        var nav = navigator()
        nav.setQuery("drop")
        check(nav.query == "drop" && title(nav) == "Dropbox", "a pasted query filters and selects the best match")
        nav.setQuery("dr\nop")
        check(nav.query == "drop", "line breaks in pasted text are dropped")
        nav.setQuery("   ")
        check(nav.query.isEmpty && nav.results.count == titles.count, "a blank field is no search")
        nav.setQuery(String(repeating: "b", count: 200))
        check(nav.query.count == PanelNavigator.maxQueryLength, "a long paste is cut to the limit")
    }

    section("Keyboard: Escape")
    do {
        var nav = navigator()
        type("drop", into: &nav)
        check(nav.handle(.escape) == .handled, "Escape while searching is handled")
        check(nav.query.isEmpty && nav.results.count == titles.count, "it clears the search")
        check(title(nav) == "Dropbox", "and keeps the icon that was selected")
        check(nav.handle(.escape) == .close, "Escape again closes the panel")
        nav.reset()
        check(nav.query.isEmpty && nav.selection == nil, "closing resets query and selection")
    }

    section("Keyboard: the icons change while the panel is open")
    do {
        var nav = navigator()
        _ = nav.handle(.right)
        _ = nav.handle(.right)  // Dropbox
        nav.update(titles: ["Raycast", "Slack", "Dropbox"])
        check(nav.selectedIndex == 2, "the selected icon stays selected at its new place")
        nav.update(titles: ["Raycast"])
        check(nav.selectedIndex == 0, "its icon gone: the selection moves to an icon that is left")
        nav.update(titles: [])
        check(nav.selection == nil, "no icons: no selection")

        var searching = navigator()
        type("s", into: &searching)
        searching.update(titles: ["Slack", "Raycast"])
        check(
            searching.query == "s" && searching.results.map { ["Slack", "Raycast"][$0] } == ["Slack", "Raycast"],
            "the query survives a rescan")
    }

    section("Keyboard: the search field")
    do {
        var nav = navigator()
        check(!nav.isSearchFieldOpen, "the field is hidden when the panel opens")
        nav.openSearch()
        check(nav.isSearchFieldOpen && nav.query.isEmpty, "⌘F shows an empty field")
        check(title(nav) == "Raycast", "and selects the first icon, so Return works")
        check(nav.handle(.deleteBackward) == .handled, "Delete in the empty field is swallowed, no beep")
        check(nav.handle(.escape) == .handled && !nav.isSearchFieldOpen, "Escape puts the empty field away")
        check(nav.handle(.escape) == .close, "the next Escape closes the panel")

        var typed = navigator()
        _ = typed.handle(.text("d"))
        check(typed.isSearchFieldOpen, "typing on the icons opens the field")
        typed.paste("rop\n")
        check(typed.query == "drop" && title(typed) == "Dropbox", "⌘V adds the pasted text")
        typed.closeSearch()
        check(!typed.isSearchFieldOpen && typed.query.isEmpty, "the close button empties and hides the field")
        check(title(typed) == "Dropbox", "the icon found stays selected")
        var pasted = navigator()
        pasted.paste("sla")
        check(pasted.isSearchFieldOpen && title(pasted) == "Slack", "pasting with the field hidden opens it")
        pasted.reset()
        check(!pasted.isSearchFieldOpen, "closing the panel hides the field")
    }

    section("Keyboard: what each key-down means (PanelKeyRoute)")
    do {
        func route(_ code: UInt16, _ chars: String = "", _ mods: KeyCombo.Modifiers = []) -> PanelKeyRoute {
            PanelKeyRoute(keyCode: code, characters: chars, modifiers: mods)
        }
        check(route(3, "f", [.command]) == .openSearch, "⌘F opens search")
        check(route(3, "а", [.command]) == .openSearch, "⌘F also with a Russian layout (same key, other letter)")
        check(route(3, "F", [.command, .shift]) == .passThrough, "⇧⌘F is not ours")
        check(route(9, "v", [.command]) == .paste, "⌘V pastes into the search")
        check(route(12, "q", [.command]) == .passThrough, "⌘Q and other menu shortcuts go on")
        check(route(43, ",", [.command]) == .passThrough, "⌘, goes on")
        check(route(123) == .key(.left) && route(124) == .key(.right), "← and → move through the icons")
        check(route(126) == .key(.up) && route(125) == .key(.down), "↑ and ↓ move a row")
        check(route(123, "", [.shift]) == .key(.left), "Shift does not stop the arrows")
        check(route(36) == .key(.returnKey) && route(76) == .key(.returnKey), "Return and keypad Enter open")
        check(route(53) == .key(.escape), "Escape")
        check(route(51) == .key(.deleteBackward), "Delete")
        check(route(0, "a") == .key(.text("a")), "a letter types")
        check(route(0, "A", [.shift]) == .key(.text("A")), "Shift+letter types")
        check(route(0, "ф") == .key(.text("ф")), "letters of any layout type")
        check(route(0, "å", [.option]) == .passThrough, "⌥ combinations are left alone")
        check(route(0, "a", [.control]) == .passThrough, "⌃ combinations are left alone")
        check(route(48, "\t") == .passThrough, "Tab is not text")
        check(route(117) == .passThrough, "forward delete is not ours")
        check(route(96, "\u{F708}") == .passThrough, "F5 is not text")
        check(route(200, "\u{F700}") == .passThrough, "function-key characters are never typed")
        check(route(0, "") == .passThrough, "a key with no characters (dead key) is not ours")
    }

    section("Keyboard: grid columns")
    check(GridLayout.columns(width: 276, cell: 32, spacing: 4) == 7, "the 300 pt panel fits 7 icons a row")
    check(GridLayout.columns(width: 31, cell: 32, spacing: 4) == 1, "narrower than one icon: still one column")
    check(GridLayout.columns(width: 100, cell: 0, spacing: 4) == 1, "a zero-size cell does not divide by zero")
    check(GridLayout.columns(width: 68, cell: 32, spacing: 4) == 2, "exactly two cells and one gap")
}
