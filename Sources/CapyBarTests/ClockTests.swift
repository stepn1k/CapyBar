import CapyBarCore
import CoreGraphics
import Foundation

/// A scripted clock where time moves only when something pauses or waits. Letting the
/// held press through toggles the panel after `panelDelay`; `events` run once their time
/// comes.
final class FakeClock: ClockEnvironment, @unchecked Sendable {
    var liftAllowed = true
    /// Lifts refused first, as while a restore still waits for MenuBarAgent.
    var refusedLifts = 0
    var agentAnswers = true
    var agentDelay: TimeInterval = 0.05
    /// Released presses that open nothing, first.
    var lostReleases = 0
    var panelDelay: TimeInterval = 0.15
    /// Nil: stays open.
    var panelOpenFor: TimeInterval? = 1.0
    var bannerWindows: Set<CGWindowID> = []
    var panelInBannerWindow = false
    var controlsReadable = true
    var menusOpenUntil: TimeInterval = 0
    var events: [(at: TimeInterval, run: () -> Void)] = []

    private(set) var time: TimeInterval = 0
    private(set) var log: [String] = []
    private(set) var liftTime: TimeInterval?
    private(set) var releaseTime: TimeInterval?
    private(set) var restoreTime: TimeInterval?
    private(set) var isLifted = false
    private var panelFrom: TimeInterval?
    private var panelUntil: TimeInterval?

    func openPanel(at start: TimeInterval, for duration: TimeInterval?) {
        panelFrom = start
        panelUntil = duration.map { start + $0 }
    }

    func closePanel() {
        panelUntil = time
    }

    var isPanelVisible: Bool {
        guard let panelFrom, time >= panelFrom else { return false }
        return panelUntil.map { time < $0 } ?? true
    }

    func lift() -> Bool {
        if refusedLifts > 0 {
            refusedLifts -= 1
            return false
        }
        guard liftAllowed, !isLifted else { return false }
        isLifted = true
        liftTime = time
        log.append("lift")
        return true
    }

    func restore() {
        guard isLifted else { return }
        isLifted = false
        restoreTime = time
        log.append("restore")
    }

    func pause(_ seconds: TimeInterval) {
        time += seconds
        while let index = events.firstIndex(where: { $0.at <= time }) {
            events.remove(at: index).run()
        }
    }

    func now() -> TimeInterval { time }

    func clockFrames() -> [CGRect] { [CGRect(x: 1400, y: 0, width: 80, height: 24)] }

    func waitForMenuBarAgent() -> Bool {
        pause(agentDelay)
        return agentAnswers
    }

    func centerWindows() -> Set<CGWindowID> {
        isPanelVisible && !panelInBannerWindow ? bannerWindows.union([7]) : bannerWindows
    }

    func showsPanelControls() -> Bool? { controlsReadable ? isPanelVisible : nil }

    func menusOpen() -> Bool { time < menusOpenUntil }

    func releaseHeldPress() {
        releaseTime = time
        log.append("release")
        // macOS ignores the clock while restricted, for closing as well as opening.
        guard isLifted else { return }
        if isPanelVisible {
            closePanel()
        } else if lostReleases > 0 {
            lostReleases -= 1
        } else {
            openPanel(at: time + panelDelay, for: panelOpenFor)
        }
    }

    func dropHeldPress() {
        log.append("drop")
    }

    func sessionEnded() {
        log.append("end")
    }
}

private let clockFrame = CGRect(x: 1400, y: 0, width: 80, height: 24)
private let onClock = CGPoint(x: 1450, y: 12)
private let menuBar = CGRect(x: 0, y: 0, width: 1512, height: 33)
private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

private func near(_ value: TimeInterval?, _ target: TimeInterval, within: TimeInterval = 0.0001) -> Bool {
    value.map { abs($0 - target) <= within } ?? false
}

private func makeGate() -> ClockGate<Int> {
    var gate = ClockGate<Int>()
    gate.clocks = [clockFrame]
    gate.menuBars = [menuBar]
    gate.displays = [display]
    return gate
}

@MainActor
func clockTests() {
    clockGateTests()
    clockOpenTests()
    clockCloseTests()
    clockFailureTests()
}

