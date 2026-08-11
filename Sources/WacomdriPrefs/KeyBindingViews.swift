// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import IntuosCore
import SwiftUI

/// Captures the next keystroke and reports its virtual key code and modifiers.
///
/// A local `NSEvent` monitor rather than SwiftUI's own key handling, because it
/// must swallow the keystroke entirely: capturing ⌘S should record ⌘S, not save
/// something. It also has to see keys SwiftUI never routes to a focused control,
/// such as ⌘Q or the arrow keys.
final class KeyCaptureController: ObservableObject {
    @Published private(set) var isCapturing = false
    private var monitor: Any?
    private var onCapture: ((UInt16, Modifiers) -> Void)?

    func begin(_ onCapture: @escaping (UInt16, Modifiers) -> Void) {
        cancel()
        self.onCapture = onCapture
        isCapturing = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self, self.isCapturing else { return event }

            // Escape abandons the capture rather than binding Escape, which is
            // what everyone expects and what nobody wants bound by accident.
            if event.type == .keyDown, event.keyCode == 53, event.modifierFlags.isDisjoint(
                with: [.command, .shift, .option, .control]) {
                self.cancel()
                return nil
            }

            // Ignore modifier-only presses: the user is still assembling a
            // chord, and binding "⌘" alone is meaningless.
            guard event.type == .keyDown else { return nil }

            self.onCapture?(event.keyCode, Modifiers(event.modifierFlags))
            self.cancel()
            return nil
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isCapturing = false
        onCapture = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

extension Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var result: Modifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        self = result
    }
}

/// One row of the ExpressKey table.
struct KeyBindingRow: View {
    let index: Int
    /// True while the physical key is held, so the row can confirm which one it
    /// is — far easier than counting keys on the tablet.
    let isPressed: Bool
    @Binding var action: PadAction

    @StateObject private var capture = KeyCaptureController()

    private var mode: BindingMode {
        get {
            switch action {
            case .none: return .none
            case .tapKey: return .tap
            case .holdKey: return .hold
            }
        }
    }

    enum BindingMode: String, CaseIterable, Identifiable {
        case none = "Nothing"
        case tap = "Press key"
        case hold = "Hold key"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 12) {
            keyBadge

            Picker("", selection: Binding(
                get: { mode },
                set: { changeMode(to: $0) })
            ) {
                ForEach(BindingMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)

            if mode == .none {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button(action: beginCapture) {
                    Text(capture.isCapturing ? "Press any key…" : shortcutLabel)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(capture.isCapturing ? .accentColor : nil)
            }
        }
        .padding(.vertical, 2)
    }

    /// Numbered badge that lights up while the physical key is held.
    private var keyBadge: some View {
        Text("\(index + 1)")
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .frame(width: 22, height: 22)
            .background(
                Circle().fill(isPressed ? Color.accentColor : Color.secondary.opacity(0.15)))
            .foregroundStyle(isPressed ? Color.white : Color.secondary)
            .animation(.easeOut(duration: 0.1), value: isPressed)
    }

    private var shortcutLabel: String {
        switch action {
        case .none: return "—"
        case .tapKey(let code, let modifiers), .holdKey(let code, let modifiers):
            return modifiers.symbols + KeyCode.name(for: code)
        }
    }

    private func beginCapture() {
        capture.begin { code, modifiers in
            switch mode {
            case .hold: action = .holdKey(code: code, modifiers: modifiers)
            default: action = .tapKey(code: code, modifiers: modifiers)
            }
        }
    }

    /// Switching mode keeps whatever key was already bound, so changing "press"
    /// to "hold" does not silently discard the binding.
    private func changeMode(to newMode: BindingMode) {
        let existing: (UInt16, Modifiers)?
        switch action {
        case .none: existing = nil
        case .tapKey(let code, let modifiers), .holdKey(let code, let modifiers):
            existing = (code, modifiers)
        }

        switch newMode {
        case .none:
            action = .none
        case .tap:
            action = .tapKey(
                code: existing?.0 ?? KeyCode.space, modifiers: existing?.1 ?? [])
        case .hold:
            action = .holdKey(
                code: existing?.0 ?? KeyCode.space, modifiers: existing?.1 ?? [])
        }
    }
}

/// The ExpressKeys pane.
struct ExpressKeysView: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ExpressKeys")
                .font(.headline)
            Text("Press a key on the tablet to see which number it is.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(0..<Intuos3.expressKeyCount, id: \.self) { index in
                    KeyBindingRow(
                        index: index,
                        isPressed: model.isKeyPressed(index),
                        action: Binding(
                            get: { model.configuration.pad.keys[index] },
                            set: { model.configuration.pad.keys[index] = $0 }))
                }
            }

            Divider().padding(.vertical, 4)

            StripBindingView(
                title: "Left Touch Strip",
                position: model.snapshot.strip1Position,
                action: $model.configuration.pad.leftStrip)

            StripBindingView(
                title: "Right Touch Strip",
                position: model.snapshot.strip2Position,
                action: $model.configuration.pad.rightStrip)

            Spacer()
        }
        .padding(20)
    }
}

/// One Touch Strip, with a live position readout.
struct StripBindingView: View {
    let title: String
    let position: Double?
    @Binding var action: StripAction

    private enum Mode: String, CaseIterable, Identifiable {
        case none = "Nothing"
        case vertical = "Scroll vertically"
        case horizontal = "Scroll horizontally"
        case zoom = "Zoom (⌘+ / ⌘−)"
        var id: String { rawValue }
    }

    private var mode: Mode {
        switch action {
        case .none: return .none
        case .scrollVertical: return .vertical
        case .scrollHorizontal: return .horizontal
        case .keySteps: return .zoom
        }
    }

    private var isInverted: Bool {
        switch action {
        case .scrollVertical(let inverted), .scrollHorizontal(let inverted): return inverted
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                stripIndicator
            }

            HStack(spacing: 12) {
                Picker("", selection: Binding(get: { mode }, set: apply)) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)

                if mode == .vertical || mode == .horizontal {
                    Toggle("Reverse", isOn: Binding(
                        get: { isInverted },
                        set: { inverted in
                            action = mode == .vertical
                                ? .scrollVertical(inverted: inverted)
                                : .scrollHorizontal(inverted: inverted)
                        }))
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    /// The strip is a row of discrete pads, so show it as discrete pads.
    private var stripIndicator: some View {
        HStack(spacing: 2) {
            ForEach(0..<PadSample.stripPadCount, id: \.self) { pad in
                let lit = position.map { abs($0 - Double(pad)) < 0.75 } ?? false
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(lit ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: 6, height: 12)
            }
        }
        .animation(.easeOut(duration: 0.08), value: position)
    }

    private func apply(_ newMode: Mode) {
        switch newMode {
        case .none:
            action = .none
        case .vertical:
            action = .scrollVertical(inverted: false)
        case .horizontal:
            action = .scrollHorizontal(inverted: false)
        case .zoom:
            action = .keySteps(
                up: .tapKey(code: KeyCode.equal, modifiers: .command),
                down: .tapKey(code: KeyCode.minus, modifiers: .command))
        }
    }
}
