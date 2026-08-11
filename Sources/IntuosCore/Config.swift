// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation

/// Which screen the tablet drives.
public enum ScreenTarget: Codable, Sendable, Equatable {
    /// Every display as one continuous surface.
    case desktop
    /// Whichever display is currently the main one.
    case main
    /// Position in the active display list. Survives a reboot better than an ID
    /// does, but shifts if displays are reordered.
    case displayIndex(Int)
    /// An exact display. Most precise while the setup is stable, but macOS
    /// reassigns these IDs across reconnects.
    case displayID(UInt32)
}

/// A rectangle of screen space: a display, optionally narrowed to part of it.
///
/// Mapping a 4:3 tablet onto one half of an ultrawide is a common setup, so the
/// region is expressed as fractions of the target rather than pixels — it then
/// survives a resolution change.
public struct ScreenRegion: Codable, Sendable, Equatable {
    public var target: ScreenTarget

    /// Sub-rectangle inside the target, in 0...1 fractions of its width and
    /// height, with the origin at the top-left.
    public var fraction: CGRect

    public init(target: ScreenTarget = .main, fraction: CGRect = ScreenRegion.whole) {
        self.target = target
        self.fraction = fraction
    }

    public static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

    public static let leftHalf = CGRect(x: 0, y: 0, width: 0.5, height: 1)
    public static let rightHalf = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)

    /// Resolve against the live display layout.
    public func resolve() -> CGRect {
        resolve(within: Self.baseBounds(for: target))
    }

    /// Apply the fraction to a known rectangle. Split out so the arithmetic can
    /// be tested without depending on whatever monitors happen to be plugged in.
    public func resolve(within base: CGRect) -> CGRect {
        guard base.width > 0, base.height > 0 else { return base }

        let clamped = CGRect(
            x: min(max(fraction.minX, 0), 1),
            y: min(max(fraction.minY, 0), 1),
            width: min(max(fraction.width, 0), 1),
            height: min(max(fraction.height, 0), 1))

        let region = CGRect(
            x: base.minX + clamped.minX * base.width,
            y: base.minY + clamped.minY * base.height,
            width: clamped.width * base.width,
            height: clamped.height * base.height)

        // A degenerate region would make the tablet unusable and divide by zero
        // downstream; fall back to the whole target instead.
        return (region.width < 1 || region.height < 1) ? base : region
    }

    /// Bounds of the target, falling back to the main display when the chosen
    /// one is not connected — otherwise unplugging a monitor would strand the
    /// pen on a screen that no longer exists.
    public static func baseBounds(for target: ScreenTarget) -> CGRect {
        switch target {
        case .desktop:
            let bounds = DisplayList.desktopBounds()
            return bounds.isEmpty ? DisplayList.mainDisplayBounds() : bounds
        case .main:
            return DisplayList.mainDisplayBounds()
        case .displayIndex(let index):
            let displays = DisplayList.activeDisplays()
            guard displays.indices.contains(index) else {
                return DisplayList.mainDisplayBounds()
            }
            return displays[index].bounds
        case .displayID(let id):
            return DisplayList.bounds(of: CGDirectDisplayID(id))
                ?? DisplayList.mainDisplayBounds()
        }
    }
}

/// Everything the driver reads from disk.
public struct Configuration: Codable, Sendable, Equatable {
    /// Where on screen the tablet maps.
    public var screen: ScreenRegion

    /// Which part of the tablet surface is live.
    public var tabletArea: TabletArea

    /// Crop the tablet so shapes are not distorted. See `TabletArea.cropped`.
    public var preserveAspectRatio: Bool

    public var pressureCurve: PressureCurve
    public var barrelButton1: BarrelAction
    public var barrelButton2: BarrelAction
    public var pad: PadConfiguration

    public init(
        screen: ScreenRegion = ScreenRegion(),
        tabletArea: TabletArea = .full,
        preserveAspectRatio: Bool = true,
        pressureCurve: PressureCurve = .linear,
        barrelButton1: BarrelAction = .rightClick,
        barrelButton2: BarrelAction = .middleClick,
        pad: PadConfiguration = PadConfiguration()
    ) {
        self.screen = screen
        self.tabletArea = tabletArea
        self.preserveAspectRatio = preserveAspectRatio
        self.pressureCurve = pressureCurve
        self.barrelButton1 = barrelButton1
        self.barrelButton2 = barrelButton2
        self.pad = pad
    }

    /// Build a mapper for the current display layout. Call again after a display
    /// reconfiguration so the pen follows the change.
    public func makeMapper() -> Mapper {
        Mapper(
            area: tabletArea,
            screenBounds: screen.resolve(),
            preserveAspectRatio: preserveAspectRatio)
    }

    // MARK: - Persistence

    /// Read from disk, falling back to defaults when the file is missing or
    /// unreadable. A malformed config should leave the tablet working, not dead.
    public static func load(from url: URL) -> Configuration {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Configuration.self, from: data)
        else {
            return Configuration()
        }
        return config
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Shared between the daemon (which runs as root) and the preferences app,
    /// hence a system-wide location rather than one inside a home directory.
    public static let defaultURL = URL(
        fileURLWithPath: "/Library/Application Support/wacomdri/config.json")
}
