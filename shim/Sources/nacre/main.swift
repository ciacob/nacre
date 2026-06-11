// main.swift
// nacre — application entry point
//
// Swift Package Manager executable targets require an explicit entry point.
// @main on AppDelegate does NOT correctly call NSApplicationMain() when built
// with SPM — it synthesises a bare main() that skips Cocoa's run-loop setup.
//
// The correct pattern for a Cocoa app built with SPM is:
//   1. NO @main attribute on AppDelegate.
//   2. An explicit main.swift that calls NSApplicationMain().
//
// NSApplicationMain() reads NSPrincipalClass and NSMainNibFile from
// Info.plist, instantiates the app delegate (via the AppDelegate class name
// passed as the second argument), runs the event loop, and never returns.

import AppKit

// Instantiate the application and assign our delegate before running the loop.
// This is the correct NIB-less Cocoa bootstrap pattern for SPM executables.
// NSApplicationMain() is NOT used because it requires a NIB or a storyboard
// to wire the delegate — we have neither.

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Activate as a regular foreground app (shows in Dock, gets menu bar)
app.setActivationPolicy(.regular)

app.run()

