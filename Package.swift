// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CapyBar",
    platforms: [.macOS("27.0")],
    targets: [
        // Thin Objective-C bridge to the private MenuBarClientCore framework.
        .target(name: "MenuBarPrivate"),
        // Logic that does not need a UI: allowlist rules, restriction, Accessibility.
        .target(name: "CapyBarCore", dependencies: ["MenuBarPrivate"]),
        // The menu bar app itself.
        .executableTarget(name: "CapyBar", dependencies: ["CapyBarCore"]),
        // Command Line Tools ship without XCTest, so tests are a plain executable:
        // `swift run CapyBarTests`, exit code 0 = all passed.
        .executableTarget(name: "CapyBarTests", dependencies: ["CapyBarCore"]),
    ]
)
