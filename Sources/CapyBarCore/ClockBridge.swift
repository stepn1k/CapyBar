import AppKit
import ApplicationServices
import Synchronization
import os

private let logger = Logger(subsystem: "app.capybar.CapyBar", category: "clock")

/// A press while the panel is open, as the tap classifies it.
package enum ClockPress: Sendable, Equatable {
    case none
    /// The clock: macOS toggles the panel itself, since the restriction is lifted.
    case clock
    /// Another item in the bar: its menu opens, so its icon must stay drawn.
    case bar
    /// Outside the panel: it closes, and icons are hidden again at once.
    case elsewhere
    /// Somewhere else before the held press went through: the user moved on, so the press
    /// is dropped rather than opening the panel late.
    case cancel
}

/// Decides, for every left click, whether the tap holds it back. Pure and lock-free:
/// the tap guards it. `Event` is `CGEvent` in the app and anything in tests.
package struct ClockGate<Event> {

    package enum Phase: Equatable {
        case idle
        /// A press on the clock is held while the restriction is lifted.
        case holding
        /// The held press went through; Notification Center may be open.
        case open
    }

    package enum Decision: Equatable {
        case pass
        /// Hold it; `starts` when it begins a session.
        case hold(starts: Bool)
        /// Pass it, and tell the session.
        case passPressed(ClockPress)
    }

    /// macOS takes clicks a little beyond the clock's frame: up to 6 pt toward its
    /// neighbour (8 pt reaches the next item), and the whole margin to the screen edge.
    static var paddingTowardNeighbour: CGFloat { 6 }
    static var paddingTowardScreenEdge: CGFloat { 24 }
    /// Notification Center's panel is at most this wide, at the right edge of its display.
    static var panelWidth: CGFloat { 420 }

    package private(set) var phase = Phase.idle
    private var held: [Event] = []
    /// Mouse event numbers of the held presses: their drags and releases are held too.
    private var heldKeys: Set<Int64> = []
    /// Dropped: what is held, and what follows it, never goes through.
    private var isDiscarding = false
    package var clocks: [CGRect] = []
    package var menuBars: [CGRect] = []
    package var displays: [CGRect] = []
    package var isLeftToRight = true

    package init() {}

    /// `refused`: ⌘-drag rearranges the bar, ⌃-click is a right click, ⌥-click is refused.
    package mutating func down(_ event: Event, key: Int64, at point: CGPoint, refused: Bool) -> Decision {
        switch phase {
        case .idle:
            guard !refused, isOnClock(point) else { return .pass }
            phase = .holding
            held = [event]
            heldKeys = [key]
            return .hold(starts: true)
        case .holding:
            // The clock again before the first went through: it follows it, in order.
            // A press anywhere else passes at once, and the held one is dropped: going
            // through after it would open the panel after the user moved on.
            guard !refused, isOnClock(point) else { return .passPressed(.cancel) }
            held.append(event)
            heldKeys.insert(key)
            return .hold(starts: false)
        case .open:
            if isOnClock(point) { return .passPressed(.clock) }
            if contains(menuBars, point) { return .passPressed(.bar) }
            if isLeftOfPanel(point) { return .passPressed(.elsewhere) }
            return .pass
        }
    }

    /// A drag or release is held while its press is.
    package mutating func follow(_ event: Event, key: Int64) -> Decision {
        guard phase == .holding, heldKeys.contains(key) else { return .pass }
        if !isDiscarding { held.append(event) }
        return .hold(starts: false)
    }

    /// The held press won't go through; its release and drags are swallowed too.
    package mutating func discard() {
        isDiscarding = true
        held = []
    }

    /// The restriction is lifted: what was held goes through now, and later clicks pass.
    package mutating func release() -> [Event] {
        defer {
            held = []
            heldKeys = []
        }
        if phase == .holding { phase = .open }
        return held
    }

    /// The session is over; anything still held goes through.
    package mutating func end() -> [Event] {
        defer {
            held = []
            heldKeys = []
            isDiscarding = false
            phase = .idle
        }
        return isDiscarding ? [] : held
    }

    /// The clock's frame is shorter than the bar, but macOS takes a click anywhere in the
    /// bar's height, the very top edge included.
    package func isOnClock(_ point: CGPoint) -> Bool {
        clocks.contains { frame in
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let bar = menuBars.first { $0.contains(center) }
            let target =
                bar.map { frame.union(CGRect(x: frame.minX, y: $0.minY, width: frame.width, height: $0.height)) }
                ?? frame
            // The padding never reaches onto the display next door.
            let display = displays.first { $0.contains(center) }
            return Self.isOnClock(point, frame: target, isLeftToRight: isLeftToRight)
                && (display?.contains(point) ?? true)
        }
    }

    package static func isOnClock(_ point: CGPoint, frame: CGRect, isLeftToRight: Bool) -> Bool {
        let left = isLeftToRight ? paddingTowardNeighbour : paddingTowardScreenEdge
        let right = isLeftToRight ? paddingTowardScreenEdge : paddingTowardNeighbour
        return point.x >= frame.minX - left && point.x <= frame.maxX + right
            && point.y >= frame.minY && point.y < frame.maxY
    }

    private func contains(_ rects: [CGRect], _ point: CGPoint) -> Bool {
        rects.contains { $0.minX <= point.x && point.x <= $0.maxX && $0.minY <= point.y && point.y <= $0.maxY }
    }

    private func isLeftOfPanel(_ point: CGPoint) -> Bool {
        guard let display = displays.first(where: { $0.contains(point) }) else { return false }
        return point.x < display.maxX - Self.panelWidth
    }
}

