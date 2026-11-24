import CapyBarCore
import CoreGraphics
import Foundation

/// Not actor-isolated: the real environment runs on the press queue, so this one
/// matches that shape and is used from one test at a time.
final class ScriptedEnvironment: PressEnvironment {
    var sameApp = true
    var drawn: DrawnItem? = DrawnItem(frame: CGRect(x: 900, y: 4, width: 30, height: 24))
    /// Results of successive AXPress calls: (success, seconds the call blocked).
    var axResults: [(Bool, TimeInterval)] = []
    /// Answers successive menu-window queries; gets (query number, timeout).
    var menuWindowScript: (Int, TimeInterval) -> Set<CGWindowID> = { _, _ in [] }
    var safePoint: CGPoint? = CGPoint(x: 915, y: 16)

    private(set) var axPresses = 0
    private(set) var clicks: [CGPoint] = []
    private(set) var closedWaits: [Set<CGWindowID>] = []
    private var menuQueries = 0

    func isSameApp(_ item: MenuBarItem) -> Bool { sameApp }
    func waitUntilDrawn(_ item: MenuBarItem) -> DrawnItem? { drawn }

    func axPress(_ drawn: DrawnItem) -> (success: Bool, elapsed: TimeInterval) {
        defer { axPresses += 1 }
        return axResults.indices.contains(axPresses) ? axResults[axPresses] : (true, 0.01)
    }

    func windowSnapshot(_ pid: pid_t) -> Set<CGWindowID> { [1, 2] }

    func menuWindows(
        _ pid: pid_t, anchor: CGRect, excluding: Set<CGWindowID>, timeout: TimeInterval
    )
        -> Set<CGWindowID>
    {
        defer { menuQueries += 1 }
        return menuWindowScript(menuQueries, timeout).subtracting(excluding)
    }

    func safeClickPoint(_ item: MenuBarItem) -> CGPoint? { safePoint }
    func click(at point: CGPoint) -> Bool {
        clicks.append(point)
        return true
    }
    func waitUntilClosed(_ windows: Set<CGWindowID>, pid: pid_t) { closedWaits.append(windows) }
}

