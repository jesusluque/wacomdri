// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation

/// A rectangle of the tablet surface, in raw tablet units.
public struct TabletArea: Equatable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The whole active surface.
    public static let full = TabletArea(
        x: 0, y: 0, width: Intuos3.maxX, height: Intuos3.maxY)

    public var aspectRatio: Double {
        height == 0 ? 1 : Double(width) / Double(height)
    }

    /// Shrink to `aspect`, keeping the area centred.
    ///
    /// Cropping the *tablet* rather than letterboxing the *screen* is deliberate:
    /// it keeps every pixel reachable, at the cost of a strip of tablet surface
    /// going unused. The other way round leaves screen edges the pen cannot
    /// reach, which is far more annoying in practice.
    public func cropped(toAspectRatio aspect: Double) -> TabletArea {
        guard aspect > 0, width > 0, height > 0 else { return self }

        if aspect > aspectRatio {
            // Target is wider than the area: keep the width, lose height.
            let newHeight = Int((Double(width) / aspect).rounded())
            return TabletArea(
                x: x, y: y + (height - newHeight) / 2,
                width: width, height: newHeight)
        } else {
            let newWidth = Int((Double(height) * aspect).rounded())
            return TabletArea(
                x: x + (width - newWidth) / 2, y: y,
                width: newWidth, height: height)
        }
    }
}

/// Maps tablet coordinates onto screen coordinates.
///
/// Works in CoreGraphics global display space — origin at the top-left of the
/// main display with y increasing downward — because that is what `CGEvent`
/// expects. Note this is *not* the bottom-left origin AppKit uses.
public struct Mapper: Equatable, Sendable {
    /// Portion of the tablet that maps to `screenBounds`.
    public var area: TabletArea

    /// Destination rectangle in global display coordinates.
    public var screenBounds: CGRect

    /// When true, `area` is cropped so tablet and screen share an aspect ratio
    /// and circles drawn on the tablet come out as circles on screen.
    public var preserveAspectRatio: Bool

    public init(
        area: TabletArea = .full,
        screenBounds: CGRect,
        preserveAspectRatio: Bool = true
    ) {
        self.area = area
        self.screenBounds = screenBounds
        self.preserveAspectRatio = preserveAspectRatio
    }

    /// The area actually used after any aspect correction.
    public var effectiveArea: TabletArea {
        guard preserveAspectRatio, screenBounds.height > 0 else { return area }
        return area.cropped(
            toAspectRatio: Double(screenBounds.width / screenBounds.height))
    }

    /// Map a tablet coordinate to a point on screen.
    ///
    /// Coordinates outside the active area clamp to the edge, so a pen resting
    /// on an unused strip parks the cursor at the border instead of flinging it
    /// off-screen.
    public func map(x: Int, y: Int) -> CGPoint {
        let area = effectiveArea
        guard area.width > 0, area.height > 0 else { return screenBounds.origin }

        let normalizedX = Double(x - area.x) / Double(area.width)
        let normalizedY = Double(y - area.y) / Double(area.height)

        let clampedX = min(max(normalizedX, 0), 1)
        let clampedY = min(max(normalizedY, 0), 1)

        // The tablet's y axis already runs top-to-bottom, matching CoreGraphics
        // global space, so no flip is needed here.
        return CGPoint(
            x: screenBounds.minX + clampedX * screenBounds.width,
            y: screenBounds.minY + clampedY * screenBounds.height)
    }
}

/// Enumerates displays without pulling AppKit into the daemon.
public enum DisplayList {
    /// Bounds of every active display, in global coordinates.
    public static func activeDisplays() -> [(id: CGDirectDisplayID, bounds: CGRect)] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return []
        }

        return ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) }
    }

    /// Rectangle spanning every display, for mapping the tablet across the whole
    /// desktop.
    public static func desktopBounds() -> CGRect {
        let displays = activeDisplays()
        guard let first = displays.first else { return .zero }
        return displays.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }

    public static func bounds(of displayID: CGDirectDisplayID) -> CGRect? {
        activeDisplays().first { $0.id == displayID }?.bounds
    }

    public static func mainDisplayBounds() -> CGRect {
        CGDisplayBounds(CGMainDisplayID())
    }
}
