// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation
import Testing
@testable import IntuosCore

/// Records what the mapper would have posted, instead of posting it.
private final class RecordingSink: PadEventSink {
    enum Emission: Equatable {
        case key(code: UInt16, modifiers: Modifiers, down: Bool)
        case scroll(vertical: Int32, horizontal: Int32)
        case click(button: CGMouseButton, count: Int)
    }

    var emissions: [Emission] = []

    func postKey(code: UInt16, modifiers: Modifiers, down: Bool) {
        emissions.append(.key(code: code, modifiers: modifiers, down: down))
    }

    func postScroll(vertical: Int32, horizontal: Int32) {
        emissions.append(.scroll(vertical: vertical, horizontal: horizontal))
    }

    func postClick(button: CGMouseButton, count: Int) {
        emissions.append(.click(button: button, count: count))
    }

    var clicks: [Emission] {
        emissions.filter { if case .click = $0 { return true } else { return false } }
    }

    var keyDowns: [UInt16] {
        emissions.compactMap { if case .key(let c, _, true) = $0 { return c } else { return nil } }
    }
    var keyUps: [UInt16] {
        emissions.compactMap { if case .key(let c, _, false) = $0 { return c } else { return nil } }
    }
    var scrolls: [Int32] {
        emissions.compactMap { if case .scroll(let v, _) = $0 { return v } else { return nil } }
    }
}

private func pad(buttons: UInt8 = 0, strip1: Int = 0, strip2: Int = 0) -> PadSample {
    PadSample(buttons: buttons, strip1: strip1, strip2: strip2)
}

private func makeMapper(
    keys: [PadAction] = PadConfiguration.defaultKeys,
    leftStrip: StripAction = .scrollVertical(inverted: false),
    rightStrip: StripAction = .none
) -> (PadMapper, RecordingSink) {
    let sink = RecordingSink()
    let config = PadConfiguration(keys: keys, leftStrip: leftStrip, rightStrip: rightStrip)
    return (PadMapper(configuration: config, sink: sink), sink)
}

// MARK: - ExpressKeys

@Test func tapKeyFiresOncePerPressNotPerReport() {
    // The pad resends its state repeatedly while a key is held. A tap binding
    // that fired per report would spam undo dozens of times per press.
    let (mapper, sink) = makeMapper(keys: [.tapKey(code: KeyCode.z, modifiers: .command)])

    mapper.handle(pad(buttons: 0b0000_0001))
    mapper.handle(pad(buttons: 0b0000_0001))
    mapper.handle(pad(buttons: 0b0000_0001))

    #expect(sink.keyDowns == [KeyCode.z])
    #expect(sink.keyUps == [KeyCode.z])
}

@Test func tapKeyEmitsNothingOnRelease() {
    let (mapper, sink) = makeMapper(keys: [.tapKey(code: KeyCode.z, modifiers: .command)])

    mapper.handle(pad(buttons: 0b0000_0001))
    let afterPress = sink.emissions.count
    mapper.handle(pad(buttons: 0))

    #expect(sink.emissions.count == afterPress)
}

@Test func holdKeyStaysDownForTheDurationOfThePress() {
    // Space-to-pan only works if the key is held, not tapped.
    let (mapper, sink) = makeMapper(keys: [.holdKey(code: KeyCode.space, modifiers: [])])

    mapper.handle(pad(buttons: 0b0000_0001))
    #expect(sink.keyDowns == [KeyCode.space])
    #expect(sink.keyUps.isEmpty)

    mapper.handle(pad(buttons: 0))
    #expect(sink.keyUps == [KeyCode.space])
}

@Test func modifiersAreCarriedThrough() {
    let (mapper, sink) = makeMapper(
        keys: [.tapKey(code: KeyCode.z, modifiers: [.command, .shift])])

    mapper.handle(pad(buttons: 0b0000_0001))

    #expect(sink.emissions.first
        == .key(code: KeyCode.z, modifiers: [.command, .shift], down: true))
}

