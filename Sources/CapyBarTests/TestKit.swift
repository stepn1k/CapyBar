import Foundation

// Minimal test kit: Command Line Tools ship without XCTest or swift-testing. Everything
// runs on the main actor, in order, from `main.swift`.

@MainActor var failures = 0
@MainActor var passed = 0

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ name: String, file: String = #fileID, line: Int = #line) {
    if condition() {
        passed += 1
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name) (\(file):\(line))")
    }
}

func section(_ title: String) {
    print("\n— \(title)")
}

@MainActor
func wait(_ duration: Duration) async {
    try? await Task.sleep(for: duration)
    // Let the main-actor task woken by the timeout run before checking.
    await Task.yield()
}
