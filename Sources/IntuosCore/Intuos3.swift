// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Hardware description for the Wacom Intuos3 6x8 (PTZ-630).
///
/// Values transcribed from `wacom_features_0xB1` in the Linux kernel's
/// `drivers/hid/wacom_wac.c`, which is the authoritative description of this
/// protocol now that Wacom no longer supports the hardware.
public enum Intuos3 {
    public static let vendorID = 0x056A
    public static let productID = 0x00B1

    public static let name = "Wacom Intuos3 6x8 (PTZ-630)"

    /// Logical tablet units across the active area.
    public static let maxX = 40640
    public static let maxY = 30480

    /// 200 points per millimetre (5080 lpi).
    public static let resolution = 200

    public static let maxPressure = 1023
    /// Hover distance reported while the tool is in range but not touching.
    public static let maxDistance = 63

    /// Tilt is reported biased by 64, so the decoded range is -64...63.
    public static let tiltBias = 64

    public static let expressKeyCount = 8
    public static let maxTouchStrip = 4095

    /// Physical active area in millimetres, derived from the logical extents.
    public static var activeAreaMM: (width: Double, height: Double) {
        (Double(maxX) / Double(resolution), Double(maxY) / Double(resolution))
    }
}

/// HID report IDs used by the Intuos3.
public enum Intuos3Report {
    /// `WACOM_REPORT_PENABLED` — pen/mouse data.
    public static let pen: UInt8 = 2
    /// `WACOM_REPORT_INTUOSPAD` — ExpressKeys and Touch Strips.
    public static let pad: UInt8 = 12

    /// Length of a pen report *including* its leading report ID byte.
    public static let penLengthWithID = 10
}

/// The tablet powers up emulating a mouse. Writing this feature report switches
/// it into full tablet mode, where it reports absolute position, pressure and
/// tilt.
///
/// Linux derives this in `_wacom_query_tablet_data()`: `INTUOS3` (12) sorts at
/// or below `BAMBOO_PT` (42) in the device-type enum, which selects
/// `mode_report = 2, mode_value = 2`.
public enum Intuos3Mode {
    public static let reportID: UInt8 = 2
    public static let value: UInt8 = 2
    public static let payload: [UInt8] = [reportID, value]
}