@Test(arguments: 0..<8)
func eachExpressKeyDrivesItsOwnBinding(index: Int) {
    // Distinct code per key so a bit-order mistake shows up as the wrong key.
    let keys = (0..<8).map { PadAction.tapKey(code: UInt16(100 + $0), modifiers: []) }
    let (mapper, sink) = makeMapper(keys: keys)

    mapper.handle(pad(buttons: UInt8(1 << index)))

    #expect(sink.keyDowns == [UInt16(100 + index)])
}

@Test func simultaneousPressesEachFireOnce() {
    let keys = (0..<8).map { PadAction.tapKey(code: UInt16(100 + $0), modifiers: []) }
    let (mapper, sink) = makeMapper(keys: keys)

    mapper.handle(pad(buttons: 0b0000_0101))

    #expect(Set(sink.keyDowns) == [100, 102])
}

@Test func releasingOneKeyWhileHoldingAnotherOnlyAffectsTheReleasedOne() {
    let (mapper, sink) = makeMapper(keys: [
        .holdKey(code: 10, modifiers: []),
        .holdKey(code: 11, modifiers: []),
    ])

    mapper.handle(pad(buttons: 0b0000_0011))
    #expect(Set(sink.keyDowns) == [10, 11])

    mapper.handle(pad(buttons: 0b0000_0010))
    #expect(sink.keyUps == [10])
}

@Test func noneBindingEmitsNothing() {
    let (mapper, sink) = makeMapper(keys: [.none])
    mapper.handle(pad(buttons: 0b0000_0001))
    mapper.handle(pad(buttons: 0))
    #expect(sink.emissions.isEmpty)
}

@Test func resetReleasesHeldKeys() {
    // On unplug a held key must be let go, or the modifier is wedged down for
    // the rest of the session with no way to clear it.
    let (mapper, sink) = makeMapper(keys: [.holdKey(code: KeyCode.space, modifiers: [])])

    mapper.handle(pad(buttons: 0b0000_0001))
    mapper.reset()

    #expect(sink.keyUps == [KeyCode.space])
}

@Test func resetDoesNotReleaseKeysThatWereNotHeld() {
    let (mapper, sink) = makeMapper(keys: [.holdKey(code: KeyCode.space, modifiers: [])])
    mapper.reset()
    #expect(sink.emissions.isEmpty)
}

@Test func aShortConfigurationDoesNotCrashOnHigherKeys() {
    // An old config file listing fewer keys than the hardware has must not
    // index out of bounds when key 8 arrives.
    let (mapper, sink) = makeMapper(keys: [.tapKey(code: 10, modifiers: [])])
    mapper.handle(pad(buttons: 0b1000_0000))
    #expect(sink.emissions.isEmpty)
}

// MARK: - Touch Strip decoding

@Test func stripMaskConvertsToAPadIndex() {
    // A sweep on real hardware produced exactly these twelve values.
    for index in 0..<12 {
        #expect(PadSample.stripPosition(mask: 1 << index) == Double(index))
    }
}

@Test func untouchedStripHasNoPosition() {
    #expect(PadSample.stripPosition(mask: 0) == nil)
}

@Test func straddlingTwoPadsGivesTheMidpoint() {
    // A fingertip covers more than one pad, which buys half-pad resolution.
    #expect(PadSample.stripPosition(mask: (1 << 3) | (1 << 4)) == 3.5)
    #expect(PadSample.stripPosition(mask: (1 << 0) | (1 << 1) | (1 << 2)) == 1.0)
}

// MARK: - Touch Strips

/// Raw reading for a finger sitting on pad `index`.
private func padMask(_ index: Int) -> Int { 1 << index }

@Test func firstStripTouchEmitsNothing() {
    // The initial reading is a reference point, not travel. Emitting on it
    // would jump the scroll position wherever the finger happened to land.
    let (mapper, sink) = makeMapper(leftStrip: .scrollVertical(inverted: false))

    mapper.handle(pad(strip1: padMask(3)))

    #expect(sink.scrolls.isEmpty)
}