@MainActor
private func clockGateTests() {
    section("Clock: which clicks are held")
    check(
        ClockGate<Int>.isOnClock(CGPoint(x: 1440, y: 10), frame: clockFrame, isLeftToRight: true), "inside the clock")
    check(
        ClockGate<Int>.isOnClock(CGPoint(x: 1395, y: 10), frame: clockFrame, isLeftToRight: true),
        "5 pt toward the neighbour still counts (macOS takes it)")
    check(
        !ClockGate<Int>.isOnClock(CGPoint(x: 1392, y: 10), frame: clockFrame, isLeftToRight: true),
        "8 pt toward the neighbour is the next item")
    check(
        ClockGate<Int>.isOnClock(CGPoint(x: 1500, y: 10), frame: clockFrame, isLeftToRight: true),
        "the margin up to the screen edge counts")
    check(
        ClockGate<Int>.isOnClock(CGPoint(x: 1380, y: 10), frame: clockFrame, isLeftToRight: false),
        "right-to-left: the screen edge is on the left")
    check(
        !ClockGate<Int>.isOnClock(CGPoint(x: 1440, y: 30), frame: clockFrame, isLeftToRight: true),
        "below the menu bar does not count")
    do {
        var gate = makeGate()
        check(gate.down(1, key: 1, at: CGPoint(x: 600, y: 12), refused: false) == .pass, "a click elsewhere passes")
        check(gate.down(1, key: 1, at: onClock, refused: true) == .pass, "a ⌘-, ⌃- or ⌥-click on the clock passes")
        check(gate.down(1, key: 1, at: onClock, refused: false) == .hold(starts: true), "a click on the clock is held…")
        check(gate.follow(2, key: 1) == .hold(starts: false), "…with its release")
        check(gate.down(3, key: 3, at: onClock, refused: false) == .hold(starts: false), "a second click meanwhile too")
        _ = gate.follow(4, key: 3)
        check(gate.release() == [1, 2, 3, 4], "all go through in order once lifted")
        check(gate.phase == .open && gate.follow(5, key: 4) == .pass, "later releases pass")
    }
    do {
        var gate = makeGate()
        _ = gate.down(1, key: 1, at: onClock, refused: false)
        _ = gate.release()
        check(gate.down(2, key: 2, at: onClock, refused: false) == .passPressed(.clock), "while open: the clock passes")
        check(
            gate.down(2, key: 2, at: CGPoint(x: 600, y: 12), refused: false) == .passPressed(.bar), "another bar item")
        check(
            gate.down(2, key: 2, at: CGPoint(x: 400, y: 500), refused: false) == .passPressed(.elsewhere),
            "left of the panel")
        check(gate.down(2, key: 2, at: CGPoint(x: 1300, y: 500), refused: false) == .pass, "where the panel may be")
        check(gate.end().isEmpty && gate.phase == .idle, "the session ends")
    }
    do {
        var gate = makeGate()
        _ = gate.down(1, key: 1, at: onClock, refused: false)
        check(gate.end() == [1] && gate.phase == .idle, "stopping lets a held press through")
    }
    do {
        var gate = makeGate()
        gate.clocks = [CGRect(x: 1385, y: 5.5, width: 106.5, height: 22)]  // as on a notched MacBook
        check(gate.isOnClock(CGPoint(x: 1450, y: 0)), "the very top edge of the screen counts")
        check(gate.isOnClock(CGPoint(x: 1450, y: 31)), "so does the bar below the clock's frame")
        check(!gate.isOnClock(CGPoint(x: 1450, y: 40)), "below the bar does not")
        check(gate.isOnClock(CGPoint(x: 1511, y: 2)), "and the top-right corner")
    }
    do {
        var gate = makeGate()
        gate.menuBars.append(CGRect(x: 1512, y: 0, width: 1920, height: 25))
        gate.displays.append(CGRect(x: 1512, y: 0, width: 1920, height: 1080))
        check(!gate.isOnClock(CGPoint(x: 1513, y: 12)), "the padding stops at the display's edge")
    }
    do {
        var gate = makeGate()
        _ = gate.down(1, key: 1, at: onClock, refused: false)
        check(gate.follow(2, key: 1) == .hold(starts: false), "a drag of the held press waits with it")
        check(
            gate.down(5, key: 5, at: CGPoint(x: 600, y: 500), refused: false) == .passPressed(.cancel),
            "a click elsewhere meanwhile passes at once, and cancels the clock")
        check(gate.follow(6, key: 5) == .pass, "with its release")
        gate.discard()
        check(gate.follow(3, key: 1) == .hold(starts: false), "the dropped press's release is swallowed too")
        check(gate.end().isEmpty, "and nothing of it ever goes through")
    }
}

