# wacomdri

A userspace macOS driver for the **Wacom Intuos3 6x8 (PTZ-630)**.

A summer project, born from the usual annoyance: a perfectly good tablet, twenty
years old and mechanically flawless, reduced to a dumb mouse because the vendor
moved on. Wacom's last driver for this hardware was a kernel extension, and
kernel extensions are finished on modern macOS. So the tablet still moves the
cursor — macOS's generic HID driver sees to that — but there is no pressure, no
tilt, no eraser, and no ExpressKeys. This project puts them back.

Everything here runs in userspace. No kernel extension, no DriverKit, no
entitlements from Apple, and it works with SIP enabled on Apple Silicon.

> Status: complete and working on real hardware. See [Status](#status).

## How it works

```
USB tablet ──▶ IOHIDManager ──▶ Intuos3Decoder ──▶ EventInjector ──▶ CGEventPost
                                                                          │
                                                          tablet-subtype mouse
                                                          events + proximity
```

Three things make it work:

**Getting the tablet to talk properly.** An Intuos3 powers up emulating a mouse.
Writing HID feature report 2 with value 2 switches it into full tablet mode,
where it reports absolute position, 1024 pressure levels and tilt.

**Decoding the packets.** The protocol is undocumented by Wacom, but the Linux
kernel has supported this hardware for two decades. `Intuos3Decoder` is a direct
port of `wacom_intuos_irq()` and its helpers from `drivers/hid/wacom_wac.c`, kept
close enough to the C that the two can be diffed.

**Getting the data into applications.** macOS carries tablet data on ordinary
mouse events tagged with the `tabletPoint` subtype, alongside standalone
proximity events. Applications that support tablets — Krita, Photoshop, Clip
Studio — read the tablet fields off those events. Posting at `cghidEventTap`
puts them below any per-session tap, so everything sees them.

## Why not use something that already exists

- **Wacom's own driver** is a kext for an unsupported product. It does not load.
- **[wacom-driver-fix](https://github.com/thenickdude/wacom-driver-fix)** patched
  that driver and did good work, but it targets Catalina through Monterey and
  cannot outlive the kext itself.
- **[OpenTabletDriver](https://opentabletdriver.net/)** supports the Intuos3 and
  is a fine project, but its macOS layer posts plain mouse events —
  `MacOSVirtualMouse.cs` sets no tablet subtype and no `kCGTabletEvent*` fields,
  so there is no pressure. It also ships an `osx-x64` binary only.

Pressure is the entire point, so none of these help.

## What the hardware actually does

Some of this is not written down anywhere, and was established by capturing raw
reports (see [`fixtures/`](fixtures/)):

- **The input buffer includes the leading report ID** and is 10 bytes, so the
  Linux `data[]` offsets apply directly. Everything in the decoder depended on
  settling this.
- **There is no eraser report.** The nib reports tool ID `0x823` and the eraser
  `0x82b` — the same pen, differing only in bit 3. Any unrecognised ID with that
  bit set is the eraser end.
- **The Touch Strip is a bitmask, not a position.** A full sweep produces exactly
  the twelve powers of two, `1, 2, 4 … 2048`: it is a row of discrete capacitive
  pads and the raw value says *which pad* is covered. Treating that number as a
  position makes scrolling accelerate exponentially along the strip.
- Reading input reports needs no root, only Input Monitoring, and seizing the
  device works unprivileged too.

Two things about macOS itself cost more time than the protocol did:

- **An ad-hoc signature identifies a program by the hash of its own contents**,
  so every rebuild is a different program and the Privacy permissions granted to
  the previous build silently stop applying — while still showing as granted.
  `make signing-identity` fixes this permanently.
- **A pen is not a mouse held still.** Emitting a drag event per report turned
  every click into a drag, which put menus into drag-to-select so they dismissed
  on release. Drags now wait until the pen has travelled far enough to mean it.

## Installing

```sh
make install
```

Everything goes into your home directory — the driver is a per-user LaunchAgent,
not a system daemon, so **nothing here needs sudo**. That is measured, not
assumed: seizing the tablet and reading its reports both succeed unprivileged,
and while seized a pen sweep worth 191x162 screen pixels moved the cursor by
17x16 px, so Apple's generic driver really is detached and there is no duplicate
cursor motion.

macOS will then need two permissions granted to `~/.local/bin/wacomdrid`, under
System Settings > Privacy & Security:

- **Input Monitoring**, to read the tablet at all.
- **Accessibility**, to post events. Without it `CGEvent.post` silently discards
  everything, which looks exactly like a broken driver.

`make uninstall` removes the agent and leaves your settings alone.

## What it does

- 1024 pressure levels, tilt, and the eraser end of the pen.
- Screen mapping to the whole desktop, one display, or an arbitrary zone of one,
  dragged and resized over a scale model of the screen. Zones are stored as
  fractions, so they survive a resolution change.
- Aspect correction that crops the *tablet* rather than the screen, so a circle
  stays a circle and every pixel stays reachable.
- An editable pressure curve that plots your current reading on it as you press.
- Both positions of the pen's rocker, and all eight ExpressKeys, bindable to a
  click, a double click, a keystroke, or a held key.
- Touch Strips bound to scrolling or to repeated keystrokes.
- Adjustable double-click speed, and double-clicking by tapping the nib twice.

## Configuring

```sh
make install-app
```

Installs **Wacom Intuos3.app** into /Applications, where Launchpad and Spotlight
can find it. (`make prefs` runs it straight from the build directory instead.)

A System Settings pane would be the obvious home for this, and there is no way
to build one: third-party preference panes no longer load on macOS 26. A
four-line AppKit pane, correctly signed and with a valid Info.plist, fails with
the same `ViewBridge error 14` as a real one — so the API is gone in practice,
whatever the headers still say.

Three panes: screen mapping, pen response, and the pad. There is no apply
button — edits are written to the config file, which the agent watches and
reloads in place.

Press a key on the tablet and its badge lights up in the app, so binding key 6
does not mean counting keys along the edge and hoping. Bindings are captured by
pressing the actual shortcut. The pressure curve plots your current reading on
it as you press, which answers the question that matters: what does *my* normal
drawing pressure map to.

## Building

Requires Xcode and macOS 15 or later.

```sh
make build     # everything
make test      # 105 tests, including golden tests over captured hardware data
```

## Tools

Three programs exist to make the driver verifiable rather than merely hopeful.

```sh
make list      # every HID device on the system, to confirm the tablet's VID/PID
make probe     # dump raw HID reports; pipe to a file to capture fixtures
make scope     # inspect what actually arrives as NSEvent tablet data
```

`wacomdri-inject-test` feeds synthetic pen samples through the real injection
path without a tablet attached, which separates "the events are wrong" from "the
decoding is wrong" when something misbehaves.

## Configuration

Screen mapping covers the whole desktop, one display, or a region of one
expressed as fractions so it survives a resolution change:

```jsonc
{
  "screen": { "target": "displayIndex(1)", "fraction": [0.5, 0, 0.5, 1] },
  "preserveAspectRatio": true
}
```

Aspect correction crops the *tablet*, not the screen. The alternative leaves
screen edges the pen cannot reach, which is far more irritating than losing a
strip of unused tablet surface.

## Status

| | |
|---|---|
| Protocol decoder | done, tested against captured hardware data |
| Screen mapping and pressure curves | done |
| Event injection | done, verified on macOS 26.5 / Apple Silicon |
| ExpressKeys and Touch Strips | done |
| Agent and launchd integration | done, installs as a per-user LaunchAgent |
| Preferences app | done |
| Out of scope | the 2D mouse and lens cursor: recognised and dropped |

## Licence

GPL-2.0-or-later, matching the Linux kernel driver this work derives from.
`Intuos3Decoder` is a port of GPL-2.0-or-later code from
`drivers/hid/wacom_wac.c`; the licence follows it.

## Acknowledgements

The [Linux Wacom Project](https://linuxwacom.github.io/) and the kernel driver's
contributors, who reverse-engineered and have maintained this protocol for
twenty years. Without `wacom_wac.c` this would have been a far longer summer.
