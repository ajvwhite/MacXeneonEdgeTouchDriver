# Mac Xeneon Edge Touch Driver

A native macOS user-space touch driver for the Corsair Xeneon Edge and compatible WCH `27C0:0859` panels. It supports multiple identical touchscreens, persistent per-controller display mapping, taps, direct pixel scrolling, and deliberate hold-to-drag.

It has no Touch Up dependency. Input capture, pairing UI, display resolution, and event injection use macOS frameworks directly.

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
    "scrollSensitivity": 1.0
  },
  "diagnostics": {
    "fileLogPath": "/Users/ajvwhite/Library/Logs/MacXeneonEdgeTouchDriver/driver.log",
    "fileLogMaxBytes": 5242880
  }
}
```

`gesture.multiTouchEnabled` is always forced to `false` as the hardware only exposes single touch information, if this ever changes we will look to see how to support multi-touch gestures.

## Pairing Multiple Displays

When a controller has no valid saved assignment, the driver covers one compatible display with **Touch this display**. Touch that physical panel once. The raw USB controller location is then paired one-to-one with that display's CoreGraphics UUID in:

```text
~/Library/Application Support/MacXeneonEdgeTouchDriver/pairings.json
```

Repeat for each overlay. Pairings survive driver and Mac restarts. Display bounds are resolved again after rearrangement or hotplug. If a controller moves to a different USB topology, or a display's stable identity changes after replacement, the driver asks for that mapping again instead of sending touch to another screen.

Gesture behavior:

- Tap and release: click.
- Move immediately: pixel-precise scroll.
- Hold still for `holdToDragMs`, then move: mouse drag.

No controller location IDs or display UUIDs are built into the driver. Matching devices are discovered at runtime, compatible displays are selected from the display configuration, and the pairing overlay creates the local one-to-one assignments.

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
- If HID open fails, check Input Monitoring permission and confirm no other process has seized the same VID/PID device.
- If a panel model is not detected, run `swift run DisplayInfo` and adjust the optional display config override.
- To deliberately reset display assignments, stop the LaunchAgent, remove only `pairings.json`, and start it again; the pairing overlays will return.
- For HID investigation, use `swift run HIDDump`; it intentionally runs in non-seize mode and is separate from the production daemon.