/// What a session needs from the system. `SystemClockEnvironment` does the real work;
/// tests script the answers.
package protocol ClockEnvironment: AnyObject, Sendable {
    /// Releases the restriction; false when it can't be released now.
    func lift() -> Bool
    /// Puts the restriction back. Safe to call when it already is.
    func restore()
    func pause(_ seconds: TimeInterval)
    /// Seconds on a monotonic clock.
    func now() -> TimeInterval
    /// The clock's frame on every display (global, top-left origin).
    func clockFrames() -> [CGRect]
    /// Blocks until MenuBarAgent answers Accessibility, which it does only once a lift has
    /// taken effect. False when it doesn't answer.
    func waitForMenuBarAgent() -> Bool
    /// Notification Center's display-tall windows on screen: its panel, or a banner.
    func centerWindows() -> Set<CGWindowID>
    /// Whether those windows show Edit Widgets, which only the panel has; nil when
    /// Accessibility can't read them.
    func showsPanelControls() -> Bool?
    /// A menu is open somewhere (one opened from the bar, say).
    func menusOpen() -> Bool
    /// Lets the held press through to MenuBarAgent.
    func releaseHeldPress()
    /// Drops the held press: it never reaches MenuBarAgent.
    func dropHeldPress()
    /// The session is over: the next press on the clock may be held again.
    func sessionEnded()
}

