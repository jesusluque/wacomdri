// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation

/// Keyboard modifiers, as a Codable stand-in for `CGEventFlags` (which is not
/// Codable and whose raw values are not stable enough to persist).
public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)

    public var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        return flags
    }
}

/// What pressing an ExpressKey does.
///
/// Deliberately the same vocabulary as `BarrelAction`: there is no reason a key
/// on the tablet should be able to do less than a button on the pen.
public enum PadAction: Codable, Sendable, Equatable, Hashable {
    case none
    /// Press and release the key immediately — for one-shot commands like undo.
    case tapKey(code: UInt16, modifiers: Modifiers)
    /// Hold the key for as long as the ExpressKey is held — for modal tools,
    /// e.g. holding space to pan.
    case holdKey(code: UInt16, modifiers: Modifiers)
    case leftClick
    case rightClick
    case middleClick
    case doubleClick

    var mouseButton: CGMouseButton? {
        switch self {
        case .leftClick, .doubleClick: return .left
        case .rightClick: return .right
        case .middleClick: return .center
        case .none, .tapKey, .holdKey: return nil
        }
    }
}

/// What sliding a finger along a Touch Strip does.
public enum StripAction: Codable, Sendable, Equatable {
    case none
    case scrollVertical(inverted: Bool)
    case scrollHorizontal(inverted: Bool)
    /// Emit a keystroke per step of travel, for zoom in/out bindings.
    case keySteps(up: PadAction, down: PadAction)
}

/// Key codes for the bindings people actually want. Values are the virtual key
/// codes from `Carbon/Events.h`, which is still the canonical list.
public enum KeyCode {
    public static let z: UInt16 = 6
    public static let x: UInt16 = 7
    public static let c: UInt16 = 8
    public static let v: UInt16 = 9
    public static let b: UInt16 = 11
    public static let e: UInt16 = 14
    public static let s: UInt16 = 1
    public static let space: UInt16 = 49
    public static let leftBracket: UInt16 = 33
    public static let rightBracket: UInt16 = 30
    public static let minus: UInt16 = 27
    public static let equal: UInt16 = 24
}

/// Configuration for the eight ExpressKeys and two Touch Strips.
public struct PadConfiguration: Codable, Sendable, Equatable {
    public var keys: [PadAction]
    public var leftStrip: StripAction
    public var rightStrip: StripAction

    public init(
        keys: [PadAction] = PadConfiguration.defaultKeys,
        leftStrip: StripAction = .scrollVertical(inverted: false),
        rightStrip: StripAction = .keySteps(
            up: .tapKey(code: KeyCode.equal, modifiers: .command),
            down: .tapKey(code: KeyCode.minus, modifiers: .command))
    ) {
        // Pad to the hardware's key count so an out-of-date config file cannot
        // crash the daemon on an index that no longer exists.
        var padded = keys
        while padded.count < Intuos3.expressKeyCount { padded.append(.none) }
        self.keys = Array(padded.prefix(Intuos3.expressKeyCount))
        self.leftStrip = leftStrip
        self.rightStrip = rightStrip
    }

    /// Bindings that are useful in most drawing apps out of the box.
    public static let defaultKeys: [PadAction] = [
        .holdKey(code: KeyCode.space, modifiers: []),          // pan
        .tapKey(code: KeyCode.z, modifiers: .command),          // undo
        .tapKey(code: KeyCode.leftBracket, modifiers: []),      // smaller brush
        .tapKey(code: KeyCode.rightBracket, modifiers: []),     // larger brush
        .tapKey(code: KeyCode.e, modifiers: []),                // eraser
        .tapKey(code: KeyCode.b, modifiers: []),                // brush
        .tapKey(code: KeyCode.z, modifiers: [.command, .shift]), // redo
        .tapKey(code: KeyCode.s, modifiers: .command),          // save
    ]
}