@Test func stripTravelScrolls() {
    let (mapper, sink) = makeMapper(leftStrip: .scrollVertical(inverted: false))

    mapper.handle(pad(strip1: padMask(3)))
    mapper.handle(pad(strip1: padMask(4)))

    #expect(sink.scrolls.count == 1)
    #expect(sink.scrolls[0] > 0)
}

@Test func scrollSpeedIsUniformAlongTheStrip() {
    // The regression this whole rework exists for: because the raw reading is a
    // bitmask, one pad of travel near the far end used to produce a delta 1024
    // times larger than the same movement near the start.
    let (low, lowSink) = makeMapper(leftStrip: .scrollVertical(inverted: false))
    low.handle(pad(strip1: padMask(1)))
    low.handle(pad(strip1: padMask(2)))

    let (high, highSink) = makeMapper(leftStrip: .scrollVertical(inverted: false))
    high.handle(pad(strip1: padMask(10)))
    high.handle(pad(strip1: padMask(11)))

    #expect(lowSink.scrolls == highSink.scrolls,
            "one pad of travel must scroll the same wherever it happens")
}

@Test func stripDirectionCanBeInverted() {
    let (forward, forwardSink) = makeMapper(leftStrip: .scrollVertical(inverted: false))
    forward.handle(pad(strip1: padMask(3)))
    forward.handle(pad(strip1: padMask(5)))

    let (inverted, invertedSink) = makeMapper(leftStrip: .scrollVertical(inverted: true))
    inverted.handle(pad(strip1: padMask(3)))
    inverted.handle(pad(strip1: padMask(5)))

    #expect(forwardSink.scrolls[0] == -invertedSink.scrolls[0])
}

@Test func releasingTheStripEndsTheGestureWithoutAJump() {
    // A release reads as 0. Treating that as travel would scroll violently back
    // to the top every time the finger lifts.
    let (mapper, sink) = makeMapper(leftStrip: .scrollVertical(inverted: false))

    mapper.handle(pad(strip1: padMask(8)))
    mapper.handle(pad(strip1: padMask(9)))
    let beforeRelease = sink.scrolls.count
    mapper.handle(pad(strip1: 0))

    #expect(sink.scrolls.count == beforeRelease)
}

@Test func touchingTheStripAgainStartsAFreshReference() {
    let (mapper, sink) = makeMapper(leftStrip: .scrollVertical(inverted: false))

    mapper.handle(pad(strip1: padMask(0)))
    mapper.handle(pad(strip1: 0))
    let afterRelease = sink.scrolls.count
    // A far-away second touch must not scroll by the distance between touches.
    mapper.handle(pad(strip1: padMask(11)))

    #expect(sink.scrolls.count == afterRelease)
}

@Test func halfPadTravelStillScrollsAtLeastOneLine() {
    // Rounding toward zero would swallow slow, precise movement entirely.
    let (mapper, sink) = makeMapper(leftStrip: .scrollVertical(inverted: false))

    mapper.handle(pad(strip1: padMask(3)))
    mapper.handle(pad(strip1: padMask(3) | padMask(4)))

    #expect(sink.scrolls.count == 1)
    #expect(sink.scrolls[0] >= 1)
}

@Test func keyStepsStripNeedsSustainedTravelBeforeFiring() {
    // Otherwise a slow drag machine-guns the zoom shortcut.
    let (mapper, sink) = makeMapper(
        leftStrip: .keySteps(
            up: .tapKey(code: KeyCode.equal, modifiers: .command),
            down: .tapKey(code: KeyCode.minus, modifiers: .command)))

    mapper.handle(pad(strip1: padMask(3)))
    mapper.handle(pad(strip1: padMask(3) | padMask(4)))
    #expect(sink.emissions.isEmpty, "half a pad should be below the step threshold")

    mapper.handle(pad(strip1: padMask(4)))
    #expect(sink.keyDowns == [KeyCode.minus], "increasing pad index runs down the strip")
}

