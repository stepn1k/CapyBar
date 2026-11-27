import Foundation

@MainActor
public final class Preferences {

    package enum Key {
        package static let hidden = "hiddenBundleIDs"
        package static let known = "knownBundleIDs"
        package static let hideNewApps = "hideNewApps"
        package static let preferredMethods = "preferredPressMethods"
        package static let appOrder = "appOrder"
        package static let loginItemOffered = "loginItemOffered"
        package static let showsNotRunningApps = "showsNotRunningApps"
        package static let checksForUpdates = "checksForUpdates"
        package static let lastUpdateCheck = "lastUpdateCheck"
        package static let iconless = "iconlessBundleIDs"
        package static let hotkey = "hotkey"
        package static let showsVPNStatus = "showsVPNStatus"
    }

    /// Upper bounds so a corrupted or hand-edited plist cannot blow up memory or the
    /// allowlist we send to MenuBarAgent.
    static let maxEntries = 5_000
    static let maxIDLength = 255

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.hideNewApps: true, Key.showsVPNStatus: true])
    }

    /// A shield on the capybara while a VPN is connected, and the VPN's row in the panel.
    /// On by default: without a VPN set up it shows nothing.
    public var showsVPNStatus: Bool {
        get { defaults.bool(forKey: Key.showsVPNStatus) }
        set { defaults.set(newValue, forKey: Key.showsVPNStatus) }
    }

    public var hidden: Set<String> {
        get { readSet(Key.hidden) }
        set { writeSet(newValue, Key.hidden) }
    }

    /// Every app CapyBar has seen, so "new app" can be told apart from "known app".
    public var known: Set<String> {
        get { readSet(Key.known) }
        set { writeSet(newValue, Key.known) }
    }

    /// Hidden apps that showed no menu bar icon even while revealed. They are left out
    /// of the cubby until a scan finds an icon for them.
    public var iconless: Set<String> {
        get { readSet(Key.iconless) }
        set { writeSet(newValue, Key.iconless) }
    }

    public var hideNewApps: Bool {
        get { defaults.bool(forKey: Key.hideNewApps) }
        set { defaults.set(newValue, forKey: Key.hideNewApps) }
    }

    /// Hidden apps that are not running also appear in the cubby, greyed out. Off by default.
    public var showsNotRunningApps: Bool {
        get { defaults.bool(forKey: Key.showsNotRunningApps) }
        set { defaults.set(newValue, forKey: Key.showsNotRunningApps) }
    }

    /// Look for a new version on GitHub once a day. Off by default: CapyBar makes no
    /// network requests unless the user turns this on or checks by hand.
    public var checksForUpdates: Bool {
        get { defaults.bool(forKey: Key.checksForUpdates) }
        set { defaults.set(newValue, forKey: Key.checksForUpdates) }
    }

    /// When the last successful update check finished.
    public var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    /// The global shortcut that opens the panel. None until the user records one: a
    /// global shortcut wins over every app's own, so a default would silently take a
    /// combination (like ⇧⌘C, Inspect Element in browsers) away from apps people use.
    public var hotkey: KeyCombo? {
        get { (defaults.object(forKey: Key.hotkey) as? [String: Any]).flatMap(KeyCombo.init(plist:)) }
        set {
            if let newValue {
                defaults.set(newValue.plist, forKey: Key.hotkey)
            } else {
                defaults.removeObject(forKey: Key.hotkey)
            }
        }
    }

    /// "Open at Login" is turned on by CapyBar itself only once; after that the switch
    /// is the user's, so turning it off sticks.
    public var loginItemOffered: Bool {
        get { defaults.bool(forKey: Key.loginItemOffered) }
        set { defaults.set(newValue, forKey: Key.loginItemOffered) }
    }

    /// The user's order of apps in settings and in the cubby. Apps not in it go last.
    public var appOrder: [String] {
        get { Self.uniqueValidIDs((defaults.array(forKey: Key.appOrder) ?? []).compactMap { $0 as? String }) }
        set { defaults.set(Self.uniqueValidIDs(newValue), forKey: Key.appOrder) }
    }

    public func preferredMethod(for bundleID: String) -> PressMethod {
        (defaults.dictionary(forKey: Key.preferredMethods)?[bundleID] as? String)
            .flatMap(PressMethod.init(rawValue:)) ?? .accessibility
    }

    public func setPreferredMethod(_ method: PressMethod, for bundleID: String) {
        guard Self.isValidBundleID(bundleID) else { return }
        var map = (defaults.dictionary(forKey: Key.preferredMethods) as? [String: String] ?? [:])
            .filter { Self.isValidBundleID($0.key) && PressMethod(rawValue: $0.value) != nil }
        guard map[bundleID] != method.rawValue else { return }
        map[bundleID] = method.rawValue
        if map.count > Self.maxEntries { map = [bundleID: method.rawValue] }
        defaults.set(map, forKey: Key.preferredMethods)
    }

    // MARK: - Storage

    public static func isValidBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= maxIDLength
    }

    private static func uniqueValidIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in ids where isValidBundleID(id) && seen.insert(id).inserted {
            result.append(id)
            if result.count == maxEntries { break }
        }
        return result
    }

    private func readSet(_ key: String) -> Set<String> {
        // Keep the valid strings of a damaged list rather than dropping all of it.
        let raw = (defaults.array(forKey: key) ?? []).compactMap { $0 as? String }
        return Set(raw.lazy.filter(Self.isValidBundleID).prefix(Self.maxEntries))
    }

    private func writeSet(_ value: Set<String>, _ key: String) {
        defaults.set(Array(value.filter(Self.isValidBundleID).sorted().prefix(Self.maxEntries)), forKey: key)
    }
}
