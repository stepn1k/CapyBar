import Foundation
import SystemConfiguration
import os

private let logger = Logger(subsystem: "app.capybar.CapyBar", category: "network")

/// Tells when a VPN may have come up or gone down. Event-driven: configd notifies the
/// System Configuration dynamic store of every change to these keys, and each VPN's
/// connection reports its own status changes, so nothing polls. Reads local network
/// state only; it sends nothing anywhere and needs no permission.
@MainActor
public final class NetworkWatch {

    /// A VPN connecting or disconnecting changes at least one of these.
    static let patterns = [
        "State:/Network/Global/IPv4",
        "State:/Network/Interface/[^/]+/IPv4",
        "State:/Network/Service/[^/]+/VPN",
        "Setup:/Network/Service/[^/]+",
        "Setup:/Network/Service/[^/]+/(Interface|VPN)",
    ]

    /// Interface types of VPN services: VPN apps (Network Extension), IKEv2/IPSec and L2TP.
    private static let vpnTypes: Set<String> = ["VPN", "IPSec"]
    private static let pppVPNSubtypes: Set<String> = ["L2TP", "PPTP"]

    private var store: SCDynamicStore?
    /// One per VPN service, by service ID. A VPN app's tunnel usually gets its address
    /// before its service reports "connected", and nothing in the dynamic store changes
    /// once it does, so without these the VPN would stay an unnamed tunnel with no app.
    private var connections: [String: SCNetworkConnection] = [:]
    private let onChange: @MainActor (NetworkSnapshot) -> Void

    public init(onChange: @escaping @MainActor (NetworkSnapshot) -> Void) {
        self.onChange = onChange
    }

    /// Starts watching and reports the current state at once.
    public func start() {
        guard store == nil else { return }
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let watch = Unmanaged<NetworkWatch>.fromOpaque(info).takeUnretainedValue()
            // The store delivers on the main queue (see below).
            MainActor.assumeIsolated { watch.changed() }
        }
        guard let store = SCDynamicStoreCreate(nil, "app.capybar.CapyBar" as CFString, callback, &context) else {
            logger.error("couldn't create the dynamic store")
            return
        }
        guard SCDynamicStoreSetNotificationKeys(store, nil, Self.patterns as CFArray),
            SCDynamicStoreSetDispatchQueue(store, .main)
        else {
            logger.error("couldn't watch the network: \(String(cString: SCErrorString(SCError())))")
            return
        }
        self.store = store
        changed()
    }

    /// Must be called before the watch goes away: the store holds an unretained pointer.
    public func stop() {
        guard let store else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        self.store = nil
        for connection in connections.values { SCNetworkConnectionSetDispatchQueue(connection, nil) }
        connections = [:]
    }

    private func changed() {
        guard let store else { return }
        var seen = Set<String>()
        let snapshot = Self.snapshot(
            value: { SCDynamicStoreCopyValue(store, $0 as CFString) as? [String: Any] },
            keys: { SCDynamicStoreCopyKeyList(store, $0 as CFString) as? [String] ?? [] },
            isConnected: { id in
                seen.insert(id)
                return isConnected(serviceID: id)
            })
        // A VPN removed from System Settings: stop listening to it.
        for (id, connection) in connections where !seen.contains(id) {
            SCNetworkConnectionSetDispatchQueue(connection, nil)
            connections[id] = nil
        }
        onChange(snapshot)
    }

    /// What System Settings shows for the service. Asking configd is cheap, and it only
    /// happens when the network or a VPN's status changes.
    private func isConnected(serviceID: String) -> Bool {
        guard let connection = connections[serviceID] ?? watchConnection(serviceID: serviceID) else { return false }
        return SCNetworkConnectionGetStatus(connection) == .connected
    }

    private func watchConnection(serviceID: String) -> SCNetworkConnection? {
        var context = SCNetworkConnectionContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: SCNetworkConnectionCallBack = { _, _, info in
            guard let info else { return }
            let watch = Unmanaged<NetworkWatch>.fromOpaque(info).takeUnretainedValue()
            // Delivered on the main queue (see below).
            MainActor.assumeIsolated { watch.changed() }
        }
        guard let connection = SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, callback, &context)
        else { return nil }
        if SCNetworkConnectionSetDispatchQueue(connection, .main) {
            connections[serviceID] = connection
        } else {
            logger.error("couldn't watch a VPN's status: \(String(cString: SCErrorString(SCError())))")
        }
        return connection
    }

    // MARK: - Reading

    /// Builds the snapshot from the dynamic store's contents. Tests pass a fake store.
    ///
    /// - Parameters:
    ///   - value: the dictionary stored under a key, if any.
    ///   - keys: the keys matching a regex pattern.
    ///   - isConnected: whether the service with this ID is connected.
    package static func snapshot(
        value: (String) -> [String: Any]?, keys: (String) -> [String], isConnected: (String) -> Bool
    ) -> NetworkSnapshot {
        /// `State:/Network/Interface/en0/IPv4` → `en0`; `Setup:/Network/Service/<id>/VPN` → `<id>`.
        func component(_ key: String) -> String? {
            let parts = key.split(separator: "/")
            return parts.count > 3 ? String(parts[3]) : nil
        }

        var snapshot = NetworkSnapshot()
        snapshot.primaryInterface = value("State:/Network/Global/IPv4")?["PrimaryInterface"] as? String
        for key in keys("State:/Network/Interface/[^/]+/IPv4") {
            guard let interface = component(key) else { continue }
            snapshot.ipv4[interface] = value(key)?["Addresses"] as? [String] ?? []
        }
        // Services in their System Settings order, so the first VPN shown is stable.
        let order = value("Setup:/Network/Global/IPv4")?["ServiceOrder"] as? [String] ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let serviceIDs = keys("Setup:/Network/Service/[^/]+/Interface").compactMap(component)
            .sorted { (rank[$0] ?? .max, $0) < (rank[$1] ?? .max, $1) }
        for id in serviceIDs {
            let base = "Setup:/Network/Service/\(id)"
            guard let interface = value("\(base)/Interface"), isVPN(interface),
                let service = value(base), service["__INACTIVE__"] == nil
            else { continue }
            let name = service["UserDefinedName"] as? String ?? VPNStatus.unnamed
            let provider = value("\(base)/VPN")?["NEProviderBundleIdentifier"] as? String
            snapshot.services.append(
                VPNService(name: name, providerBundleID: provider, isConnected: isConnected(id)))
        }
        return snapshot
    }

    private static func isVPN(_ interface: [String: Any]) -> Bool {
        let type = interface["Type"] as? String ?? ""
        if vpnTypes.contains(type) { return true }
        return type == "PPP" && pppVPNSubtypes.contains(interface["SubType"] as? String ?? "")
    }
}
