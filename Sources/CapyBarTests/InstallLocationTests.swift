import CapyBarCore
import Foundation

@MainActor
func installLocationTests() {
    let app = "/Applications/CapyBar.app"
    let translocated = "/private/var/folders/05/x/T/AppTranslocation/711A/d/CapyBar.app"
    let downloads = "/Users/me/Downloads/CapyBar.app"

    section("InstallLocation.problem")
    check(
        InstallLocation.problem(bundlePath: app, resolvedPath: app) == nil,
        "the resolved copy in /Applications can hide")
    check(
        InstallLocation.problem(bundlePath: app, resolvedPath: app + "/") == nil,
        "a trailing slash does not make it another copy")
    check(
        InstallLocation.problem(bundlePath: translocated, resolvedPath: translocated) == .outsideApplications,
        "a translocated copy cannot hide, even when LaunchServices resolves to it")
    check(
        InstallLocation.problem(bundlePath: downloads, resolvedPath: downloads) == .outsideApplications,
        "a copy in Downloads cannot hide")
    check(
        InstallLocation.problem(bundlePath: "/Users/me/Applications/CapyBar.app", resolvedPath: nil)
            == .outsideApplications,
        "~/Applications does not count")
    check(
        InstallLocation.problem(bundlePath: app, resolvedPath: downloads) == .otherCopy(downloads),
        "in /Applications, but LaunchServices picks another copy")
    check(
        InstallLocation.problem(bundlePath: app, resolvedPath: nil) == .otherCopy(nil),
        "in /Applications, but LaunchServices knows no copy")

    section("InstallLocation.shouldMoveAutomatically")
    check(
        InstallLocation.shouldMoveAutomatically(bundlePath: translocated, isQuarantined: false),
        "a translocated copy moves itself")
    check(
        InstallLocation.shouldMoveAutomatically(bundlePath: downloads, isQuarantined: true),
        "a downloaded copy moves itself")
    check(
        !InstallLocation.shouldMoveAutomatically(
            bundlePath: "/Users/me/src/CapyBar/build/CapyBar.app", isQuarantined: false),
        "a local build stays where it is")
    check(
        !InstallLocation.shouldMoveAutomatically(bundlePath: app, isQuarantined: true),
        "a copy already in /Applications does not move")
    check(
        InstallLocation.problem(
            bundlePath: "/private/var/folders/x/T/AppTranslocation/1/d/Applications/CapyBar.app",
            resolvedPath: nil) == .outsideApplications,
        "a translocated path that mentions Applications is still outside it")
    check(
        InstallLocation.installedPath == app,
        "always installs as /Applications/CapyBar.app, whatever the download is named")

    section("InstallLocation.isLeftover")
    check(InstallLocation.isLeftover(translocated), "a translocated view is a leftover record")
    check(InstallLocation.isLeftover("/Users/me/.Trash/CapyBar.app"), "a trashed copy is a leftover record")
    check(!InstallLocation.isLeftover(downloads), "a real copy elsewhere is not")

    section("InstallLocation.shouldReplace")
    check(InstallLocation.shouldReplace(installedBuild: "3", ownBuild: "4"), "a newer build replaces the installed one")
    check(!InstallLocation.shouldReplace(installedBuild: "4", ownBuild: "4"), "the same build is kept")
    check(!InstallLocation.shouldReplace(installedBuild: "10", ownBuild: "9"), "an older download never downgrades")
    check(
        InstallLocation.shouldReplace(installedBuild: nil, ownBuild: "4"), "an unreadable installed build is replaced")
    check(InstallLocation.shouldReplace(installedBuild: "x", ownBuild: "4"), "a non-numeric build is replaced")
}
