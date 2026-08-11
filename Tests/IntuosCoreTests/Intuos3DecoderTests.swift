// SPDX-License-Identifier: GPL-2.0-or-later
import Testing
@testable import IntuosCore

// Reports are hand-built from the bit layout documented in `Intuos3Decoder`, so
// these tests pin the port to the specification rather than to itself. Fixtures
// captured from real hardware by `wacomdri-probe` are added alongside them.

/// Enter-proximity report encoding tool ID `0x822` (Grip Pen) and serial
/// `0x12345`.
///
///   toolID = (0x82 << 4) | (0x20 >> 4)                     = 0x822
///   serial = (0x12 << 12) | (0x34 << 4) | (0x50 >> 4)      = 0x12345
private let penEnterReport: [UInt8] =
    [0x02, 0xc0, 0x82, 0x20, 0x00, 0x12, 0x34, 0x50, 0x00, 0x00]

/// Same, but tool ID `0x82a` — bit 3 set marks the eraser end.
private let eraserEnterReport: [UInt8] =
    [0x02, 0xc0, 0x82, 0xa0, 0x00, 0x12, 0x34, 0x50, 0x00, 0x00]

private let exitReport: [UInt8] =
    [0x02, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

/// Returns a decoder that already has the Grip Pen in proximity.
private func decoderInProximity() -> Intuos3Decoder {
    var decoder = Intuos3Decoder()
    _ = decoder.decode(penEnterReport)
    return decoder
}

// MARK: - Proximity

@Test func enterProximityCapturesToolIdentity() {
    var decoder = Intuos3Decoder()
    let event = decoder.decode(penEnterReport)

    guard case .proximityEnter(let tool) = event else {
        Issue.record("expected proximityEnter, got \(String(describing: event))")
        return
    }
    #expect(tool.toolID == 0x822)
    #expect(tool.serial == 0x12345)
    #expect(tool.type == .pen)
    #expect(decoder.currentTool == tool)
}

@Test func flippedPenIsReportedAsEraser() {
    var decoder = Intuos3Decoder()
    let event = decoder.decode(eraserEnterReport)

    guard case .proximityEnter(let tool) = event else {
        Issue.record("expected proximityEnter, got \(String(describing: event))")
        return
    }
    #expect(tool.toolID == 0x82a)
    #expect(tool.type == .eraser)
    #expect(tool.type.isEraser)
}

@Test func exitProximityClearsTool() {
    var decoder = decoderInProximity()
    let event = decoder.decode(exitReport)

    guard case .proximityExit(let tool) = event else {
        Issue.record("expected proximityExit, got \(String(describing: event))")
        return
    }
    #expect(tool.toolID == 0x822)
    #expect(decoder.currentTool == nil)
}

@Test func exitWithoutEntryIsSuppressed() {
    // Mirrors the kernel's "don't report exit if we don't know the ID" guard:
    // plugging in mid-stroke must not fabricate an identity.
    var decoder = Intuos3Decoder()
    #expect(decoder.decode(exitReport) == nil)
}

@Test func hoveringInRangeEmitsNothing() {
    var decoder = decoderInProximity()
    let inRange: [UInt8] = [0x02, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    #expect(decoder.decode(inRange) == nil)
    #expect(decoder.currentTool != nil)
}

@Test func dataWithoutIdentityIsDropped() {
    // Position is meaningless until the tablet tells us which tool is in range.
    var decoder = Intuos3Decoder()
    let data: [UInt8] = [0x02, 0x00, 0x10, 0x00, 0x0F, 0x00, 0x40, 0x20, 0x80, 0x02]
    #expect(decoder.decode(data) == nil)
}

@Test func resetDiscardsProximityState() {
    var decoder = decoderInProximity()
    decoder.reset()
    #expect(decoder.currentTool == nil)
}

// MARK: - Pen samples

@Test func decodesPositionPressureAndTilt() {
    var decoder = decoderInProximity()

    // x = (0x10 << 9) | (0x00 << 1) | ((0x02 >> 1) & 1) = 8192 + 1
    // y = (0x0F << 9) | (0x00 << 1) | (0x02 & 1)        = 7680
    // pressure = ((0x40 << 3) | ((0x20 & 0xC0) >> 5) | 0) >> 1 = 512 >> 1
    // tiltX = (((0x20 << 1) & 0x7e) | (0x80 >> 7)) - 64 = (0x40 | 1) - 64
    // tiltY = (0x80 & 0x7f) - 64                        = -64
    let report: [UInt8] = [0x02, 0x00, 0x10, 0x00, 0x0F, 0x00, 0x40, 0x20, 0x80, 0x02]

    guard case .pen(let sample, let tool) = decoder.decode(report) else {
        Issue.record("expected pen sample")
        return
    }
    #expect(sample.x == 8193)
    #expect(sample.y == 7680)
    #expect(sample.distance == 0)
    #expect(sample.pressure == 256)
    #expect(sample.tiltX == 1)
    #expect(sample.tiltY == -64)
    #expect(sample.tipDown)
    #expect(!sample.barrelButton1)
    #expect(!sample.barrelButton2)
    #expect(tool.toolID == 0x822)
}

@Test func decodesFullScalePressure() {
    var decoder = decoderInProximity()

    // t = (0xFF << 3) | ((0xC0 & 0xC0) >> 5) | (0x01 & 1) = 2040 + 6 + 1
    // pressure = 2047 >> 1 = 1023, the model's maximum.
    let report: [UInt8] = [0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x00]

    guard case .pen(let sample, _) = decoder.decode(report) else {
        Issue.record("expected pen sample")
        return
    }
    #expect(sample.pressure == Intuos3.maxPressure)
    #expect(sample.tipDown)
}

@Test func pressureBelowThresholdIsNotATouch() {
    var decoder = decoderInProximity()

    // t = (0x02 << 3) | 0 | 0 = 16, pressure = 8, which is under the kernel's
    // threshold of 10 — hovering with the nib barely loaded, not a stroke.
    let report: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]

    guard case .pen(let sample, _) = decoder.decode(report) else {
        Issue.record("expected pen sample")
        return
    }
    #expect(sample.pressure == 8)
    #expect(!sample.tipDown)
}

@Test func decodesMaximumCoordinates() {
    var decoder = decoderInProximity()

    // The tablet's extents fit in 16 bits once the low bit from d[9] is folded
    // in; check nothing overflows or sign-extends on the way through.
    let report: [UInt8] = [0x02, 0x00, 0x4F, 0x60, 0x3B, 0x88, 0x00, 0x00, 0x00, 0x03]

    guard case .pen(let sample, _) = decoder.decode(report) else {
        Issue.record("expected pen sample")
        return
    }
    #expect(sample.x == (0x4F << 9) | (0x60 << 1) | 1)
    #expect(sample.y == (0x3B << 9) | (0x88 << 1) | 1)
    #expect(sample.x >= Intuos3.maxX)
    #expect(sample.y >= Intuos3.maxY)
    #expect(sample.distance == 0)
}

@Test func decodesHoverDistance() {
    var decoder = decoderInProximity()

    // distance = 0xFF >> 2 = 63, the far end of the hover range.
    let report: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF]

    guard case .pen(let sample, _) = decoder.decode(report) else {
        Issue.record("expected pen sample")
        return
    }
    #expect(sample.distance == Intuos3.maxDistance)
}

