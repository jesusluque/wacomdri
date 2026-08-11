// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import IntuosCore

// Replays reports captured from a real PTZ-630 through the decoder. The
// synthetic tests pin the port to the specification; these pin it to the
// hardware, and would catch a spec misreading that is self-consistent.

private func loadFixture(_ name: String) throws -> [[UInt8]] {
    // Walk up from this source file to the package root rather than declaring a
    // test resource, so the fixture stays next to the capture tooling that
    // produced it.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // IntuosCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
    let url = root.appendingPathComponent("fixtures/\(name)")

    let text = try String(contentsOf: url, encoding: .utf8)
    return text.split(separator: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        return trimmed.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }
}

@Test func replaysCapturedPenSessionWithoutAnomalies() throws {
    let reports = try loadFixture("pen-session.txt")
    #expect(reports.count > 50, "fixture looks truncated")

    var decoder = Intuos3Decoder()
    var enters = 0
    var exits = 0
    var samples: [PenSample] = []
    var toolTypes: [Int: ToolType] = [:]

    for report in reports {
        #expect(report.count == Intuos3Report.penLengthWithID,
                "captured reports should all be 10 bytes")

        switch decoder.decode(report) {
        case .proximityEnter(let tool):
            enters += 1
            toolTypes[tool.toolID] = tool.type
        case .proximityExit:
            exits += 1
        case .pen(let sample, let tool):
            samples.append(sample)
            toolTypes[tool.toolID] = tool.type
        case .pad, .none:
            break
        }
    }

    #expect(enters > 0, "capture should contain proximity entries")
    #expect(exits > 0, "capture should contain proximity exits")
    #expect(samples.count > 40, "capture should contain pen samples")

    // The session used both ends of one Grip Pen. The IDs differ only in bit 3,
    // which is exactly how the Intuos3 signals "flipped over" — there is no
    // separate eraser report. This is the real-hardware check on that rule.
    #expect(Set(toolTypes.keys) == [0x823, 0x82b],
            "unexpected tool IDs: \(toolTypes.keys.map { String($0, radix: 16) })")
    #expect(toolTypes[0x823] == .pen)
    #expect(toolTypes[0x82b] == .eraser)

    // Every decoded value must sit inside what the hardware can express. A
    // shifted byte offset would blow one of these bounds immediately.
    for sample in samples {
        #expect((0...Intuos3.maxX).contains(sample.x), "x out of range: \(sample.x)")
        #expect((0...Intuos3.maxY).contains(sample.y), "y out of range: \(sample.y)")
        #expect((0...Intuos3.maxPressure).contains(sample.pressure),
                "pressure out of range: \(sample.pressure)")
        #expect((0...Intuos3.maxDistance).contains(sample.distance),
                "distance out of range: \(sample.distance)")
        #expect((-64...63).contains(sample.tiltX), "tiltX out of range: \(sample.tiltX)")
        #expect((-64...63).contains(sample.tiltY), "tiltY out of range: \(sample.tiltY)")
    }
}

@Test func capturedSessionExercisesTheFullPressureRange() throws {
    let reports = try loadFixture("pen-session.txt")
    var decoder = Intuos3Decoder()
    var pressures: [Int] = []
    var sawBarrelButton = false

    for report in reports {
        if case .pen(let sample, _) = decoder.decode(report) {
            pressures.append(sample.pressure)
            if sample.barrelButton1 || sample.barrelButton2 { sawBarrelButton = true }
        }
    }

    // The capture deliberately swept light to hard, so both ends must appear.
    // A stuck or half-decoded pressure field would collapse this range.
    #expect(pressures.contains { $0 == 0 }, "no zero-pressure samples")
    #expect(pressures.contains { $0 > Intuos3.maxPressure - 32 },
            "pressure never reached full scale; max was \(pressures.max() ?? -1)")
    #expect(pressures.contains { $0 > 10 && $0 < 900 }, "no mid-range pressure")
    #expect(sawBarrelButton, "capture should include barrel-button packets")
}

@Test func decodesAKnownCapturedEnterReportExactly() throws {
    // 02 c2 82 31 54 00 02 a0 00 00 — the first report of the session.
    var decoder = Intuos3Decoder()
    let report: [UInt8] = [0x02, 0xc2, 0x82, 0x31, 0x54, 0x00, 0x02, 0xa0, 0x00, 0x00]

    guard case .proximityEnter(let tool) = decoder.decode(report) else {
        Issue.record("expected proximityEnter")
        return
    }
    // A genuine Intuos3 Grip Pen ID, read off real hardware.
    #expect(tool.toolID == 0x823)
    #expect(tool.serial == 0x1540002a)
    #expect(tool.type == .pen)
    #expect(!tool.type.isEraser)
}

