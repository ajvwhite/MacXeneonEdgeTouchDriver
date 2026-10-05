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

`focus.restorePreviousWindow` defaults to `true`: the driver captures the focused window and, where the app exposes it, the exact focused control before each touch. Set it to `false` to skip capture and restoration. Both settings prepare the touched window before delivering a click, so an inactive window can receive that first click.

Preparation has a 150 ms scheduled budget. The driver resolves the window under the mapped point, activates its application, and confirms window focus before posting one mouse-down. It buffers up to 256 move/release events from that contact during preparation and replays them in order after confirmation. Physical release closes held-contact liveness immediately. Failed or overdue target preparation rejects the contact through its release; it never sends a speculative activation click. If original focus capture is unavailable, target preparation can still proceed independently and restoration is skipped. The configured warp and click delays follow preparation. Queue scheduling and an AX request already in progress can exceed the budget; it is not a hard real-time deadline.

Accessibility capture, target preparation and restoration run away from button/cursor cleanup. Each AX worker admits at most one operation at a time. When restoration is enabled and capture succeeded, the destination window is observed and confirmed before synthetic input. Accepted physical release freezes restoration eligibility. Because a delivered click can change focus after the HID release, restoration takes fresh observations of the captured source or verified touch destination before proceeding. An unrelated application cannot supply that baseline. Touch-generated control focus changes never replace the captured typing destination.

Restoration starts after button and cursor cleanup, with a 150 ms budget for starting further work. It rechecks the captured process, window, control and confirmed destination before one supported focus request. If a captured control exists, the driver restores that control or leaves focus alone; it does not substitute a window-only raise. A verified floating panel can deliver a click without becoming a keyboard window. If that application subsequently has no focused window or control, restoration verifies the absence twice, activates the retained source application once, and confirms its activation before restoring the exact control. These steps share the original deadline and physical-input guard. It verifies the result where possible and never retries an uncertain mutation. Physical mouse-down, typing or scrolling observed after capture revokes restoration. New touches, app/window lifecycle changes, shutdown and Space/session changes also invalidate pending work. A request already sent to another app can still finish after invalidation.

`cursor.returnToPreviousPosition` also defaults to `true`. Set it to `false` to skip the return to the pre-touch cursor position. Cleanup still releases the mouse button, restores cursor visibility and mouse association, and clears the borrowed state. This applies to normal completion, cancellation, device removal, and shutdown. Touch input still moves the shared system cursor; focus restoration does not warp it.

| Restore previous window | Return cursor | End of gesture |
| --- | --- | --- |
| `true` | `true` | Return the cursor and attempt to restore the previous window (default). |
| `false` | `true` | Return the cursor; leave focus to normal window behavior. |
| `true` | `false` | Release the cursor at its current position and attempt to restore the previous window. |
| `false` | `false` | Release the cursor at its current position; leave focus to normal window behavior. |

Target preparation can add the bounded wait described above with either focus setting. Restart the driver after changing the configuration.

`gesture.multiTouchEnabled` is always forced to `false` as the hardware only exposes single touch information, if this ever changes we will look to see how to support multi-touch gestures.

## Touch report liveness and source ownership

Valid pressed reports from the accepted endpoint/contact renew `timing.stuckGestureTimeoutMs`, including identical stationary reports. They do not become moves, update the cursor, flush focus preparation, or change tap/drag classification. Accepted touch-up closes pressed liveness before focus eligibility freezes; delayed mouse-up and cursor return have a separate fixed cleanup bound using the same timeout. Default delays and restoration options are unchanged.

