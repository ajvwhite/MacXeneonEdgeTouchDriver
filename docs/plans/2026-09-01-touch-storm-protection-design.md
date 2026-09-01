# Touch Storm Protection Design

## Goal

Prevent a malfunctioning panel controller or USB input path from turning an incoherent raw HID report burst into macOS clicks, scrolling, dragging, or cursor movement. Keep ordinary taps, double-clicks, scrolling, fast continuous swipes, and hold-to-drag behavior unchanged, and keep validation independent for every attached controller.

## Hardware and report reference

The implementation builds on the public hardware investigation in [Myseri/xeneon-edge-multitouch-macos](https://github.com/Myseri/xeneon-edge-multitouch-macos). Its [userspace documentation](https://github.com/Myseri/xeneon-edge-multitouch-macos/tree/main/userspace) describes the working macOS mouse interface and seven-byte report format. Its [HID mouse reader](https://github.com/Myseri/xeneon-edge-multitouch-macos/blob/main/userspace/xeneon_touch/hid_mouse.py) interprets byte 1 bit 0 as touch, bytes 2-3 as X, and bytes 4-5 as Y.

The controller's actual digitizer interface remains silent on macOS according to that investigation, so the production driver must continue reading the working mouse interface. Storm protection therefore belongs between raw report parsing and synthetic gesture generation rather than on a different interface.

## Captured evidence

`HIDDump` was extended to tag every raw report with wall-clock time and the dynamically discovered controller location ID. The production driver was then stopped so it could not synthesize input, and the tracer observed normal taps followed by the reported storm.

Normal taps produced:

- button byte `0x01` while the finger was down and `0x00` on release;
- repeated reports at one stable coordinate during the contact;
- a clear quiet interval between contacts.

The storm produced:

- more than one thousand reports in roughly nineteen seconds;
- genuine `0x01` touch-down and `0x00` release values rather than unrelated button bits;
- rapidly changing X/Y coordinates, including large discontinuities approximately every eight milliseconds;
- input from one controller while the other controller remained independently identifiable.

The reports came directly from IOHID while the production driver was not running. That confirms the source was the screen controller or its upstream USB/power path, not the driver's coordinate mapping, synthetic-event code, browser automation, or another process asking the driver to click. Reconnecting that controller ended the observed storm and a subsequent hands-off trace was quiet.

## Resulting protection

Every `DeviceTouchSession` owns a `TouchStreamValidator`, so a bad stream from one controller cannot suppress the other controllers.

The validator:

1. Passes touch-down into a pending gesture state without borrowing or warping the system cursor.
2. Holds the first short window of movement while measuring normalized distance, speed, path length, and continuity.
3. Releases coherent buffered movement in order, preserving normal pixel scrolling and fast continuous swipes.
4. Rejects severe coordinate jumps, repeated implausibly fast segments, and chaotic paths before they reach gesture synthesis.
5. Cancels an already accepted gesture safely if an impossible jump appears later.
6. Originally suppressed that controller until the raw stream had been quiet for a bounded interval.

Cursor borrowing is now lazy: a tap borrows the cursor only when it is released, scrolling borrows it only after motion passes validation, and dragging borrows it only after the hold threshold. A rejected initial burst therefore cannot move the cursor or emit synthetic input.

Live testing later showed that whole-controller suppression also hid intentional input while a storm remained active. The follow-up [Active Storm Confidence Tracking Design](2026-09-02-active-storm-confidence-tracking-design.md) replaces that recovery boundary with a per-controller storm mode that extracts coherent finger paths from interleaved outliers and returns to normal after raw-report silence.

## Boundary and limitations

The validator is generic. It contains no saved controller IDs, display positions, user paths, application names, or machine-specific topology. Controller identity is used only to keep validation state independent.

A single false contact that exactly matches the timing and stable coordinates of a real tap is indistinguishable from a real tap. This design addresses the observed storm signature: high-rate, spatially incoherent controller reports. It does not claim to repair defective hardware, cabling, hub power, or firmware; it prevents that failure mode from becoming destructive desktop input.

## Verification

Automated coverage includes:

- stable taps and existing double-click sequencing;
- buffered coherent motion released in order;
- a high-rate continuous swipe accepted as plausible;
- captured storm-coordinate jumps rejected before movement escapes;
- impossible motion after acceptance canceling the active stream;
- quiet-period recovery;
- one storming controller producing no input while another controller continues clicking normally;
- existing scrolling, focus restoration, cancellation, and hold-to-drag behavior.

The signed local build was then exercised on two physical touchscreens. Single tap, double-tap, slow scrolling, fast swiping, and hold-to-drag remained functional on both displays.
