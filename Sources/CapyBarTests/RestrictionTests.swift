import CapyBarCore
import Foundation

final class Token {
    let id: Int
    let ids: [String]

    init(id: Int, ids: [String]) {
        self.id = id
        self.ids = ids
    }
}

/// Records activations and releases; replies only when the test says so, synchronously
/// on the main actor (the same path `Restriction` takes for any main-thread reply).
@MainActor
final class FakeBackend: AssertionBackend {
    var isAvailable = true
    var refuseActivation = false
    private var tokens: [Token] = []
    private var replies: [Int: @Sendable (String?) -> Void] = [:]
    private var released: [Int: Int] = [:]  // token id → release count

    func activate(allowing bundleIDs: [String], reply: @escaping @Sendable (String?) -> Void) -> AnyObject? {
        if refuseActivation { return nil }
        let token = Token(id: tokens.count, ids: bundleIDs)
        tokens.append(token)
        replies[token.id] = reply
        return token
    }

    func invalidate(_ assertion: AnyObject?) {
        guard let token = assertion as? Token else { return }
        released[token.id, default: 0] += 1
    }

    /// Answers activation `index` (nil = success). Each activation answers once.
    func reply(_ index: Int, error: String? = nil) {
        replies.removeValue(forKey: index)?(error)
    }

    var activations: Int { tokens.count }
    func ids(of index: Int) -> [String] { tokens[index].ids }
    func releaseCount(_ index: Int) -> Int { released[index, default: 0] }
    /// Tokens never released: these keep icons hidden in the real system.
    var alive: Set<Int> { Set(tokens.map(\.id)).subtracting(released.keys) }
    var unanswered: [Int] { replies.keys.sorted() }
}

@MainActor
final class Outcome {
    private(set) var results: [Restriction.Failure?] = []
    var called: Bool { !results.isEmpty }
    func record(_ failure: Restriction.Failure?) { results.append(failure) }
}

@MainActor
func makeRestriction(_ fake: FakeBackend, timeout: Duration = .seconds(60)) -> Restriction {
    Restriction(backend: fake, replyTimeout: timeout)
}