@Test func keyStepsFireInBothDirections() {
    let (mapper, sink) = makeMapper(
        leftStrip: .keySteps(
            up: .tapKey(code: KeyCode.equal, modifiers: .command),
            down: .tapKey(code: KeyCode.minus, modifiers: .command)))

    mapper.handle(pad(strip1: padMask(5)))
    mapper.handle(pad(strip1: padMask(6)))
    mapper.handle(pad(strip1: padMask(4)))

    #expect(sink.keyDowns.contains(KeyCode.minus))
    #expect(sink.keyDowns.contains(KeyCode.equal))
}

@Test func longTravelFiresProportionallyManySteps() {
    let (mapper, sink) = makeMapper(
        leftStrip: .keySteps(
            up: .tapKey(code: 1, modifiers: []),
            down: .tapKey(code: 2, modifiers: [])))

    mapper.handle(pad(strip1: padMask(0)))
    mapper.handle(pad(strip1: padMask(4)))

    // Four pads of travel at one step per pad.
    #expect(sink.keyDowns.count == 4)
}

@Test func disabledStripEmitsNothing() {
    let (mapper, sink) = makeMapper(leftStrip: .none)

    mapper.handle(pad(strip1: padMask(2)))
    mapper.handle(pad(strip1: padMask(7)))

    #expect(sink.emissions.isEmpty)
}

@Test func bothStripsWorkIndependently() {
    let sink = RecordingSink()
    let config = PadConfiguration(
        keys: PadConfiguration.defaultKeys,
        leftStrip: .scrollVertical(inverted: false),
        rightStrip: .scrollHorizontal(inverted: false))
    let mapper = PadMapper(configuration: config, sink: sink)

    mapper.handle(pad(strip1: padMask(3), strip2: padMask(3)))
    mapper.handle(pad(strip1: padMask(5), strip2: padMask(5)))

    let vertical = sink.emissions.compactMap {
        if case .scroll(let v, let h) = $0, v != 0, h == 0 { return v } else { return nil }
    }
    let horizontal = sink.emissions.compactMap {
        if case .scroll(let v, let h) = $0, h != 0, v == 0 { return h } else { return nil }
    }
    #expect(vertical.count == 1)
    #expect(horizontal.count == 1)
}

// MARK: - Mouse actions on the pad

@Test(arguments: [
    (PadAction.leftClick, CGMouseButton.left, 1),
    (PadAction.rightClick, CGMouseButton.right, 1),
    (PadAction.middleClick, CGMouseButton.center, 1),
    (PadAction.doubleClick, CGMouseButton.left, 2),
])
func expressKeysCanClick(action: PadAction, button: CGMouseButton, count: Int) {
    let (mapper, sink) = makeMapper(keys: [action])

    mapper.handle(pad(buttons: 0b0000_0001))

    #expect(sink.clicks == [.click(button: button, count: count)])
}

@Test func aClickBoundKeyFiresOnceOnPressAndNothingOnRelease() {
    // The pad resends its state while held; a click that repeated would be
    // unusable.
    let (mapper, sink) = makeMapper(keys: [.doubleClick])

    mapper.handle(pad(buttons: 0b0000_0001))
    mapper.handle(pad(buttons: 0b0000_0001))
    mapper.handle(pad(buttons: 0))

    #expect(sink.clicks.count == 1)
}

@Test func aStripCanBeBoundToClicks() {
    let (mapper, sink) = makeMapper(
        leftStrip: .keySteps(up: .leftClick, down: .rightClick))

    mapper.handle(pad(strip1: 1 << 3))
    mapper.handle(pad(strip1: 1 << 4))

    #expect(sink.clicks == [.click(button: .right, count: 1)])
}
