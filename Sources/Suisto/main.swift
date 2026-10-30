import AppKit
import SuistoKit

// SwiftPM builds a plain executable, so the app is bootstrapped by hand
// instead of through @main / NSApplicationMain. Everything else lives in
// SuistoKit so the tests can reach it.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
