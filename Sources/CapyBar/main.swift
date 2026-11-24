import AppKit

// NSApplication holds its delegate weakly; a top-level constant keeps it alive for the
// whole run. (A local inside a closure may be released right after its last use.)
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