Each HID registration has its own parser and contact epochs. Only the source/contact accepted by the gesture controller can move, end, or renew that gesture. After accepted physical release, up to sixteen fresh contacts and 256 total events can wait for synthetic mouse-up. Moves and releases replay in order once the old button is released, preserving the configured minimum press duration. Buffer overflow, a 150 ms admission deadline, source retirement, cancellation or later physical input abandons the affected work. A contact beginning while the old physical contact remains pressed stays rejected through its own release. After mouse-up, a fresh contact can finish the remaining cursor-return delay and take ownership; old delayed work cannot affect that new contact. A silent rejected endpoint does not block later fresh taps on another endpoint. Merely matching or seizing another interface does not select, reject, or cancel the reporting source. No usage-page/usage pair is hard-coded as the reporting endpoint.

Removing an idle source, or one whose accepted touch-up has already arrived, allows ordinary first-down admission on a replacement registration. If the accepted source disappears while still pressed, the replacement must prove release before a fresh down can be accepted. In addition to raw release reports, a supported report-7 endpoint can supply cached release evidence: all six input fields must be initialized, two complete reads must agree, all buttons must be up, and a button timestamp must follow source loss. Only that exact registration's recovery barrier is cleared. Queued raw packets at or before the certified release are dropped using their provider timestamps. Cache failures, unsupported descriptors and missing timestamps retain the release safeguard. A held finger never becomes a new down merely because USB reconnects.

A complete monitor power reset can suppress the carried-over held contact and its lift, leaving the replacement input cache uninitialized. A separate recovery path qualifies a new controller and upstream hub generation at the same USB location, controller revision `bcdDevice=0x0150`, hub VID/PID `0x1a40/0x0801`, the supported report-7 descriptor, and two identical all-zero, timestamp-zero cache reads before any pressed report. The cache is a reset marker, not release evidence. Qualification lasts ten seconds from the first new hub generation and covers the second enumeration observed during monitor startup. Driver stop/start clears it; unknown hardware and warm replacements retain the release barrier.

The [corrective hardware session](docs/HARDWARE-VALIDATION-2026-10-05.md) passed the first fresh counter tap after idle power reconnect, disconnect during a held drag with lift before reconnect, and a finger continuously held through both startup enumerations. The held-through-startup trial produced no unintended action or stuck drag. This establishes the captured single-panel profile; it does not qualify other controller revisions or hubs.

Endpoint registration identity does not establish physical-finger or panel identity. A previously silent endpoint beginning a stream after the prior gesture and debounce have ended may be admitted; the driver cannot distinguish a genuine new touch from an unobserved delayed alias using the available report format. This repair does not claim physical endpoint grouping or multiple-panel support.

The watchdog keeps one pending delayed task. Accepted heartbeats update its deadline; reaching an older deadline schedules only the remaining interval. Cleanup uses a separate fixed deadline that heartbeats cannot renew. The watchdog measures inactivity as processed on the serial gesture queue. When heartbeat and timeout compete, the first processed operation wins: a committed timeout cannot be reversed by a late report, even one captured earlier. Queued valid reports can keep a still-open gesture alive until one timeout after the last processed report, and queue starvation can delay cleanup. This is not a hardware-time or hard real-time guarantee.

## Permission startup

If synthetic event access is missing, the driver stays alive and waits before opening HID or starting gestures. It installs signal handlers first, makes at most one initial permission request sequence per process, and checks readiness without prompting every two seconds with 500 ms of timer leeway. Grant access to the executable or launcher identified in the log; startup continues automatically. SIGINT, SIGTERM, and normal stop cancel the wait and exit successfully. Cancellation cannot dismiss a dialog macOS has already shown.

Accessibility trust is required for target preparation even when restoration is disabled. CoreGraphics post-event access remains a separate check; the synthetic-posting compatibility rule accepts either grant, but neither check proves delivery to another app. Apple's [Accessibility API documentation](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions) specifies that its prompt is asynchronous and does not change the immediate return value. The [CoreGraphics request](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()) runs on a separate worker so a blocked request cannot hold up shutdown. Already-granted access is not requested again. Only state changes are logged while waiting.