@MainActor
func restrictionTests() async {
    section("Restriction: basics")
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        let first = Outcome()
        restriction.apply(allowing: ["b", "a"], completion: first.record)
        check(fake.activations == 1 && fake.ids(of: 0) == ["a", "b"], "activates once with a sorted list")
        check(restriction.allowed == ["a", "b"], "reports the allowlist right away")
        check(!first.called, "completion waits for MenuBarAgent")
        fake.reply(0)
        check(first.results == [nil], "success completes with nil, exactly once")
        check(restriction.pendingCount == 0, "nothing left pending")
        check(fake.alive == [0], "the active assertion is kept")

        let same = Outcome()
        restriction.apply(allowing: ["a", "b"], completion: same.record)
        check(fake.activations == 1 && same.results == [nil], "unchanged list: no new assertion (no re-layout)")

        restriction.apply(allowing: ["a", "b", "c"])
        check(fake.activations == 2, "changed list: new assertion")
        check(fake.alive == [0, 1], "old assertion kept until the new one is confirmed (no flash)")
        fake.reply(1)
        check(fake.alive == [1], "confirmed: old assertion released")

        restriction.clear()
        check(fake.alive.isEmpty && restriction.allowed == nil, "clear releases everything")
    }

    section("Restriction: unchanged list while still pending")
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        let first = Outcome()
        let second = Outcome()
        restriction.apply(allowing: ["a"], completion: first.record)
        restriction.apply(allowing: ["a"], completion: second.record)
        check(fake.activations == 1, "no second activation")
        check(!second.called, "second caller is not told 'done' before MenuBarAgent confirms")
        fake.reply(0, error: "nope")
        check(
            first.results == [.rejected("nope")] && second.results == [.rejected("nope")],
            "both callers learn about the rejection")
    }

    section("Restriction: activation refused in between")
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        restriction.apply(allowing: ["a"])
        fake.refuseActivation = true
        let refused = Outcome()
        restriction.apply(allowing: ["a", "b"], completion: refused.record)
        check(refused.results == [.unavailable], "refused activation is reported")
        check(restriction.allowed == ["a"], "the pending one is still in charge")
        fake.refuseActivation = false
        let again = Outcome()
        restriction.apply(allowing: ["a"], completion: again.record)
        check(!again.called, "asking for the pending list again still waits for its reply")
        fake.reply(0)
        check(again.results == [nil], "and is answered when it arrives")
    }

    section("Restriction: rejection is fail-open")
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        restriction.apply(allowing: ["a"])
        fake.reply(0)
        let outcome = Outcome()
        restriction.apply(allowing: ["a", "b"], completion: outcome.record)
        fake.reply(1, error: "denied")
        check(outcome.results == [.rejected("denied")], "caller is told")
        check(fake.alive.isEmpty, "every assertion released: all icons come back")
        check(restriction.allowed == nil, "state says nothing is restricted")
        restriction.apply(allowing: ["a", "b"])
        check(fake.activations == 3, "a later apply with the same list activates again (not skipped)")
    }

    section("Restriction: newest fails with an older one still pending")
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        restriction.apply(allowing: ["a"])
        fake.reply(0)  // A confirmed
        restriction.apply(allowing: ["a", "b"])  // B pending
        let newest = Outcome()
        restriction.apply(allowing: ["a", "b", "c"], completion: newest.record)  // C
        fake.reply(2, error: "denied")
        check(newest.results == [.rejected("denied")], "the newest caller is told")
        check(fake.alive.isEmpty, "A, B and C are all released at once, not when B answers")
        check(restriction.allowed == nil, "state matches: nothing restricted")
        fake.reply(1)
        check(fake.alive.isEmpty && restriction.allowed == nil, "B's late success changes nothing")
    }

    section("Restriction: superseded activation fails")
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        let older = Outcome()
        let newer = Outcome()
        restriction.apply(allowing: ["a"], completion: older.record)
        restriction.apply(allowing: ["a", "b"], completion: newer.record)
        fake.reply(0, error: "late failure")
        check(older.results == [nil], "older caller is not told 'all shown' while a newer one is in flight")
        check(restriction.allowed == ["a", "b"], "newer allowlist still in charge")
        fake.reply(1)
        check(newer.results == [nil] && fake.alive == [1], "newer one confirmed, older released")
    }

    section("Restriction: older activation confirmed while a newer one is pending")
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        restriction.apply(allowing: ["a"])
        restriction.apply(allowing: ["a", "b"])
        fake.reply(0)
        check(fake.alive == [1], "the superseded one is released as soon as it is confirmed")
        check(restriction.allowed == ["a", "b"], "the newer allowlist stays in charge")
    }

    section("Restriction: replies out of order")
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        restriction.apply(allowing: ["a"])
        restriction.apply(allowing: ["a", "b"])
        fake.reply(1)
        fake.reply(0)
        check(fake.alive == [1], "newest wins; the older one is released when its reply comes")
    }

    section("Restriction: clear while in flight")
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake)
        restriction.apply(allowing: ["a"])
        fake.reply(0)
        let outcome = Outcome()
        restriction.apply(allowing: ["a", "b"], completion: outcome.record)
        restriction.clear()
        check(fake.alive.isEmpty, "clear releases the in-flight one and its predecessor at once")
        fake.reply(1)
        check(fake.alive.isEmpty && fake.releaseCount(1) >= 2, "late success is released again (never lingers)")
        check(outcome.called, "its caller still gets an answer")
        check(restriction.allowed == nil, "still cleared")
    }

    section("Restriction: MenuBarAgent never answers")
    do {
        let fake = FakeBackend()
        let restriction = makeRestriction(fake, timeout: .milliseconds(20))
        let outcome = Outcome()
        restriction.apply(allowing: ["a"], completion: outcome.record)
        await wait(.milliseconds(100))
        check(outcome.results == [.rejected("MenuBarAgent did not answer")], "times out with a rejection")
        check(fake.alive.isEmpty && restriction.allowed == nil, "fail-open after the timeout")
        fake.reply(0)
        check(fake.releaseCount(0) >= 2, "a reply after the timeout is released again")
        check(outcome.results.count == 1, "the caller is not answered twice")
    }

    section("Restriction: system API missing")
    do {
        let fake = FakeBackend()
        fake.isAvailable = false
        let restriction = makeRestriction(fake)
        let outcome = Outcome()
        restriction.apply(allowing: ["a"], completion: outcome.record)
        check(outcome.results == [.unavailable] && fake.activations == 0, "unavailable: nothing activated")
        check(!restriction.isAvailable, "reports the injected backend's availability")
    }

    section("Restriction: randomized sequences never leak an assertion")
    do {
        var generator = SplitMix(seed: 27)
        var leaks = 0
        var unanswered = 0
        for _ in 0..<500 {
            let fake = FakeBackend()
            let restriction = makeRestriction(fake)
            var calls = 0
            var answers = 0
            for _ in 0..<12 {
                switch generator.next() % 6 {
                case 0, 1:
                    calls += 1
                    let list = Set(["a", "b", "c", "d"].filter { _ in generator.next() % 2 == 0 })
                    restriction.apply(allowing: list.union(["own"])) { _ in answers += 1 }
                case 2:
                    restriction.clear()
                case 3:
                    fake.refuseActivation = generator.next() % 4 == 0
                default:
                    if let index = fake.unanswered.randomElement(using: &generator) {
                        fake.reply(index, error: generator.next() % 3 == 0 ? "x" : nil)
                    }
                }
            }
            restriction.clear()
            for index in fake.unanswered { fake.reply(index) }
            if !fake.alive.isEmpty { leaks += 1 }
            if answers != calls { unanswered += 1 }
        }
        check(leaks == 0, "after clear and all replies, no assertion is left alive (500 runs)")
        check(unanswered == 0, "every apply gets exactly one answer (500 runs)")
    }
}

/// Small deterministic generator so the randomized test is reproducible.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
