// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import IntuosCore
import WacomdriUI
import SwiftUI

// Preferences for the wacomdri agent.
//
// There is no apply button: edits are written to the config file, which the
// agent watches and reloads in place. Live tablet state comes back over XPC,
// since the agent holds the device exclusively.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let model = PreferencesModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Wacom Intuos3"
        window.contentView = NSHostingView(rootView: PreferencesWindow(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flushes any edit still inside the save debounce.
        model.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// NSApplication holds its delegate weakly, so something else must own it.
nonisolated(unsafe) var delegateReference: AppDelegate?

// Top-level code is not main-actor isolated under the Swift 5 language mode,
// but this runs on the main thread by definition, so state the fact rather than
// hopping to reach it.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Held for the process lifetime: NSApplication does not retain its delegate.
    delegateReference = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
