import CapyBarCore
import Foundation

// What keeps hidden icons hidden through sleep, restarts of MenuBarAgent, a login and
// app updates. The system is faked: `RestrictionKeeper` gets a scripted `resend`, or a
// real `Restriction` over `FakeBackend`; delays are milliseconds instead of seconds.

/// Delays short enough for tests, long enough to tell the triggers apart.
private let fastPolicy = RestrictionKeeper.Policy(
    firstDelay: [
        .agentRestarted: .milliseconds(10), .woke: .milliseconds(20), .sessionActivated: .milliseconds(10),
        .failed: .milliseconds(10),
    ],
    maxAttempts: 3)

/// Polls until `condition` holds, so the test does not race the timers it waits for.
@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        await wait(.milliseconds(2))
    }
    return true
}

@MainActor
private func checkEventually(
    _ name: String, file: String = #fileID, line: Int = #line, _ condition: () -> Bool
) async {
    let holds = await waitUntil(condition)
    check(holds, name, file: file, line: line)
}

/// A resend that answers from a script: true = MenuBarAgent accepted it.
@MainActor
private final class ScriptedResend {
    var answers: [Bool]
    private(set) var calls = 0
    var wanted = true

    init(answers: [Bool] = []) { self.answers = answers }

    func makeKeeper() -> RestrictionKeeper {
        RestrictionKeeper(
            policy: fastPolicy,
            isWanted: { [unowned self] in wanted },
            resend: { [unowned self] done in
                calls += 1
                done(answers.isEmpty ? true : answers.removeFirst())
            })
    }
}

