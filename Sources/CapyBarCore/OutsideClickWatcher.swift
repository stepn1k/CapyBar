import AppKit

/// Delivers mouse-down locations, in screen coordinates (AppKit's, origin bottom left).
@MainActor
public protocol ClickSource: AnyObject {
    func startWatching(_ handler: @escaping @MainActor (CGPoint) -> Void) -> AnyObject
    func stopWatching(_ token: AnyObject)
}

/// `NSPopover.transient` alone is not enough: CapyBar is an agent app that does not
/// become active when the panel opens (activating would take focus from the app in
/// front), so clicks in other apps never reach the popover and it stays open.
@MainActor
public final class OutsideClickWatcher {

    private let source: ClickSource
    /// Areas where a click is not "outside": the panel itself and our menu bar icon,
    /// whose own action toggles the panel.
    private let insideFrames: () -> [CGRect]
    private let onOutsideClick: () -> Void
    private var token: AnyObject?

    public var isWatching: Bool { token != nil }

    public init(
        source: ClickSource = SystemClickSource(),
        insideFrames: @escaping () -> [CGRect],
        onOutsideClick: @escaping () -> Void
    ) {
        self.source = source
        self.insideFrames = insideFrames
        self.onOutsideClick = onOutsideClick
    }

    public func start() {
        guard token == nil else { return }
        token = source.startWatching { [weak self] point in self?.clicked(at: point) }
    }

    public func stop() {
        guard let token else { return }
        self.token = nil
        source.stopWatching(token)
    }

    public static func isOutside(_ point: CGPoint, of frames: [CGRect]) -> Bool {
        !frames.contains { $0.contains(point) }
    }

    private func clicked(at point: CGPoint) {
        guard isWatching, Self.isOutside(point, of: insideFrames()) else { return }
        // Stop first: closing may post more events (an item's menu being pressed).
        stop()
        onOutsideClick()
    }
}

/// Real clicks: a global monitor for clicks in other apps (and the menu bar), plus a
/// local one for clicks in our own windows. Mouse monitors need no extra permission.
@MainActor
public final class SystemClickSource: ClickSource {

    private final class Monitors {
        let tokens: [Any]
        init(_ tokens: [Any]) { self.tokens = tokens }
    }

    private static let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    public nonisolated init() {}

    public func startWatching(_ handler: @escaping @MainActor (CGPoint) -> Void) -> AnyObject {
        // Monitors run on the main thread.
        let global = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { _ in
            MainActor.assumeIsolated { handler(NSEvent.mouseLocation) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { event in
            MainActor.assumeIsolated { handler(NSEvent.mouseLocation) }
            return event
        }
        return Monitors([global, local].compactMap { $0 })
    }

    public func stopWatching(_ token: AnyObject) {
        guard let monitors = token as? Monitors else { return }
        monitors.tokens.forEach(NSEvent.removeMonitor)
    }
}
