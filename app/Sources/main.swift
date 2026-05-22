import AppKit

// Entry point. NSApplicationMain isn't usable in a Swift script-style target,
// so we wire it up the manual way.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