Input Monitoring denial also leaves the same process waiting. Known denial prevents HID open. If opening reports `kIOReturnNotPermitted`, the driver waits until a later check positively reports HID access granted before trying again. Unknown access does not cause repeated open attempts after denial. Exclusive-device conflicts and other HID errors still fail startup and report the IOKit code. These waits address permission-related restart loops reported in [issue #1](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/issues/1); no persistent prompt marker or automatic permission settings changes are added.

Run `MacXeneonEdgeTouchDriver --check-permissions` for a JSON snapshot without opening HID, requesting grants or posting input. Exit status is zero only when required synthetic/Accessibility access and HID listen access are already granted; otherwise it is 77.

## Known Caveats

- This version targets a single Xeneon Edge panel in landscape orientation. The [hardware validation report](docs/HARDWARE-VALIDATION-2026-10-05.md) records corrective first-click, exact text-field restoration, all four focus/cursor settings, and power-recovery results, with their coverage limits. Rotations and multiple matching panels have not been validated.
- A silent or interrupted accepted contact still reaches the safety timeout (`timing.stuckGestureTimeoutMs`, 2,000 ms by default). Continued held reports after cancellation cannot restart that contact; release and touch again. The hardware session verified stationary-report liveness and release-then-fresh-touch recovery on one panel.
- Focus restoration is best effort. Observed physical mouse-down, typing or scrolling during a touch prevents restoration over that later choice. Changes observed after the accepted touch-up report, a newer gesture, shutdown, target invalidation, or a Space/session change stop further restoration work. HID reports and focus notifications can arrive late, so the software boundary cannot establish the exact physical finger-lift time. An AX request already sent to another app can still finish afterward; invalidation cannot undo it.
- With cursor return enabled, physical mouse movement during a touch does not change the saved return position. With it disabled, cleanup leaves the cursor at its current position rather than warping to an assumed final touch point.
- Multi-contact gestures are not supported as the hardware doesn't report this information back.
- If the process is killed with `SIGKILL`, normal shutdown cleanup cannot run. Relaunching the driver or moving the physical mouse after cursor association is restored may be needed.

## Troubleshooting

- If the driver is waiting for synthetic event permission, grant Accessibility to the exact executable or launcher shown in the log. It will continue without a restart.
- If the driver is waiting for HID listen access, grant Input Monitoring to the executable or launcher identified in the log. A positive grant resumes startup. For exclusive-device errors, confirm no other process has seized the same VID/PID device.
- If taps land on the wrong display, run `swift run DisplayInfo` and adjust the optional display config override.
- For HID investigation, stop the production daemon using the commands above, then run `swift run HIDDump`. The bundled diagnostic uses non-seize mode. Do not run a seizing build of HIDDump or another driver instance alongside the production daemon. Quit HIDDump before starting the installed LaunchAgent again. `swift run HIDDump --describe-input-cache` reports descriptors and cached-read errors without opening the device. Add `--open` for non-seize cached reads after stopping the driver; this mode requires an existing HID grant and neither prompts nor sends feature requests.

### Opt-in HID cache diagnostic

With one XENEON attached, all fingers lifted and the installed driver stopped, run:

```sh
XENEON_RUN_HARDWARE_TESTS=1 swift test --filter HIDRecoveryHardwareTests
```

This check uses the production cached-release reader, requires already-granted Input Monitoring, and closes its non-seize HID manager before returning. It posts no input and requests no permissions. It checks descriptor support, coherent initialized neutral values and rejection of stale release evidence. It does not replace a physical reconnect test. Restart the installed service afterward. Ordinary test runs skip this hardware check.


## Contributors

Thanks to [Greg Thompson (`isleofgreg`)](https://github.com/isleofgreg) for the per-touch-down display refresh proposal and moved-display regression test in [PR #4](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/pull/4), which this driver adapts.

Thanks to [Clark Hager](https://github.com/clarkhager) for the already-focused-window guard proposed in [PR #5](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver/pull/5). The focus restoration implementation retains that guard, with regression tests that verify it skips focus mutations when the target window is already focused.
