import CapyBarCore
import Foundation

@MainActor
func vpnTests() {
    section("VPN status")

    let installed: Set<String> = ["toggle.vpn", "com.wireguard.macos"]
    let isApp = { installed.contains($0) }
    func evaluate(_ network: NetworkSnapshot) -> VPNStatus? { VPNStatus.evaluate(network, isApp: isApp) }

    let toggle = VPNService(name: "Toggle VPN", providerBundleID: "toggle.vpn.extension-tunnel", isConnected: false)
    var toggleOn = toggle
    toggleOn.isConnected = true
    let wifi = NetworkSnapshot(primaryInterface: "en0", ipv4: ["en0": ["192.168.1.5"]])

    check(evaluate(wifi) == nil, "no VPN set up and no tunnel: nothing to show")

    // macOS keeps idle utuns with link-local IPv6 only; they must not count.
    var idle = wifi
    idle.ipv4["utun0"] = []
    idle.ipv4["utun1"] = ["169.254.3.4"]
    check(evaluate(idle) == nil, "idle system tunnels are not a VPN")

    var off = wifi
    off.services = [toggle]
    check(
        evaluate(off) == VPNStatus(isConnected: false, name: "Toggle VPN", appBundleID: "toggle.vpn"),
        "a VPN set up but off is shown as off, with its app")

    var on = off
    on.services = [toggleOn]
    on.primaryInterface = "utun4"
    on.ipv4["utun4"] = ["10.5.153.254"]
    check(
        evaluate(on) == VPNStatus(isConnected: true, name: "Toggle VPN", appBundleID: "toggle.vpn"),
        "a connected VPN is shown with its name and app")

    var reportedOnly = off
    reportedOnly.services = [toggleOn]
    check(evaluate(reportedOnly)?.isConnected == true, "connected as System Settings says, even before a tunnel shows")

    var split = wifi
    split.ipv4["utun3"] = ["100.64.0.7"]
    check(
        evaluate(split) == VPNStatus(isConnected: true, name: VPNStatus.unnamed),
        "a tunnel with a real address is a VPN, also when it isn't the default route")

    var full = wifi
    full.primaryInterface = "ppp0"
    check(evaluate(full)?.isConnected == true, "a tunnel carrying the default route is a VPN")

    var tunnelAndOff = split
    tunnelAndOff.services = [toggle]
    check(
        evaluate(tunnelAndOff) == VPNStatus(isConnected: true, name: VPNStatus.unnamed),
        "a tunnel nobody set up wins over a VPN that is off")

    let builtIn = VPNService(name: "Office", isConnected: false)
    var two = wifi
    two.services = [builtIn, toggle]
    check(
        evaluate(two)?.name == "Toggle VPN", "with every VPN off, one whose app can open a menu goes first")
    two.services = [builtIn]
    check(
        evaluate(two) == VPNStatus(isConnected: false, name: "Office"), "a built-in VPN has no app to open")

    let missing = VPNService(name: "Gone", providerBundleID: "com.deleted.app.tunnel", isConnected: false)
    var deleted = wifi
    deleted.services = [missing]
    check(evaluate(deleted)?.appBundleID == nil, "a VPN whose app was deleted has no app to open")

    let work = VPNService(name: "Work", providerBundleID: "com.unknown.vpn.tunnel", isConnected: true)
    var both = wifi
    both.services = [work, toggleOn]
    check(evaluate(both)?.name == "Work", "with two VPNs connected, the first in System Settings order is shown")
    both.services = [work]
    check(
        evaluate(both) == VPNStatus(isConnected: true, name: "Work"),
        "a connected VPN whose app isn't installed is shown without an app")

    for interface in ["wg0", "tap1", "ipsec0"] {
        var tunnel = wifi
        tunnel.ipv4[interface] = ["10.0.0.2"]
        check(evaluate(tunnel)?.isConnected == true, "a \(interface) tunnel with an address is a VPN")
    }
    var loopback = wifi
    loopback.ipv4["utun2"] = ["127.0.0.1"]
    check(evaluate(loopback) == nil, "a tunnel with a loopback address only is not a VPN")
    var bridge = wifi
    bridge.ipv4["bridge100"] = ["192.168.64.1"]
    check(evaluate(bridge) == nil, "a virtual machine's bridge is not a VPN")

    section("VPN services from System Configuration")
    networkSnapshotTests()

    section("VPN app lookup")
    check(
        VPNStatus.appBundleID(forProvider: "toggle.vpn.extension-tunnel", isApp: isApp) == "toggle.vpn",
        "the extension's app is found by its bundle ID")
    check(
        VPNStatus.appBundleID(forProvider: "com.wireguard.macos.network-extension", isApp: isApp)
            == "com.wireguard.macos", "a longer extension ID finds its app")
    check(
        VPNStatus.appBundleID(forProvider: "com.wireguard.macos.a.b.c", isApp: isApp) == "com.wireguard.macos",
        "nested extension IDs find their app")
    check(VPNStatus.appBundleID(forProvider: "toggle.vpn", isApp: isApp) == nil, "an ID is not its own app")
    check(VPNStatus.appBundleID(forProvider: "com.x", isApp: { $0 == "com" }) == nil, "a single part is never an app")
    check(
        VPNStatus.appBundleID(forProvider: "toggle..vpn.x", isApp: { _ in true }) == nil, "malformed IDs are rejected")
    check(VPNStatus.appBundleID(forProvider: "", isApp: { _ in true }) == nil, "an empty ID has no app")

    section("VPN preference")
    let suite = "app.capybar.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        check(false, "test defaults suite")
        return
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = Preferences(defaults: defaults)
    check(prefs.showsVPNStatus, "VPN status is on by default (it shows nothing without a VPN)")
    prefs.showsVPNStatus = false
    check(!Preferences(defaults: defaults).showsVPNStatus, "turning VPN status off is remembered")
}

