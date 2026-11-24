import Foundation
import os

private let logger = Logger(subsystem: "app.capybar.CapyBar", category: "keeper")

/// Gets hidden icons hidden again after macOS loses or refuses CapyBar's restriction.
///
/// The restriction lives in MenuBarAgent. It is gone when MenuBarAgent restarts, may not
/// survive sleep or a switch back from another user, and is refused while MenuBarAgent is
/// still starting up (CapyBar opening at login can be faster). `Restriction` fails open
/// in all of these cases, so the icons come back; this class sends the restriction again,
/// with a few retries spaced further apart, and gives up quietly if nothing helps.
///
/// It decides only when to resend; what to send is the caller's (`resend`).
@MainActor
public final class RestrictionKeeper {

    public enum Trigger: String, Sendable, CaseIterable {
        /// MenuBarAgent has a new pid: the old restriction died with the old process.
        case agentRestarted
        /// The Mac woke from sleep.
        case woke
        /// This user's session became active again (fast user switching, screen unlock).
        case sessionActivated
        /// Sending the restriction failed, so every icon is visible right now.
        case failed
    }

    public struct Policy: Sendable {
        /// Delay before the first resend for each trigger; attempt N waits 2^(N-1) times
        /// as long, so a slow MenuBarAgent gets more time on each try.
        public var firstDelay: [Trigger: Duration]
        public var maxAttempts: Int

        public init(firstDelay: [Trigger: Duration], maxAttempts: Int) {
            self.firstDelay = firstDelay
            self.maxAttempts = maxAttempts
        }

        /// MenuBarAgent answers in milliseconds once it runs; the delays cover its start.
        /// Four attempts span about 15 s after a restart and 30 s after a failure.
        public static let standard = Policy(
            firstDelay: [
                .agentRestarted: .seconds(1), .woke: .seconds(2), .sessionActivated: .seconds(1), .failed: .seconds(2),
            ],
            maxAttempts: 4)

        public func delay(for trigger: Trigger, attempt: Int) -> Duration {
            (firstDelay[trigger] ?? .seconds(1)) * (1 << max(0, min(attempt - 1, 16)))
        }
    }

    /// Sends the current restriction again (forced, even if unchanged) and reports
    /// whether MenuBarAgent accepted it.
    public typealias Resend = @MainActor (_ done: @escaping @MainActor (_ accepted: Bool) -> Void) -> Void

    private let policy: Policy
    private let resend: Resend
    /// False when nothing hidden is running or hiding is paused: then there is nothing
    /// to restore and no resend happens.
    private let isWanted: @MainActor () -> Bool
    private var task: Task<Void, Never>?
    /// Bumped by every trigger, so a reply to an older resend cannot schedule a retry
    /// over a newer one.
    private var generation = 0

    /// Resends made so far, and the outcome of the last one; for tests and diagnostics.
    public private(set) var resendCount = 0
    public private(set) var lastOutcome: Outcome?

    public enum Outcome: Equatable, Sendable {
        case restored(Trigger, attempt: Int)
        case gaveUp(Trigger, attempts: Int)
    }

    public init(
        policy: Policy = .standard,
        isWanted: @escaping @MainActor () -> Bool,
        resend: @escaping Resend
    ) {
        self.policy = policy
        self.isWanted = isWanted
        self.resend = resend
    }

    /// A newer trigger replaces a resend still waiting: one resend covers both.
    public func trigger(_ trigger: Trigger) {
        generation += 1
        task?.cancel()
        task = nil
        guard isWanted() else {
            logger.info("\(trigger.rawValue, privacy: .public): nothing hidden, no resend")
            return
        }
        logger.info("\(trigger.rawValue, privacy: .public): resend scheduled")
        schedule(trigger, attempt: 1, generation: generation)
    }

    /// Drops a resend still waiting, for example when the user shows every icon.
    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    public var isWaiting: Bool { task != nil }

    private func schedule(_ trigger: Trigger, attempt: Int, generation: Int) {
        let delay = policy.delay(for: trigger, attempt: attempt)
        task = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, let self, self.generation == generation else { return }
            task = nil
            guard isWanted() else { return }
            resendCount += 1
            logger.info("\(trigger.rawValue, privacy: .public): resend attempt \(attempt, privacy: .public)")
            resend { [weak self] accepted in
                self?.finished(trigger, attempt: attempt, generation: generation, accepted: accepted)
            }
        }
    }

    private func finished(_ trigger: Trigger, attempt: Int, generation: Int, accepted: Bool) {
        guard self.generation == generation else { return }
        if accepted {
            lastOutcome = .restored(trigger, attempt: attempt)
            logger.info("\(trigger.rawValue, privacy: .public): restored on attempt \(attempt, privacy: .public)")
        } else if attempt < policy.maxAttempts, isWanted() {
            schedule(trigger, attempt: attempt + 1, generation: generation)
        } else {
            lastOutcome = .gaveUp(trigger, attempts: attempt)
            logger.error("\(trigger.rawValue, privacy: .public): gave up after \(attempt, privacy: .public) attempts")
        }
    }
}
