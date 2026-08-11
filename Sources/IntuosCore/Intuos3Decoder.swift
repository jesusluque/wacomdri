// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from the Linux kernel's drivers/hid/wacom_wac.c, which is
// GPL-2.0-or-later. This file is a derivative work of it and carries the same
// licence.
import Foundation

/// Decodes Intuos3 HID reports into `TabletEvent`s.
///
/// This is a direct port of `wacom_intuos_irq()` and its helpers from the Linux
/// kernel's `drivers/hid/wacom_wac.c`, restricted to what an Intuos3 6x8
/// actually emits. Bit-level operations are kept literally identical to the C so
/// they can be diffed against the source; the divergences are called out where
/// they occur.
///
/// The type is pure: no I/O, no timing, no platform dependencies. It carries
/// only proximity state, which is genuinely required because the tablet reports
/// tool identity once on entry and never repeats it.
///
/// ## Report layout
///
/// Reports must be passed in *Linux layout*: `report[0]` is the report ID,
/// matching the `data[]` indices in the kernel source. Normalising to this
/// convention is the transport's job — macOS may or may not include the report
/// ID in the buffer it hands back, and pinning that down is what
/// `wacomdri-probe` is for.
public struct Intuos3Decoder {
    /// Identity of the tool currently in proximity, captured from the enter
    /// report. `nil` means nothing is in range.
    public private(set) var currentTool: ToolIdentity?

    /// True once a position sample has been emitted for the current tool.
    /// Mirrors `wacom->reporting_data`.
    private var reportingData = false

    /// Last emitted sample, kept so a stroke can be terminated at the position
    /// it actually ended at. Linux gets this for free because the input layer
    /// only transmits changed axes; we build whole events, so we need the
    /// previous one.
    private var lastSample: PenSample?

    public init() {}

    /// Decode one report. Returns `nil` when the report carries no event we act
    /// on, which is normal and frequent.
    public mutating func decode(_ report: [UInt8]) -> TabletEvent? {
        guard let reportID = report.first else { return nil }

        switch reportID {
        case Intuos3Report.pad:
            return decodePad(report)
        case Intuos3Report.pen:
            // Proximity transitions take priority. Note the three-way outcome:
            // a report can be a proximity report that yields no event, which is
            // still "handled" and must not fall through to the data decoder —
            // otherwise a hover report decodes as a pen sample at (0, 0) and
            // yanks the cursor into the corner.
            switch decodeProximity(report) {
            case .handled(let event): return event
            case .notProximity: return decodePenData(report)
            }
        default:
            return nil
        }
    }

    /// Discard proximity state, e.g. after the device is unplugged, so a stale
    /// tool identity cannot leak into the next session.
    public mutating func reset() {
        currentTool = nil
        reportingData = false
        lastSample = nil
    }

    // MARK: - Proximity (wacom_intuos_inout)

    /// Outcome of the proximity stage, distinguishing "this was a proximity
    /// report" from "this report carries data". The kernel encodes the same
    /// distinction in the integer return value of `wacom_intuos_inout()`.
    private enum ProximityOutcome {
        /// The report was a proximity transition, optionally producing an event.
        case handled(TabletEvent?)
        /// Not a proximity report; the data decoder should look at it.
        case notProximity
    }

    private mutating func decodeProximity(_ d: [UInt8]) -> ProximityOutcome {
        guard d.count >= 9 else { return .notProximity }
        let d1 = Int(d[1])

        let isEnter = (d1 & 0xfc) == 0xc0
        let isInRange = (d1 & 0xfe) == 0x20
        let isExit = (d1 & 0xfe) == 0x80
        guard isEnter || isInRange || isExit else { return .notProximity }

        if isEnter {
            let serial = (UInt64(d[3] & 0x0f) << 28)
                + (UInt64(d[4]) << 20)
                + (UInt64(d[5]) << 12)
                + (UInt64(d[6]) << 4)
                + (UInt64(d[7]) >> 4)

            let toolID = (Int(d[2]) << 4)
                | (Int(d[3]) >> 4)
                | ((Int(d[7]) & 0x0f) << 16)
                | ((Int(d[8]) & 0xf0) << 8)

            let tool = ToolIdentity(
                toolID: toolID, serial: serial,
                type: ToolIdentity.classify(toolID: toolID))
            currentTool = tool
            reportingData = false
            lastSample = nil

            // Divergence from Linux, which emits nothing here and lets the
            // input layer infer proximity from the tool key. macOS models
            // proximity explicitly: apps need an enter event before they will
            // treat what follows as tablet input.
            return .handled(.proximityEnter(tool))
        }

        if isInRange {
            // The tool is hovering. If a stroke was in progress the tablet can
            // jump straight to in-range without ever sending a zero-pressure
            // data packet, so synthesise the lift-off here — otherwise the
            // button stays down forever and the app keeps drawing.
            guard reportingData, let tool = currentTool, var sample = lastSample else {
                return .handled(nil)
            }
            reportingData = false
            sample.pressure = 0
            sample.tipDown = false
            sample.distance = Intuos3.maxDistance
            lastSample = sample
            return .handled(.pen(sample, tool))
        }

        // Exit. Suppress it if we never learned who was in range, matching the
        // kernel's "don't report exit if we don't know the ID" guard.
        guard let tool = currentTool else { return .handled(nil) }
        currentTool = nil
        reportingData = false
        lastSample = nil
        return .handled(.proximityExit(tool))
    }