/// Opens Notification Center from the clock while icons are hidden.
///
/// macOS ignores clicks on the clock while a restriction is held. The tap holds a press on
/// the clock back; the session lifts the restriction, lets the press through once
/// MenuBarAgent takes clicks again, and restores the restriction as Notification Center
/// closes. Hidden icons show while it is open, as they would without CapyBar. Exactly one
/// click reaches the clock, so the panel never opens and closes again by itself.
/// Runs on one serial queue, since every step waits on another process.
package final class ClockEngine: @unchecked Sendable {

    package enum Outcome: String, Sendable {
        /// Notification Center opened, and has closed again.
        case opened
        /// It was already open: the press closed it.
        case closed
        case notOpened
        /// The restriction couldn't be lifted.
        case notLifted
        /// The user clicked elsewhere before the press went through.
        case cancelled
        /// MenuBarAgent didn't answer once lifted (it restarted, say).
        case noClock
    }

    /// Asking MenuBarAgent sooner than this after a lift can return before it applied it.
    static let liftDelay: TimeInterval = 0.03
    /// Clicks sooner than this after a lift can be ignored.
    package static let minimumLift: TimeInterval = 0.08
    /// A lift is refused while the previous restore still waits for MenuBarAgent.
    static let liftRetry: TimeInterval = 0.15
    static let panelTimeout: TimeInterval = 0.5
    static let panelPoll: TimeInterval = 0.01
    static let closePoll: TimeInterval = 0.05
    /// Every this many polls the panel's controls are looked at too, in case a lasting alert
    /// window came up with it and outlives it.
    static let controlsEvery = 10
    /// After closing from the clock: a press this soon reopens the panel while still
    /// lifted, so the bar doesn't hide and show again.
    static let reopenGrace: TimeInterval = 0.12
    package static let closeTimeout: TimeInterval = 600
    static let menuTimeout: TimeInterval = 120

    private let env: any ClockEnvironment
    /// Windows the panel is in, while on screen.
    private var panelWindows: Set<CGWindowID> = []
    /// The panel took a window a banner already had, so only Edit Widgets tells when it
    /// closes.
    private var panelSharesBannerWindow = false
    private let press = Mutex(ClockPress.none)

    /// Called on the queue with the clock's frames whenever they are read.
    package var onClocks: (@Sendable ([CGRect]) -> Void)?

    package init(env: any ClockEnvironment) {
        self.env = env
    }

    package func refreshClocks() {
        onClocks?(env.clockFrames())
    }

    /// Any thread.
    package func pressed(_ kind: ClockPress) {
        press.withLock { $0 = kind }
    }

    /// A press on the clock is held: one session, from the lift to hiding again.
    package func run() -> Outcome {
        defer { env.sessionEnded() }
        press.withLock { $0 = .none }
        // Open already (from a swipe, say): the press closes it, but only once lifted too.
        // Only when it surely is: unreadable windows could be a banner.
        let wasOpen = isPanelOpenForSure()
        let deadline = env.now() + Self.liftRetry
        while !env.lift() {
            guard env.now() < deadline else {
                env.releaseHeldPress()
                return .notLifted
            }
            env.pause(Self.panelPoll)
        }
        let lifted = env.now()
        env.pause(Self.liftDelay)
        guard env.waitForMenuBarAgent() else {
            env.releaseHeldPress()
            env.restore()
            return .noClock
        }
        let ready = env.now() - lifted
        if ready < Self.minimumLift { env.pause(Self.minimumLift - ready) }
        if press.withLock({ $0 }) == .cancel {
            env.dropHeldPress()
            env.restore()
            return .cancelled
        }
        let before = env.centerWindows()
        env.releaseHeldPress()
        if wasOpen {
            let closeDeadline = env.now() + Self.panelTimeout * 2
            while !isPanelGone(), env.now() < closeDeadline { env.pause(Self.closePoll) }
            panelWindows = []
            env.restore()
            return .closed
        }
        let opened = waitForPanel(excluding: before)
        let ms = { (seconds: TimeInterval) in Int((seconds * 1000).rounded()) }
        logger.info(
            """
            clock: released \(ms(max(ready, Self.minimumLift)), privacy: .public) ms after the lift, panel \
            \(opened ? "at" : "missing", privacy: .public) \(ms(self.env.now() - lifted), privacy: .public) ms
            """)
        guard opened else {
            env.restore()
            return .notOpened
        }
        waitUntilPanelCloses()
        env.restore()
        return .opened
    }

    /// Open by its own window or by Edit Widgets, never by unreadable windows alone.
    private func isPanelOpenForSure() -> Bool {
        let windows = env.centerWindows()
        panelWindows.formIntersection(windows)
        guard !windows.isEmpty else { return false }
        if !panelWindows.isEmpty { return true }
        guard env.showsPanelControls() == true else { return false }
        panelWindows = windows
        panelSharesBannerWindow = true
        return true
    }

    /// The panel's own window still up, or a window showing Edit Widgets. Unreadable
    /// counts as open, so a press never reopens it.
    package func isPanelOpen() -> Bool {
        let windows = env.centerWindows()
        panelWindows.formIntersection(windows)
        guard !windows.isEmpty else { return false }
        if !panelWindows.isEmpty { return true }
        return env.showsPanelControls() ?? true
    }

    private func waitForPanel(excluding before: Set<CGWindowID>) -> Bool {
        let deadline = env.now() + Self.panelTimeout
        while env.now() < deadline {
            if spotPanel(excluding: before) { return true }
            env.pause(Self.panelPoll)
        }
        return false
    }

    /// A new window, or Edit Widgets in a banner's window.
    private func spotPanel(excluding before: Set<CGWindowID>) -> Bool {
        let windows = env.centerWindows()
        let fresh = windows.subtracting(before)
        if !fresh.isEmpty {
            panelWindows = fresh
            panelSharesBannerWindow = false
            return true
        }
        if !windows.isEmpty, env.showsPanelControls() == true {
            panelWindows = windows
            panelSharesBannerWindow = true
            return true
        }
        return false
    }

    /// Returns once the panel is gone, or a press outside it closed it, or after
    /// `closeTimeout`. Polls only while the panel is open.
    private func waitUntilPanelCloses() {
        let deadline = env.now() + Self.closeTimeout
        var barPressed = false
        var clockPressed = false
        var polls = 0
        var controlsMissing = 0
        while env.now() < deadline {
            polls += 1
            switch press.withLock({ kind in
                defer { kind = .none }
                return kind
            }) {
            case .elsewhere:
                panelWindows = []
                return
            case .bar: barPressed = true
            case .clock: clockPressed = true
            case .none, .cancel: break
            }
            // Edit Widgets gone twice running: the windows left are a lasting alert's. Once
            // could be a slow read, or Edit Widgets turning into Done.
            if polls % Self.controlsEvery == 0 {
                controlsMissing = env.showsPanelControls() == false ? controlsMissing + 1 : 0
            }
            if isPanelGone() || controlsMissing >= 2 {
                if clockPressed, waitForReopen() {
                    clockPressed = false
                    continue
                }
                break
            }
            env.pause(Self.closePoll)
        }
        panelWindows = []
        // A menu opened from an icon shown meanwhile needs that icon drawn.
        if barPressed {
            let menusDeadline = env.now() + Self.menuTimeout
            while env.menusOpen(), env.now() < menusDeadline { env.pause(Self.closePoll) }
        }
    }

    private func isPanelGone() -> Bool {
        panelWindows.formIntersection(env.centerWindows())
        guard !panelWindows.isEmpty else { return true }
        return panelSharesBannerWindow && env.showsPanelControls() != true
    }

    private func waitForReopen() -> Bool {
        let banners = env.centerWindows()
        let deadline = env.now() + Self.reopenGrace
        while env.now() < deadline {
            env.pause(Self.panelPoll)
            if spotPanel(excluding: banners) { return true }
        }
        return false
    }
}

