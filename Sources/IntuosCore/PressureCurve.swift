// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation

/// Maps raw pen pressure onto output pressure through a cubic Bézier.
///
/// The curve runs from (0, 0) to (1, 1) with two draggable control points, the
/// same shape as a CSS timing function. That gives the four control points a
/// preferences UI needs while keeping evaluation cheap enough to run on every
/// report.
///
/// The identity curve is the default: whatever shaping the user wants belongs in
/// preferences, not baked into the driver.
public struct PressureCurve: Equatable, Sendable, Codable {
    /// First control point, normally between (0, 0) and (1, 1).
    public var control1: CGPoint
    /// Second control point.
    public var control2: CGPoint

    /// Output pressure at the moment the tip registers, so a stroke starts with
    /// visible ink instead of nothing.
    public var minimumOutput: Double

    public init(
        control1: CGPoint = CGPoint(x: 1.0 / 3.0, y: 1.0 / 3.0),
        control2: CGPoint = CGPoint(x: 2.0 / 3.0, y: 2.0 / 3.0),
        minimumOutput: Double = 0
    ) {
        self.control1 = control1
        self.control2 = control2
        self.minimumOutput = minimumOutput
    }

    /// A straight line — raw pressure passes through untouched.
    public static let linear = PressureCurve()

    /// Eases in: light touches stay light, so fine control is easier.
    public static let soft = PressureCurve(
        control1: CGPoint(x: 0.42, y: 0.15),
        control2: CGPoint(x: 0.75, y: 0.6))

    /// Eases out: reaches full pressure sooner, for less hand fatigue.
    public static let firm = PressureCurve(
        control1: CGPoint(x: 0.25, y: 0.4),
        control2: CGPoint(x: 0.58, y: 0.85))

    /// Convert a raw reading into normalised output pressure.
    ///
    /// - Parameter raw: pressure in tablet units, 0...`Intuos3.maxPressure`.
    public func apply(rawPressure raw: Int) -> Double {
        apply(normalized: Double(raw) / Double(Intuos3.maxPressure))
    }

    /// Evaluate the curve for an already-normalised input.
    public func apply(normalized input: Double) -> Double {
        let x = min(max(input, 0), 1)
        guard x > 0 else { return 0 }
        let y = evaluate(atX: x)
        return min(max(minimumOutput + y * (1 - minimumOutput), 0), 1)
    }

    /// Bézier curves are parameterised by `t`, not by `x`, so solving for a
    /// given `x` needs a search. Newton's method converges in a couple of
    /// iterations here; bisection is the fallback for the rare flat region
    /// where the derivative vanishes.
    private func evaluate(atX x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let error = bezier(t, control1.x, control2.x) - x
            if abs(error) < 1e-6 { return bezier(t, control1.y, control2.y) }
            let derivative = bezierDerivative(t, control1.x, control2.x)
            if abs(derivative) < 1e-6 { break }
            t -= error / derivative
        }

        var low = 0.0
        var high = 1.0
        t = x
        for _ in 0..<20 {
            let value = bezier(t, control1.x, control2.x)
            if abs(value - x) < 1e-6 { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return bezier(t, control1.y, control2.y)
    }

    /// Cubic Bézier with endpoints fixed at 0 and 1.
    private func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    private func bezierDerivative(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
    }
}
