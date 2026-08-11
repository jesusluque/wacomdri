// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

// Mirror everything to stdout as well as the window, so a verification run can
// assert on the output instead of a human squinting at a readout.
private func log(_ message: String) {
    print(message)
    fflush(stdout)
}

// Milestone 1 de-risking tool. It verifies the *output* half of the driver:
// that a synthetic CGEvent carrying tablet fields is delivered to a normal Cocoa
// app as a genuine tablet NSEvent, with pressure, tilt and proximity intact.
//
// Using this instead of Krita/Photoshop for the first check means a failure
// points at our event construction rather than at some app's tablet support.

struct Sample {
    var point: CGPoint = .zero
    var pressure: Float = 0
    var tilt: CGPoint = .zero
    var rotation: Float = 0
    var deviceID: Int = 0
    var pointingDeviceType: NSEvent.PointingDeviceType = .unknown
    var serialNumber: Int = 0
    var inProximity = false
    var subtype: String = "—"
    var eventType: String = "—"
    var tabletPointCount = 0
    var proximityCount = 0
    var plainMouseCount = 0
}

/// One rendered stroke segment. Width follows pressure, which makes a working
/// driver obvious at a glance and a broken one equally obvious.
struct Segment {
    let from: CGPoint
    let to: CGPoint
    let pressure: Float
    let isEraser: Bool
}

final class ScopeView: NSView {
    private var sample = Sample()
    private var segments: [Segment] = []
    private var lastPoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    // MARK: Event capture

    override func tabletPoint(with event: NSEvent) {
        record(event, eventType: "tabletPoint")
    }

    override func tabletProximity(with event: NSEvent) {
        sample.proximityCount += 1
        sample.eventType = "tabletProximity"
        sample.inProximity = event.isEnteringProximity
        sample.deviceID = event.deviceID
        sample.pointingDeviceType = event.pointingDeviceType
        sample.serialNumber = event.pointingDeviceSerialNumber
        if !event.isEnteringProximity { lastPoint = nil }
        log("PROXIMITY \(event.isEnteringProximity ? "enter" : "exit")"
            + " deviceID=\(event.deviceID)"
            + " pointerType=\(event.pointingDeviceType.rawValue)"
            + " serial=\(event.pointingDeviceSerialNumber)")
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { record(event, eventType: "mouseMoved") }
    override func mouseDragged(with event: NSEvent) { record(event, eventType: "mouseDragged", drawing: true) }
    override func mouseDown(with event: NSEvent) {
        lastPoint = nil
        record(event, eventType: "mouseDown", drawing: true)
    }
    override func mouseUp(with event: NSEvent) {
        record(event, eventType: "mouseUp")
        lastPoint = nil
    }
    override func rightMouseDown(with event: NSEvent) { record(event, eventType: "rightMouseDown") }
    override func rightMouseUp(with event: NSEvent) { record(event, eventType: "rightMouseUp") }

    override func keyDown(with event: NSEvent) {
        // Space clears the canvas so successive experiments stay readable.
        if event.charactersIgnoringModifiers == " " {
            segments.removeAll()
            lastPoint = nil
            needsDisplay = true
        } else {
            super.keyDown(with: event)
        }
    }

    private func record(_ event: NSEvent, eventType: String, drawing: Bool = false) {
        sample.eventType = eventType
        sample.point = convert(event.locationInWindow, from: nil)

        // A mouse event only carries tablet fields when its subtype says so.
        // Reading `tilt` on a plain mouse event throws, so this guard is load
        // bearing, not defensive noise.
        let isTablet: Bool
        if event.type == .tabletPoint {
            isTablet = true
            sample.subtype = "tabletPoint (native)"
        } else {
            switch event.subtype {
            case .tabletPoint:
                isTablet = true
                sample.subtype = "tabletPoint"
            case .tabletProximity:
                isTablet = false
                sample.subtype = "tabletProximity"
            default:
                isTablet = false
                sample.subtype = "mouseEvent (NO tablet data)"
                sample.plainMouseCount += 1
            }
        }

        if isTablet {
            sample.tabletPointCount += 1
            sample.pressure = event.pressure
            sample.tilt = event.tilt
            sample.rotation = event.rotation
            sample.deviceID = event.deviceID

            // Decimated: a stroke is hundreds of samples and the interesting
            // question is whether pressure varies at all, not every value.
            if sample.tabletPointCount % 20 == 1 {
                log("TABLET \(eventType) p=\(String(format: "%.3f", event.pressure))"
                    + " tilt=(\(String(format: "%+.2f", event.tilt.x)),"
                    + "\(String(format: "%+.2f", event.tilt.y)))"
                    + " deviceID=\(event.deviceID)")
            }
        } else {
            sample.pressure = event.pressure
            if sample.plainMouseCount % 20 == 1 {
                log("PLAIN \(eventType) — no tablet subtype")
            }
        }

        if drawing {
            if let last = lastPoint {
                segments.append(Segment(
                    from: last, to: sample.point,
                    pressure: sample.pressure,
                    isEraser: sample.pointingDeviceType == .eraser))
            }
            lastPoint = sample.point
        }

        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        for segment in segments {
            let path = NSBezierPath()
            path.move(to: segment.from)
            path.line(to: segment.to)
            path.lineCapStyle = .round
            // Scale so that a dead-flat pressure signal renders as a uniform
            // hairline and a working one renders as a tapering stroke.
            path.lineWidth = 0.5 + CGFloat(segment.pressure) * 24
            (segment.isEraser ? NSColor.systemRed : NSColor.labelColor).setStroke()
            path.stroke()
        }

        drawReadout()
    }

    private func drawReadout() {
        let deviceType: String
        switch sample.pointingDeviceType {
        case .pen: deviceType = "pen"
        case .eraser: deviceType = "ERASER"
        case .cursor: deviceType = "cursor (mouse/lens)"
        case .unknown: deviceType = "unknown"
        @unknown default: deviceType = "?"
        }

        let verdict: String
        if sample.tabletPointCount == 0 {
            verdict = sample.plainMouseCount > 0
                ? "NO TABLET DATA — events arrive as plain mouse events"
                : "waiting for events…"
        } else {
            verdict = "TABLET DATA OK — \(sample.tabletPointCount) tablet points, \(sample.proximityCount) proximity"
        }

        let text = """
        \(verdict)

        event            \(sample.eventType)
        subtype          \(sample.subtype)
        location         \(String(format: "%.1f, %.1f", sample.point.x, sample.point.y))
        pressure         \(String(format: "%.4f", sample.pressure))  \(bar(sample.pressure))
        tilt             \(String(format: "%+.3f, %+.3f", sample.tilt.x, sample.tilt.y))
        rotation         \(String(format: "%.2f", sample.rotation))
        device type      \(deviceType)
        in proximity     \(sample.inProximity)
        deviceID         \(sample.deviceID)
        serial           \(sample.serialNumber)

        plain mouse events: \(sample.plainMouseCount)
        draw to test pressure · space clears
        """

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        let origin = NSPoint(x: 16, y: bounds.height - size.height - 16)

        NSColor.textBackgroundColor.withAlphaComponent(0.85).setFill()
        NSRect(x: origin.x - 8, y: origin.y - 8, width: size.width + 16, height: size.height + 16).fill()
        attributed.draw(at: origin)
    }

    private func bar(_ value: Float) -> String {
        let filled = Int((max(0, min(1, value)) * 20).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "·", count: 20 - filled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = ScopeView(frame: NSRect(x: 0, y: 0, width: 760, height: 620))

        window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "PressureScope — tablet event inspector"
        window.contentView = view
        window.acceptsMouseMovedEvents = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