/// Holds presses on the clock back while icons are hidden (see `ClockEngine`). An active
/// event tap, which Accessibility allows; every other click passes untouched.
///
/// Fails open: if CapyBar stalls, macOS turns the tap off and clicks flow as usual, and
/// stopping it lets anything held go through.
@MainActor
public final class ClockBridge {

    /// Marks clicks CapyBar posts. Posting again can drop it, so the tap also matches
    /// them by mouse event number.
    nonisolated static let releaseTag: Int64 = 0x4361_7079  // "Capy"

    private let lift: @MainActor @Sendable () -> Bool
    private let restore: @MainActor @Sendable () -> Void
    private var tap: ClockTap?
    private var screenObserver: NSObjectProtocol?

    public init(lift: @escaping @MainActor @Sendable () -> Bool, restore: @escaping @MainActor @Sendable () -> Void) {
        self.lift = lift
        self.restore = restore
    }

    public func arm() {
        guard tap == nil else { return }
        let tap = ClockTap(lift: lift, restore: restore)
        guard tap.start() else { return }
        self.tap = tap
        updateScreens()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateScreens() }
        }
    }

    public func disarm() {
        tap?.stop()
        tap = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func updateScreens() {
        tap?.update(
            menuBars: Self.menuBarFrames(), displays: ItemPresser.activeDisplayBounds(),
            isLeftToRight: NSApp?.userInterfaceLayoutDirection != .rightToLeft)
    }

    /// The menu bar of every display (global, top-left origin).
    static func menuBarFrames() -> [CGRect] {
        guard let primaryHeight = NSScreen.screens.first?.frame.maxY else { return [] }
        return NSScreen.screens.map { screen in
            let height = max(
                screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top,
                NSStatusBar.system.thickness)
            return CGRect(
                x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: height)
        }
    }
}

/// The tap itself, on a thread of its own so a busy main thread never delays a click.
final class ClockTap: @unchecked Sendable {

