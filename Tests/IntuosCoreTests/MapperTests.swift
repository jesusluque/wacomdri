// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Testing
@testable import IntuosCore

/// A 4:3 screen, matching the tablet, so aspect correction is a no-op.
private let matchedScreen = CGRect(x: 0, y: 0, width: 1600, height: 1200)
/// A 16:10 screen, wider than the tablet — the common real-world case.
private let wideScreen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

@Test func mapsCornersToScreenCorners() {
    let mapper = Mapper(screenBounds: matchedScreen, preserveAspectRatio: false)

    #expect(mapper.map(x: 0, y: 0) == CGPoint(x: 0, y: 0))
    #expect(mapper.map(x: Intuos3.maxX, y: Intuos3.maxY)
        == CGPoint(x: 1600, y: 1200))
    #expect(mapper.map(x: Intuos3.maxX / 2, y: Intuos3.maxY / 2)
        == CGPoint(x: 800, y: 600))
}

@Test func mapsOntoDisplayAtNonZeroOrigin() {
    // A second display to the right of the main one: the offset has to be
    // carried through or the pen lands on the wrong screen.
    let secondary = CGRect(x: 1600, y: 0, width: 1600, height: 1200)
    let mapper = Mapper(screenBounds: secondary, preserveAspectRatio: false)

    #expect(mapper.map(x: 0, y: 0) == CGPoint(x: 1600, y: 0))
    #expect(mapper.map(x: Intuos3.maxX, y: Intuos3.maxY) == CGPoint(x: 3200, y: 1200))
}

@Test func coordinatesOutsideTheAreaClampToTheEdge() {
    // Reaching past the active area must park the cursor at the border, not
    // fling it off-screen.
    let mapper = Mapper(screenBounds: matchedScreen, preserveAspectRatio: false)

    #expect(mapper.map(x: -5000, y: -5000) == CGPoint(x: 0, y: 0))
    #expect(mapper.map(x: Intuos3.maxX * 2, y: Intuos3.maxY * 2)
        == CGPoint(x: 1600, y: 1200))
}

@Test func aspectCorrectionCropsTheTabletNotTheScreen() {
    // The whole screen must stay reachable; it is the tablet that gives up a
    // strip. Check both extremes still hit the screen corners exactly.
    let mapper = Mapper(screenBounds: wideScreen, preserveAspectRatio: true)
    let area = mapper.effectiveArea

    #expect(area.width == Intuos3.maxX, "full width should be kept")
    #expect(area.height < Intuos3.maxY, "height should be cropped")

    let topLeft = mapper.map(x: area.x, y: area.y)
    let bottomRight = mapper.map(x: area.x + area.width, y: area.y + area.height)
    #expect(topLeft == CGPoint(x: 0, y: 0))
    #expect(bottomRight == CGPoint(x: 1600, y: 1000))
}

@Test func aspectCorrectionKeepsSquaresSquare() {
    // The point of the feature: equal distances on the tablet must travel equal
    // distances on screen in both axes.
    let mapper = Mapper(screenBounds: wideScreen, preserveAspectRatio: true)
    let area = mapper.effectiveArea

    let step = 1000
    let origin = mapper.map(x: area.x + area.width / 2, y: area.y + area.height / 2)
    let movedX = mapper.map(x: area.x + area.width / 2 + step, y: area.y + area.height / 2)
    let movedY = mapper.map(x: area.x + area.width / 2, y: area.y + area.height / 2 + step)

    let deltaX = movedX.x - origin.x
    let deltaY = movedY.y - origin.y
    #expect(abs(deltaX - deltaY) < 0.5, "\(deltaX) vs \(deltaY) — aspect is distorted")
}

@Test func croppedAreaStaysCentred() {
    let area = TabletArea.full.cropped(toAspectRatio: 1600.0 / 1000.0)
    let topMargin = area.y
    let bottomMargin = Intuos3.maxY - (area.y + area.height)
    #expect(abs(topMargin - bottomMargin) <= 1)
}

@Test func aspectCorrectionHandlesTallScreens() {
    // A rotated display is narrower than the tablet, so the crop goes the other
    // way: keep the height, lose width.
    let portrait = CGRect(x: 0, y: 0, width: 1200, height: 1600)
    let mapper = Mapper(screenBounds: portrait, preserveAspectRatio: true)
    let area = mapper.effectiveArea

    #expect(area.height == Intuos3.maxY)
    #expect(area.width < Intuos3.maxX)
}

@Test func customActiveAreaMapsToFullScreen() {
    // Using only the middle of the tablet should still reach every pixel.
    let area = TabletArea(
        x: Intuos3.maxX / 4, y: Intuos3.maxY / 4,
        width: Intuos3.maxX / 2, height: Intuos3.maxY / 2)
    let mapper = Mapper(area: area, screenBounds: matchedScreen, preserveAspectRatio: false)

    #expect(mapper.map(x: area.x, y: area.y) == CGPoint(x: 0, y: 0))
    #expect(mapper.map(x: area.x + area.width, y: area.y + area.height)
        == CGPoint(x: 1600, y: 1200))
    // Outside the chosen area, clamped.
    #expect(mapper.map(x: 0, y: 0) == CGPoint(x: 0, y: 0))
}

@Test func degenerateAreaDoesNotDivideByZero() {
    let area = TabletArea(x: 0, y: 0, width: 0, height: 0)
    let mapper = Mapper(area: area, screenBounds: matchedScreen, preserveAspectRatio: false)
    #expect(mapper.map(x: 100, y: 100) == matchedScreen.origin)
}
