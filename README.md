# Mac Xeneon Edge Touch Driver

A macOS touch driver for the Corsair Xeneon Edge 14.5 inch 32:9 touchscreen. It supports tapping, dragging and selecting text with one finger.

## How To Install

From the repository folder on your Mac, run:

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

The installer keeps your existing config, including settings it does not recognise. The file must contain a valid JSON object; otherwise installation stops before replacing anything. New configs enable both `focus.restorePreviousWindow` and `cursor.returnToPreviousPosition`.

The installer checks the new executable, config and LaunchAgent before stopping the current driver. To sign the executable during installation, set `CODESIGN_IDENTITY`. Signing keeps the `MacXeneonEdgeTouchDriver` identifier and must pass verification before installation continues. This uses [Greg Thompson's (`isleofgreg`) signing contribution in PR #4](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/pull/4). macOS may still ask you to grant permissions again after an update.

Before replacing files, the installer saves a backup under `~/Library/Application Support/MacXeneonEdgeTouchDriver/install-backups/transaction.*`. It keeps that backup after installation. Your existing config is never rewritten.

If installation fails after replacement starts, the installer tries to stop the replacement, restore the previous files and reload the previous LaunchAgent. If it cannot safely determine which job is running, stop it, or restore its files, it stops recovery and reports the backup location. Check the error before trying again.

Replacing files and reloading the driver happen in separate steps. A power loss or forced stop can interrupt them and leave the installer lock in place. Check the running driver and backups before removing a stale lock. The lock prevents two copies of this installer running together; it cannot prevent another tool from changing the files. Recovery uses the saved files, so it cannot recover unsaved changes to launchd's loaded configuration. Existing launchd enable/disable settings are kept. The LaunchAgent uses Interactive process scheduling to avoid macOS background timer delays. After installation, check the log and try a touch: launchd accepting the job does not prove the driver is working.

Uninstall:

```sh
./Scripts/uninstall.sh
```

Uninstall removes the LaunchAgent, config, driver and installer backups, but keeps logs. It stops and unregisters the current user's LaunchAgent before deleting files. If that fails or the job's status is unclear, the files are left alone.

Uninstall does not stop copies started manually. If deleting files fails, the script reports what remains; it does not reinstall them. Avoid running other installation tools at the same time.

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

The tests use simulated input and a virtual clock. They do not run the driver, need an attached Edge or request macOS permissions. GitHub Actions runs tests and builds on macOS for pushes and pull requests.

Installer and uninstaller tests use temporary folders and simulated signing and launchctl commands. They cover failures without changing your installed driver. The installer workflow runs when its scripts, template or workflow change.

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
    "multiTouchEnabled": false,
    "mode": "direct",
    "holdDurationMs": 300,
    "scrollThresholdPx": 6,
    "scrollSensitivity": 1.0,
    "doubleClickEnabled": true
  },
  "diagnostics": {
    "fileLogPath": "~/Library/Logs/MacXeneonEdgeTouchDriver/driver.log",
    "fileLogMaxBytes": 5242880,
    "performanceMetricsEnabled": false
  }
}
```

Display matching requires the configured vendor and model and valid display bounds. If `display.serialNumber` is set, only displays with that serial are eligible. Matching `display.expectedWidth` and `display.expectedHeight` is preferred; if none match those dimensions, all otherwise eligible displays are considered.

If several displays match equally well, the driver pauses touch input rather than guessing. It cancels any current gesture and resumes when there is one clear match. Set `display.serialNumber` or disconnect an extra matching display to resolve the tie. A serial number only helps if the displays report different serials. Restart after changing the config. This driver supports one touch panel.

`focus.restorePreviousWindow` defaults to `true`. The driver remembers the window and text field you were using before a touch and tries to return focus there afterward. Set it to `false` to leave the touched app active.

With either setting, the driver first checks that the window under your finger is ready to receive a click. This lets the first tap work on an inactive window. It allows 30 ms to prepare the window and holds up to 256 movement/release events while waiting. If it cannot confirm the target in time, it drops that touch. The configured click delays follow this check. A slow macOS request can take longer than the scheduled limit.

Focus returns after the mouse button is released and cursor cleanup finishes. The driver checks the saved window and field before asking the app to restore focus. If a text field was captured but is no longer available, it leaves focus alone. Floating panels, such as a virtual Stream Deck, can receive a tap without needing a text field of their own. The driver can reactivate the original app once before restoring its field.

Clicking the mouse, typing or scrolling cancels further focus restoration. New touches, closed windows, app changes, shutdown and Space/session changes can also cancel it. A focus request already sent to another app may still finish. Accessibility work runs separately so a slow app does not hold up mouse-button release or cursor cleanup.

`cursor.returnToPreviousPosition` defaults to `true`. Set it to `false` to leave the cursor where it is after the touch. Both settings release the mouse button, make the cursor visible and return control to the mouse, including after cancellation, USB removal or shutdown. Touch uses the system cursor; restoring focus does not move it.

| Restore previous window | Return cursor | End of gesture |
| --- | --- | --- |
| `true` | `true` | Return the cursor and attempt to restore the previous window (default). |
| `false` | `true` | Return the cursor; leave focus to normal window behavior. |
| `true` | `false` | Release the cursor at its current position and attempt to restore the previous window. |
| `false` | `false` | Release the cursor at its current position; leave focus to normal window behavior. |

The window readiness check applies with either focus setting. Restart the driver after changing the configuration.

### Tap, drag and scroll

The default `gesture.mode`, `"direct"`, keeps the existing behavior: tap to click, or move a held finger to drag.

Set `gesture.mode` to `"scroll"` to scroll with one finger. A quick tap still clicks. Movement beyond `scrollThresholdPx` scrolls the page; hold still for `holdDurationMs` before moving to drag instead. Increase `scrollSensitivity` for more scrolling per movement. Scrolling does not hold a mouse button down.

Two nearby taps can produce a double-click within macOS's double-click interval. Both taps must hit the same window. If macOS identifies the button or control, both taps must hit it; otherwise they must land almost on the same point. A drag, failed click, changed display mapping or intervening mouse/keyboard input breaks the pair. Set `doubleClickEnabled` to `false` for separate clicks.

The touch reports currently handled by this driver contain one position. Two-finger scrolling and other multi-contact gestures remain unsupported. `gesture.multiTouchEnabled` is forced to `false`; an unsupported mode logs a warning and keeps direct touch behavior. It does not silently switch to single-finger scrolling.

### Inconsistent touch reports

The driver checks consecutive reports before accepting a new touch. When a stream starts jumping between unrelated positions, it releases the affected gesture and looks for a consistent track. A deliberate touch can continue while unrelated reports arrive, provided the track remains clear. Noise alone cannot extend a held gesture indefinitely: a track that loses support for 120 ms is released. A quiet stream returns to normal validation automatically.

Every report is checked, including reports that do not move the finger. During an established drag, queued movement can skip intermediate positions and use the latest accepted point. The first drag movement and final point before release are preserved. Scrolling keeps each accepted direction change.

## Held touches and USB reconnect

A held finger keeps the gesture alive while the Edge continues sending touch reports, even when the finger does not move. If reports stop for `timing.stuckGestureTimeoutMs` (2,000 ms by default), the driver releases the gesture. Lift and touch again after a timeout.

New taps can wait briefly for the previous mouse-button release. The queue holds up to sixteen contacts and 256 events, with a 150 ms limit for admitting a waiting contact. Movements and releases stay in order, and the previous click keeps its minimum press time. Overflow, a timeout, a disconnected source or later mouse/keyboard input discards the affected work. Reports from other USB interfaces cannot take over an active gesture.

If USB disconnects during a hold, the driver releases the mouse button. Before accepting another touch, it checks for a release from the replacement connection. On supported report-7 devices, it can also check the device's saved input values: all six fields must be available, two reads must agree that the buttons are up, and a button timestamp must be newer than the disconnect. Older queued reports are ignored. If those checks fail, the driver waits for a release.

A full monitor power reset needs a different check because it can discard both the held touch and its lift. The supported reset path checks the USB location, new controller and hub connections, controller revision `bcdDevice=0x0150`, hub VID/PID `0x1a40/0x0801`, the report-7 format and two matching empty input reads. It waits for a fresh touch rather than treating a held finger as a new press. The reset check lasts ten seconds and includes the monitor's second startup connection. Other controller revisions, hubs and reconnects without a full reset keep the release requirement.

USB connection identifiers do not uniquely identify a finger or physical panel. The available report format also cannot distinguish every delayed report from a new touch. Multiple-panel support and grouping reports from several connections remain unsupported.

The timeout uses one pending timer, updated by reports from the active touch. Button-release and cursor cleanup have their own deadline. These checks run on the gesture queue, so a busy queue can delay cleanup. A late report cannot restart a gesture that has already timed out.

## Permission startup

In System Settings > Privacy & Security, enable the driver under Device Control and Data Access and Input Monitoring. On macOS 26 and earlier, Device Control and Data Access is called Accessibility. The driver needs this access to prepare windows for touch, even if focus restoration is disabled. If access is missing, it stays running and waits; startup continues after approval.

Startup requests permission at most once per process and checks again every two seconds without repeated prompts. While waiting, it runs its read-only permission check in a short-lived process because macOS can keep an old answer in the running driver. Only one check runs at a time; a timeout or invalid answer cannot start touch input. You can stop the driver while it waits. Stopping cannot dismiss a permission dialog macOS has already shown. Apple's [Accessibility API documentation](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions) explains that the prompt does not grant access immediately. The [CoreGraphics request](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()) runs separately so it cannot hold up shutdown.

If Input Monitoring is denied, the driver waits for a confirmed grant before opening the device again. An error such as `kIOReturnNotPermitted` starts that wait too. It closes a failed device-open attempt before retrying. If macOS still remembers the denial after approval, startup refreshes once to clear that answer. If the refresh fails, the driver stops and logs a request to check permissions and restart it; it cannot keep restarting itself. Other USB errors, including another process holding the device exclusively, still stop startup and are recorded in the log. This addresses the restart loop reported in [issue #1](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/issues/1). The driver does not change your permission settings.

Run `MacXeneonEdgeTouchDriver --check-permissions` for a JSON snapshot without opening the touch device, requesting access or generating input. Exit status is zero only when device-control and Input Monitoring access are already granted; otherwise it is 77.

An update or signing change may need a new permission approval. If the driver's entry is enabled but access is still denied, remove that entry and add the installed executable again. Do this only for the driver, in the affected permission category.

## Known Caveats

- This version supports one Xeneon Edge in landscape orientation. Rotation and multiple Edge panels have not been tested.
- If touch reports stop, `timing.stuckGestureTimeoutMs` releases the gesture. Lift and touch again to continue.
- Apps must expose their windows and text fields through macOS Accessibility for focus restoration to work. Mouse clicks, typing and scrolling cancel further restoration, but a request already sent to an app may still finish afterward.
- With cursor return enabled, moving the mouse during a touch does not change the saved return position. With it disabled, the cursor stays where it is after cleanup.
- The supported report format contains one position, so multi-contact gestures are unsupported.
- Killing the process with `SIGKILL` prevents normal cleanup. Restarting the driver or moving the mouse after cursor control is restored may be needed.

## Troubleshooting

- If the driver is waiting for synthetic event permission, enable Device Control and Data Access (Accessibility on earlier macOS) for the exact executable or launcher shown in the log. Startup continues after approval.
- If the driver is waiting for HID listen access, grant Input Monitoring to the executable or launcher identified in the log. Startup continues once access is granted. If the device is in exclusive use, close the other driver or diagnostic tool.
- If taps land on the wrong display, run `swift run DisplayInfo` and adjust the optional display config override.
- For HID investigation, stop the production daemon using the commands above, then run `swift run HIDDump`. The bundled diagnostic uses non-seize mode. Do not run a seizing build of HIDDump or another driver instance alongside the production daemon. Quit HIDDump before starting the installed LaunchAgent again. `swift run HIDDump --describe-input-cache` reports descriptors and cached-read errors without opening the device. Add `--open` for non-seize cached reads after stopping the driver; this mode requires an existing HID grant and neither prompts nor sends feature requests.

### Opt-in HID cache diagnostic

With one XENEON attached, all fingers lifted and the installed driver stopped, run:

```sh
XENEON_RUN_HARDWARE_TESTS=1 swift test --filter HIDRecoveryHardwareTests
```

This check uses the production cached-release reader, requires already-granted Input Monitoring, and closes its non-seize HID manager before returning. It posts no input and requests no permissions. It checks descriptor support, coherent initialized neutral values and rejection of stale release evidence. It does not replace a physical reconnect test. Restart the installed service afterward. Ordinary test runs skip this hardware check.


### Timing and report replay

Set `diagnostics.performanceMetricsEnabled` to `true` to write a timing summary when the driver stops normally. It reports counts and recent median, 95th and 99th percentile timings for queued reports, mouse-event posting and focus restoration. Canceled or unverified focus work is counted separately. The summary contains no typed text or touch coordinates. Event-posting times do not establish when an app received the click.

For an offline check, run:

```sh
swift run -c release Benchmarks
swift run -c release Benchmarks --timers
swift run -c release Benchmarks --backlog
swift run -c release Benchmarks --trace recording.jsonl
```

The default replay generates repeatable taps. `--backlog` simulates delayed drag reports to check movement coalescing and balanced button release. `--timers` measures queue wake delays without touch input. Trace replay uses the driver's parser and gesture handling with simulated mouse, cursor and focus effects. It cannot establish physical touch accuracy or native focus behavior.

To record raw touch reports, stop the installed driver first, then run `swift run HIDDump --record recording.jsonl`. The destination must be a new file. Quit the recorder before restarting the driver. Recordings contain touch coordinates, timestamps and USB connection identifiers; review them before sharing. The recorder does not change USB modes or request new permission grants.

## Contributors

Thanks to [Greg Thompson (`isleofgreg`)](https://github.com/isleofgreg) for the per-touch-down display refresh proposal and moved-display regression test in [PR #4](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/pull/4), which this driver adapts.

Thanks to [Clark Hager](https://github.com/clarkhager) for the focus check proposed in [PR #5](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/pull/5). The driver keeps that check to avoid unnecessarily refocusing an already focused window.

Thanks to [`mrnocreativity`](https://github.com/mrnocreativity) for the touch-stream validation and gesture proposals in [PR #3](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/pull/3). The noise tracking, double-click and optional scroll work follows those proposals with separate implementation and tests.
