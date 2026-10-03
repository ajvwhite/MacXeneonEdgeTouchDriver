# Mac Xeneon Edge Touch Driver

A from-scratch macOS user-space touch driver for the Corsair Xeneon Edge 14.5 inch 32:9 touchscreen panel so you can make it genuinely useful when using it with a Mac.

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

## Development checks

Run the native tests and both build configurations on macOS:

```sh
swift test
swift build --configuration debug
swift build --configuration release
```

The unit tests use fake input, cursor, and focus dependencies. Delayed gesture tests advance a virtual clock instead of waiting for real time. These checks do not install or run the driver, require attached hardware, or request macOS permissions. GitHub Actions runs the same checks on macOS for pushes and pull requests.

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
  "focus": {
    "restorePreviousWindow": true
  },
  "cursor": {
    "returnToPreviousPosition": true
  },
  "gesture": {
    "multiTouchEnabled": false
  },
  "diagnostics": {
    "fileLogPath": "/Users/ajvwhite/Library/Logs/MacXeneonEdgeTouchDriver/driver.log",
    "fileLogMaxBytes": 5242880
  }
}
```

`focus.restorePreviousWindow` defaults to `true`: the driver captures the focused window before each touch and attempts to restore it afterward. Set it to `false` to skip focus capture and restoration and leave focus to normal window behavior. If focus cannot be captured, the touch still proceeds.

Focus preparation has a 30 ms deadline on the gesture queue. If capture finishes first, input proceeds with that capture. If a move or release arrives first, the driver immediately delivers the original down followed by that event, without waiting for focus. Every subsequent drag point is delivered normally. The deadline also releases a stationary touch when capture is slow; late results are discarded. The existing warp and click delays apply after preparation. Queue scheduling can delay execution, so this is not a hard real-time guarantee.

Accessibility work runs separately from input cleanup, with at most one operation outstanding. Restoration starts after button and cursor cleanup, with a 150 ms budget for starting further work. It checks the exact captured process and window against a fresh observation, skips an already-focused window, and makes at most one supported focus or raise request. It verifies the result when possible; it never clicks a title bar or retries an uncertain request. A stalled request can outlive the budget; later touches continue without capture until that worker returns. If macOS cannot report focus reliably or the app does not support the required operations and observations, the driver leaves focus alone.

`cursor.returnToPreviousPosition` also defaults to `true`. Set it to `false` to skip the return to the pre-touch cursor position. Cleanup still releases the mouse button, restores cursor visibility and mouse association, and clears the borrowed state. This applies to normal completion, cancellation, device removal, and shutdown. Touch input still moves the shared system cursor; focus restoration does not warp it.

| Restore previous window | Return cursor | End of gesture |
| --- | --- | --- |
| `true` | `true` | Return the cursor and attempt to restore the previous window (default). |
| `false` | `true` | Return the cursor; leave focus to normal window behavior. |
| `true` | `false` | Release the cursor at its current position and attempt to restore the previous window. |
| `false` | `false` | Release the cursor at its current position; leave focus to normal window behavior. |

The configured gesture delays are unchanged; enabling focus restoration can add the bounded preparation wait described above. Restart the driver after changing the configuration.

`gesture.multiTouchEnabled` is always forced to `false` as the hardware only exposes single touch information, if this ever changes we will look to see how to support multi-touch gestures.

## Known Caveats

- Focus restoration is best effort. An intentional app or window selection made during a touch may be restored over, as with the previous behavior. Changes observed after release, a newer gesture, shutdown, target invalidation, or a Space/session change stop further restoration work. An AX request already sent to another app can still finish afterward; invalidation cannot undo it.
- With cursor return enabled, physical mouse movement during a touch does not change the saved return position. With it disabled, cleanup leaves the cursor at its current position rather than warping to an assumed final touch point.
- Multi-contact gestures are not supported as the hardware doesn't report this information back.
- If the process is killed with `SIGKILL`, normal shutdown cleanup cannot run. Relaunching the driver or moving the physical mouse after cursor association is restored may be needed.

## Troubleshooting

- If the driver exits immediately, check Accessibility permission for the exact binary location as provided by the install script.
- If HID open fails, check Input Monitoring permission and confirm no other process has seized the same VID/PID device.
- If taps land on the wrong display, run `swift run DisplayInfo` and adjust the optional display config override.
- For HID investigation, use `swift run HIDDump`; it intentionally runs in non-seize mode and is separate from the production daemon.
