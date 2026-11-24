import CapyBarCore
import Foundation

@MainActor
func keyComboTests() {
    section("KeyCombo: what may be a shortcut")
    let optionCommandB = KeyCombo(keyCode: 11, modifiers: [.option, .command], key: "b")
    check(optionCommandB != nil, "⌥⌘B is allowed")
    check(optionCommandB?.displayString == "⌥⌘B", "shown like a menu shortcut, letter upper-cased")
    check(KeyCombo(keyCode: 11, modifiers: [], key: "b") == nil, "a plain letter is refused: it would eat typing")
    check(KeyCombo(keyCode: 11, modifiers: [.shift], key: "B") == nil, "Shift alone is not enough")
    check(KeyCombo(keyCode: 53, modifiers: [.command], key: "") == nil, "Escape is never a shortcut")
    check(KeyCombo(keyCode: 200, modifiers: [.command], key: "x") == nil, "out-of-range key codes are refused")
    check(KeyCombo(keyCode: 11, modifiers: [.command], key: "  ") == nil, "a key without a label is refused")
    check(KeyCombo(keyCode: 96, modifiers: [], key: "")?.displayString == "F5", "an F-key works on its own")
    check(KeyCombo(keyCode: 49, modifiers: [.control], key: " ")?.displayString == "⌃Space", "Space has a name")
    check(
        KeyCombo(keyCode: 0, modifiers: [.command, .shift, .option, .control], key: "a")?.displayString == "⌃⌥⇧⌘A",
        "modifiers in macOS order")
    check(
        KeyCombo(keyCode: 11, modifiers: [.command, .option], key: "b")?.carbonModifiers == (1 << 8 | 1 << 11),
        "Carbon mask: cmdKey | optionKey")
    check(
        KeyCombo(keyCode: 0, modifiers: [.control, .shift], key: "a")?.carbonModifiers == (1 << 12 | 1 << 9),
        "Carbon mask: controlKey | shiftKey")

    section("KeyCombo: shown in menus")
    check(optionCommandB?.menuKeyEquivalent == "b", "a letter is lower case, as NSMenuItem wants it")
    check(KeyCombo(keyCode: 96, modifiers: [], key: "")?.menuKeyEquivalent == "\u{F708}", "F5 is NSF5FunctionKey")
    check(KeyCombo(keyCode: 90, modifiers: [], key: "")?.menuKeyEquivalent == "\u{F717}", "F20 is NSF20FunctionKey")
    check(KeyCombo(keyCode: 123, modifiers: [.command], key: "")?.menuKeyEquivalent == "\u{F702}", "← arrow")
    check(KeyCombo(keyCode: 49, modifiers: [.control], key: " ")?.menuKeyEquivalent == " ", "Space")
    check(KeyCombo(keyCode: 26, modifiers: [.command], key: "7")?.menuKeyEquivalent == "7", "a digit")

    section("KeyCombo: storage")
    if let combo = optionCommandB {
        check(KeyCombo(plist: combo.plist) == combo, "survives a round trip through the plist")
    }
    check(KeyCombo(plist: ["keyCode": 11, "modifiers": 0, "key": "B"]) == nil, "a stored plain letter is refused")
    check(KeyCombo(plist: ["keyCode": "11", "modifiers": 10, "key": "B"]) == nil, "wrong types are refused")
    check(KeyCombo(plist: ["keyCode": -1, "modifiers": 10, "key": "B"]) == nil, "negative key codes are refused")
    check(
        KeyCombo(plist: ["keyCode": 11, "modifiers": 10 | 1 << 20, "key": "B"])?.modifiers == [.option, .command],
        "unknown modifier bits are dropped")
    check(
        KeyCombo(plist: ["keyCode": 11, "modifiers": 10, "key": String(repeating: "x", count: 50)]) == nil,
        "an oversized label is refused")

    let suite = "app.capybar.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return check(false, "test defaults suite") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = Preferences(defaults: defaults)
    check(prefs.hotkey == nil, "no shortcut until the user records one")
    prefs.hotkey = optionCommandB
    check(Preferences(defaults: defaults).hotkey == optionCommandB, "the shortcut is remembered")
    prefs.hotkey = nil
    check(Preferences(defaults: defaults).hotkey == nil, "removing the shortcut is remembered")
    defaults.set("garbage", forKey: Preferences.Key.hotkey)
    check(prefs.hotkey == nil, "a damaged stored shortcut reads as none")
}

@MainActor
func panelSearchTests() {
    section("PanelSearch")
    let titles = ["iStat Menus", "Raycast", "Dropbox", "1Password", "Bartender — Clock", "Café Notes", "Stats"]
    func names(_ query: String) -> [String] { PanelSearch.matches(query, in: titles).map { titles[$0] } }

    check(names("") == titles, "an empty query keeps every icon in panel order")
    check(names("   ") == titles, "a blank query is empty")
    check(names("ray") == ["Raycast"], "prefix match")
    check(names("RAY") == ["Raycast"], "case is ignored")
    check(names("cafe") == ["Café Notes"], "accents are ignored")
    check(names("stat") == ["Stats", "iStat Menus"], "a title that starts with the query beats one that contains it")
    check(names("menus") == ["iStat Menus"], "a word inside the title")
    check(names("clock") == ["Bartender — Clock"], "the item label after the app name is searched too")
    check(names("im") == ["iStat Menus"], "initials")
    check(names("pass") == ["1Password"], "letters after a digit")
    check(names("o") == ["Dropbox", "1Password", "Bartender — Clock", "Café Notes"], "ties keep panel order")
    check(names("notes cafe") == ["Café Notes"], "several words: each must appear, in any order")
    check(names("zzz").isEmpty, "no match gives nothing")
    check(PanelSearch.matches("x", in: []).isEmpty, "nothing to search")
}
