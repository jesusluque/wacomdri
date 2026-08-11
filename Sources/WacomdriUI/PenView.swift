// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import IntuosCore
import SwiftUI

/// Draggable pressure curve with the live reading plotted on it.
///
/// Showing where the pen currently sits on the curve is the whole point: a curve
/// editor without it is guesswork, because the useful question is "what does
/// *my* normal drawing pressure map to", not "what shape is this spline".
public struct PressureCurveEditor: View {
    @Binding var curve: PressureCurve
    /// Current raw pressure, 0...1, or nil when nothing is touching.
    let liveInput: Double?

    private let handleRadius: CGFloat = 7

    public var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let rect = CGRect(x: 0, y: 0, width: size, height: size)

            ZStack(alignment: .topLeading) {
                grid(in: rect)
                curvePath(in: rect)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                if let liveInput {
                    liveMarker(in: rect, input: liveInput)
                }

                handle(point: curve.control1, in: rect) { curve.control1 = $0 }
                handle(point: curve.control2, in: rect) { curve.control2 = $0 }
            }
            .frame(width: size, height: size)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: Drawing

    private func grid(in rect: CGRect) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.06))
            Path { path in
                for step in 1..<4 {
                    let fraction = CGFloat(step) / 4
                    path.move(to: CGPoint(x: rect.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: rect.width * fraction, y: rect.height))
                    path.move(to: CGPoint(x: 0, y: rect.height * fraction))
                    path.addLine(to: CGPoint(x: rect.width, y: rect.height * fraction))
                }
            }
            .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)

            // The identity curve, for comparison.
            Path { path in
                path.move(to: CGPoint(x: 0, y: rect.height))
                path.addLine(to: CGPoint(x: rect.width, y: 0))
            }
            .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .frame(width: rect.width, height: rect.height)
    }

    private func curvePath(in rect: CGRect) -> Path {
        Path { path in
            let steps = 96
            for step in 0...steps {
                let input = Double(step) / Double(steps)
                let output = curve.apply(normalized: input)
                let point = plot(input: input, output: output, in: rect)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    private func liveMarker(in rect: CGRect, input: Double) -> some View {
        let output = curve.apply(normalized: input)
        let point = plot(input: input, output: output, in: rect)
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: point.x, y: rect.height))
                path.addLine(to: point)
                path.addLine(to: CGPoint(x: 0, y: point.y))
            }
            .stroke(Color.orange.opacity(0.5), lineWidth: 1)

            Circle()
                .fill(Color.orange)
                .frame(width: 9, height: 9)
                .position(point)
        }
        .frame(width: rect.width, height: rect.height)
    }

    private func handle(
        point: CGPoint, in rect: CGRect, onChange: @escaping (CGPoint) -> Void
    ) -> some View {
        let position = plot(input: point.x, output: point.y, in: rect)
        return Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
            .frame(width: handleRadius * 2, height: handleRadius * 2)
            .position(position)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Clamp to the unit square: a control point outside it
                        // produces a curve that is no longer a function of
                        // pressure.
                        let x = min(max(value.location.x / rect.width, 0), 1)
                        let y = min(max(1 - value.location.y / rect.height, 0), 1)
                        onChange(CGPoint(x: x, y: y))
                    })
    }

    /// Curve space has its origin bottom-left; views have it top-left.
    private func plot(input: Double, output: Double, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.width * input, y: rect.height * (1 - output))
    }
}

/// The Pen pane: pressure response and barrel buttons.
public struct PenView: View {
    @ObservedObject var model: PreferencesModel