/// Where the pad's output goes. Injected so the mapping logic — edge detection,
/// strip thresholds, held-key bookkeeping — can be tested without posting real
/// events into the user's session.
public protocol PadEventSink: AnyObject {
    func postKey(code: UInt16, modifiers: Modifiers, down: Bool)
    func postScroll(vertical: Int32, horizontal: Int32)
    /// A click at wherever the cursor currently is. `count` of 2 is a double
    /// click, which needs the second click to arrive a moment after the first.
    func postClick(button: CGMouseButton, count: Int)
}

/// The real sink: synthesises system-wide keyboard and scroll events.
public final class SystemPadEventSink: PadEventSink {
    public init() {}

    public func postKey(code: UInt16, modifiers: Modifiers, down: Bool) {
        guard let event = CGEvent(
            keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
        else { return }
        event.flags = modifiers.cgFlags
        event.post(tap: .cghidEventTap)
    }

    public func postScroll(vertical: Int32, horizontal: Int32) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
            wheel1: vertical, wheel2: horizontal, wheel3: 0)
        else { return }
        event.post(tap: .cghidEventTap)
    }

    public func postClick(button: CGMouseButton, count: Int) {
        // The pad has no position of its own, so a click lands wherever the
        // pointer already is — which is where the user is looking.
        guard let location = CGEvent(source: nil)?.location else { return }

        let down: CGEventType
        let up: CGEventType
        switch button {
        case .right: down = .rightMouseDown; up = .rightMouseUp
        case .center: down = .otherMouseDown; up = .otherMouseUp
        default: down = .leftMouseDown; up = .leftMouseUp
        }

        func click(_ clickState: Int64) {
            for type in [down, up] {
                guard let event = CGEvent(
                    mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: location, mouseButton: button)
                else { continue }
                event.setIntegerValueField(.mouseEventClickState, value: clickState)
                event.post(tap: .cghidEventTap)
            }
        }

        click(1)
        guard count > 1 else { return }
        // The gap is part of the gesture; two clicks sharing one instant do not
        // read as a double click however the click state is labelled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { click(2) }
    }
}

/// Converts pad samples into keyboard and scroll events.
///
/// The pad reports a level, not transitions: a report arrives whenever anything
/// changes and carries the current state of everything. Turning that into
/// press/release pairs is this type's job.
public final class PadMapper {
    public var configuration: PadConfiguration
    private let sink: PadEventSink

    /// Button state from the previous report, for edge detection.
    private var previousButtons: UInt8 = 0

    /// Last strip positions, in pad indices. A strip reports nothing when
    /// untouched, so the first touch and the release must not be read as jumps.
    private var lastLeftStrip: Double?
    private var lastRightStrip: Double?

    /// Travel, in pads, needed before a `keySteps` strip fires once. Without it
    /// a slow drag machine-guns the keystroke.
    private var leftStripAccumulator = 0.0
    private var rightStripAccumulator = 0.0
    private static let stepThreshold = 1.0

    /// Scroll lines emitted per pad of travel.
    private static let linesPerPad: Double = 3

    public init(
        configuration: PadConfiguration = PadConfiguration(),
        sink: PadEventSink = SystemPadEventSink()
    ) {
        self.configuration = configuration
        self.sink = sink
    }

    public func handle(_ sample: PadSample) {
        handleButtons(sample.buttons)
        lastLeftStrip = handleStrip(
            sample.strip1Position, previous: lastLeftStrip,
            action: configuration.leftStrip, accumulator: &leftStripAccumulator)
        lastRightStrip = handleStrip(
            sample.strip2Position, previous: lastRightStrip,
            action: configuration.rightStrip, accumulator: &rightStripAccumulator)
    }

