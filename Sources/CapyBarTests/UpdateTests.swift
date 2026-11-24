import CapyBarCore
import Foundation

@MainActor
func updateTests() {
    section("Update check")

    func release(_ version: String, _ build: Int) -> ReleaseInfo { ReleaseInfo(version: version, build: build)! }

    check(release("0.3.0", 3).isNewer(than: release("0.2.0", 2)), "higher version is newer")
    check(release("0.10.0", 1).isNewer(than: release("0.9.9", 9)), "versions compare as numbers, not text")
    check(!release("0.2.0", 2).isNewer(than: release("0.2.0", 2)), "the same version is not newer")
    check(release("0.2.0", 3).isNewer(than: release("0.2.0", 2)), "same version, higher build is newer")
    check(!release("0.2", 2).isNewer(than: release("0.2.0", 2)), "0.2 equals 0.2.0")
    check(!release("0.2.0", 9).isNewer(than: release("0.3.0", 1)), "a higher build does not beat a higher version")

    check(ReleaseInfo(version: "", build: 1) == nil, "empty version is rejected")
    check(ReleaseInfo(version: "1.2.beta", build: 1) == nil, "non-numeric version is rejected")
    check(ReleaseInfo(version: "1..2", build: 1) == nil, "empty version part is rejected")
    check(ReleaseInfo(version: "1.0", build: -1) == nil, "negative build is rejected")

    let plist: [String: Any] = ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2"]
    check(ReleaseInfo(infoDictionary: plist) == release("0.2.0", 2), "version is read from Info.plist")
    check(ReleaseInfo(infoDictionary: nil) == nil, "no Info.plist, no version")

    check(UpdateCheck.parse(Data(#"{"version":"0.3.0","build":3}"#.utf8)) == release("0.3.0", 3), "version.json is read")
    check(UpdateCheck.parse(Data(#"{"version":"0.3.0"}"#.utf8)) == nil, "version.json without a build is rejected")
    check(UpdateCheck.parse(Data("<html>Not Found</html>".utf8)) == nil, "an HTML page is rejected")
    let huge = #"{"version":"1.0","build":1,"pad":""# + String(repeating: "x", count: 5_000) + #""}"#
    check(UpdateCheck.parse(Data(huge.utf8)) == nil, "an oversized response is rejected")

    let suite = "app.capybar.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        check(false, "test defaults suite")
        return
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = Preferences(defaults: defaults)
    check(!prefs.checksForUpdates, "automatic update checks are off by default")
    check(prefs.lastUpdateCheck == nil, "no update check has happened yet")
    let now = Date()
    prefs.checksForUpdates = true
    prefs.lastUpdateCheck = now
    let reread = Preferences(defaults: defaults)
    check(reread.checksForUpdates && reread.lastUpdateCheck == now, "update settings are remembered")
}
