// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation
import Testing
@testable import IntuosCore

// Expected CGFloat values are written as explicit CGFloat(...) rather than bare
// arithmetic. An expression like `1512 + 1920` infers as Int, and inside #expect
// the resulting CGFloat-versus-Int comparison compiles and evaluates to false —
// an assertion that looks right and silently fails.

/// Stand-in for a 4K display sitting to the right of a laptop screen, so the
/// non-zero origin is exercised too.
private let external = CGRect(x: 1512, y: 0, width: 3840, height: 2160)

@Test func wholeRegionIsTheTargetItself() {
    let region = ScreenRegion(target: .main, fraction: ScreenRegion.whole)
    #expect(region.resolve(within: external) == external)
}

@Test func regionMapsToTheRightHalfOfADisplay() {
    // The headline case: a 4:3 tablet driving half an ultrawide.
    let region = ScreenRegion(target: .main, fraction: ScreenRegion.rightHalf)
    let resolved = region.resolve(within: external)

    #expect(resolved.minX == CGFloat(1512 + 1920))
    #expect(resolved.minY == CGFloat(0))
    #expect(resolved.width == CGFloat(1920))
    #expect(resolved.height == CGFloat(2160))
}

@Test func regionMapsToTheLeftHalfOfADisplay() {
    let region = ScreenRegion(target: .main, fraction: ScreenRegion.leftHalf)
    let resolved = region.resolve(within: external)

    #expect(resolved.minX == CGFloat(1512))
    #expect(resolved.width == CGFloat(1920))
}

@Test func regionMapsToAnArbitraryCentredBox() {
    let region = ScreenRegion(
        target: .main,
        fraction: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    let resolved = region.resolve(within: external)

    #expect(resolved.minX == CGFloat(1512 + 960))
    #expect(resolved.minY == CGFloat(540))
    #expect(resolved.width == CGFloat(1920))
    #expect(resolved.height == CGFloat(1080))
}

@Test func fractionsAreExpressedRelativeToTheDisplaySoResolutionChangesAreSafe() {
    // Same fraction, different resolution: the region should scale with it
    // rather than pointing at stale pixel coordinates.
    let region = ScreenRegion(target: .main, fraction: ScreenRegion.rightHalf)

    let hidpi = region.resolve(within: CGRect(x: 0, y: 0, width: 3840, height: 2160))
    let lowRes = region.resolve(within: CGRect(x: 0, y: 0, width: 1920, height: 1080))

    #expect(hidpi.minX == CGFloat(1920))
    #expect(lowRes.minX == CGFloat(960))
}

@Test func outOfRangeFractionsAreClamped() {
    let region = ScreenRegion(
        target: .main,
        fraction: CGRect(x: -1, y: -1, width: 5, height: 5))
    let resolved = region.resolve(within: external)

    #expect(external.contains(resolved) || resolved == external)
    #expect(resolved.minX >= external.minX)
    #expect(resolved.minY >= external.minY)
}

@Test func degenerateRegionFallsBackToTheWholeTarget() {
    // A zero-width region would make the tablet unusable and divide by zero in
    // the mapper; the whole display is a far better failure mode.
    let region = ScreenRegion(
        target: .main,
        fraction: CGRect(x: 0.5, y: 0.5, width: 0, height: 0))
    #expect(region.resolve(within: external) == external)
}

@Test func mapperCoversExactlyTheChosenRegion() {
    // End to end: the tablet corners must land on the region corners, not the
    // display corners.
    let region = ScreenRegion(target: .main, fraction: ScreenRegion.rightHalf)
    let bounds = region.resolve(within: external)
    let mapper = Mapper(screenBounds: bounds, preserveAspectRatio: false)

    #expect(mapper.map(x: 0, y: 0) == CGPoint(x: 3432, y: 0))
    #expect(mapper.map(x: Intuos3.maxX, y: Intuos3.maxY)
        == CGPoint(x: CGFloat(3432 + 1920), y: 2160))
}

@Test func configurationRoundTripsThroughJSON() throws {
    var config = Configuration()
    config.screen = ScreenRegion(target: .displayIndex(1), fraction: ScreenRegion.rightHalf)
    config.tabletArea = TabletArea(x: 100, y: 200, width: 30000, height: 20000)
    config.pressureCurve = .soft
    config.barrelButton1 = .middleClick
    config.preserveAspectRatio = false

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(Configuration.self, from: data)

    #expect(decoded == config)
}

@Test func missingConfigFileYieldsUsableDefaults() {
    // A fresh install has no config; the tablet must still work.
    let missing = URL(fileURLWithPath: "/nonexistent/wacomdri/config.json")
    #expect(Configuration.load(from: missing) == Configuration())
}

@Test func malformedConfigFileYieldsUsableDefaults() throws {
    // A half-written or hand-edited file should not brick the tablet.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wacomdri-bad-\(UUID().uuidString).json")
    try Data("{ this is not json".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(Configuration.load(from: url) == Configuration())
}

@Test func configurationSurvivesADiskRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wacomdri-\(UUID().uuidString)/config.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    var config = Configuration()
    config.pressureCurve = .firm
    config.screen = ScreenRegion(target: .desktop, fraction: ScreenRegion.leftHalf)

    try config.save(to: url)
    #expect(Configuration.load(from: url) == config)
}

@Test func unknownDisplayFallsBackToMain() {
    // Unplugging the configured monitor must not strand the pen on a screen
    // that no longer exists.
    let bounds = ScreenRegion.baseBounds(for: .displayIndex(99))
    #expect(bounds == DisplayList.mainDisplayBounds())
    #expect(bounds.width > 0)

    let byID = ScreenRegion.baseBounds(for: .displayID(0xDEAD_BEEF))
    #expect(byID == DisplayList.mainDisplayBounds())
}
