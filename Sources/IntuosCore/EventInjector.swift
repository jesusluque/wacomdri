// SPDX-License-Identifier: GPL-2.0-or-later
import ApplicationServices
import CoreGraphics
import Foundation

/// What one of the two barrel buttons on the pen does.
///
/// The rocker has an upper and a lower position, each assignable independently,
/// as in Wacom's own driver.
public enum BarrelAction: Sendable, Codable, Equatable, Hashable {
    case none
    case leftClick
    case rightClick
    case middleClick
    case doubleClick
    /// Press and release a key.
    case tapKey(code: UInt16, modifiers: Modifiers)
    /// Hold a key for as long as the barrel button is held.
    case holdKey(code: UInt16, modifiers: Modifiers)

    var mouseButton: CGMouseButton? {
        switch self {
        case .leftClick, .doubleClick: return .left
        case .rightClick: return .right
        case .middleClick: return .center
        case .none, .tapKey, .holdKey: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .none: return "Nothing"
        case .leftClick: return "Left click"
        case .rightClick: return "Right click"
        case .middleClick: return "Middle click"
        case .doubleClick: return "Double click"
        case .tapKey(let code, let modifiers):
            return modifiers.symbols + KeyCode.name(for: code)
        case .holdKey(let code, let modifiers):
            return "Hold " + modifiers.symbols + KeyCode.name(for: code)
        }
    }
}

/// Turns decoded tablet events into synthetic macOS input events.
///
/// macOS carries tablet data on ordinary mouse events tagged with the
/// `tabletPoint` subtype, plus standalone proximity events. Apps that support
/// tablets (Krita, Photoshop, Clip Studio) read the tablet fields off those
/// events via `NSEvent`; apps that do not simply see a mouse. Posting at
/// `cghidEventTap` puts the events in below any per-session tap, so every
/// application sees them.
public final class EventInjector {
    public var mapper: Mapper
    public var pressureCurve: PressureCurve
    public var barrelButton1: BarrelAction
    public var barrelButton2: BarrelAction

    /// Identifies this tablet to applications. Stable for the process lifetime;
    /// apps use it to tell two tablets apart.
    private let deviceID: Int64 = 1

    // Button state, tracked because macOS wants explicit down/up transitions
    // rather than a level.
    private var tipDown = false
    private var button1Down = false
    private var button2Down = false
    private var lastPoint: CGPoint?
    private var lastPressure: Double = 0
    private var currentTool: ToolIdentity?

    public init(
        mapper: Mapper,
        pressureCurve: PressureCurve = .linear,
        barrelButton1: BarrelAction = .rightClick,
        barrelButton2: BarrelAction = .middleClick
    ) {
        self.mapper = mapper
        self.pressureCurve = pressureCurve
        self.barrelButton1 = barrelButton1
        self.barrelButton2 = barrelButton2
    }

    /// Whether this process may post synthetic events. Without Accessibility
    /// permission `CGEvent.post` silently does nothing, which is indistinguishable
    /// from a decoding bug unless it is checked explicitly.
    public static var canPostEvents: Bool { AXIsProcessTrusted() }

    /// Ask macOS to prompt for Accessibility.
    ///
    /// There is no API to request this the way Input Monitoring can be
    /// requested; the only lever is this options dictionary, which shows the
    /// standard dialog and — crucially — registers the binary in the
    /// Accessibility list. Without it the user has to add the executable by
    /// hand, which means navigating to a hidden directory in an open panel.
    ///
    /// - Returns: whether permission is already granted. A false return means
    ///   the prompt was shown, not that it was refused.
    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public func handle(_ event: TabletEvent) {
        switch event {
        case .proximityEnter(let tool):
            currentTool = tool
            postProximity(tool: tool, entering: true)

        case .proximityExit(let tool):
            releaseHeldButtons()
            postProximity(tool: tool, entering: false)
            currentTool = nil
            lastPoint = nil

        case .pen(let sample, let tool):
            handlePen(sample, tool: tool)

        case .pad:
            // Handled by the pad mapper, not here.
            break
        }
    }

    /// Release everything, e.g. when the tablet is unplugged mid-stroke. Without
    /// this the button stays logically down and the desktop is left in a
    /// drag that nothing can end.
    public func reset() {
        releaseHeldButtons()
        currentTool = nil
        lastPoint = nil
    }

    // MARK: - Pen

