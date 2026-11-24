import AppKit
import ApplicationServices

public enum PressMethod: String, Sendable {
    case accessibility
    case click
}

public enum PressOutcome: Sendable, Equatable {
    /// The item's menu or popover opened and has been closed again by the user.
    case finished(PressMethod)
    /// The item's app is gone or the item never showed up after being revealed.
    case notDrawn
    /// Nothing opened, and a click was not safe or did not help.
    case noResponse
}

/// A revealed item as found in the menu bar: where it is, plus the system handle needed
/// to press it (nil in tests).
package struct DrawnItem {
    package let frame: CGRect
    let element: AXUIElement?

    package init(frame: CGRect) {
        self.init(frame: frame, element: nil)
    }

    init(frame: CGRect, element: AXUIElement?) {
        self.frame = frame
        self.element = element
    }
}

/// The system operations a press needs. `SystemPressEnvironment` does the real work;
/// tests script the answers to exercise every branch of `ItemPresser.run`.
package protocol PressEnvironment: AnyObject {
    /// The pid still belongs to the app the item was scanned from.
    func isSameApp(_ item: MenuBarItem) -> Bool
    func waitUntilDrawn(_ item: MenuBarItem) -> DrawnItem?
    func axPress(_ drawn: DrawnItem) -> (success: Bool, elapsed: TimeInterval)
    func windowSnapshot(_ pid: pid_t) -> Set<CGWindowID>
    /// New menu/popover windows of `pid`, waiting up to `timeout` for one to appear.
    func menuWindows(
        _ pid: pid_t, anchor: CGRect, excluding: Set<CGWindowID>, timeout: TimeInterval
    )
        -> Set<CGWindowID>
    func safeClickPoint(_ item: MenuBarItem) -> CGPoint?
    func click(at point: CGPoint) -> Bool
    func waitUntilClosed(_ windows: Set<CGWindowID>, pid: pid_t)
}

/// Opens another app's status item and waits until its menu closes.
///
/// Runs on its own serial queue: AXPress on an NSMenu-based item blocks until the menu
/// closes, which can take minutes, so it must never run on the main thread or on Swift's
/// cooperative pool. Polling happens only during an active press and stops by itself.
///
/// Safety: the synthetic click is the one place CapyBar uses its Accessibility grant to
/// act on the screen, and the coordinates come from the target app itself. Before
/// clicking we therefore re-read the frame, require it to sit inside the menu bar, and
/// hit-test that the element under the point is the menu bar or the target app.
public final class ItemPresser: Sendable {

    static let drawTimeout: TimeInterval = 1.5
    /// Three equal reads in a row = the reveal animation has settled.
    static let stableReadsNeeded = 2
    static let openTimeout: TimeInterval = 1.0
    /// Second look for a popover after a slow (blocking) press.
    static let quickLook: TimeInterval = 0.1
    /// A press that blocked at least this long tracked a menu (NSMenu blocks AXPress).
    static let menuTrackingThreshold: TimeInterval = 0.3
    /// Upper bound for keeping an item revealed while its menu stays open.
    static let closeTimeout: TimeInterval = 120
    static let pressMessagingTimeout: Float = 60
    /// A status item is at most this tall/wide; anything bigger is not a menu bar item.
    static let maxItemSize = CGSize(width: 400, height: 48)
    /// How far below a display's top edge a status item may start.
    static let menuBarTopTolerance: CGFloat = 8
    /// A popover window hangs at most this far under its item…
    static let popoverVerticalSlack: CGFloat = 24
    /// …and its item lies at most this far beyond the popover's sides.
    static let popoverHorizontalSlack: CGFloat = 200
    static let drawPollInterval: TimeInterval = 0.05
    static let closePollInterval: TimeInterval = 0.3
    /// Lets the window server take the mouse-up before the cursor is moved back.
    static let clickSettleDelay: TimeInterval = 0.05

    private let queue = DispatchQueue(label: "app.capybar.press", qos: .userInitiated)

    public init() {}

    /// Call right after the item's app has been revealed.
    public func press(
        _ item: MenuBarItem,
        preferred: PressMethod,
        completion: @escaping @MainActor @Sendable (PressOutcome) -> Void
    ) {
        queue.async {
            let outcome = Self.run(item, preferred: preferred, env: SystemPressEnvironment())
            Task { @MainActor in completion(outcome) }
        }
    }

    // MARK: - Decision logic (on `queue`)