    private let lock = NSLock()
    private var gate = ClockGate<CGEvent>()
    /// Clicks CapyBar let through, by mouse event number: they come back through the tap,
    /// and the user-data tag doesn't survive posting again.
    private var released: [Int64] = []
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    /// Turned off: a session already queued must not lift any more.
    private var stopped = false
    /// Counts sessions, so the hold limit only ends the one it was set for.
    private var sessions = 0
    /// The longest a press is held, whatever the session is waiting for.
    static let holdLimit: TimeInterval = 1.5

    /// Tells when the clock's text changes (every minute, or its format), so its frame is
    /// read again then rather than on a timer. Used on `queue` only.
    private var clockObserver: (observer: AXObserver, pid: pid_t)?
    var isStopped: Bool { withLockHeld { stopped } }
    private let queue = DispatchQueue(label: "app.capybar.clock", qos: .userInteractive)
    private let restoreOnMain: @MainActor @Sendable () -> Void
    private var env: SystemClockEnvironment!
    private var engine: ClockEngine!

    init(lift: @escaping @MainActor @Sendable () -> Bool, restore: @escaping @MainActor @Sendable () -> Void) {
        restoreOnMain = restore
        env = SystemClockEnvironment(tap: self, lift: lift, restore: restore)
        engine = ClockEngine(env: env)
        engine.onClocks = { [weak self] frames in self?.withGate { $0.clocks = frames } }
    }