@MainActor
private func clockOpenTests() {
    section("Clock: opening Notification Center")
    do {
        let fake = FakeClock()
        check(ClockEngine(env: fake).run() == .opened, "the held press opens the panel once lifted")
        check(fake.log == ["lift", "release", "restore", "end"], "one lift, one press, one restore")
        check(
            (fake.releaseTime ?? 0) - (fake.liftTime ?? 0) >= ClockEngine.minimumLift - 0.0001,
            "never let through sooner than 80 ms after the lift")
        let closed = (fake.releaseTime ?? 0) + fake.panelDelay + 1.0
        check(
            (fake.restoreTime ?? 0) >= closed && (fake.restoreTime ?? 0) < closed + 0.06,
            "hidden again as the panel goes, not before")
    }
    do {
        let fake = FakeClock()
        fake.agentDelay = 0.2
        _ = ClockEngine(env: fake).run()
        check(near(fake.releaseTime, 0.23), "let through as soon as MenuBarAgent is ready")
    }
    do {
        let fake = FakeClock()
        fake.refusedLifts = 3
        check(ClockEngine(env: fake).run() == .opened, "a lift refused while the last restore settles is retried")
    }
    do {
        let fake = FakeClock()
        let engine = ClockEngine(env: fake)
        fake.events = [(0.05, { engine.pressed(.cancel) })]
        check(engine.run() == .cancelled, "clicked elsewhere before it went through: no panel…")
        check(fake.log == ["lift", "drop", "restore", "end"], "…the press is dropped, hidden again")
    }
    do {
        let fake = FakeClock()
        fake.bannerWindows = [9]
        fake.controlsReadable = false
        check(
            ClockEngine(env: fake).run() == .opened, "a banner with unreadable controls is not taken for an open panel")
    }
    do {
        let fake = FakeClock()
        fake.openPanel(at: 0, for: nil)
        check(ClockEngine(env: fake).run() == .closed, "panel already open: the press closes it…")
        check(fake.log == ["lift", "release", "restore", "end"], "…lifted for it, then hidden again")
        check(!fake.isPanelVisible, "and it is closed")
    }
}

@MainActor
private func clockCloseTests() {
    section("Clock: closing Notification Center")
    do {
        let fake = FakeClock()
        fake.panelOpenFor = nil
        let engine = ClockEngine(env: fake)
        fake.events = [(1.0, { engine.pressed(.elsewhere) })]
        _ = engine.run()
        check(near(fake.restoreTime, 1.0, within: 0.06), "a click outside the panel ends it at once")
    }
    do {
        let fake = FakeClock()
        fake.panelOpenFor = nil
        let engine = ClockEngine(env: fake)
        fake.events = [
            (
                1.0,
                {
                    engine.pressed(.clock)
                    fake.closePanel()
                }
            ),
            (
                1.05,
                {
                    engine.pressed(.clock)
                    fake.openPanel(at: fake.time, for: 0.5)
                }
            ),
        ]
        check(engine.run() == .opened, "closed and reopened from the clock…")
        check(fake.log.filter { $0 == "lift" }.count == 1, "…stays lifted, so the bar doesn't hide and show")
        check((fake.restoreTime ?? 0) >= 1.55, "and hides once the panel is really gone")
    }
    do {
        let fake = FakeClock()
        fake.panelOpenFor = nil
        let engine = ClockEngine(env: fake)
        fake.events = [
            (
                1.0,
                {
                    engine.pressed(.clock)
                    fake.closePanel()
                }
            )
        ]
        _ = engine.run()
        check((fake.restoreTime ?? 0) <= 1.0 + 0.05 + 0.12 + 0.02, "closed from the clock: hidden right after")
    }
    do {
        let fake = FakeClock()
        fake.panelOpenFor = nil
        let engine = ClockEngine(env: fake)
        fake.events = [
            (
                1.0,
                {
                    engine.pressed(.bar)
                    fake.closePanel()
                    fake.menusOpenUntil = 3.0
                }
            )
        ]
        _ = engine.run()
        check((fake.restoreTime ?? 0) >= 3.0, "an icon clicked meanwhile stays drawn until its menu closes")
    }
    do {
        let fake = FakeClock()
        fake.bannerWindows = [9]
        check(ClockEngine(env: fake).run() == .opened, "a banner on screen is not taken for the panel")
        check((fake.restoreTime ?? 0) < 1.4, "hidden again when the panel goes, though the banner stays")
    }
    do {
        let fake = FakeClock()
        fake.bannerWindows = [9]
        fake.panelInBannerWindow = true
        check(ClockEngine(env: fake).run() == .opened, "a panel in the banner's window is found by Edit Widgets")
        check((fake.restoreTime ?? 0) < 1.4, "and hidden again once only the banner is left")
    }
    do {
        let fake = FakeClock()
        fake.bannerWindows = [9]
        fake.panelInBannerWindow = true
        fake.panelOpenFor = nil
        fake.events = [(1.0, { fake.controlsReadable = false })]
        _ = ClockEngine(env: fake).run()
        check((fake.restoreTime ?? 600) < 1.1, "unreadable after sharing a banner's window: not held for minutes")
    }
    do {
        let fake = FakeClock()
        fake.bannerWindows = [9]
        fake.controlsReadable = false
        check(ClockEngine(env: fake).isPanelOpen(), "unreadable windows count as the panel, so it is never reopened")
    }
    do {
        let fake = FakeClock()
        fake.panelOpenFor = 0.6
        let engine = ClockEngine(env: fake)
        // A lasting alert pops up with the panel, in a window of its own, and stays.
        fake.events = [(0.2, { fake.bannerWindows = [11] })]
        _ = engine.run()
        check((fake.restoreTime ?? 600) < 2.5, "a lasting alert doesn't keep icons shown after the panel closes")
    }
}

