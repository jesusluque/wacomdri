// SPDX-License-Identifier: GPL-2.0-or-later
import ApplicationServices
import CoreGraphics
import Foundation
import IntuosCore

// Milestone 1 de-risking tool, output half.
//
// Feeds synthetic pen samples straight into `EventInjector`, bypassing the
// tablet entirely, and posts them to the system. Run PressureScope (or Krita)
// and watch: if pressure, tilt and proximity show up there, the CGEvent tablet
// path works on this macOS version and any later failure is a decoding problem,
// not an architectural one.
//
// It needs no tablet and no root — only Accessibility permission.

setvbuf(stdout, nil, _IONBF, 0)

struct Options {
    var strokes = 3
    var samplesPerStroke = 120
    var delayMicroseconds: UInt32 = 8000
    var countdownSeconds = 3
}

var options = Options()
var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--strokes":
        index += 1
        options.strokes = Int(arguments[safe: index] ?? "") ?? options.strokes
    case "--no-countdown":
        options.countdownSeconds = 0
    case "--help", "-h":
        print("""
        wacomdri-inject-test — post synthetic tablet events

        USAGE
          wacomdri-inject-test [--strokes N] [--no-countdown]

        Draws horizontal strokes across the centre of the main display with
        pressure ramping up and down and tilt sweeping side to side. Point
        PressureScope at it to confirm the events carry tablet data.

        The cursor will move on its own while this runs.
        """)
        exit(0)
    default:
        FileHandle.standardError.write("unknown option: \(arguments[index])\n".data(using: .utf8)!)
        exit(2)
    }
    index += 1
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// Posting synthetic events is gated on Accessibility. Without it CGEvent.post
// fails silently, which looks exactly like broken event construction.
if !EventInjector.canPostEvents {
    print("""
    Accessibility permission is NOT granted for this binary.

    CGEvent.post will silently do nothing. Grant it under
    System Settings > Privacy & Security > Accessibility, then run again.

    Continuing anyway so the failure mode is visible.
    """)
} else {
    print("Accessibility: granted")
}

let screen = DisplayList.mainDisplayBounds()
print("main display: \(Int(screen.width))x\(Int(screen.height)) at \(Int(screen.minX)),\(Int(screen.minY))")

// Deliberately confined to a box the size of the PressureScope window rather
// than the whole display: these strokes include real mouse-down events, and a
// full-screen sweep would click on whatever else happens to be under the path.
let target = CGRect(
    x: screen.midX - 350, y: screen.midY - 250,
    width: 700, height: 500)
print("injecting into \(Int(target.width))x\(Int(target.height)) box at "
    + "\(Int(target.minX)),\(Int(target.minY)) — keep the test window there")

let mapper = Mapper(area: .full, screenBounds: target, preserveAspectRatio: true)
let injector = EventInjector(mapper: mapper, pressureCurve: .linear)

// A standard Intuos3 Grip Pen, so apps see a plausible tool identity.
let pen = ToolIdentity(toolID: 0x822, serial: 0x12345, type: .pen)

for second in stride(from: options.countdownSeconds, to: 0, by: -1) {
    print("starting in \(second)… (focus the window you want to draw in)")
    sleep(1)
}

print("proximity enter")
injector.handle(.proximityEnter(pen))

for stroke in 0..<options.strokes {
    // Space the strokes down the middle third of the tablet so they land in
    // the middle of the screen, where a centred test window is.
    let bandTop = Double(Intuos3.maxY) * 0.35
    let bandHeight = Double(Intuos3.maxY) * 0.30
    let y = Int(bandTop + bandHeight * (Double(stroke) / Double(max(1, options.strokes - 1))))

    print("stroke \(stroke + 1)/\(options.strokes)")

    for step in 0..<options.samplesPerStroke {
        let progress = Double(step) / Double(options.samplesPerStroke - 1)

        // Sweep left to right across the middle 80% of the tablet.
        let x = Int(Double(Intuos3.maxX) * (0.1 + 0.8 * progress))

        // Pressure ramps 0 -> full -> 0, so a working driver draws a stroke
        // that tapers at both ends and a broken one draws a uniform line.
        let pressure = Int(sin(progress * .pi) * Double(Intuos3.maxPressure))

        // Tilt sweeps the full range across the stroke.
        let tiltX = Int((progress * 2 - 1) * 63)
        let tiltY = Int((0.5 - progress) * 63)

        let sample = PenSample(
            x: x, y: y, distance: 0, pressure: pressure,
            tiltX: tiltX, tiltY: tiltY,
            tipDown: pressure > 10,
            barrelButton1: false, barrelButton2: false)

        injector.handle(.pen(sample, pen))
        usleep(options.delayMicroseconds)
    }

    // Lift between strokes so each one is a separate drag.
    let lift = PenSample(
        x: Int(Double(Intuos3.maxX) * 0.9), y: y,
        distance: Intuos3.maxDistance, pressure: 0,
        tiltX: 0, tiltY: 0, tipDown: false,
        barrelButton1: false, barrelButton2: false)
    injector.handle(.pen(lift, pen))
    usleep(200_000)
}

print("proximity exit")
injector.handle(.proximityExit(pen))

print("""

Done. In PressureScope you should see:
  - "TABLET DATA OK", with a non-zero proximity count
  - pressure sweeping 0.0 -> 1.0 -> 0.0 across each stroke
  - tilt changing across the stroke
  - strokes that taper at both ends

If it instead says "NO TABLET DATA", the tablet subtype is not surviving
CGEventPost on this macOS version, and the injection design needs rethinking.
""")
