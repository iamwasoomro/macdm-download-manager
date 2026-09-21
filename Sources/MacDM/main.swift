import AppKit

// AppKit entry point (SwiftUI property-wrapper macros are unavailable with
// Command Line Tools only, so the UI is plain AppKit).
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
