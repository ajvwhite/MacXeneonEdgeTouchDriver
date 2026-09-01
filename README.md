# Mac Xeneon Edge Touch Driver

A native macOS user-space touch driver for the Corsair Xeneon Edge and compatible WCH `27C0:0859` panels. It supports multiple identical touchscreens, safe per-controller display mapping, taps, direct pixel scrolling, and deliberate hold-to-drag.

It has no Touch Up dependency. Input capture, pairing UI, display resolution, event injection, and hotplug observation use documented macOS frameworks directly. It does not depend on private CoreDisplay symbols, unavailable display-service bridges, or I/O Registry topology guesses.

## How To Install

To install for the current user, just run the following from the root of the checked out repository on the relevant mac:

```sh
./Scripts/install.sh
```

This builds the release binary, installs it under:

```text
~/Library/Application Support/MacXeneonEdgeTouchDriver/bin/MacXeneonEdgeTouchDriver
```

and installs the LaunchAgent at:

```text
~/Library/LaunchAgents/com.ajvwhite.MacXeneonEdgeTouchDriver.plist
```

No script uses `sudo`. Driver logs are written to:

```text
~/Library/Logs/MacXeneonEdgeTouchDriver/driver.log
```

The LaunchAgent also creates `stdout.log` and `stderr.log` in the same directory for process-level output. The driver itself uses Unified Logging plus `driver.log`, so stdout and stderr are normally empty unless launchd or a lower-level runtime writes there.

