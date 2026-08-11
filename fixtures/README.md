# Captures

Raw HID reports from a real PTZ-630, used as golden tests for `Intuos3Decoder`.

- `raw.txt` — the unedited pen session, 10548 reports. Kept as provenance.
- `pen-session.txt` — curated from it: every proximity transition, a stratified
  sample across the pressure range, and barrel-button packets.
- `pad-session.txt` — ExpressKey presses and a full sweep of the left Touch Strip.

## Capturing more

```sh
./.build/debug/wacomdri-probe | tee fixtures/raw.txt
```

**No root needed.** Reading input reports only requires Input Monitoring, which
macOS grants to the terminal. Seizing the device (`--seize` is the default in
the daemon, not the probe) is a separate question: it decides whether Apple's
generic HID driver *also* moves the cursor, not whether we can read.

## Sequence

Pause a beat between steps so the gaps are visible in the timestamps:

1. Hover the pen just above the surface, then lift it away — enter/exit proximity.
2. Press the tip down and drag slowly, light to hard — position and pressure.
3. Tilt the pen far to the left, then far to the right — tilt extremes.
4. Press each barrel button while touching the surface.
5. Flip the pen and use the eraser end — tool ID with bit 3 set.
6. Press each of the 8 ExpressKeys, left side top to bottom, then right.
7. Sweep each Touch Strip end to end.

## What these captures established

- The input buffer **includes** the leading report ID and is 10 bytes, so the
  Linux `data[]` offsets apply directly. This was the open question the whole
  decoder depended on.
- Tool IDs `0x823` (nib) and `0x82b` (eraser) — the same physical pen, differing
  only in bit 3. That is how the Intuos3 signals "flipped over"; there is no
  separate eraser report.
- **The Touch Strip is a bitmask, not a position.** A full sweep produced
  exactly the twelve powers of two, `1, 2, 4 … 2048`: the strip is a row of
  discrete capacitive pads and the raw value says *which pad* is covered. Naive
  delta arithmetic on that number makes scrolling accelerate exponentially along
  the strip. See `PadSample.stripPosition(mask:)`.