    /// Release anything still held, e.g. on unplug. A `holdKey` binding left
    /// down would otherwise wedge a modifier for the whole session.
    public func reset() {
        for index in 0..<Intuos3.expressKeyCount where previousButtons & (1 << UInt8(index)) != 0 {
            if case .holdKey(let code, let modifiers) = configuration.keys[index] {
                sink.postKey(code: code, modifiers: modifiers, down: false)
            }
        }
        previousButtons = 0
        lastLeftStrip = nil
        lastRightStrip = nil
        leftStripAccumulator = 0
        rightStripAccumulator = 0
    }

    // MARK: - ExpressKeys

    private func handleButtons(_ buttons: UInt8) {
        let changed = buttons ^ previousButtons
        guard changed != 0 else { return }

        for index in 0..<Intuos3.expressKeyCount {
            let mask = UInt8(1 << index)
            guard changed & mask != 0 else { continue }

            let pressed = buttons & mask != 0
            switch configuration.keys[index] {
            case .none:
                break
            case .tapKey(let code, let modifiers):
                // Fire on press only; a tap has no meaningful release.
                if pressed {
                    sink.postKey(code: code, modifiers: modifiers, down: true)
                    sink.postKey(code: code, modifiers: modifiers, down: false)
                }
            case .holdKey(let code, let modifiers):
                sink.postKey(code: code, modifiers: modifiers, down: pressed)
            case .leftClick, .rightClick, .middleClick:
                if pressed, let button = configuration.keys[index].mouseButton {
                    sink.postClick(button: button, count: 1)
                }
            case .doubleClick:
                if pressed { sink.postClick(button: .left, count: 2) }
            }
        }

        previousButtons = buttons
    }

    // MARK: - Touch Strips

    /// Travel is measured in pad indices, not raw readings — see
    /// `PadSample.stripPosition(mask:)` for why.
    ///
    /// - Parameter position: current position, or nil when the strip is not
    ///   being touched.
    /// - Returns: the position to remember for next time, or nil once released.
    private func handleStrip(
        _ position: Double?, previous: Double?, action: StripAction,
        accumulator: inout Double
    ) -> Double? {
        guard case .none = action else {
            // No position means the finger left the strip: end the gesture
            // without emitting the jump back to the start.
            guard let position else {
                accumulator = 0
                return nil
            }

            // First touch establishes a reference point and emits nothing.
            guard let previous else { return position }

            let delta = position - previous
            guard delta != 0 else { return position }

            switch action {
            case .none:
                break
            case .scrollVertical(let inverted):
                sink.postScroll(vertical: scrollAmount(delta, inverted: inverted), horizontal: 0)
            case .scrollHorizontal(let inverted):
                sink.postScroll(vertical: 0, horizontal: scrollAmount(delta, inverted: inverted))
            case .keySteps(let up, let down):
                accumulator += delta
                while abs(accumulator) >= Self.stepThreshold {
                    let forward = accumulator > 0
                    accumulator -= forward ? Self.stepThreshold : -Self.stepThreshold
                    // Pad 0 is at the top of the strip, so an increasing index
                    // means downward travel.
                    perform(forward ? down : up)
                }
            }
            return position
        }
        return nil
    }

    /// Scale strip travel into scroll lines, rounding away from zero so that
    /// slow, deliberate movement still scrolls instead of being swallowed.
    private func scrollAmount(_ delta: Double, inverted: Bool) -> Int32 {
        let scaled = delta * Self.linesPerPad
        let rounded = scaled < 0 ? min(Int32(scaled.rounded(.down)), -1)
                                 : max(Int32(scaled.rounded(.up)), 1)
        return inverted ? -rounded : rounded
    }

    private func perform(_ action: PadAction) {
        switch action {
        case .none:
            break
        case .tapKey(let code, let modifiers), .holdKey(let code, let modifiers):
            sink.postKey(code: code, modifiers: modifiers, down: true)
            sink.postKey(code: code, modifiers: modifiers, down: false)
        case .leftClick, .rightClick, .middleClick:
            if let button = action.mouseButton { sink.postClick(button: button, count: 1) }
        case .doubleClick:
            sink.postClick(button: .left, count: 2)
        }
    }
}
