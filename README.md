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

Uninstall removes the LaunchAgent and Application Support files (including config and retained installer backups) but keeps logs. It checks the current user's GUI-domain registration, requires a successful bootout for a registered job, and verifies that the job is unregistered before removing files. A bootout or ambiguous query failure leaves installation files untouched and returns failure. Like the installer, the state query treats service-print status 113 as absent only after a successful GUI-domain query; this macOS convention is not a guarantee of the public launchctl interface.

Registration checks do not prove synchronous process exit or stop manually started copies. Other tools can change registration after the final check. If file removal fails after unregistration, uninstall reports failure and leaves any remaining files for manual recovery; it does not claim rollback or complete removal.

Build a signed release binary:

```sh
./Scripts/build-release.sh
```

By default this uses ad-hoc signing. Set `CODESIGN_IDENTITY` for Developer ID signing and `NOTARIZATION_PROFILE` to submit the release archive with `xcrun notarytool`.

## Start, stop and status

Run these commands as the installing user in a macOS GUI login, without `sudo`.

Check the installed LaunchAgent:

```sh
launchctl print "gui/$(id -u)/com.ajvwhite.MacXeneonEdgeTouchDriver"
```

Stop and unregister it:

```sh
launchctl bootout "gui/$(id -u)/com.ajvwhite.MacXeneonEdgeTouchDriver"
```

Check status again after stopping. A service-not-found result means the job is unregistered; other query failures do not establish that it stopped. Confirm the daemon process has exited before starting another copy or a diagnostic capture. Stopping does not disable the installed LaunchAgent; a later login may load it again.

Start the installed LaunchAgent again:

```sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ajvwhite.MacXeneonEdgeTouchDriver.plist"
```

To restart after editing the config, stop and then start. These commands leave installed files and persistent enable/disable overrides unchanged. Check `driver.log` after starting; launchd registration alone does not confirm working touch input.

## Development checks

Run the native tests and both build configurations on macOS:

```sh
swift test
swift build --configuration debug
swift build --configuration release
/bin/sh -n Scripts/install.sh
/bin/sh -n Scripts/uninstall.sh
python3 Scripts/test-install.py
python3 Scripts/test-uninstall.py
```

The unit tests use fake input, cursor, focus, permissions, request workers, signals, run loops, and HID startup dependencies. Delayed gesture tests advance a virtual clock instead of waiting for real time. These checks do not install or run the driver, require attached hardware, or request macOS permissions. GitHub Actions runs the same checks on macOS for pushes and pull requests.

Installer tests use temporary homes and workspaces with a restricted command path. Swift builds, signing and launchctl are stubbed; the Foundation serializer is compiled and exercised with real JSON/XML parsers. Uninstaller tests use strict fake launchctl and removal commands, with deletion restricted to harmless fixtures inside owned temporary directories. They exercise registration-query, bootout and partial file-removal failures without running the driver or controlling any real jobs. The installer workflow runs when its scripts, template or workflow change.