    private var liveInput: Double? {
        guard model.snapshot.toolType != nil, model.snapshot.rawPressure > 0 else { return nil }
        return Double(model.snapshot.rawPressure) / Double(Intuos3.maxPressure)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pressure response")
                .font(.headline)
            Text("Drag the handles. Press the pen on the tablet to see where you land.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 20) {
                PressureCurveEditor(
                    curve: $model.configuration.pressureCurve,
                    liveInput: liveInput)
                .frame(width: 200, height: 200)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(presets, id: \.name) { preset in
                        Button(preset.name) {
                            model.configuration.pressureCurve.control1 = preset.curve.control1
                            model.configuration.pressureCurve.control2 = preset.curve.control2
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider().padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Minimum output")
                            .font(.caption)
                        Slider(
                            value: $model.configuration.pressureCurve.minimumOutput,
                            in: 0...0.5)
                        .frame(width: 140)
                        Text("Ink laid down the instant the nib registers.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 150, alignment: .leading)
                    }
                }
            }

            liveReadout

            Divider().padding(.vertical, 4)

            Text("Pen buttons")
                .font(.headline)
            Text("The rocker on the pen has two positions, each assignable "
                + "separately.")
                .font(.caption)
                .foregroundStyle(.secondary)

            BarrelButtonRow(title: "Upper", action: $model.configuration.barrelButton2)
            BarrelButtonRow(title: "Lower", action: $model.configuration.barrelButton1)

            Spacer()
        }
        .padding(20)
    }

    private var presets: [(name: String, curve: PressureCurve)] {
        [("Linear", .linear), ("Soft", .soft), ("Firm", .firm)]
    }

    private var liveReadout: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Raw").font(.caption2).foregroundStyle(.secondary)
                Text("\(model.snapshot.rawPressure) / \(Intuos3.maxPressure)")
                    .font(.system(.callout, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Output").font(.caption2).foregroundStyle(.secondary)
                Text(String(format: "%.3f", model.snapshot.curvedPressure))
                    .font(.system(.callout, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Tilt").font(.caption2).foregroundStyle(.secondary)
                Text("\(model.snapshot.tiltX), \(model.snapshot.tiltY)")
                    .font(.system(.callout, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Tool").font(.caption2).foregroundStyle(.secondary)
                Text(model.snapshot.toolType ?? "—")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(model.snapshot.isEraser ? Color.red : Color.primary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

/// One position of the pen's rocker switch.
public struct BarrelButtonRow: View {
    let title: String
    @Binding var action: BarrelAction

    @StateObject private var capture = KeyCaptureController()

    private enum Choice: String, CaseIterable, Identifiable {
        case none = "Nothing"
        case left = "Left click"
        case right = "Right click"
        case middle = "Middle click"
        case double = "Double click"
        case tap = "Press key"
        case hold = "Hold key"
        var id: String { rawValue }
    }

    private var choice: Choice {
        switch action {
        case .none: return .none
        case .leftClick: return .left
        case .rightClick: return .right
        case .middleClick: return .middle
        case .doubleClick: return .double
        case .tapKey: return .tap
        case .holdKey: return .hold
        }
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 54, alignment: .leading)

            Picker("", selection: Binding(get: { choice }, set: apply)) {
                ForEach(Choice.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)

            if choice == .tap || choice == .hold {
                Button(action: beginCapture) {
                    Text(capture.isCapturing ? "Press any key…" : action.displayName)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(capture.isCapturing ? .accentColor : nil)
            }
        }
    }

    private func beginCapture() {
        capture.begin { code, modifiers in
            action = choice == .hold
                ? .holdKey(code: code, modifiers: modifiers)
                : .tapKey(code: code, modifiers: modifiers)
        }
    }

    /// Switching between the two key modes keeps whatever key was bound.
    private func apply(_ newChoice: Choice) {
        let existing: (UInt16, Modifiers)?
        switch action {
        case .tapKey(let c, let m), .holdKey(let c, let m): existing = (c, m)
        default: existing = nil
        }

        switch newChoice {
        case .none: action = .none
        case .left: action = .leftClick
        case .right: action = .rightClick
        case .middle: action = .middleClick
        case .double: action = .doubleClick
        case .tap: action = .tapKey(code: existing?.0 ?? KeyCode.space, modifiers: existing?.1 ?? [])
        case .hold: action = .holdKey(code: existing?.0 ?? KeyCode.space, modifiers: existing?.1 ?? [])
        }
    }
}