    // MARK: - Pen data (wacom_intuos_general)

    private mutating func decodePenData(_ d: [UInt8]) -> TabletEvent? {
        guard d.count >= 10 else { return nil }

        // Without an identity the sample is unattributable. Linux reschedules a
        // proximity query here; we simply wait for the tablet to resend one.
        guard let tool = currentTool else { return nil }

        // The 6x8 is a plain `INTUOS3`, which the kernel excludes from lens
        // cursor support.
        guard tool.type != .lensCursor else { return nil }

        // Packet type. For plain pen packets (0...3) the low two bits double as
        // the barrel button state, which is why `type` and the button masks
        // overlap. That is the hardware's encoding, not a transcription error.
        let type = (Int(d[1]) >> 1) & 0x0F

        let x = (Int(d[2]) << 9) | (Int(d[3]) << 1) | ((Int(d[9]) >> 1) & 1)
        let y = (Int(d[4]) << 9) | (Int(d[5]) << 1) | (Int(d[9]) & 1)
        let distance = Int(d[9]) >> 2

        // Built by the branches below; a nil sample means the packet type is one
        // we deliberately drop. Funnelling every branch through one exit keeps
        // `reportingData` and `lastSample` from drifting out of sync.
        let sample: PenSample?

        switch type {
        case 0x00, 0x01, 0x02, 0x03:
            // Pressure is 10 bits split across three bytes. The kernel shifts
            // right by one because this model tops out at 1023, not 2047.
            var pressure = (Int(d[6]) << 3) | ((Int(d[7]) & 0xC0) >> 5) | (Int(d[1]) & 1)
            pressure >>= 1

            sample = PenSample(
                x: x, y: y, distance: distance, pressure: pressure,
                tiltX: tiltX(d), tiltY: tiltY(d),
                // The kernel's tip-down threshold. A small deadband is needed
                // because the sensor idles slightly above zero.
                tipDown: pressure > 10,
                barrelButton1: (Int(d[1]) & 2) != 0,
                barrelButton2: (Int(d[1]) & 4) != 0)

        case 0x0a:
            // Airbrush second packet: fingerwheel plus tilt, no pressure.
            let wheel = (Int(d[6]) << 2) | ((Int(d[7]) >> 6) & 3)
            sample = PenSample(
                x: x, y: y, distance: distance, pressure: 0,
                tiltX: tiltX(d), tiltY: tiltY(d),
                tipDown: false, barrelButton1: false, barrelButton2: false,
                wheel: wheel)

        case 0x05:
            // Marker Pen barrel rotation, mapped to -900...899 tenths of a
            // degree by the kernel's piecewise conversion.
            let raw = (Int(d[6]) << 3) | ((Int(d[7]) >> 5) & 7)
            let rotation: Int
            if (Int(d[7]) & 0x20) != 0 {
                rotation = raw > 900 ? ((raw - 1) / 2 - 1350) : ((raw - 1) / 2 + 450)
            } else {
                rotation = 450 - raw / 2
            }
            sample = PenSample(
                x: x, y: y, distance: distance, pressure: 0,
                tiltX: 0, tiltY: 0,
                tipDown: false, barrelButton1: false, barrelButton2: false,
                rotation: rotation)

        default:
            // 0x04 (4D mouse), 0x06 (I4 mouse) and 0x08 (2D mouse / lens
            // cursor) are recognised and dropped: puck support is out of scope.
            // Adding it means decoding the button bits of d[8] per
            // `wacom_intuos_general()` and emitting a separate event case.
            sample = nil
        }

        guard let sample else { return nil }
        reportingData = true
        lastSample = sample
        return .pen(sample, tool)
    }

    /// Tilt is 7 bits split across two bytes, biased by 64.
    private func tiltX(_ d: [UInt8]) -> Int {
        (((Int(d[7]) << 1) & 0x7e) | (Int(d[8]) >> 7)) - Intuos3.tiltBias
    }

    private func tiltY(_ d: [UInt8]) -> Int {
        (Int(d[8]) & 0x7f) - Intuos3.tiltBias
    }

    // MARK: - Pad (wacom_intuos_pad)

    private func decodePad(_ d: [UInt8]) -> TabletEvent? {
        guard d.count >= 7 else { return nil }

        // The 8 ExpressKeys arrive as two nibbles plus two stray high bits, one
        // pair per side of the tablet.
        let buttons = ((Int(d[6]) & 0x10) << 5)
            | ((Int(d[5]) & 0x10) << 4)
            | ((Int(d[6]) & 0x0F) << 4)
            | (Int(d[5]) & 0x0F)

        let strip1 = ((Int(d[1]) & 0x1f) << 8) | Int(d[2])
        let strip2 = ((Int(d[3]) & 0x1f) << 8) | Int(d[4])

        return .pad(PadSample(
            buttons: UInt8(truncatingIfNeeded: buttons),
            strip1: strip1,
            strip2: strip2))
    }
}