The package declares macOS 13 as its minimum deployment target. A successful build or CI run does not establish runtime validation on macOS 13.

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
    "fileLogPath": "~/Library/Logs/MacXeneonEdgeTouchDriver/driver.log",
    "fileLogMaxBytes": 5242880
  }
}
```

Display matching requires the configured vendor and model and valid display bounds. If `display.serialNumber` is set, only displays with that serial are eligible. Matching `display.expectedWidth` and `display.expectedHeight` is preferred; if none match those dimensions, all otherwise eligible displays are considered.

Touch routing pauses and input is dropped when more than one valid display is equally preferred, including displays reporting the same serial number. Detecting ambiguity cancels any active gesture and clears the previous mapping instead of choosing the first enumerated display. Routing resumes when a display refresh finds a unique best match. A configured serial resolves a tie only if it distinguishes the candidate displays. Adjust the display configuration or connected displays to resolve a tie; config changes require a driver restart. This matching safeguard does not establish support for multiple touch panels.

`focus.restorePreviousWindow` defaults to `true`: the driver captures the focused window before each touch and attempts to restore it afterward. Set it to `false` to skip focus capture and restoration and leave focus to normal window behavior. If focus cannot be captured, the touch still proceeds.

The gesture queue uses a 30 ms scheduled preparation deadline. If capture finishes first, input proceeds with that capture. If a move or release arrives first, the driver immediately delivers the original down followed by that event, without waiting for focus. Every subsequent drag point is delivered normally. The deadline also releases a stationary touch when capture is slow; late results are discarded. The existing warp and click delays apply after preparation. Queue scheduling can delay execution substantially, so this is not a hard real-time guarantee.

Accessibility work runs separately from input cleanup, with at most one operation outstanding. When focus changes during a touch, the driver makes one attempt to observe and confirm the destination window before the gesture queue receives the accepted HID touch-up report. Receipt of that report freezes the confirmed window, before any configured synthetic mouse-up delay; a later focus read cannot replace it. If confirmation is unfinished, stale, or unavailable at that boundary, the driver leaves focus alone. This can skip restoration for quick taps, late app activation, or further focus changes during a touch, without delaying button or cursor cleanup.

Restoration starts after button and cursor cleanup, with a 150 ms budget for starting further work. It rechecks the exact captured process and frozen destination window, skips an already-focused window, and makes at most one supported focus or raise request. It verifies the result when possible; it never clicks a title bar or retries an uncertain request. A stalled request can outlive the budget; later touches continue without capture until that worker returns. If macOS cannot report focus reliably or the app does not support the required operations and observations, the driver leaves focus alone.

`cursor.returnToPreviousPosition` also defaults to `true`. Set it to `false` to skip the return to the pre-touch cursor position. Cleanup still releases the mouse button, restores cursor visibility and mouse association, and clears the borrowed state. This applies to normal completion, cancellation, device removal, and shutdown. Touch input still moves the shared system cursor; focus restoration does not warp it.

| Restore previous window | Return cursor | End of gesture |
| --- | --- | --- |
| `true` | `true` | Return the cursor and attempt to restore the previous window (default). |
| `false` | `true` | Return the cursor; leave focus to normal window behavior. |
| `true` | `false` | Release the cursor at its current position and attempt to restore the previous window. |
| `false` | `false` | Release the cursor at its current position; leave focus to normal window behavior. |

The configured gesture delays are unchanged; enabling focus restoration can add the bounded preparation wait described above. Restart the driver after changing the configuration.

`gesture.multiTouchEnabled` is always forced to `false` as the hardware only exposes single touch information, if this ever changes we will look to see how to support multi-touch gestures.

## Permission startup

If synthetic event access is missing, the driver stays alive and waits before opening HID or starting gestures. It installs signal handlers first, makes at most one initial permission request sequence per process, and checks readiness without prompting every two seconds with 500 ms of timer leeway. Grant access to the executable or launcher identified in the log; startup continues automatically. SIGINT, SIGTERM, and normal stop cancel the wait and exit successfully. Cancellation cannot dismiss a dialog macOS has already shown.

CoreGraphics post-event access and Accessibility trust remain separate checks. The existing compatibility rule accepts either; it does not prove that events reach another application. A missing focused window does not prevent touch startup. Apple's [Accessibility API documentation](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions) specifies that its prompt is asynchronous and does not change the immediate return value. The [CoreGraphics request](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()) runs on a separate worker so a blocked request cannot hold up shutdown. Only state changes are logged while waiting.

This wait addresses the synthetic-permission restart loop reported in [issue #1](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/issues/1). Input Monitoring and HID open errors remain separate startup failures, reported with the IOKit error code. Opening HID can itself request Input Monitoring access; denial or another process holding exclusive device access can still cause a failed launch. The driver does not retry HID open on each permission poll. No persistent prompt marker or permission settings are added.

## Known Caveats

- This version targets a single Xeneon Edge panel in landscape orientation. The revised touch, focus and cursor behavior still needs on-device acceptance testing; rotations and multiple matching panels have not been validated.
- A stationary hold can hit the safety timeout. Repeated HID reports at the same position currently don't reset `timing.stuckGestureTimeoutMs` (2,000 ms by default), so the driver can release the mouse button while your finger is still down. Lift and touch again to start a new gesture after a timeout. Hold behavior still needs on-device testing.
- Focus restoration is best effort. An intentional app or window selection made during a touch may be restored over, as with the previous behavior. Changes observed after the accepted touch-up report, a newer gesture, shutdown, target invalidation, or a Space/session change stop further restoration work. HID reports and focus notifications can arrive late, so the software boundary cannot establish the exact physical finger-lift time. An AX request already sent to another app can still finish afterward; invalidation cannot undo it.
- With cursor return enabled, physical mouse movement during a touch does not change the saved return position. With it disabled, cleanup leaves the cursor at its current position rather than warping to an assumed final touch point.
- Multi-contact gestures are not supported as the hardware doesn't report this information back.
- If the process is killed with `SIGKILL`, normal shutdown cleanup cannot run. Relaunching the driver or moving the physical mouse after cursor association is restored may be needed.

## Troubleshooting

- If the driver is waiting for synthetic event permission, grant Accessibility to the exact executable or launcher shown in the log. It will continue without a restart.
- If HID open fails, check Input Monitoring permission and confirm no other process has seized the same VID/PID device.
- If taps land on the wrong display, run `swift run DisplayInfo` and adjust the optional display config override.
- For HID investigation, stop the production daemon using the commands above, then run `swift run HIDDump`. The bundled diagnostic uses non-seize mode. Do not run a seizing build of HIDDump or another driver instance alongside the production daemon. Quit HIDDump before starting the installed LaunchAgent again.

## Contributors

Thanks to [Greg Thompson (`isleofgreg`)](https://github.com/isleofgreg) for the per-touch-down display refresh proposal and moved-display regression test in [PR #4](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/pull/4), which this driver adapts.

Thanks to [Clark Hager](https://github.com/clarkhager) for the already-focused-window guard proposed in [PR #5](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/pull/5). The focus restoration implementation retains that guard, with regression tests that verify it skips focus mutations when the target window is already focused.
