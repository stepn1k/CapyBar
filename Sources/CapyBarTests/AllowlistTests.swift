import CapyBarCore
import Foundation

@MainActor
func allowlistTests() {
    let own = "app.capybar.CapyBar"

    section("Allowlist.compute")
    check(
        Allowlist.compute(running: ["a", "b", "c"], hidden: ["b"], ownBundleID: own) == ["a", "c", own],
        "hidden app is left out, own app is always in")
    check(
        Allowlist.compute(running: ["a", "b"], hidden: ["b"], revealed: ["b"], ownBundleID: own) == ["a", "b", own],
        "revealed app comes back")
    check(
        Allowlist.compute(running: ["a"], known: ["b", "c"], hidden: ["c"], ownBundleID: own) == ["a", "b", own],
        "known apps stay listed when not running, so quits do not change the list")
    check(
        Allowlist.compute(running: ["a"], known: ["a"], hidden: [], ownBundleID: own)
            == Allowlist.compute(running: [], known: ["a"], hidden: [], ownBundleID: own),
        "an app quitting does not change the allowlist")
    check(
        Allowlist.compute(running: ["a", own], hidden: [own], ownBundleID: own).contains(own),
        "own app cannot be hidden even if stored as hidden")

    section("Allowlist.needsRestriction")
    check(
        !Allowlist.needsRestriction(running: ["a"], hidden: ["b"], ownBundleID: own),
        "no assertion when no hidden app runs")
    check(
        Allowlist.needsRestriction(running: ["a", "b"], hidden: ["b"], ownBundleID: own),
        "assertion when a hidden app runs")
    check(
        !Allowlist.needsRestriction(running: ["a", "b"], hidden: ["b"], revealed: ["b"], ownBundleID: own),
        "no assertion while the only hidden app is revealed")
    check(
        !Allowlist.needsRestriction(running: [own], hidden: [own], ownBundleID: own),
        "own app never triggers an assertion")

    section("Allowlist.shouldAutoHide")
    check(
        Allowlist.shouldAutoHide(bundleID: "com.example.new", known: [], hideNewApps: true, ownBundleID: own),
        "new third-party app is a candidate")
    check(
        !Allowlist.shouldAutoHide(bundleID: "com.example.new", known: [], hideNewApps: false, ownBundleID: own),
        "setting off: nothing auto-hidden")
    check(
        !Allowlist.shouldAutoHide(
            bundleID: "com.example.old", known: ["com.example.old"], hideNewApps: true, ownBundleID: own),
        "known app is not auto-hidden again")
    check(
        !Allowlist.shouldAutoHide(
            bundleID: "com.apple.TextInputMenuAgent", known: [], hideNewApps: true, ownBundleID: own),
        "Apple agents stay visible")
    check(
        !Allowlist.shouldAutoHide(bundleID: own, known: [], hideNewApps: true, ownBundleID: own),
        "own app is never auto-hidden")

    section("Allowlist.needsUnscannedEntry")
    func unscanned(
        _ id: String, scanned: Set<String> = [], hidden: Set<String> = ["a"], iconless: Set<String> = []
    )
        -> Bool
    {
        Allowlist.needsUnscannedEntry(
            bundleID: id, scanned: scanned, hidden: hidden, iconless: iconless, ownBundleID: own)
    }
    check(unscanned("a"), "hidden running app the scan missed gets an entry")
    check(!unscanned("a", scanned: ["a"]), "an app the scan found is listed by its icons instead")
    check(!unscanned("b"), "an app that is not hidden gets none")
    check(!unscanned("a", iconless: ["a"]), "an app known to have no icon gets none")
    check(!unscanned(own, hidden: [own]), "own app never gets one")
    check(!unscanned("com.apple.Siri", hidden: ["com.apple.Siri"]), "Apple agents never get one")

    section("Allowlist.isAppleProcess")
    check(Allowlist.isAppleProcess("com.apple.MenuBarAgent"), "MenuBarAgent is Apple's")
    check(Allowlist.isAppleProcess("com.apple.TextInputMenuAgent"), "the input menu agent is Apple's")
    check(!Allowlist.isAppleProcess("com.google.Chrome"), "a third-party app is not")
    check(!Allowlist.isAppleProcess("com.applepie.app"), "a look-alike prefix is not")
}

@MainActor
func preferencesTests() {
    section("Preferences")
    let suite = "app.capybar.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        check(false, "test defaults suite")
        return
    }
    defer { defaults.removePersistentDomain(forName: suite) }

    let prefs = Preferences(defaults: defaults)
    check(prefs.hideNewApps, "hideNewApps defaults to on")
    prefs.hidden = ["a", "", String(repeating: "x", count: 300)]
    check(prefs.hidden == ["a"], "empty and oversized IDs are dropped")
    defaults.set(["ok", 42, "ok2"] as [Any], forKey: Preferences.Key.hidden)
    check(prefs.hidden == ["ok", "ok2"], "damaged list: the valid entries are kept")
    defaults.set(["a": 7, "b": "click"] as [String: Any], forKey: Preferences.Key.preferredMethods)
    check(prefs.preferredMethod(for: "a") == .accessibility, "garbage preferred method falls back to AXPress")
    check(prefs.preferredMethod(for: "b") == .click, "valid entry next to garbage is still read")
    prefs.setPreferredMethod(.click, for: "c")
    check(prefs.preferredMethod(for: "c") == .click, "preferred method is remembered")
    check(prefs.appOrder.isEmpty, "app order starts empty")
    prefs.appOrder = ["b", "a", "b", "", "c"]
    check(prefs.appOrder == ["b", "a", "c"], "app order keeps the first of duplicates and drops invalid IDs")
    defaults.set(["x", 3, "y", "x"] as [Any], forKey: Preferences.Key.appOrder)
    check(prefs.appOrder == ["x", "y"], "damaged app order: valid, unique entries are kept in order")
    check(!prefs.loginItemOffered, "Open at Login has not been offered yet")
    prefs.loginItemOffered = true
    check(Preferences(defaults: defaults).loginItemOffered, "Open at Login is offered only once")
    check(!prefs.showsNotRunningApps, "not-running apps are left out of the cubby by default")
    prefs.showsNotRunningApps = true
    check(Preferences(defaults: defaults).showsNotRunningApps, "showing not-running apps is remembered")
    check(prefs.iconless.isEmpty, "no app is marked iconless at first")
    prefs.iconless = ["chrome"]
    check(Preferences(defaults: defaults).iconless == ["chrome"], "iconless apps are remembered")
    prefs.setPreferredMethod(.click, for: "")
    check(
        (defaults.dictionary(forKey: Preferences.Key.preferredMethods)?[""]) == nil, "invalid bundle ID is not stored")
}
