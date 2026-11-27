import Foundation
import MenuBarPrivate
import os

private let logger = Logger(subsystem: "app.capybar.CapyBar", category: "restriction")

/// What `Restriction` needs from the system. The real one talks to MenuBarClientCore;
/// tests substitute a fake that records activations and answers on demand.
@MainActor
package protocol AssertionBackend {
    var isAvailable: Bool { get }
    /// Starts an activation and returns its assertion object, or nil if impossible.
    /// `reply` may run on any thread: nil on success, otherwise an error description.
    func activate(allowing bundleIDs: [String], reply: @escaping @Sendable (String?) -> Void) -> AnyObject?
    /// Must tolerate nil and repeated calls.
    func invalidate(_ assertion: AnyObject?)
}

/// The real backend: MenuBarClientCore's assessment-mode assertion.
struct MenuBarAgentBackend: AssertionBackend {
    var isAvailable: Bool { MenuBarPrivate.isAvailable }

    func activate(allowing bundleIDs: [String], reply: @escaping @Sendable (String?) -> Void) -> AnyObject? {
        MenuBarPrivate.activate(allowing: bundleIDs, systemItems: SystemItems.allowAll) { error in
            reply(error.map { ($0 as NSError).localizedDescription })
        }
    }

    func invalidate(_ assertion: AnyObject?) {
        MenuBarPrivate.invalidate(assertion as? NSObject)
    }
}

/// Owns the MenuBarAgent visibility assertions CapyBar holds.
///
/// Main-actor only: every change comes from user actions or workspace notifications,
/// all delivered on the main thread, so there is no locking.
///
/// Failure policy is fail-open: if MenuBarAgent rejects the newest activation or does not
/// answer in time, every assertion is released and all icons come back. Leaving the user
/// with icons that stay hidden after they asked for them is the worse outcome.
@MainActor
public final class Restriction {

    public enum Failure: Error, Equatable {
        case unavailable
        case rejected(String)
    }

    /// How long MenuBarAgent may take to confirm an activation (it answers in < 10 ms).
    static let defaultReplyTimeout: Duration = .seconds(3)
    /// Bound on remembered timed-out activations; late replies are rare.
    static let maxAbandoned = 32

    private struct Pending {
        let created: AnyObject
        let previous: AnyObject?
        var completions: [@MainActor (Failure?) -> Void]
    }

    private let backend: any AssertionBackend
    private let replyTimeout: Duration
    private var assertion: AnyObject?
    private var applied: Set<String>?
    /// Generation of the newest activation that was actually created.
    private var generation = 0
    /// Activations waiting for MenuBarAgent's reply, by generation. Each keeps the
    /// assertion it replaces alive until the reply says whether the new one took effect.
    private var pending: [Int: Pending] = [:]
    /// Activations given up on after a timeout. Released again if a late reply arrives,
    /// in case the framework ignored a release sent before activation completed.
    private var abandoned: [Int: AnyObject] = [:]
    /// While lifted (see `suspend()`): the list `resume()` sends.
    private var suspendedList: Set<String>?
    /// Completions of `apply` calls made while lifted; they get `resume()`'s answer.
    private var deferred: [@MainActor (Failure?) -> Void] = []

    public convenience init() {
        self.init(backend: MenuBarAgentBackend(), replyTimeout: Self.defaultReplyTimeout)
    }

    package init(backend: any AssertionBackend, replyTimeout: Duration) {
        self.backend = backend
        self.replyTimeout = replyTimeout
    }

    public var isAvailable: Bool { backend.isAvailable }

    /// Currently enforced allowlist, nil when nothing is restricted.
    public var allowed: Set<String>? { applied }

    package var pendingCount: Int { pending.count }

    /// Lifted by `suspend()`; `resume()` hides again.
    public var isSuspended: Bool { suspendedList != nil }

    /// Releases the restriction while Notification Center is open from the clock (macOS
    /// ignores the clock while any restriction is held). Until `resume()`, `apply` only
    /// records the newest list, and `clear()` ends the lift for good.
    ///
    /// Returns false when nothing is held, or when an activation still waits for
    /// MenuBarAgent: a release sent before it answers can be ignored.
    public func suspend() -> Bool {
        guard suspendedList == nil, let applied, assertion != nil, pending.isEmpty else { return false }
        logger.info("restriction lifted for the clock")
        suspendedList = applied
        backend.invalidate(assertion)
        assertion = nil
        self.applied = nil
        return true
    }