    package static func run(_ item: MenuBarItem, preferred: PressMethod, env: any PressEnvironment) -> PressOutcome {
        guard env.isSameApp(item), let drawn = env.waitUntilDrawn(item) else { return .notDrawn }
        let methods: [PressMethod] = preferred == .click ? [.click, .accessibility] : [.accessibility, .click]
        // One snapshot for all attempts, so a window opened late by the first attempt
        // still counts as new during the second.
        let before = env.windowSnapshot(item.pid)
        func menuWindows(_ timeout: TimeInterval) -> Set<CGWindowID> {
            env.menuWindows(item.pid, anchor: drawn.frame, excluding: before, timeout: timeout)
        }

        for (attempt, method) in methods.enumerated() {
            // Something may have opened late from the previous attempt: never press again
            // on top of it (a second press would close it).
            if attempt > 0 {
                let late = menuWindows(0)
                if !late.isEmpty {
                    env.waitUntilClosed(late, pid: item.pid)
                    return .finished(methods[attempt - 1])
                }
            }
            switch method {
            case .accessibility:
                let (success, elapsed) = env.axPress(drawn)
                let blocked = elapsed >= menuTrackingThreshold
                // A popover opened by a slow app also makes AXPress slow: look first.
                let opened = menuWindows(blocked ? quickLook : openTimeout)
                if !opened.isEmpty {
                    env.waitUntilClosed(opened, pid: item.pid)
                    return .finished(.accessibility)
                }
                // Blocked with nothing on screen: either an NSMenu was tracked and is closed
                // now (success), or the app hung until the timeout (failure). Either way a
                // second press now would be wrong.
                if blocked { return success ? .finished(.accessibility) : .noResponse }
                if !success { continue }
            case .click:
                guard let point = env.safeClickPoint(item), env.click(at: point) else { continue }
                let opened = menuWindows(openTimeout)
                if !opened.isEmpty {
                    env.waitUntilClosed(opened, pid: item.pid)
                    return .finished(.click)
                }
            }
        }
        return .noResponse
    }

    // MARK: - System helpers (used by SystemPressEnvironment)

    /// The pid still belongs to the app the item was scanned from (pids get reused).
    static func isSameApp(_ item: MenuBarItem) -> Bool {
        NSRunningApplication(processIdentifier: item.pid)?.bundleIdentifier == item.bundleID
    }

    /// Re-resolves the item after the reveal and waits until its frame is inside the
    /// menu bar and stable for three reads in a row (the reveal animates it into place).
    static func waitUntilDrawn(_ item: MenuBarItem) -> DrawnItem? {
        let deadline = Date().addingTimeInterval(drawTimeout)
        var last: CGRect?
        var stableReads = 0
        while Date() < deadline {
            if let element = resolve(item), let frame = MenuBarScanner.frame(of: element), isInMenuBar(frame) {
                stableReads = (frame == last) ? stableReads + 1 : 0
                last = frame
                if stableReads >= stableReadsNeeded { return DrawnItem(frame: frame, element: element) }
            }
            Thread.sleep(forTimeInterval: drawPollInterval)
        }
        return nil
    }

    /// Finds the same item again. An item scanned with a label must still carry that
    /// label: if it is gone, a different item that moved into its position is never
    /// pressed instead. The position breaks ties between equal labels.
    static func resolve(_ item: MenuBarItem) -> AXUIElement? {
        let kids = MenuBarScanner.children(pid: item.pid)
        let atIndex = kids.indices.contains(item.index) ? kids[item.index] : nil
        guard let label = item.label else { return atIndex }
        if let atIndex, MenuBarScanner.label(of: atIndex) == label { return atIndex }
        return kids.first { MenuBarScanner.label(of: $0) == label }
    }

    /// The frame is item-sized and its top edge touches the top of some display.
    static func isInMenuBar(_ frame: CGRect) -> Bool {
        isInMenuBar(frame, displays: activeDisplayBounds())
    }

    /// Pure geometry behind `isInMenuBar`, testable with made-up displays.
    package static func isInMenuBar(_ frame: CGRect, displays: [CGRect]) -> Bool {
        guard frame.width > 0, frame.height > 0,
            frame.width <= maxItemSize.width, frame.height <= maxItemSize.height
        else { return false }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.contains { bounds in
            bounds.contains(center) && frame.minY - bounds.minY <= menuBarTopTolerance
        }
    }

    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Where it is safe to click: re-read right before clicking, inside the menu bar, and
    /// the element the system finds at that point is the menu bar or the target app.
    /// Returns nil otherwise, so a lying or moved item never turns into a click on
    /// someone else's window.
    static func safeClickPoint(_ item: MenuBarItem) -> CGPoint? {
        guard isSameApp(item), let element = resolve(item),
            let frame = MenuBarScanner.frame(of: element), isInMenuBar(frame)
        else { return nil }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        var hit: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
                == .success, let hit
        else { return nil }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success else { return nil }
        // On macOS 27 MenuBarAgent draws every status item, so the element under the
        // point may belong to it rather than to the app; it routes the click on to the
        // item there. Anything else under the point (a window, another app) is refused.
        guard hitPID == item.pid || isMenuBarAgent(hitPID) else { return nil }
        return point
    }

