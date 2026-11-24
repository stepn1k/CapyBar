import AppKit
import ApplicationServices
import Synchronization

public struct MenuBarItem: Sendable, Hashable, Identifiable {
    public let bundleID: String
    public let pid: pid_t
    /// Position among the app's own status items (AX child index).
    public let index: Int
    /// Best human-readable label: AX title, description, help or identifier.
    public let label: String?

    public var id: String { "\(bundleID)#\(pid)#\(index)" }

    public init(bundleID: String, pid: pid_t, index: Int, label: String?) {
        self.bundleID = bundleID
        self.pid = pid
        self.index = index
        self.label = label
    }
}

/// Reads other apps' status items through Accessibility (`AXExtrasMenuBar`).
///
/// All calls block on IPC to other processes, so they must run off the main thread.
/// Nothing here polls: callers scan when the panel or settings open, or an app launches.
public enum MenuBarScanner {

    /// Per-element IPC timeout. Unresponsive helper processes would otherwise stall a
    /// sweep for the default 6 s each.
    static let messagingTimeout: Float = 0.25
    /// Apps read in parallel, so a few hung apps cost one timeout, not one each.
    static let sweepWidth = 8

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func requestTrust() {
        // A literal instead of `kAXTrustedCheckOptionPrompt`: that global is a mutable
        // `var` in the SDK, which Swift 6 rejects as shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Status items of every given app, or nil when Accessibility is not granted.
    public static func sweep(_ apps: [(pid: pid_t, bundleID: String)]) -> [MenuBarItem]? {
        guard isTrusted else { return nil }
        let slots = Mutex([[MenuBarItem]](repeating: [], count: apps.count))
        DispatchQueue.concurrentPerform(iterations: sweepWidth) { lane in
            for index in stride(from: lane, to: apps.count, by: sweepWidth) {
                let found = items(pid: apps[index].pid, bundleID: apps[index].bundleID)
                slots.withLock { $0[index] = found }
            }
        }
        return slots.withLock { $0.flatMap { $0 } }
    }

    /// Status items of one app; empty when it has none or does not answer. Reads only
    /// labels: the press re-reads geometry when it needs it, so frames are not fetched.
    static func items(pid: pid_t, bundleID: String) -> [MenuBarItem] {
        children(pid: pid).enumerated().map { index, element in
            MenuBarItem(bundleID: bundleID, pid: pid, index: index, label: label(of: element))
        }
    }

    static func children(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let bar = elementAttribute(app, "AXExtrasMenuBar") else { return [] }
        AXUIElementSetMessagingTimeout(bar, messagingTimeout)
        let kids = elementsAttribute(bar, kAXChildrenAttribute)
        for kid in kids { AXUIElementSetMessagingTimeout(kid, messagingTimeout) }
        return kids
    }

    static func label(of element: AXUIElement) -> String? {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute] {
            if let text = stringAttribute(element, name), !text.isEmpty { return text }
        }
        return nil
    }

    /// Global frame, top-left origin (the same space as CGEvent).
    static func frame(of element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = valueAttribute(element, kAXPositionAttribute),
            let extent = valueAttribute(element, kAXSizeAttribute),
            AXValueGetValue(position, .cgPoint, &origin),
            AXValueGetValue(extent, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Typed attribute reads (CF type IDs checked: another app controls the values)

    private static func rawAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = rawAttribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func valueAttribute(_ element: AXUIElement, _ name: String) -> AXValue? {
        guard let value = rawAttribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        rawAttribute(element, name) as? String
    }

    private static func elementsAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = rawAttribute(element, name), CFGetTypeID(value) == CFArrayGetTypeID(),
            let array = value as? [CFTypeRef]
        else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeDowncast(item, to: AXUIElement.self) : nil
        }
    }
}