    /// Ends a lift: sends the newest list again. The completion, and those of `apply`
    /// calls made meanwhile, get its answer. Does nothing unless lifted.
    public func resume(completion: (@MainActor (Failure?) -> Void)? = nil) {
        guard let list = suspendedList else {
            completion?(nil)
            return
        }
        suspendedList = nil
        let waiting = deferred
        deferred = []
        logger.info("restriction back after a lift")
        apply(allowing: list, force: true) { failure in
            waiting.forEach { $0(failure) }
            completion?(failure)
        }
    }

    /// Makes `bundleIDs` the only apps whose icons are drawn.
    ///
    /// The new assertion is activated before the old one is released (the newest wins),
    /// so the bar never flashes every icon in between. An unchanged list is not sent
    /// again: every new assertion makes MenuBarAgent re-lay out the whole bar. `force`
    /// sends it anyway.
    public func apply(
        allowing bundleIDs: Set<String>,
        force: Bool = false,
        completion: (@MainActor (Failure?) -> Void)? = nil
    ) {
        guard backend.isAvailable else {
            completion?(.unavailable)
            return
        }
        if suspendedList != nil {
            // Lifted for a click on the clock: `resume()` sends the newest list.
            suspendedList = bundleIDs
            if let completion { deferred.append(completion) }
            return
        }
        if !force, assertion != nil, applied == bundleIDs {
            // Same list: if it is still waiting for MenuBarAgent, answer when it does.
            if let completion, pending[generation] != nil {
                pending[generation]?.completions.append(completion)
            } else {
                completion?(nil)
            }
            return
        }

        let myGeneration = generation + 1
        let created = backend.activate(allowing: bundleIDs.sorted()) { @Sendable [weak self] message in
            // Real replies come on MenuBarClientCore's XPC queue; test replies on main.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.activationFinished(myGeneration, error: message) }
            } else {
                Task { @MainActor in self?.activationFinished(myGeneration, error: message) }
            }
        }
        guard let created else {
            completion?(.unavailable)
            return
        }

        generation = myGeneration
        pending[myGeneration] = Pending(
            created: created,
            previous: assertion,
            completions: completion.map { [$0] } ?? []
        )
        assertion = created
        applied = bundleIDs
        logger.info(
            "activation #\(myGeneration, privacy: .public) requested, \(bundleIDs.count, privacy: .public) apps")

        let timeout = replyTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.activationFinished(myGeneration, error: "MenuBarAgent did not answer", timedOut: true)
        }
    }

    /// Releases every assertion: all icons are drawn again. Activations still in flight
    /// keep their entries so their callers still get an answer.
    public func clear() {
        if suspendedList != nil {
            // Nothing is held while lifted: the lift just never ends.
            suspendedList = nil
            let waiting = deferred
            deferred = []
            waiting.forEach { $0(nil) }
        }
        guard assertion != nil || !pending.isEmpty else { return }
        logger.info("restriction cleared")
        releaseAll()
    }

    // MARK: - Replies

    private func releaseAll() {
        generation += 1  // nothing in flight is "current" any more
        backend.invalidate(assertion)
        for entry in pending.values {
            backend.invalidate(entry.created)
            backend.invalidate(entry.previous)
        }
        assertion = nil
        applied = nil
    }

    private func activationFinished(_ finished: Int, error: String?, timedOut: Bool = false) {
        guard let entry = pending.removeValue(forKey: finished) else {
            // Reply for an activation we already gave up on: make sure it is released.
            if !timedOut, let late = abandoned.removeValue(forKey: finished) {
                backend.invalidate(late)
            }
            return
        }
        logger.info("activation #\(finished, privacy: .public) finished, error: \(error ?? "none", privacy: .public)")
        let isCurrent = assertion === entry.created

        guard let error else {
            // Confirmed: whatever it replaced is superseded. If it was itself cleared or
            // replaced while in flight, it must not linger either.
            backend.invalidate(entry.previous)
            if !isCurrent { backend.invalidate(entry.created) }
            entry.completions.forEach { $0(nil) }
            return
        }

        backend.invalidate(entry.created)
        if timedOut {
            if abandoned.count >= Self.maxAbandoned { abandoned.removeAll() }
            abandoned[finished] = entry.created
        }
        if isCurrent {
            // The newest activation failed: fail open. Release everything, including
            // older confirmed or still-pending assertions further back in the chain.
            backend.invalidate(entry.previous)
            releaseAll()
            entry.completions.forEach { $0(.rejected(error)) }
        } else {
            // A newer activation owns the bar and releases this one's predecessor when
            // it is confirmed; this failure changes nothing for callers.
            backend.invalidate(entry.previous)
            entry.completions.forEach { $0(nil) }
        }
    }
}
