// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation
import Testing
@testable import IntuosCore

private let origin = CGPoint(x: 100, y: 100)

@Test func aSingleTapIsASingleClick() {
    var counter = ClickCounter(interval: 0.5, distance: 6)
    #expect(counter.register(at: origin, now: 0) == 1)
}

@Test func twoQuickTapsInPlaceMakeADoubleClick() {
    // The whole point: without this the nib can be tapped twice and nothing
    // opens, because the click state never says "this is the second one".
    var counter = ClickCounter(interval: 0.5, distance: 6)
    #expect(counter.register(at: origin, now: 0) == 1)
    #expect(counter.register(at: origin, now: 0.2) == 2)
}

@Test func threeQuickTapsMakeATripleClick() {
    var counter = ClickCounter(interval: 0.5, distance: 6)
    _ = counter.register(at: origin, now: 0)
    _ = counter.register(at: origin, now: 0.2)
    #expect(counter.register(at: origin, now: 0.4) == 3)
}

@Test func aSlowSecondTapStartsAgain() {
    var counter = ClickCounter(interval: 0.5, distance: 6)
    _ = counter.register(at: origin, now: 0)
    #expect(counter.register(at: origin, now: 0.7) == 1)
}

@Test func tapsExactlyAtTheIntervalStillCount() {
    // The threshold is inclusive; a tap landing right on the configured speed
    // should not be the one that mysteriously fails.
    var counter = ClickCounter(interval: 0.5, distance: 6)
    _ = counter.register(at: origin, now: 0)
    #expect(counter.register(at: origin, now: 0.5) == 2)
}

@Test func aDistantSecondTapStartsAgain() {
    var counter = ClickCounter(interval: 0.5, distance: 6)
    _ = counter.register(at: origin, now: 0)
    #expect(counter.register(at: CGPoint(x: 200, y: 100), now: 0.1) == 1)
}

@Test func smallPenWanderStillCounts() {
    // A pen never lands twice on exactly the same pixel, so the distance
    // threshold has to tolerate a few pixels or double tapping never works.
    var counter = ClickCounter(interval: 0.5, distance: 6)
    _ = counter.register(at: origin, now: 0)
    #expect(counter.register(at: CGPoint(x: 103, y: 102), now: 0.1) == 2)
}

@Test func aLongerIntervalMakesDoubleClickingEasier() {
    var slow = ClickCounter(interval: 1.0, distance: 6)
    _ = slow.register(at: origin, now: 0)
    #expect(slow.register(at: origin, now: 0.8) == 2)

    var quick = ClickCounter(interval: 0.25, distance: 6)
    _ = quick.register(at: origin, now: 0)
    #expect(quick.register(at: origin, now: 0.8) == 1)
}

@Test func currentReportsTheStateOfTheLastClick() {
    // Drags and the release belong to the click that started them.
    var counter = ClickCounter(interval: 0.5, distance: 6)
    _ = counter.register(at: origin, now: 0)
    _ = counter.register(at: origin, now: 0.2)
    #expect(counter.current == 2)
}

@Test func currentIsOneBeforeAnyClick() {
    let counter = ClickCounter(interval: 0.5, distance: 6)
    #expect(counter.current == 1)
}

@Test func resetEndsTheSequence() {
    // A synthesised double click must not bleed into the count of real taps.
    var counter = ClickCounter(interval: 0.5, distance: 6)
    _ = counter.register(at: origin, now: 0)
    counter.reset()
    #expect(counter.register(at: origin, now: 0.1) == 1)
}