    private func handlePen(_ sample: PenSample, tool: ToolIdentity) {
        let point = mapper.map(x: sample.x, y: sample.y)
        let pressure = pressureCurve.apply(rawPressure: sample.pressure)

        let wantButton1 = sample.barrelButton1 && barrelButton1 != .none
        let wantButton2 = sample.barrelButton2 && barrelButton2 != .none

        // Post at most one state change per report, movement last, so that
        // every down/up lands at the position it actually happened.
        if sample.tipDown != tipDown {
            tipDown = sample.tipDown
            post(
                type: tipDown ? .leftMouseDown : .leftMouseUp,
                button: .left, at: point, sample: sample, tool: tool, pressure: pressure)
            return
        }

        if wantButton1 != button1Down {
            button1Down = wantButton1
            perform(barrelButton1, down: wantButton1,
                    at: point, sample: sample, tool: tool, pressure: pressure)
            return
        }

        if wantButton2 != button2Down {
            button2Down = wantButton2
            perform(barrelButton2, down: wantButton2,
                    at: point, sample: sample, tool: tool, pressure: pressure)
            return
        }

        // No transition: a move, or a drag if something is held.
        //
        // A pen is never perfectly still, so holding it against the tablet used
        // to emit a continuous stream of drag events. Menus read that as
        // drag-to-select and dismiss on release, which is why clicking a
        // dropdown or a context menu would open it and then lose it the moment
        // the tip or the barrel button came up.
        //
        // Movement that does not shift the cursor by a whole pixel is therefore
        // dropped — unless pressure changed, which still matters to a drawing
        // app even when the nib has not travelled.
        if let last = lastPoint,
           last.rounded() == point.rounded(),
           abs(pressure - lastPressure) < 0.002 {
            return
        }

        let type: CGEventType
        let button: CGMouseButton
        if tipDown {
            type = .leftMouseDragged
            button = .left
        } else if button1Down {
            type = draggedType(for: barrelButton1)
            button = cgButton(for: barrelButton1)
        } else if button2Down {
            type = draggedType(for: barrelButton2)
            button = cgButton(for: barrelButton2)
        } else {
            type = .mouseMoved
            button = .left
        }

        post(type: type, button: button, at: point, sample: sample, tool: tool, pressure: pressure)
    }

    /// Carry out a barrel button transition, whatever it is bound to.
    private func perform(
        _ action: BarrelAction, down: Bool, at point: CGPoint,
        sample: PenSample, tool: ToolIdentity, pressure: Double
    ) {
        switch action {
        case .none:
            break

        case .leftClick, .rightClick, .middleClick:
            post(type: eventType(for: action, down: down), button: cgButton(for: action),
                 at: point, sample: sample, tool: tool, pressure: pressure)

        case .doubleClick:
            // Only on the press; a double click is a gesture, not a held state.
            // The second click carries clickState 2, which is what makes the
            // system treat the pair as a double click rather than two singles.
            guard down else { break }
            for clickState in 1...2 {
                post(type: .leftMouseDown, button: .left, at: point,
                     sample: sample, tool: tool, pressure: pressure, clickState: clickState)
                post(type: .leftMouseUp, button: .left, at: point,
                     sample: sample, tool: tool, pressure: pressure, clickState: clickState)
            }

        case .tapKey(let code, let modifiers):
            guard down else { break }
            postKey(code: code, modifiers: modifiers, down: true)
            postKey(code: code, modifiers: modifiers, down: false)

        case .holdKey(let code, let modifiers):
            postKey(code: code, modifiers: modifiers, down: down)
        }
    }

