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

Existing config files are validated as JSON objects and preserved byte-for-byte, including unknown keys and the focus/cursor settings. Invalid JSON stops the installer before replacement. New configs enable both `focus.restorePreviousWindow` and `cursor.returnToPreviousPosition`.

The installer builds and validates the replacement executable, config and LaunchAgent in staging directories before changing installed files or stopping the job. To sign the staged executable, set `CODESIGN_IDENTITY` when running the installer. Signing explicitly uses the `MacXeneonEdgeTouchDriver` identifier so the temporary filename does not change it. Signing and signature verification must both succeed before replacement. This interface adapts [Greg Thompson's (`isleofgreg`) signing contribution in PR #4](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/pull/4). Signing does not guarantee that macOS will retain permission grants.

Before replacement, the installer saves the prior files and whether the job was registered under `~/Library/Application Support/MacXeneonEdgeTouchDriver/install-backups/transaction.*`. Backups remain after success or failure. A preflight failure leaves the installed executable, config, plist and registered job unchanged; it may leave newly created directories or a partial backup.

If replacement or bootstrap fails, the installer attempts to unload any replacement job, restore prior files (or their prior absence), and bootstrap the saved on-disk plist if the old job was registered. Existing config is never rewritten. Recovery stops if an unexpected job appears before activation, the replacement job cannot be unloaded, or its state cannot be determined. File restoration failures prevent restarting the prior job. Errors identify incomplete recovery and the retained backup directory for manual repair.

Each file replacement uses a rename; the files and launchd state do not change atomically as a group. Rollback cannot recover an earlier PID or launchd's in-memory definition if the on-disk plist had been edited. The installer lock prevents concurrent runs of this installer, but does not coordinate with other tools editing these files. Forced termination or power loss can interrupt recovery and leave the lock in place; check the job and saved files before removing a stale lock or retrying. A successful bootstrap means launchd accepted the job, not that the daemon remains healthy. Persistent launchd enable/disable overrides are preserved, so a disabled job may reject bootstrap.

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
/bin/sh -n Scripts/install.sh
python3 Scripts/test-install.py
```

The unit tests use fake input, cursor, and focus dependencies. Delayed gesture tests advance a virtual clock instead of waiting for real time. These checks do not install or run the driver, require attached hardware, or request macOS permissions. GitHub Actions runs the same checks on macOS for pushes and pull requests.

Installer tests use temporary homes and workspaces with a restricted command path. Swift builds, signing and launchctl are stubbed; the Foundation serializer is compiled and exercised with real JSON/XML parsers. The installer workflow runs when its scripts, template or workflow change.

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

`cursor.returnToPreviousPosition` also defaults to `true`. Set it to `false` to skip the return to the pre-touch cursor position. Cleanup still releases the mouse button, restores cursor visibility and mouse association, and clears the borrowed state. This applies to normal completion, cancellation, device removal, and shutdown. Touch and focus restoration can still move the shared system cursor.

| Restore previous window | Return cursor | End of gesture |
| --- | --- | --- |
| `true` | `true` | Return the cursor and attempt to restore the previous window (default). |
| `false` | `true` | Return the cursor; leave focus to normal window behavior. |
| `true` | `false` | Release the cursor at its current position and attempt to restore the previous window. |
| `false` | `false` | Release the cursor at its current position; leave focus to normal window behavior. |

Both settings preserve the existing gesture timing. Restart the driver after changing the configuration.

`gesture.multiTouchEnabled` is always forced to `false` as the hardware only exposes single touch information, if this ever changes we will look to see how to support multi-touch gestures.

## Known Caveats

- With cursor return enabled, physical mouse movement during a touch does not change the saved return position. With it disabled, cleanup leaves the cursor at its current position rather than warping to an assumed final touch point.
- Multi-contact gestures are not supported as the hardware doesn't report this information back.
- If the process is killed with `SIGKILL`, normal shutdown cleanup cannot run. Relaunching the driver or moving the physical mouse after cursor association is restored may be needed.

## Troubleshooting

- If the driver exits immediately, check Accessibility permission for the exact binary location as provided by the install script.
- If HID open fails, check Input Monitoring permission and confirm no other process has seized the same VID/PID device.
- If taps land on the wrong display, run `swift run DisplayInfo` and adjust the optional display config override.
- For HID investigation, use `swift run HIDDump`; it intentionally runs in non-seize mode and is separate from the production daemon.
