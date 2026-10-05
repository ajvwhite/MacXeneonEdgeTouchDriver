# Changelog

## Unreleased

- Prevent early mouse-button release during a stationary hold while touch reports continue. Keep other HID interfaces from interrupting the active touch. Silent input still uses the default two-second safety timeout. A disconnect during a touch may require lifting and tapping again after reconnect. A single-panel hardware session verified stationary hold, drag, fresh taps and recovery after a neutral release. See [hardware validation](docs/HARDWARE-VALIDATION-2026-10-05.md) for results and limits.

- Stop routing touch input when multiple valid displays are equally preferred, including duplicate reported serials. Detected ambiguity cancels any active gesture and clears stale mapping; routing resumes when a unique best match is found. Configured serial filtering stays strict and expected-size preference is unchanged.
- Keep mapped touch points inside the target rectangle by clamping the final global coordinates below its excluded maximum edges. Existing interior coordinates stay unchanged. Reject bounds whose positive dimensions round to equal minimum and maximum edges. This establishes mathematical containment; live click routing at display boundaries remains unverified.
- Refresh display matching and geometry before each touch-down.
- Add optional signing of the staged executable with `CODESIGN_IDENTITY` during installation. Signing and signature verification must succeed before installed files are replaced.

## 1.0.0 - 2026-05-03

- Initial release of the single-touch Mac Xeneon Edge Touch Driver.
- Supports single tap, touch-hold drag, and drag-to-select using cursor borrow and return.
- Includes user-level install, uninstall, and release build scripts.
- Creates default user configuration and writes driver diagnostics to `~/Library/Logs/MacXeneonEdgeTouchDriver/driver.log`.
- Honors configured file-log verbosity and covers delayed gesture sequencing in tests.
- Recovers display mapping automatically after HID or display hotplug events.
- Writes file diagnostics using the machine's local timezone.
- Restores focus to the exact previously focused window after touch gestures.
