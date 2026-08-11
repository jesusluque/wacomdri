// SPDX-License-Identifier: GPL-2.0-or-later
import IntuosCore
import SwiftUI

public struct PreferencesWindow: View {
    @ObservedObject var model: PreferencesModel

    public init(model: PreferencesModel) { self.model = model }

    public var body: some View {
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
        // Name the real problem. A tablet that is plugged in but unreadable
        // looks exactly like an absent one from the agent's point of view.
        if !model.snapshot.hasInputMonitoring {
            return "Input Monitoring not granted — the agent cannot read the tablet"
        }
        if !model.snapshot.hasAccessibility {
            return "Accessibility not granted — events will not reach applications"
        }
        if !model.snapshot.isConnected { return "Agent running — tablet not connected" }
        if let tool = model.snapshot.toolType { return "Tablet connected — \(tool) in range" }
        return "Tablet connected"
    }
}
