// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import IntuosCore
import SwiftUI

// Preferences for the wacomdri agent.
//
// There is no apply button: edits are written to the config file, which the
// agent watches and reloads in place. Live tablet state comes back over XPC,
// since the agent holds the device exclusively.

struct PreferencesWindow: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                MappingView(model: model)
                    .tabItem { Label("Mapping", systemImage: "rectangle.on.rectangle") }
                PenView(model: model)
                    .tabItem { Label("Pen", systemImage: "pencil.tip") }
                ExpressKeysView(model: model)
                    .tabItem { Label("Keys", systemImage: "keyboard") }
            }
            .padding(.top, 8)

            Divider()
            statusBar
        }
        .frame(minWidth: 560, minHeight: 560)
    }

    /// Distinguishes "the agent is not running" from "the tablet is unplugged".
    /// Conflating them sends people hunting for the wrong problem.
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !model.isAgentRunning {
                Text("Start it with: make install")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        if !model.isAgentRunning { return .red }
        return model.snapshot.isConnected ? .green : .orange
    }

    private var statusText: String {
        if !model.isAgentRunning { return "Agent not running" }
        if !model.snapshot.isConnected { return "Agent running — tablet not connected" }
        if let tool = model.snapshot.toolType { return "Tablet connected — \(tool) in range" }
        return "Tablet connected"
    }
}

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