@MainActor
func presserTests() {
    let item = MenuBarItem(bundleID: "com.example.app", pid: 4242, index: 0, label: "Example")
    let menu: Set<CGWindowID> = [99]

    section("ItemPresser: basic outcomes")
    do {
        let env = ScriptedEnvironment()
        env.sameApp = false
        check(
            ItemPresser.run(item, preferred: .accessibility, env: env) == .notDrawn && env.axPresses == 0,
            "pid now belongs to another app: nothing is pressed")
    }
    do {
        let env = ScriptedEnvironment()
        env.drawn = nil
        check(
            ItemPresser.run(item, preferred: .accessibility, env: env) == .notDrawn && env.axPresses == 0,
            "item never drawn after reveal: nothing is pressed")
    }
    do {
        let env = ScriptedEnvironment()
        env.menuWindowScript = { query, _ in query == 0 ? menu : [] }
        let outcome = ItemPresser.run(item, preferred: .accessibility, env: env)
        check(outcome == .finished(.accessibility), "AXPress opens a popover: finished via Accessibility")
        check(env.closedWaits == [menu] && env.clicks.isEmpty, "waits for that popover to close, never clicks")
    }

    section("ItemPresser: menus that block AXPress")
    do {
        let env = ScriptedEnvironment()
        env.axResults = [(true, 2.0)]
        let outcome = ItemPresser.run(item, preferred: .accessibility, env: env)
        check(
            outcome == .finished(.accessibility) && env.clicks.isEmpty,
            "NSMenu tracked and closed (AXPress blocked 2 s): finished, no click")
    }
    do {
        let env = ScriptedEnvironment()
        env.axResults = [(false, 60.0)]
        env.menuWindowScript = { _, _ in menu }  // the menu is still open
        let outcome = ItemPresser.run(item, preferred: .accessibility, env: env)
        check(outcome == .finished(.accessibility), "menu open longer than the 60 s timeout: still finished")
        check(env.clicks.isEmpty, "and no click lands on the open menu (it would close it)")
        check(env.closedWaits == [menu], "waits for the user to close it")
    }
    do {
        let env = ScriptedEnvironment()
        env.axResults = [(false, 60.0)]
        let outcome = ItemPresser.run(item, preferred: .accessibility, env: env)
        check(
            outcome == .noResponse && env.clicks.isEmpty, "hung app (timeout, nothing on screen): no response, no click"
        )
    }
    do {
        let env = ScriptedEnvironment()
        env.axResults = [(true, 0.5)]
        env.menuWindowScript = { query, timeout in query == 0 && timeout <= 0.1 ? menu : [] }
        let outcome = ItemPresser.run(item, preferred: .accessibility, env: env)
        check(
            outcome == .finished(.accessibility) && env.closedWaits == [menu],
            "slow app opens a popover (AXPress 0.5 s): waits for the popover, not re-hidden early")
    }

    do {
        let env = ScriptedEnvironment()
        env.axResults = [(false, 0.5)]
        let outcome = ItemPresser.run(item, preferred: .accessibility, env: env)
        check(outcome == .noResponse, "slow AXPress failure with nothing on screen is not counted as success")
        check(env.clicks.isEmpty, "and is not followed by a second press")
    }

    section("ItemPresser: click fallback")
    do {
        let env = ScriptedEnvironment()
        env.menuWindowScript = { query, _ in query >= 2 ? menu : [] }  // opens only after the click
        let outcome = ItemPresser.run(item, preferred: .accessibility, env: env)
        check(outcome == .finished(.click), "app ignores AXPress: the click opens it")
        check(env.clicks == [CGPoint(x: 915, y: 16)], "exactly one click, at the safe point")
    }
    do {
        let env = ScriptedEnvironment()
        env.axResults = [(false, 0.01)]
        env.safePoint = nil
        let outcome = ItemPresser.run(item, preferred: .accessibility, env: env)
        check(
            outcome == .noResponse && env.clicks.isEmpty,
            "no safe point (frame outside the bar or someone else's UI under it): never clicks")
    }
    do {
        let env = ScriptedEnvironment()
        // Nothing during AXPress's own wait; the popover shows up just before the click.
        env.menuWindowScript = { query, _ in query == 1 ? menu : [] }
        let outcome = ItemPresser.run(item, preferred: .accessibility, env: env)
        check(
            outcome == .finished(.accessibility) && env.clicks.isEmpty,
            "late popover from AXPress is not toggled shut by a click")
    }
    do {
        let env = ScriptedEnvironment()
        env.menuWindowScript = { query, _ in query == 1 ? menu : [] }
        let outcome = ItemPresser.run(item, preferred: .click, env: env)
        check(outcome == .finished(.click) && env.axPresses == 0, "remembered method 'click' goes first")
    }
    do {
        let env = ScriptedEnvironment()
        env.menuWindowScript = { _, _ in [7] }  // some unrelated new window, visible from the start
        let outcome = ItemPresser.run(item, preferred: .click, env: env)
        check(env.clicks.count == 1, "remembered click: the first attempt is really made")
        check(outcome == .finished(.click), "the outcome belongs to that click, not to an earlier window")
    }
    do {
        let env = ScriptedEnvironment()
        env.menuWindowScript = { _, _ in [1] }  // only windows that already existed
        let outcome = ItemPresser.run(item, preferred: .accessibility, env: env)
        check(outcome == .noResponse, "windows that were open before the press do not count as its menu")
    }

    section("ItemPresser.isInMenuBar")
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let external = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
    check(
        ItemPresser.isInMenuBar(CGRect(x: 900, y: 4, width: 30, height: 24), displays: [laptop]),
        "status item at the top of the display")
    check(
        ItemPresser.isInMenuBar(CGRect(x: 2000, y: -196, width: 30, height: 24), displays: [laptop, external]),
        "status item on a second display placed higher")
    check(
        !ItemPresser.isInMenuBar(CGRect(x: 900, y: 200, width: 30, height: 24), displays: [laptop]),
        "item-sized frame in the middle of the screen is refused")
    check(
        !ItemPresser.isInMenuBar(CGRect(x: 100, y: 0, width: 800, height: 600), displays: [laptop]),
        "window-sized frame is refused")
    check(
        !ItemPresser.isInMenuBar(CGRect(x: 900, y: 4, width: 0, height: 24), displays: [laptop]),
        "zero-size frame is refused")
    check(
        !ItemPresser.isInMenuBar(CGRect(x: 5000, y: 4, width: 30, height: 24), displays: [laptop]),
        "frame off every display is refused")
}