    private func withGate<T>(_ body: (inout ClockGate<CGEvent>) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&gate)
    }

    func update(menuBars: [CGRect], displays: [CGRect], isLeftToRight: Bool) {
        withGate {
            $0.menuBars = menuBars
            $0.displays = displays
            $0.isLeftToRight = isLeftToRight
        }
        refreshClocks()
    }

    /// Reads the clock's frame again, and (re)subscribes to its changes when MenuBarAgent
    /// is new. Any thread.
    func refreshClocks() {
        queue.async { [self] in
            engine.refreshClocks()
            watchClock()
        }
    }

    /// The clock was rebuilt: watch the new one.
    private func clockElementGone() {
        queue.async { [self] in
            if let old = clockObserver { CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(old.observer)) }
            clockObserver = nil
        }
    }

    private func watchClock() {
        guard let pid = env.agentPID, clockObserver?.pid != pid, !isStopped else { return }
        if let old = clockObserver {
            CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(old.observer))
        }
        clockObserver = nil
        var observer: AXObserver?
        let created = AXObserverCreate(
            pid,
            { _, _, note, refcon in
                guard let refcon else { return }
                let tap = Unmanaged<ClockTap>.fromOpaque(refcon).takeUnretainedValue()
                if (note as String) == kAXUIElementDestroyedNotification { tap.clockElementGone() }
                tap.refreshClocks()
            }, &observer)
        guard created == .success, let observer, let runLoop = withLockHeld({ runLoop }) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notes = [
            kAXTitleChangedNotification, kAXValueChangedNotification, kAXResizedNotification, kAXMovedNotification,
            kAXUIElementDestroyedNotification,
        ]
        var watching = false
        for element in env.clockElements() {
            for note in notes where AXObserverAddNotification(observer, element, note as CFString, refcon) == .success {
                watching = true
            }
        }
        // No clock yet (the bar was mid-layout): try again on the next refresh.
        guard watching else { return }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .commonModes)
        CFRunLoopWakeUp(runLoop)
        clockObserver = (observer, pid)
    }

    func start() -> Bool {
        let mask =
            (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    return Unmanaged<ClockTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            logger.error("clock: no event tap")
            return false
        }
        self.port = port
        let ready = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            lock.lock()
            let port = self.port
            runLoop = CFRunLoopGetCurrent()
            lock.unlock()
            guard let port else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        ready.wait()
        return true
    }

    func stop() {
        lock.lock()
        let port = port
        let runLoop = runLoop
        self.port = nil
        self.runLoop = nil
        stopped = true
        lock.unlock()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        queue.async { [self] in
            if let old = clockObserver { CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(old.observer)) }
            clockObserver = nil
        }
        engine.pressed(.elsewhere)
        post(withGate { $0.end() })
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let port = port
            lock.unlock()
            // Never revive it without Accessibility: the controller is taking it down.
            if let port, AXIsProcessTrusted() { CGEvent.tapEnable(tap: port, enable: true) }
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != ClockBridge.releaseTag else { return pass }
        let number = event.getIntegerValueField(.mouseEventNumber)
        let isOurs: Bool = withLockHeld {
            guard let index = released.firstIndex(of: number) else { return false }
            released.remove(at: index)
            return true
        }
        if isOurs { return pass }
        let decision: ClockGate<CGEvent>.Decision
        if type == .leftMouseDown {
            let refused = !event.flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate])
            decision = withGate { $0.down(event, key: number, at: event.location, refused: refused) }
        } else {
            decision = withGate { $0.follow(event, key: number) }
        }
        switch decision {
        case .pass:
            return pass
        case .hold(let starts):
            if starts {
                sessions += 1
                let session = sessions
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Self.holdLimit) {
                    [weak self] in self?.endHold(session)
                }
                let engine = engine!
                queue.async {
                    let outcome = engine.run()
                    engine.refreshClocks()
                    self.watchClock()
                    logger.info("clock session done: \(outcome.rawValue, privacy: .public)")
                }
            }
            return nil
        case .passPressed(let kind):
            engine.pressed(kind)
            if kind == .cancel { logger.info("clock: clicked elsewhere first, press dropped") }
            if kind == .elsewhere {
                // Hide now, so the bar changes while the panel slides out.
                let restore = restoreOnMain
                DispatchQueue.main.async { MainActor.assumeIsolated { restore() } }
            }
            return pass
        }
    }

    /// Still holding after `holdLimit` (a hung Accessibility read, say): let the press
    /// through as it is rather than keep the user's click.
    private func endHold(_ session: Int) {
        lock.lock()
        guard session == sessions, gate.phase == .holding else {
            lock.unlock()
            return
        }
        logger.error("clock: press held too long, let through")
        postLocked(gate.release())
        lock.unlock()
    }

    fileprivate func releaseHeldPress() {
        // Posted under the lock, so a live release can't overtake its held press.
        lock.lock()
        let pointer = CGEvent(source: nil)?.location
        let events = gate.release()
        postLocked(events)
        lock.unlock()
        // Posting a click moves the pointer to it; put it back if it had moved on.
        if let pointer, let clicked = events.first?.location, hypot(pointer.x - clicked.x, pointer.y - clicked.y) > 1 {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + ItemPresser.clickSettleDelay) {
                CGWarpMouseCursorPosition(pointer)
            }
        }
    }

    fileprivate func dropHeldPress() {
        withGate { $0.discard() }
    }

    fileprivate func sessionEnded() {
        post(withGate { $0.end() })
    }

    private func withLockHeld<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func post(_ events: [CGEvent]) {
        lock.lock()
        defer { lock.unlock() }
        postLocked(events)
    }

    private func postLocked(_ events: [CGEvent]) {
        guard !events.isEmpty else { return }
        released.append(contentsOf: events.map { $0.getIntegerValueField(.mouseEventNumber) })
        if released.count > 16 { released.removeFirst(released.count - 16) }
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: ClockBridge.releaseTag)
            event.post(tap: .cgSessionEventTap)
        }
    }
}

/// The real restriction, clock and Notification Center.
final class SystemClockEnvironment: ClockEnvironment, @unchecked Sendable {

    static let menuBarAgentID = "com.apple.MenuBarAgent"
    static let clockID = "com.apple.menuextra.clock"
    static let notificationCenterID = "com.apple.notificationcenterui"
    static let panelControlID = "widget-editor-button"
    static let messagingTimeout: Float = 0.5
    /// Edit Widgets sits four levels below the window; deeper levels hold notifications.
    static let controlDepth = 5
    /// How long a lift may wait for the main thread before the press goes through anyway.
    static let mainTimeout: TimeInterval = 1

    private weak var tap: ClockTap?
    private let liftOnMain: @MainActor @Sendable () -> Bool
    private let restoreOnMain: @MainActor @Sendable () -> Void

