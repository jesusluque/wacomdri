// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation

/// Counts consecutive clicks, so that tapping the nib twice reads as a double
/// click rather than two unrelated clicks.
///
/// macOS does not infer this from the timing of the events: the click state
/// field has to carry it. Hardcoding that field to 1 — which is the obvious
/// thing to do — means a double tap never opens anything.
///
/// The clock is injected so the thresholds can be tested without waiting in
/// real time.
public struct ClickCounter {
    /// Taps further apart than this in time start a new count. Follows the
    /// user's setting in System Settings.
    public var interval: TimeInterval

    /// Taps further apart than this on screen start a new count. A pen lands
    /// within a few pixels of itself, so this can be tight.
    public var distance: CGFloat

    private var lastTime: TimeInterval?
    private var lastPoint: CGPoint = .zero
    private var count = 0

    public init(interval: TimeInterval = ClickCounter.systemInterval, distance: CGFloat = 6) {
        self.interval = interval
        self.distance = distance
    }

    /// The double-click speed from System Settings, falling back to the
    /// historical default when it has never been set.
    public static var systemInterval: TimeInterval {
        let value = CFPreferencesCopyAppValue(
            "com.apple.mouse.doubleClickThreshold" as CFString,
            kCFPreferencesAnyApplication) as? Double
        return value ?? 0.5
    }

    /// Register a click and return its click state: 1 for a fresh click, 2 for a
    /// double, and so on.
    public mutating func register(at point: CGPoint, now: TimeInterval) -> Int {
        let travelled = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
        let soonEnough = lastTime.map { now - $0 <= interval } ?? false

        count = (soonEnough && travelled <= distance) ? count + 1 : 1
        lastTime = now
        lastPoint = point
        return count
    }

    /// Click state of the most recent click, for the drag and release events
    /// that belong to it.
    public var current: Int { max(count, 1) }

    /// Forget the sequence — used after synthesising a double click explicitly,
    /// so it does not bleed into the count of real taps.
    public mutating func reset() {
        count = 0
        lastTime = nil
    }
}