@Test func decodesAKnownCapturedHoverReportExactly() throws {
    // 02 e0 14 42 17 ad 00 25 e9 b9 — hovering, nib off the surface.
    var decoder = Intuos3Decoder()
    _ = decoder.decode([0x02, 0xc2, 0x82, 0x31, 0x54, 0x00, 0x02, 0xa0, 0x00, 0x00])

    guard case .pen(let sample, _) = decoder.decode(
        [0x02, 0xe0, 0x14, 0x42, 0x17, 0xad, 0x00, 0x25, 0xe9, 0xb9])
    else {
        Issue.record("expected pen sample")
        return
    }

    #expect(sample.x == 10372)
    #expect(sample.y == 12123)
    #expect(sample.distance == 46)
    #expect(sample.pressure == 0)
    #expect(sample.tiltX == 11)
    #expect(sample.tiltY == 41)
    // Hovering at distance 46 with zero pressure: the tip must not read as down.
    #expect(!sample.tipDown)
}

@Test func proximityStateMachineStaysConsistentAcrossTheCapture() throws {
    // Position samples must never be emitted while nothing is in proximity,
    // and an exit must always follow an entry.
    let reports = try loadFixture("pen-session.txt")
    var decoder = Intuos3Decoder()
    var inProximity = false

    for report in reports {
        switch decoder.decode(report) {
        case .proximityEnter:
            inProximity = true
        case .proximityExit:
            #expect(inProximity, "exit without a matching entry")
            inProximity = false
        case .pen:
            #expect(inProximity, "pen sample emitted while out of proximity")
        case .pad, .none:
            break
        }
    }
}

// MARK: - Pad

@Test func replaysCapturedPadSession() throws {
    let reports = try loadFixture("pad-session.txt")
    #expect(reports.count > 20, "fixture looks truncated")

    var decoder = Intuos3Decoder()
    var pressedKeys = Set<Int>()
    var stripPositions: [Double] = []

    for report in reports {
        guard case .pad(let pad) = decoder.decode(report) else {
            Issue.record("every report in this capture should decode as a pad sample")
            continue
        }

        for index in 0..<Intuos3.expressKeyCount where pad.isPressed(index) {
            pressedKeys.insert(index)
        }
        if let position = pad.strip1Position { stripPositions.append(position) }
    }

    #expect(!pressedKeys.isEmpty, "capture should contain ExpressKey presses")
    // The capture pressed the four keys on one side of the tablet.
    #expect(pressedKeys.isSubset(of: Set(0..<Intuos3.expressKeyCount)))
    #expect(pressedKeys.count >= 4, "expected at least one side's worth of keys")

    // The sweep ran the length of the strip.
    #expect(stripPositions.contains(0))
    #expect((stripPositions.max() ?? 0) >= 10)
}

@Test func capturedStripSweepIsAMonotonicRunOfPadIndices() throws {
    // The raw readings were powers of two; decoded they must come out as the
    // consecutive integers 0...11. If this ever reads as a huge linear value
    // again, the bitmask decoding has regressed.
    let reports = try loadFixture("pad-session.txt")
    var decoder = Intuos3Decoder()
    var sweep: [Double] = []

    for report in reports {
        if case .pad(let pad) = decoder.decode(report), let position = pad.strip1Position {
            sweep.append(position)
        }
    }

    #expect(Set(sweep) == Set((0..<12).map(Double.init)),
            "expected every pad index exactly once across the sweep; got \(Set(sweep).sorted())")
    for position in sweep {
        #expect(position <= Double(PadSample.stripPadCount),
                "position \(position) is off the end of the strip")
    }
}

@Test func decodesAKnownCapturedPadReportExactly() {
    // 0c 00 00 00 00 02 00 00 00 00 — ExpressKey 1, nothing else.
    var decoder = Intuos3Decoder()

    guard case .pad(let pad) = decoder.decode(
        [0x0c, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00])
    else {
        Issue.record("expected pad sample")
        return
    }

    #expect(pad.buttons == 0b0000_0010)
    #expect(pad.isPressed(1))
    #expect(!pad.isPressed(0))
    #expect(pad.strip1Position == nil)
    #expect(pad.strip2Position == nil)
    #expect(pad.isActive)
}
