import Foundation

// `swift run CapyBarTests` — exit code 0 means every check passed.

allowlistTests()
installLocationTests()
preferencesTests()
presserTests()
outsideClickTests()
updateTests()
keyComboTests()
panelSearchTests()
keyboardTests()
panelNotesTests()
vpnTests()
clockTests()
clockRestrictionTests()
await restrictionTests()
await reliabilityTests()

print(failures == 0 ? "\nall \(passed) passed" : "\n\(failures) failed, \(passed) passed")
exit(failures == 0 ? 0 : 1)
