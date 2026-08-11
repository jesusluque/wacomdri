// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The physical tool in proximity, identified by the ID the tablet reports when
/// the tool enters range.
public enum ToolType: Equatable, Sendable {
    case pen
    case inkingPen
    case brush
    case airbrush
    case markerPen
    case eraser
    case mouse
    case lensCursor

    /// Whether this tool should be reported to macOS as the eraser end.
    public var isEraser: Bool { self == .eraser }

    /// Tools that report pressure and tilt, as opposed to the puck-style ones.
    public var isStylus: Bool {
        switch self {
        case .mouse, .lensCursor: return false
        default: return true
        }
    }
}

/// Identity of the tool currently in proximity.
///
/// The tablet only sends this on the enter-proximity report, so it has to be
/// held in decoder state and attached to every subsequent sample.
public struct ToolIdentity: Equatable, Sendable {
    public let toolID: Int
    public let serial: UInt64
    public let type: ToolType

    public init(toolID: Int, serial: UInt64, type: ToolType) {
        self.toolID = toolID
        self.serial = serial
        self.type = type
    }

    /// Classification of `toolID`, ported from `wacom_intuos_get_tool_type()`.
    ///
    /// Note the fallback: any unrecognised ID with bit 3 set is the eraser end
    /// of a stylus. That is how the Intuos3 signals "pen flipped over" — there
    /// is no dedicated eraser report.
    public static func classify(toolID: Int) -> ToolType {
        switch toolID {
        case 0x812, 0x801, 0x12802, 0x012:
            return .inkingPen
        case 0x832, 0x032:
            return .brush
        case 0x007, 0x09c, 0x094, 0x017, 0x806:
            return .mouse
        case 0x096, 0x097, 0x006:
            return .lensCursor
        case 0xd12, 0x912, 0x112, 0x913, 0x902, 0x10902:
            return .airbrush
        case 0x885, 0x804, 0x10804, 0x204:
            return .markerPen
        default:
            return (toolID & 0x0008) != 0 ? .eraser : .pen
        }
    }
}

/// A pen/stylus sample in raw tablet units.
public struct PenSample: Equatable, Sendable {
    /// 0...`Intuos3.maxX`
    public var x: Int
    /// 0...`Intuos3.maxY`
    public var y: Int
    /// Hover height, 0...`Intuos3.maxDistance`.
    public var distance: Int
    /// 0...`Intuos3.maxPressure`
    public var pressure: Int
    /// -64...63
    public var tiltX: Int
    /// -64...63
    public var tiltY: Int
    public var tipDown: Bool
    public var barrelButton1: Bool
    public var barrelButton2: Bool
    /// Barrel rotation, -900...899. Marker Pen only.
    public var rotation: Int?
    /// Fingerwheel, 0...1023. Airbrush only.
    public var wheel: Int?

    public init(
        x: Int, y: Int, distance: Int, pressure: Int,
        tiltX: Int, tiltY: Int, tipDown: Bool,
        barrelButton1: Bool, barrelButton2: Bool,
        rotation: Int? = nil, wheel: Int? = nil
    ) {
        self.x = x
        self.y = y
        self.distance = distance
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.tipDown = tipDown
        self.barrelButton1 = barrelButton1
        self.barrelButton2 = barrelButton2
        self.rotation = rotation
        self.wheel = wheel
    }
}

/// ExpressKeys and Touch Strips.
public struct PadSample: Equatable, Sendable {
    /// Bit *n* is ExpressKey *n*; 8 keys on the 6x8, four per side.
    public var buttons: UInt8
    /// Left Touch Strip, 0...`Intuos3.maxTouchStrip`. Zero means "not touched".
    public var strip1: Int
    /// Right Touch Strip.
    public var strip2: Int

    public init(buttons: UInt8, strip1: Int, strip2: Int) {
        self.buttons = buttons
        self.strip1 = strip1
        self.strip2 = strip2
    }

    /// True while anything on the pad is being touched. Mirrors the `prox`
    /// calculation in `wacom_intuos_pad()`.
    public var isActive: Bool { buttons != 0 || strip1 != 0 || strip2 != 0 }

    /// Position along the left Touch Strip, or nil when it is not being touched.
    public var strip1Position: Double? { PadSample.stripPosition(mask: strip1) }

    /// Position along the right Touch Strip.
    public var strip2Position: Double? { PadSample.stripPosition(mask: strip2) }

    /// Convert a raw Touch Strip reading into a position along the strip.
    ///
    /// The strip is a row of discrete capacitive pads, not a linear
    /// potentiometer: the raw value is a **bitmask of which pads are covered**,
    /// so sliding along it reads 1, 2, 4, 8 … 2048. Confirmed on hardware — a
    /// full sweep produced exactly the twelve powers of two.
    ///
    /// Treating the raw number as a position makes travel accelerate
    /// exponentially along the strip; the fix is to work in pad indices.
    /// A finger straddling two pads sets both bits, so the centroid is used,
    /// which also yields half-pad resolution.
    ///
    /// - Returns: 0...11 for the touched position, or nil when untouched.
    public static func stripPosition(mask: Int) -> Double? {
        guard mask != 0 else { return nil }

        var sum = 0.0
        var count = 0.0
        for bit in 0..<13 where mask & (1 << bit) != 0 {
            sum += Double(bit)
            count += 1
        }
        return count == 0 ? nil : sum / count
    }

    /// Number of discrete pads in a Touch Strip.
    public static let stripPadCount = 12

    public func isPressed(_ index: Int) -> Bool {
        guard (0..<Intuos3.expressKeyCount).contains(index) else { return false }
        return buttons & (1 << UInt8(index)) != 0
    }
}

/// Decoded output. One report can yield at most one of these.
///
/// The 2D mouse and lens cursor are deliberately out of scope: their packets are
/// recognised and dropped rather than decoded. See `Intuos3Decoder` for where
/// they would slot in.
public enum TabletEvent: Equatable, Sendable {
    case proximityEnter(ToolIdentity)
    case proximityExit(ToolIdentity)
    case pen(PenSample, ToolIdentity)
    case pad(PadSample)
}