For a development machine that rebuilds the driver, pass a stable signing identity so macOS can keep Accessibility and Input Monitoring approval across upgrades:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/install.sh
```

Without `CODESIGN_IDENTITY`, Swift's linker ad hoc signature is used. Its designated requirement changes whenever the executable changes, so macOS may require privacy approval again after an upgrade. The signing identity is supplied only through the environment and is never written into the repository, configuration, LaunchAgent, or pairing file.

The installer creates a default config file if one does not already exist:

```text
~/Library/Application Support/MacXeneonEdgeTouchDriver/config.json
```

Uninstall:

```sh
./Scripts/uninstall.sh
```

Uninstall removes the LaunchAgent and Application Support files but keeps logs.

Build a signed release binary:

```sh
./Scripts/build-release.sh
```

By default this uses ad-hoc signing. Set `CODESIGN_IDENTITY` for Developer ID signing and `NOTARIZATION_PROFILE` to submit the release archive with `xcrun notarytool`.

## Configuration

Optional config file:

```text
~/Library/Application Support/MacXeneonEdgeTouchDriver/config.json
```

All fields are optional. Missing or malformed config falls back to defaults and logs a warning.
`logLevel` only controls the minimum level written to `driver.log`; Unified Logging remains controlled by macOS logging configuration.

```json
{
  "logLevel": "info",
  "timing": {
    "warpToClickDelayMs": 10,
    "downToUpDelayMs": 20,
    "clickToWarpBackDelayMs": 10,
    "tapDebounceMs": 50,
    "stuckGestureTimeoutMs": 2000
  },
  "display": {
    "vendorNumber": 3672,
    "modelNumber": 60672,
    "serialNumber": null,
    "expectedWidth": 2560,
    "expectedHeight": 720
  },
  "gesture": {
    "multiTouchEnabled": false,
    "holdToDragMs": 300,
    "movementThresholdPoints": 8,
    "scrollSensitivity": 1.0,
    "doubleClickDistancePoints": 12
  },
  "diagnostics": {
    "fileLogPath": "/Users/ajvwhite/Library/Logs/MacXeneonEdgeTouchDriver/driver.log",
    "fileLogMaxBytes": 5242880
  }
}
```

`gesture.multiTouchEnabled` is always forced to `false` as the hardware only exposes single touch information, if this ever changes we will look to see how to support multi-touch gestures.

## Pairing Multiple Displays

When a controller has no valid saved assignment, the driver covers one compatible display with **Touch this display**. Touch that physical panel once. The current USB controller endpoint is then paired one-to-one with that current CoreGraphics display in:

```text
~/Library/Application Support/MacXeneonEdgeTouchDriver/pairings.json
```

Repeat for each overlay. Pairings survive driver restarts and sleep during the same boot, using the kernel-reported boot time as the session boundary. They survive a Mac restart only when both the touch controller and display report public hardware serials that are unique among the attached devices. Identical controllers with duplicate serials and displays with a zero EDID serial—such as the tested Prechen panels—deliberately request pairing once after each reboot because macOS exposes no supported durable association between their USB and video endpoints.

Display position is never used as identity. CoreGraphics and AppKit display-change notifications trigger a debounced refresh of live display bounds, so rearrangement and resolution changes update the global click destination without recalibrating an otherwise valid current-boot pairing. If AppKit is not ready to place the calibration window during login, the driver retries for a bounded period and listens for the next supported display-change event.

When display membership changes, the driver rejects runtime IDs whose current public descriptors no longer match the saved device or display. Ambiguous same-boot pairings are invalidated after the relevant controller or display is removed and require another physical touch. Bounds-only rearrangement keeps the pairing and updates its mapper. The calibration overlay is shown only after the target `NSScreen` identity and frame agree with the current CoreGraphics display snapshot; geometry that is still settling causes a retry instead of placing the prompt on another display.

Gesture behavior:

- Tap and release: click.
- Tap twice nearby within the macOS double-click interval: double-click.
- Move immediately: pixel-precise scroll.
- Hold still for `holdToDragMs`, then move: mouse drag.

Each controller also has an independent touch-stream validator. It briefly holds an unconfirmed contact and accepts stable taps plus spatially continuous swipes, while rejecting coordinate jumps and incoherent report bursts that cannot represent plausible finger motion. A confirmed storm switches only that controller into confidence-tracking mode: coherent finger paths can continue through interleaved bad coordinates while individual outliers and false transitions are discarded. The other attached touchscreens continue working normally.

Storm recovery is event-driven. One low-frequency GCD timer exists only while a controller is storming and checks the timestamp of the complete raw report stream once per second. After one full second without a report, it logs the incident summary, cancels itself, and restores normal low-latency validation. Active incidents log bounded five-second summaries rather than every raw report.

This protection was added after a panel controller was captured emitting a raw HID touch storm while the production driver was stopped. The reports contained genuine touch bits but rapidly changing coordinates at the controller's report rate, so they originated upstream of synthetic event generation and could not be distinguished by checking the button byte alone. See [Touch Storm Protection Design](docs/plans/2026-09-01-touch-storm-protection-design.md) for the captured evidence and [Active Storm Confidence Tracking Design](docs/plans/2026-09-02-active-storm-confidence-tracking-design.md) for live recovery behavior.

The driver keeps focus on the touched application while a second tap remains possible. After a single- or double-click sequence, it restores the previously focused application and exact window through AppKit and Accessibility—without generating another mouse click on the original display.

Matching devices and compatible displays are discovered at runtime. The pairing overlay creates the one-to-one assignments for the attached hardware and live display arrangement.

## Acknowledgements and Provenance

This implementation was informed by the public macOS touchscreen work and hardware research in:

- [ymlaine/TouchscreenDriver](https://github.com/ymlaine/TouchscreenDriver) for its documentation of the Xeneon Edge controller, raw coordinate ranges, and exclusive user-space HID capture.
- [Myseri/xeneon-edge-multitouch-macos](https://github.com/Myseri/xeneon-edge-multitouch-macos) for its hardware-verified USB/HID investigation and evidence explaining the controller's single-touch behavior on macOS.
- [shueber/Touch-Up](https://github.com/shueber/Touch-Up) for the direct-touch interaction model of tap, immediate scroll, and hold-to-drag.
- [talesmousinho/m14t-touch-macos](https://github.com/talesmousinho/m14t-touch-macos) as a reference for keeping HID input, display resolution, coordinate mapping, and synthetic events behind small native Swift boundaries.

Those repositories identify their work as MIT-licensed. This project does not vendor their source or require any of them at runtime; the implementation in this repository uses native macOS frameworks behind its own existing abstractions.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for authorship, license links, and the specific role of each reference.

## Known Caveats

- If the physical mouse is moved during a touch gesture, the cursor will return to the position captured when the touch began.
- Multi-contact gestures are not supported as the hardware doesn't report this information back.
- If the process is killed with `SIGKILL`, normal shutdown cleanup cannot run. Relaunching the driver or moving the physical mouse after cursor association is restored may be needed.

## Troubleshooting

- If the driver exits immediately, check Accessibility permission for the exact binary location as provided by the install script.
- If privacy approval disappears after rebuilding, reinstall with the same `CODESIGN_IDENTITY` each time, then approve that signed binary once.
- If HID open fails, check Input Monitoring permission and confirm no other process has seized the same VID/PID device.
- If a panel model is not detected, run `swift run DisplayInfo` and adjust the optional display config override.
- On identical panels without unique public serials, seeing **Touch this display** once after reboot is the intentional safety behavior. The driver will not guess from screen order or position.
- To deliberately reset display assignments, stop the LaunchAgent, remove only `pairings.json`, and start it again; the pairing overlays will return.
- For HID investigation, use `swift run HIDDump`; it intentionally runs in non-seize mode and is separate from the production daemon.