@Test(arguments: [
    // d[1], button 1, button 2. The low bits of d[1] are simultaneously the
    // packet type and the barrel button state on pen packets.
    (UInt8(0x00), false, false),
    (UInt8(0x02), true, false),
    (UInt8(0x04), false, true),
    (UInt8(0x06), true, true),
])
func decodesBarrelButtons(byte: UInt8, expectFirst: Bool, expectSecond: Bool) {
    var decoder = decoderInProximity()
    let report: [UInt8] = [0x02, byte, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00]

    guard case .pen(let sample, _) = decoder.decode(report) else {
        Issue.record("expected pen sample for d[1]=\(byte)")
        return
    }
    #expect(sample.barrelButton1 == expectFirst)
    #expect(sample.barrelButton2 == expectSecond)
}

@Test func decodesAirbrushWheel() {
    var decoder = decoderInProximity()

    // Packet type 0x0a: d[1] = 0x0a << 1 = 0x14.
    // wheel = (0xFF << 2) | ((0xC0 >> 6) & 3) = 1020 + 3
    let report: [UInt8] = [0x02, 0x14, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x00]

    guard case .pen(let sample, _) = decoder.decode(report) else {
        Issue.record("expected pen sample")
        return
    }
    #expect(sample.wheel == 1023)
    #expect(!sample.tipDown)
}

