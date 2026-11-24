import Foundation

// `swift run CapyBarTests` — exit code 0 means every check passed.
// (Command Line Tools ship without XCTest, so this is a plain executable.)

allowlistTests()
preferencesTests()
presserTests()
outsideClickTests()
await restrictionTests()

print(failures == 0 ? "\nall \(passed) passed" : "\n\(failures) failed, \(passed) passed")
exit(failures == 0 ? 0 : 1)
