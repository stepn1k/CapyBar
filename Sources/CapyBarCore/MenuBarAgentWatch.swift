import AppKit

/// A restarted MenuBarAgent forgets our restriction, so a new MenuBarAgent pid means
/// "send it again".
public struct MenuBarAgentWatch: Sendable {

    public static let bundleID = "com.apple.MenuBarAgent"

    private var lastPID: pid_t?

    public init(currentPID: pid_t?) {
        lastPID = currentPID
    }

    /// True for a MenuBarAgent pid not seen before. Nil (no agent right now) is ignored.
    public mutating func observe(_ pid: pid_t?) -> Bool {
        guard let pid, pid != lastPID else { return false }
        lastPID = pid
        return true
    }

    public static func currentPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }?.processIdentifier
    }
}
