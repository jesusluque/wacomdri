// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation
import Testing
@testable import IntuosCore

@Test func linearCurvePassesPressureThrough() {
    let curve = PressureCurve.linear

    #expect(abs(curve.apply(normalized: 0.0) - 0.0) < 1e-4)
    #expect(abs(curve.apply(normalized: 0.25) - 0.25) < 1e-3)
    #expect(abs(curve.apply(normalized: 0.5) - 0.5) < 1e-3)
    #expect(abs(curve.apply(normalized: 1.0) - 1.0) < 1e-4)
}

@Test func rawPressureIsNormalisedAgainstTheModelMaximum() {
    let curve = PressureCurve.linear

    #expect(curve.apply(rawPressure: 0) == 0)
    #expect(abs(curve.apply(rawPressure: Intuos3.maxPressure) - 1.0) < 1e-4)
    #expect(abs(curve.apply(rawPressure: Intuos3.maxPressure / 2) - 0.5) < 1e-2)
}

@Test(arguments: [PressureCurve.linear, .soft, .firm])
func curvesAreMonotonicAndBounded(curve: PressureCurve) {
    // Any usable curve must never dip: more force on the nib can only mean more
    // ink, or strokes get visibly jittery.
    var previous = -1.0
    for step in 0...100 {
        let value = curve.apply(normalized: Double(step) / 100)
        #expect(value >= 0 && value <= 1, "out of range at \(step): \(value)")
        #expect(value >= previous - 1e-6, "curve dips at \(step): \(previous) -> \(value)")
        previous = value
    }
}

@Test(arguments: [PressureCurve.linear, .soft, .firm])
func curvesPinTheEndpoints(curve: PressureCurve) {
    #expect(curve.apply(normalized: 0) == 0)
    #expect(abs(curve.apply(normalized: 1) - 1) < 1e-3)
}

@Test func softCurveIsLighterThanLinearInTheMiddle() {
    #expect(PressureCurve.soft.apply(normalized: 0.5)
        < PressureCurve.linear.apply(normalized: 0.5))
}

@Test func firmCurveIsHeavierThanLinearInTheMiddle() {
    #expect(PressureCurve.firm.apply(normalized: 0.5)
        > PressureCurve.linear.apply(normalized: 0.5))
}

@Test func minimumOutputLiftsTheStartOfTheStroke() {
    // So a stroke lays down visible ink the instant the tip registers.
    let curve = PressureCurve(minimumOutput: 0.2)

    // Zero pressure is still zero: the nib is not touching.
    #expect(curve.apply(normalized: 0) == 0)
    // The faintest real contact clears the floor.
    #expect(curve.apply(normalized: 0.001) >= 0.2)
    #expect(abs(curve.apply(normalized: 1.0) - 1.0) < 1e-3)
}

@Test func inputIsClampedToTheValidRange() {
    let curve = PressureCurve.linear
    #expect(curve.apply(normalized: -1) == 0)
    #expect(abs(curve.apply(normalized: 5) - 1) < 1e-4)
    #expect(curve.apply(rawPressure: -100) == 0)
    #expect(abs(curve.apply(rawPressure: Intuos3.maxPressure * 2) - 1) < 1e-4)
}

@Test func curveSurvivesRoundTripThroughJSON() throws {
    // Curves are stored in the preferences file, so encoding has to hold.
    let original = PressureCurve.soft
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PressureCurve.self, from: data)
    #expect(decoded == original)
}

@Test func extremeControlPointsDoNotHangTheSolver() {
    // Newton's method stalls where the derivative vanishes; the bisection
    // fallback has to catch it rather than spin.
    let curve = PressureCurve(
        control1: CGPoint(x: 0, y: 1),
        control2: CGPoint(x: 1, y: 0))

    for step in 0...20 {
        let value = curve.apply(normalized: Double(step) / 20)
        #expect(value >= 0 && value <= 1)
    }
}