    private func postKey(code: UInt16, modifiers: Modifiers, down: Bool) {
        guard let event = CGEvent(
            keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
        else { return }
        event.flags = modifiers.cgFlags
        event.post(tap: .cghidEventTap)
    }

    private func post(
        type: CGEventType,
        button: CGMouseButton,
        at point: CGPoint,
        sample: PenSample,
        tool: ToolIdentity,
        pressure: Double,
        clickState: Int = 1
    ) {
        guard let event = CGEvent(
            mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: point, mouseButton: button)
        else { return }

        // Tag the event as tablet input. Without this the tablet fields below
        // are ignored and apps treat it as an ordinary mouse.
        event.setIntegerValueField(
            .mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))

        event.setIntegerValueField(.tabletEventPointX, value: Int64(sample.x))
        event.setIntegerValueField(.tabletEventPointY, value: Int64(sample.y))
        event.setIntegerValueField(.tabletEventPointZ, value: 0)
        event.setIntegerValueField(.tabletEventDeviceID, value: deviceID)

        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        // Also set the generic mouse pressure: some apps read only this one.
        event.setDoubleValueField(.mouseEventPressure, value: pressure)

        // macOS expects tilt normalised to -1...1; the tablet reports -64...63.
        event.setDoubleValueField(
            .tabletEventTiltX, value: Double(sample.tiltX) / Double(Intuos3.tiltBias))
        event.setDoubleValueField(
            .tabletEventTiltY, value: Double(sample.tiltY) / Double(Intuos3.tiltBias))

        if let rotation = sample.rotation {
            // Tenths of a degree from the tablet, degrees for macOS.
            event.setDoubleValueField(.tabletEventRotation, value: Double(rotation) / 10.0)
        }

        var buttonMask: Int64 = 0
        if sample.tipDown { buttonMask |= 1 << 0 }
        if sample.barrelButton1 { buttonMask |= 1 << 1 }
        if sample.barrelButton2 { buttonMask |= 1 << 2 }
        event.setIntegerValueField(.tabletEventPointButtons, value: buttonMask)

        // Deltas matter to apps that track relative movement even while
        // receiving absolute positions.
        if let last = lastPoint {
            event.setIntegerValueField(
                .mouseEventDeltaX, value: Int64((point.x - last.x).rounded()))
            event.setIntegerValueField(
                .mouseEventDeltaY, value: Int64((point.y - last.y).rounded()))
        }
        lastPoint = point
        lastPressure = pressure

        // A click state of 0 on a down event makes some apps ignore the click.
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            || type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Proximity

    private func postProximity(tool: ToolIdentity, entering: Bool) {
        guard let event = CGEvent(source: nil) else { return }
        event.type = .tabletProximity

        event.setIntegerValueField(.tabletProximityEventVendorID, value: Int64(Intuos3.vendorID))
        event.setIntegerValueField(.tabletProximityEventTabletID, value: Int64(Intuos3.productID))
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        event.setIntegerValueField(.tabletProximityEventPointerID, value: 0)

        event.setIntegerValueField(
            .tabletProximityEventVendorPointerType, value: Int64(tool.toolID))
        event.setIntegerValueField(
            .tabletProximityEventVendorPointerSerialNumber, value: Int64(tool.serial))
        event.setIntegerValueField(
            .tabletProximityEventVendorUniqueID, value: Int64(tool.serial))

        event.setIntegerValueField(
            .tabletProximityEventPointerType, value: Int64(pointerType(for: tool.type)))
        event.setIntegerValueField(
            .tabletProximityEventCapabilityMask, value: Self.capabilityMask)
        event.setIntegerValueField(
            .tabletProximityEventEnterProximity, value: entering ? 1 : 0)

        event.post(tap: .cghidEventTap)
    }

    /// What this tablet can report, as `NX_TABLET_CAPABILITY_*` bits. Apps use
    /// it to decide which controls to offer, so claiming capabilities the
    /// hardware lacks would be worse than useless.
    private static let capabilityMask: Int64 =
        0x0001  // device ID
        | 0x0002  // absolute X
        | 0x0004  // absolute Y
        | 0x0040  // buttons
        | 0x0080  // tilt X
        | 0x0100  // tilt Y
        | 0x0400  // pressure
        | 0x2000  // rotation

    /// `NX_TABLET_POINTER_*`.
    private func pointerType(for tool: ToolType) -> Int {
        switch tool {
        case .eraser: return 3
        case .mouse, .lensCursor: return 2
        default: return 1
        }
    }

    // MARK: - Button plumbing

    private func releaseHeldButtons() {
        guard let tool = currentTool, let point = lastPoint else {
            tipDown = false
            button1Down = false
            button2Down = false
            return
        }

        // Synthesise a zero-pressure sample at the last known position so the
        // release lands somewhere sensible.
        var sample = PenSample(
            x: 0, y: 0, distance: Intuos3.maxDistance, pressure: 0,
            tiltX: 0, tiltY: 0, tipDown: false,
            barrelButton1: false, barrelButton2: false)

        if tipDown {
            tipDown = false
            post(type: .leftMouseUp, button: .left, at: point, sample: sample, tool: tool, pressure: 0)
        }
        if button1Down {
            button1Down = false
            sample.barrelButton1 = false
            perform(barrelButton1, down: false,
                    at: point, sample: sample, tool: tool, pressure: 0)
        }
        if button2Down {
            button2Down = false
            perform(barrelButton2, down: false,
                    at: point, sample: sample, tool: tool, pressure: 0)
        }
    }

    private func cgButton(for action: BarrelAction) -> CGMouseButton {
        action.mouseButton ?? .left
    }

    private func eventType(for action: BarrelAction, down: Bool) -> CGEventType {
        switch action.mouseButton {
        case .right: return down ? .rightMouseDown : .rightMouseUp
        case .center: return down ? .otherMouseDown : .otherMouseUp
        case .left: return down ? .leftMouseDown : .leftMouseUp
        default: return .mouseMoved
        }
    }

    private func draggedType(for action: BarrelAction) -> CGEventType {
        switch action.mouseButton {
        case .right: return .rightMouseDragged
        case .center: return .otherMouseDragged
        case .left: return .leftMouseDragged
        default: return .mouseMoved
        }
    }
}

extension CGPoint {
    /// Whole-pixel position, used to tell real movement from pen jitter.
    func rounded() -> CGPoint {
        CGPoint(x: x.rounded(), y: y.rounded())
    }
}