@MainActor
private func clockFailureTests() {
    section("Clock: when something goes wrong")
    do {
        let fake = FakeClock()
        fake.lostReleases = 1
        check(ClockEngine(env: fake).run() == .notOpened, "nothing opened: no second click is sent")
        check(fake.log == ["lift", "release", "restore", "end"], "and hidden again")
    }
    do {
        let fake = FakeClock()
        fake.panelOpenFor = nil
        _ = ClockEngine(env: fake).run()
        check(fake.log.suffix(2) == ["restore", "end"], "a panel left open for ages still ends in hiding again")
    }
    do {
        let fake = FakeClock()
        fake.liftAllowed = false
        check(ClockEngine(env: fake).run() == .notLifted, "no lift possible…")
        check(fake.log == ["release", "end"], "…the press still goes through")
    }
    do {
        let fake = FakeClock()
        fake.agentAnswers = false
        check(ClockEngine(env: fake).run() == .noClock, "MenuBarAgent silent once lifted…")
        check(fake.log == ["lift", "release", "restore", "end"], "…press let through, hidden again")
    }
}

@MainActor
func clockRestrictionTests() {
    section("Restriction: lifting for the clock")
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        check(!restriction.suspend(), "nothing held: nothing to lift")
        restriction.apply(allowing: ["a"])
        check(!restriction.suspend(), "not while MenuBarAgent hasn't answered")
        fake.reply(0)
        check(restriction.suspend(), "lifts a confirmed restriction")
        check(fake.alive.isEmpty, "every icon shows while lifted")
        check(restriction.isSuspended && restriction.allowed == nil, "reports the lift")
        check(!restriction.suspend(), "a second lift is refused")

        let resumed = Outcome()
        restriction.resume(completion: resumed.record)
        check(fake.activations == 2 && fake.ids(of: 1) == ["a"], "resume sends the list again")
        fake.reply(1)
        check(resumed.results == [nil] && !restriction.isSuspended, "and answers once MenuBarAgent has")
        check(fake.alive == [1], "hidden again")
    }
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        restriction.apply(allowing: ["a"])
        fake.reply(0)
        _ = restriction.suspend()
        let meanwhile = Outcome()
        restriction.apply(allowing: ["a", "b"], force: true, completion: meanwhile.record)
        check(fake.activations == 1, "an apply while lifted (a resend after wake, say) waits")
        check(!meanwhile.called, "and its caller waits too")
        restriction.resume()
        check(fake.ids(of: 1) == ["a", "b"], "resume sends the newest list")
        fake.reply(1)
        check(meanwhile.results == [nil], "the waiting caller gets the real answer")
    }
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        restriction.apply(allowing: ["a"])
        fake.reply(0)
        _ = restriction.suspend()
        let meanwhile = Outcome()
        restriction.apply(allowing: ["a"], completion: meanwhile.record)
        restriction.clear()
        check(meanwhile.results == [nil], "clear while lifted answers waiting callers")
        restriction.resume()
        check(fake.activations == 1 && fake.alive.isEmpty, "and resume after clear hides nothing")
    }
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        restriction.apply(allowing: ["a"])
        fake.reply(0)
        _ = restriction.suspend()
        let resumed = Outcome()
        restriction.resume(completion: resumed.record)
        fake.reply(1, error: "refused")
        check(resumed.results == [.rejected("refused")], "a refused resume reports it (the keeper retries)")
        check(fake.alive.isEmpty, "and fails open")
    }
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        restriction.apply(allowing: ["a"])
        fake.reply(0)
        _ = restriction.suspend()
        restriction.clear()
        restriction.apply(allowing: ["a", "b"])
        check(fake.activations == 2 && fake.ids(of: 1) == ["a", "b"], "after a clear, apply sends at once")
    }
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        restriction.apply(allowing: ["a"])
        fake.reply(0)
        _ = restriction.suspend()
        fake.isAvailable = false
        let resumed = Outcome()
        restriction.resume(completion: resumed.record)
        check(resumed.results == [.unavailable] && !restriction.isSuspended, "resume without MenuBarAgent fails open")
    }
}
