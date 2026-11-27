import Foundation

/// A VPN set up in System Settings, as SystemConfiguration describes it.
public struct VPNService: Equatable, Sendable {
    public var name: String
    /// The Network Extension that runs it, for VPN apps; nil for VPNs built into macOS.
    public var providerBundleID: String?
    public var isConnected: Bool

    public init(name: String, providerBundleID: String? = nil, isConnected: Bool) {
        self.name = name
        self.providerBundleID = providerBundleID
        self.isConnected = isConnected
    }
}

/// What the network looks like right now. Read from the System Configuration dynamic
/// store by `NetworkWatch`; built by hand in tests.
public struct NetworkSnapshot: Equatable, Sendable {
    /// The interface that carries the default route.
    public var primaryInterface: String?
    /// Interface name to its IPv4 addresses.
    public var ipv4: [String: [String]]
    public var services: [VPNService]

    public init(primaryInterface: String? = nil, ipv4: [String: [String]] = [:], services: [VPNService] = []) {
        self.primaryInterface = primaryInterface
        self.ipv4 = ipv4
        self.services = services
    }
}

/// What CapyBar shows about the VPN: a shield on the capybara while one is connected,
/// and a row in the panel that opens the VPN app's menu.
public struct VPNStatus: Equatable, Sendable {
    public var isConnected: Bool
    public var name: String
    /// The installed app whose menu bar icon controls this VPN, when one is known.
    public var appBundleID: String?

    public init(isConnected: Bool, name: String, appBundleID: String? = nil) {
        self.isConnected = isConnected
        self.name = name
        self.appBundleID = appBundleID
    }

    /// The name used for a tunnel that no VPN in System Settings owns.
    public static let unnamed = "VPN"

    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]

    /// Nil when there is nothing to show: no VPN set up and no tunnel up.
    ///
    /// A VPN that System Settings reports as connected wins. Otherwise a tunnel counts
    /// once it carries the default route or has a real IPv4 address: macOS keeps several
    /// idle `utun`s of its own (iCloud Private Relay and the like) with link-local IPv6
    /// only, so their mere presence means nothing. Without either, the first VPN whose
    /// app is installed is shown as off, so its menu is one click away.
    ///
    /// - Parameter isApp: whether an app with this bundle ID is installed.
    public static func evaluate(_ network: NetworkSnapshot, isApp: (String) -> Bool) -> VPNStatus? {
        func status(_ service: VPNService, connected: Bool) -> VPNStatus {
            VPNStatus(
                isConnected: connected, name: service.name,
                appBundleID: service.providerBundleID.flatMap { appBundleID(forProvider: $0, isApp: isApp) })
        }
        if let service = network.services.first(where: \.isConnected) {
            return status(service, connected: true)
        }
        if isTunnelUp(network) {
            // A VPN app not set up in System Settings (a command-line WireGuard, say).
            return VPNStatus(isConnected: true, name: unnamed)
        }
        let candidates = network.services.map { status($0, connected: false) }
        return candidates.first { $0.appBundleID != nil } ?? candidates.first
    }

    static func isTunnelUp(_ network: NetworkSnapshot) -> Bool {
        if let primary = network.primaryInterface, isTunnel(primary) { return true }
        return network.ipv4.contains { interface, addresses in
            isTunnel(interface) && addresses.contains(where: isRoutable)
        }
    }

    static func isTunnel(_ interface: String) -> Bool {
        tunnelPrefixes.contains { interface.hasPrefix($0) }
    }

    static func isRoutable(_ address: String) -> Bool {
        !address.isEmpty && !address.hasPrefix("169.254.") && !address.hasPrefix("127.")
    }

    /// A Network Extension lives inside its app and its bundle ID extends the app's
    /// (`toggle.vpn.extension-tunnel` in `toggle.vpn`), so the app is found by dropping
    /// the last parts until an installed app matches. One part alone (`com`) is never an
    /// app ID worth trusting.
    public static func appBundleID(forProvider provider: String, isApp: (String) -> Bool) -> String? {
        var parts = provider.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.contains(where: \.isEmpty) else { return nil }
        while parts.count >= 2 {
            parts.removeLast()
            let candidate = parts.joined(separator: ".")
            if parts.count >= 2, isApp(candidate) { return candidate }
        }
        return nil
    }
}
