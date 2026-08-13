import AppKit

// LSUIElement lives in the bundle's Info.plist (see dist/Info.plist). The
// activation policy is also set in code so that running the bare SwiftPM binary
// during development behaves the same way: no dock icon, no menu bar takeover,
// no main window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