@MainActor
func reliabilityTests() async {
    section("Reliability: retry policy")
    do {
        let policy = RestrictionKeeper.Policy.standard
        check(policy.delay(for: .agentRestarted, attempt: 1) == .seconds(1), "restart: first resend after 1 s")
        check(policy.delay(for: .agentRestarted, attempt: 3) == .seconds(4), "each retry waits twice as long")
        check(policy.delay(for: .woke, attempt: 1) == .seconds(2), "wake: 2 s, so the menu bar is back first")
        check(policy.delay(for: .failed, attempt: 4) == .seconds(16), "failure: the last retry ~30 s after the first")
        check(policy.delay(for: .failed, attempt: 1000) > .zero, "a huge attempt number does not overflow")
        check(
            RestrictionKeeper.Trigger.allCases.allSatisfy { policy.firstDelay[$0] != nil },
            "every trigger has a delay")
    }

    section("Reliability: MenuBarAgent restarts, the Mac wakes, the session returns")
    for trigger in [RestrictionKeeper.Trigger.agentRestarted, .woke, .sessionActivated] {
        let script = ScriptedResend()
        let keeper = script.makeKeeper()
        keeper.trigger(trigger)
        check(script.calls == 0 && keeper.isWaiting, "\(trigger): waits before resending")
        await wait(.milliseconds(80))
        check(script.calls == 1, "\(trigger): sends the restriction again once")
        check(keeper.lastOutcome == .restored(trigger, attempt: 1), "\(trigger): restored")
        check(!keeper.isWaiting, "\(trigger): nothing left waiting")
    }

    section("Reliability: nothing to restore")
    do {
        let script = ScriptedResend()
        script.wanted = false
        let keeper = script.makeKeeper()
        keeper.trigger(.woke)
        await wait(.milliseconds(60))
        check(script.calls == 0 && keeper.lastOutcome == nil, "nothing hidden running: no resend")

        script.wanted = true
        keeper.trigger(.woke)
        script.wanted = false  // the user showed every icon before the resend was due
        await wait(.milliseconds(60))
        check(script.calls == 0, "paused before the resend: it is skipped")

        script.wanted = true
        keeper.trigger(.agentRestarted)
        keeper.cancel()
        await wait(.milliseconds(60))
        check(script.calls == 0 && !keeper.isWaiting, "cancel drops a waiting resend")
    }

    section("Reliability: MenuBarAgent not ready yet (login, restart)")
    do {
        let script = ScriptedResend(answers: [false, true])
        let keeper = script.makeKeeper()
        keeper.trigger(.failed)
        await checkEventually("a refused resend is retried") { script.calls == 2 }
        check(keeper.lastOutcome == .restored(.failed, attempt: 2), "restored on the second attempt")
    }
    do {
        let script = ScriptedResend(answers: [false, false, false, false, false])
        let keeper = script.makeKeeper()
        keeper.trigger(.agentRestarted)
        await checkEventually("reports that it gave up") { keeper.lastOutcome == .gaveUp(.agentRestarted, attempts: 3) }
        await wait(.milliseconds(100))
        check(script.calls == 3, "gives up after maxAttempts, no endless loop")
        check(!keeper.isWaiting, "nothing keeps running after giving up")
    }
    do {
        let script = ScriptedResend(answers: [false, false, false])
        let keeper = script.makeKeeper()
        keeper.trigger(.failed)
        // Wait for the first resend itself: a fixed delay races it on a slow CI runner.
        await checkEventually("first resend refused") { script.calls == 1 }
        script.wanted = false  // the hidden app quit meanwhile
        await wait(.milliseconds(100))
        check(script.calls == 1, "stops retrying once nothing hidden runs")
    }

    section("Reliability: several events at once")
    do {
        let script = ScriptedResend()
        let keeper = script.makeKeeper()
        // Waking often restarts MenuBarAgent too: one resend covers both.
        keeper.trigger(.woke)
        keeper.trigger(.agentRestarted)
        keeper.trigger(.sessionActivated)
        await wait(.milliseconds(80))
        check(script.calls == 1, "back-to-back triggers make one resend")
        check(keeper.lastOutcome == .restored(.sessionActivated, attempt: 1), "the newest trigger wins")
    }
    do {
        // A reply to an older resend must not schedule a retry over a newer trigger.
        var pending: [(Bool) -> Void] = []
        var calls = 0
        let keeper = RestrictionKeeper(
            policy: fastPolicy, isWanted: { true },
            resend: { done in
                calls += 1
                pending.append(done)
            })
        keeper.trigger(.failed)
        await wait(.milliseconds(40))
        check(calls == 1, "first resend is in flight")
        keeper.trigger(.agentRestarted)
        pending.removeFirst()(false)  // the stale reply arrives: refused
        await wait(.milliseconds(40))
        check(calls == 2, "the stale refusal did not add a retry; the newer trigger resent once")
        pending.removeFirst()(true)
        check(keeper.lastOutcome == .restored(.agentRestarted, attempt: 1), "the newer trigger's reply counts")
    }

    section("Reliability: with the real Restriction")
    do {
        let fake = FakeBackend()
        // Long enough that a slow CI machine replies in time, short enough to test the timeout.
        let restriction = makeRestriction(fake, timeout: .milliseconds(300))
        let allowed: Set<String> = ["capybar", "visible.app"]
        restriction.apply(allowing: allowed)
        fake.reply(0)
        let keeper = RestrictionKeeper(
            policy: fastPolicy, isWanted: { true },
            resend: { done in restriction.apply(allowing: allowed, force: true) { done($0 == nil) } })

        // MenuBarAgent restarted: the same list goes out again, although it did not change.
        keeper.trigger(.agentRestarted)
        await checkEventually("restart: the same allowlist is resent") {
            fake.activations == 2 && fake.ids(of: 1) == allowed.sorted()
        }
        fake.reply(1)
        check(fake.alive == [1], "the old assertion is released once the new one holds")
        check(keeper.lastOutcome == .restored(.agentRestarted, attempt: 1), "restored")

        // The new MenuBarAgent is still starting and refuses: Restriction fails open
        // (every icon visible) and the keeper tries again.
        keeper.trigger(.sessionActivated)
        await checkEventually("session back: resent") { fake.activations == 3 }
        fake.reply(2, error: "Connection invalid")
        check(restriction.allowed == nil, "refused: fail open, every icon visible")
        await checkEventually("the keeper retries") { fake.activations == 4 }
        fake.reply(3)
        check(restriction.allowed == allowed, "hidden again")
        check(keeper.lastOutcome == .restored(.sessionActivated, attempt: 2), "restored on the second attempt")

        // After wake MenuBarAgent may not answer at all: the reply timeout fails
        // open, and the keeper tries again.
        keeper.trigger(.woke)
        await checkEventually("wake: resent") { fake.activations == 5 }
        await checkEventually("no answer: fail open after the timeout") { restriction.allowed == nil }
        await checkEventually("the keeper retries") { fake.activations == 6 }
        fake.reply(5)
        check(restriction.allowed == allowed, "hidden again")
        check(keeper.lastOutcome == .restored(.woke, attempt: 2), "restored on the second attempt")
        check(fake.alive == [5], "exactly one assertion alive, nothing leaked")
    }

    section("Reliability: a hidden app updates and relaunches")
    do {
        let own = "capybar"
        let known: Set<String> = ["finder", "slack", "dropbox"]
        let hidden: Set<String> = ["dropbox"]
        let before = Allowlist.compute(
            running: ["finder", "slack", "dropbox"], known: known, hidden: hidden, ownBundleID: own)
        let whileQuit = Allowlist.compute(running: ["finder", "slack"], known: known, hidden: hidden, ownBundleID: own)
        let after = Allowlist.compute(
            running: ["finder", "slack", "dropbox"], known: known, hidden: hidden, ownBundleID: own)
        check(before == whileQuit && whileQuit == after, "quitting and relaunching does not change the allowlist")
        check(!after.contains("dropbox"), "the updated app is still hidden: it is matched by bundle ID")
        check(
            !Allowlist.needsRestriction(running: ["finder", "slack"], hidden: hidden, ownBundleID: own),
            "while it is quit no assertion is held (no side effects)")
        check(
            Allowlist.needsRestriction(running: ["finder", "slack", "dropbox"], hidden: hidden, ownBundleID: own),
            "back after the update: hidden again")

        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        restriction.apply(allowing: before)
        fake.reply(0)
        restriction.apply(allowing: after)
        check(fake.activations == 1, "an unchanged allowlist is not resent: no menu bar re-layout")
    }

    section("Reliability: after a restart (login)")
    do {
        // Apps that open at login after CapyBar create their icons while already hidden;
        // the cubby still lists them so they can be opened.
        check(
            Allowlist.needsUnscannedEntry(
                bundleID: "dropbox", scanned: [], hidden: ["dropbox"], iconless: [], ownBundleID: "capybar"),
            "a hidden app with no scanned icon still gets a place in the cubby")
        var watch = MenuBarAgentWatch(currentPID: nil)
        check(watch.observe(310), "MenuBarAgent starting after CapyBar counts as a restart, so the list is resent")
        check(!watch.observe(310), "and only once")
    }
}