/// `NetworkWatch.snapshot` against a fake dynamic store.
@MainActor
private func networkSnapshotTests() {
    func service(_ type: String, subType: String? = nil, name: String? = nil) -> [String: [String: Any]] {
        var interface: [String: Any] = ["Type": type]
        interface["SubType"] = subType
        var setup: [String: Any] = [:]
        setup["UserDefinedName"] = name
        return ["": setup, "/Interface": interface]
    }
    var store: [String: [String: Any]] = [
        "State:/Network/Global/IPv4": ["PrimaryInterface": "utun4"],
        "State:/Network/Interface/en0/IPv4": ["Addresses": ["192.168.1.5"]],
        "State:/Network/Interface/utun4/IPv4": ["Addresses": ["10.5.153.254"]],
        "State:/Network/Interface/utun0/IPv4": [:],
        "Setup:/Network/Global/IPv4": ["ServiceOrder": ["ETH", "L2TP", "APP", "IKE"]],
    ]
    let services: [String: [String: [String: Any]]] = [
        "ETH": service("Ethernet", name: "Ethernet"),
        "IKE": service("IPSec", name: "Office IKEv2"),
        "L2TP": service("PPP", subType: "L2TP", name: "Old L2TP"),
        "PPTP": service("PPP", subType: "PPTP", name: "Older PPTP"),
        "PPPOE": service("PPP", subType: "PPPoE", name: "DSL"),
        "APP": service("VPN", name: "Toggle VPN"),
        "ZZZ": service("VPN"),
        "AAA": service("VPN", name: "Unordered"),
        "OFF": service("VPN", name: "Disabled"),
    ]
    for (id, entities) in services {
        for (suffix, value) in entities { store["Setup:/Network/Service/\(id)\(suffix)"] = value }
    }
    store["Setup:/Network/Service/APP/VPN"] = ["NEProviderBundleIdentifier": "toggle.vpn.extension-tunnel"]
    store["Setup:/Network/Service/OFF"]?["__INACTIVE__"] = 1

    let snapshot = NetworkWatch.snapshot(
        value: { store[$0] },
        keys: { pattern in
            guard let regex = try? Regex(pattern) else { return [] }
            return store.keys.filter { $0.wholeMatch(of: regex) != nil }
        },
        isConnected: { $0 == "APP" })

    check(snapshot.primaryInterface == "utun4", "the default route's interface is read")
    check(
        snapshot.ipv4 == ["en0": ["192.168.1.5"], "utun4": ["10.5.153.254"], "utun0": []],
        "each interface's IPv4 addresses are read, none for one without")
    check(
        snapshot.services.map(\.name) == ["Old L2TP", "Toggle VPN", "Office IKEv2", "Unordered", "Older PPTP", "VPN"],
        "VPN services only, in System Settings order, then the rest by ID; inactive ones skipped")
    check(
        snapshot.services.first { $0.name == "Toggle VPN" }
            == VPNService(name: "Toggle VPN", providerBundleID: "toggle.vpn.extension-tunnel", isConnected: true),
        "a VPN app's service has its extension and connection state")
    check(
        snapshot.services.filter(\.isConnected).count == 1 && snapshot.services.allSatisfy { $0.name != "DSL" },
        "only the connected service is connected; PPPoE is not a VPN")
    check(
        NetworkWatch.snapshot(value: { _ in nil }, keys: { _ in [] }, isConnected: { _ in true }) == NetworkSnapshot(),
        "an empty store gives an empty snapshot")
}