@Test func decodesMarkerPenRotation() {
    var decoder = decoderInProximity()

    // Packet type 0x05: d[1] = 0x05 << 1 = 0x0a.
    // raw = (0x00 << 3) | ((0x00 >> 5) & 7) = 0, d[7] & 0x20 == 0
    // => rotation = 450 - 0 / 2 = 450
    let report: [UInt8] = [0x02, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    guard case .pen(let sample, _) = decoder.decode(report) else {
        Issue.record("expected pen sample")
        return
    }
    #expect(sample.rotation == 450)
}

@Test func puckPacketsAreDroppedNotMisdecoded() {
    // Packet type 0x08 is the 2D mouse. Out of scope, but it must not be
    // mistaken for a pen sample and inject a bogus zero-pressure stroke.
    var decoder = decoderInProximity()
    let report: [UInt8] = [0x02, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F, 0x00]
    #expect(decoder.decode(report) == nil)
}

// MARK: - Pad

@Test(arguments: 0..<8)
func decodesEachExpressKey(index: Int) {
    var decoder = Intuos3Decoder()

    // Keys 0-3 live in the low nibble of d[5], keys 4-7 in the low nibble of
    // d[6] — one nibble per side of the tablet.
    var report = [UInt8](repeating: 0, count: 10)
    report[0] = Intuos3Report.pad
    if index < 4 {
        report[5] = UInt8(1 << index)
    } else {
        report[6] = UInt8(1 << (index - 4))
    }

    guard case .pad(let pad) = decoder.decode(report) else {
        Issue.record("expected pad sample")
        return
    }
    #expect(pad.isPressed(index), "key \(index) should read as pressed")
    #expect(pad.buttons == UInt8(1 << index))
    #expect(pad.isActive)
}

@Test func decodesAllExpressKeysAtOnce() {
    var decoder = Intuos3Decoder()
    var report = [UInt8](repeating: 0, count: 10)
    report[0] = Intuos3Report.pad
    report[5] = 0x0F
    report[6] = 0x0F

    guard case .pad(let pad) = decoder.decode(report) else {
        Issue.record("expected pad sample")
        return
    }
    #expect(pad.buttons == 0xFF)
    for index in 0..<Intuos3.expressKeyCount {
        #expect(pad.isPressed(index))
    }
}

@Test func decodesTouchStrips() {
    var decoder = Intuos3Decoder()

    // strip1 = ((0x1F & 0x1f) << 8) | 0xFF = 8191 -> clamped by the 5-bit mask
    // strip2 = ((0x01 & 0x1f) << 8) | 0x00 = 256
    var report = [UInt8](repeating: 0, count: 10)
    report[0] = Intuos3Report.pad
    report[1] = 0x1F
    report[2] = 0xFF
    report[3] = 0x01
    report[4] = 0x00

    guard case .pad(let pad) = decoder.decode(report) else {
        Issue.record("expected pad sample")
        return
    }
    #expect(pad.strip1 == 0x1FFF)
    #expect(pad.strip2 == 0x100)
    #expect(pad.isActive)
}

@Test func idlePadIsInactive() {
    var decoder = Intuos3Decoder()
    var report = [UInt8](repeating: 0, count: 10)
    report[0] = Intuos3Report.pad

    guard case .pad(let pad) = decoder.decode(report) else {
        Issue.record("expected pad sample")
        return
    }
    #expect(!pad.isActive)
    #expect(pad.buttons == 0)
}

@Test func padHighBitsBeyondEightKeysAreMasked() {
    // The kernel shares this branch with larger tablets, so d[5]/d[6] bit 4
    // carry buttons 8 and 9. The 6x8 has only 8 keys; those bits must not
    // wrap around into a real key.
    var decoder = Intuos3Decoder()
    var report = [UInt8](repeating: 0, count: 10)
    report[0] = Intuos3Report.pad
    report[5] = 0x10
    report[6] = 0x10

    guard case .pad(let pad) = decoder.decode(report) else {
        Issue.record("expected pad sample")
        return
    }
    #expect(pad.buttons == 0)
}

// MARK: - Framing

@Test func unknownReportIDsAreIgnored() {
    var decoder = Intuos3Decoder()
    #expect(decoder.decode([0x09, 0x00, 0x00]) == nil)
    #expect(decoder.decode([]) == nil)
}

@Test func truncatedReportsDoNotCrash() {
    // Guards against a short read indexing past the end of the buffer.
    var decoder = decoderInProximity()
    #expect(decoder.decode([Intuos3Report.pen, 0x00, 0x10]) == nil)
    #expect(decoder.decode([Intuos3Report.pad, 0x00]) == nil)
}

// MARK: - Tool classification

@Test(arguments: [
    (0x822, ToolType.pen),
    (0x82a, ToolType.eraser),
    (0x801, ToolType.inkingPen),
    (0x913, ToolType.airbrush),
    (0x885, ToolType.markerPen),
    (0x017, ToolType.mouse),
    (0x097, ToolType.lensCursor),
])
func classifiesTools(toolID: Int, expected: ToolType) {
    #expect(ToolIdentity.classify(toolID: toolID) == expected)
}