    init(
        tap: ClockTap, lift: @escaping @MainActor @Sendable () -> Bool,
        restore: @escaping @MainActor @Sendable () -> Void
    ) {
        self.tap = tap
        liftOnMain = lift
        restoreOnMain = restore
    }

    /// A stalled main thread never holds a click for long: past `mainTimeout` the press
    /// goes through restricted, and a late lift is undone at once.
    func lift() -> Bool {
        guard tap?.isStopped == false else { return false }
        let lift = liftOnMain
        let restore = restoreOnMain
        let result = Mutex<Bool?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let lifted = lift()
                let late = result.withLock { value -> Bool in
                    if value == false { return true }
                    value = lifted
                    return false
                }
                if late, lifted { restore() }
                done.signal()
            }
        }
        if done.wait(timeout: .now() + Self.mainTimeout) == .timedOut {
            return result.withLock { value in
                if let value { return value }
                value = false
                return false
            }
        }
        return result.withLock { $0 } ?? false
    }

    func restore() {
        let restore = restoreOnMain
        DispatchQueue.main.async { MainActor.assumeIsolated { restore() } }
    }

    func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private var agent: AXUIElement? {
        guard let pid = agentPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        return app
    }

    func clockFrames() -> [CGRect] {
        clockElements().compactMap(MenuBarScanner.frame(of:))
    }

    /// bar > group > menu extra.
    func clockElements() -> [AXUIElement] {
        guard let agent, let bar = MenuBarScanner.elementAttribute(agent, "AXExtrasMenuBar") else { return [] }
        return MenuBarScanner.elementsAttribute(bar, kAXChildrenAttribute).flatMap { group in
            ([group] + MenuBarScanner.elementsAttribute(group, kAXChildrenAttribute)).filter {
                MenuBarScanner.stringAttribute($0, kAXIdentifierAttribute) == Self.clockID
            }
        }
    }

    var agentPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.menuBarAgentID).first?.processIdentifier
    }

    func waitForMenuBarAgent() -> Bool {
        guard let agent else { return false }
        return MenuBarScanner.elementAttribute(agent, "AXExtrasMenuBar") != nil
    }

    private var centerPIDs: Set<pid_t> {
        Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.notificationCenterID)
                .map(\.processIdentifier))
    }

    /// Owner, layer and bounds only: no Screen Recording needed.
    private func windows(where include: (pid_t, Int, CGRect) -> Bool) -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return Set(
            list.compactMap { info in
                guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                    let id = info[kCGWindowNumber as String] as? CGWindowID,
                    let layer = info[kCGWindowLayer as String] as? Int,
                    let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                        .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                    include(pid, layer, bounds)
                else { return nil }
                return id
            })
    }

    func centerWindows() -> Set<CGWindowID> {
        let owners = centerPIDs
        let minimumHeight = (ItemPresser.activeDisplayBounds().map(\.height).min() ?? 0) / 2
        guard !owners.isEmpty, minimumHeight > 0 else { return [] }
        return windows { pid, layer, bounds in owners.contains(pid) && layer >= 0 && bounds.height >= minimumHeight }
    }

    func showsPanelControls() -> Bool? {
        var readable = false
        for pid in centerPIDs {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
            guard MenuBarScanner.rawAttribute(app, kAXWindowsAttribute) != nil else { continue }
            readable = true
            for window in MenuBarScanner.elementsAttribute(app, kAXWindowsAttribute)
            where Self.contains(Self.panelControlID, in: window, depth: 0) {
                return true
            }
        }
        return readable ? false : nil
    }

    private static func contains(_ identifier: String, in element: AXUIElement, depth: Int) -> Bool {
        // Each element has its own timeout; the default is several seconds.
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        if MenuBarScanner.stringAttribute(element, kAXIdentifierAttribute) == identifier { return true }
        guard depth < controlDepth else { return false }
        return MenuBarScanner.elementsAttribute(element, kAXChildrenAttribute).contains {
            contains(identifier, in: $0, depth: depth + 1)
        }
    }

    func menusOpen() -> Bool {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return !windows { _, layer, _ in layer == level }.isEmpty
    }

    func releaseHeldPress() {
        tap?.releaseHeldPress()
    }

    func dropHeldPress() {
        tap?.dropHeldPress()
    }

    func sessionEnded() {
        tap?.sessionEnded()
    }
}