    static func isMenuBarAgent(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.MenuBarAgent"
    }

    // MARK: - Windows (IDs, owner, layer and bounds only: no Screen Recording needed)

    struct WindowInfo {
        let id: CGWindowID
        let layer: Int
        let bounds: CGRect
    }

    static func windowIDs(of pid: pid_t) -> Set<CGWindowID> {
        Set(windows(of: pid).map(\.id))
    }

    static func windows(of pid: pid_t) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                let id = info[kCGWindowNumber as String] as? CGWindowID
            else { return nil }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let bounds =
                (info[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .null
            return WindowInfo(id: id, layer: layer, bounds: bounds)
        }
    }

    /// New windows of the item's app that look like its menu or popover: above the normal
    /// window layer, or a window whose top edge hangs right under the menu bar near the
    /// item. An unrelated document window the app opens does not keep the item revealed.
    static func waitForMenuWindows(
        of pid: pid_t,
        anchor: CGRect,
        excluding before: Set<CGWindowID>,
        timeout: TimeInterval
    ) -> Set<CGWindowID> {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let fresh = windows(of: pid).filter { window in
                guard !before.contains(window.id) else { return false }
                if window.layer > 0 { return true }
                guard !window.bounds.isNull else { return false }
                let hangsUnderItem = abs(window.bounds.minY - anchor.maxY) <= popoverVerticalSlack
                let nearItem = window.bounds.insetBy(dx: -popoverHorizontalSlack, dy: 0)
                    .contains(CGPoint(x: anchor.midX, y: window.bounds.midY))
                return hangsUnderItem && nearItem
            }
            if !fresh.isEmpty { return Set(fresh.map(\.id)) }
            if Date() >= deadline { return [] }
            Thread.sleep(forTimeInterval: drawPollInterval)
        }
    }

    /// Waits until none of `windows` is on screen. Asks only about those windows, which
    /// is ~4x cheaper than listing every window on every tick.
    static func waitUntilClosed(_ windows: Set<CGWindowID>, pid: pid_t) {
        let deadline = Date().addingTimeInterval(closeTimeout)
        // The API wants CGWindowID values stored directly in the array, not boxed objects.
        var values: [UnsafeRawPointer?] = windows.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let ids = CFArrayCreate(kCFAllocatorDefault, &values, values.count, nil) else { return }
        while Date() < deadline {
            let described = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]] ?? []
            let stillOpen = described.contains { info in
                (info[kCGWindowIsOnscreen as String] as? Bool) == true
                    && (info[kCGWindowOwnerPID as String] as? pid_t) == pid
            }
            if !stillOpen { return }
            Thread.sleep(forTimeInterval: closePollInterval)
        }
    }

    /// Posts a plain left click at `point` (global, top-left origin) from a private event
    /// source, so modifier keys the user is holding do not leak into it, then puts the
    /// cursor back.
    static func click(at point: CGPoint) -> Bool {
        let source = CGEventSource(stateID: .privateState)
        guard
            let down = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
            let up = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else { return false }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        let original = CGEvent(source: nil)?.location
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: clickSettleDelay)
        if let original { CGWarpMouseCursorPosition(original) }
        return true
    }
}

final class SystemPressEnvironment: PressEnvironment {
    func isSameApp(_ item: MenuBarItem) -> Bool { ItemPresser.isSameApp(item) }

    func waitUntilDrawn(_ item: MenuBarItem) -> DrawnItem? { ItemPresser.waitUntilDrawn(item) }

    func axPress(_ drawn: DrawnItem) -> (success: Bool, elapsed: TimeInterval) {
        guard let element = drawn.element else { return (false, 0) }
        AXUIElementSetMessagingTimeout(element, ItemPresser.pressMessagingTimeout)
        let started = Date()
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return (result == .success, Date().timeIntervalSince(started))
    }

    func windowSnapshot(_ pid: pid_t) -> Set<CGWindowID> { ItemPresser.windowIDs(of: pid) }

    func menuWindows(
        _ pid: pid_t, anchor: CGRect, excluding: Set<CGWindowID>, timeout: TimeInterval
    )
        -> Set<CGWindowID>
    {
        ItemPresser.waitForMenuWindows(of: pid, anchor: anchor, excluding: excluding, timeout: timeout)
    }

    func safeClickPoint(_ item: MenuBarItem) -> CGPoint? { ItemPresser.safeClickPoint(item) }

    func click(at point: CGPoint) -> Bool { ItemPresser.click(at: point) }

    func waitUntilClosed(_ windows: Set<CGWindowID>, pid: pid_t) {
        ItemPresser.waitUntilClosed(windows, pid: pid)
    }
}
