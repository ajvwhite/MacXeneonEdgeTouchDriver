# Changelog

## Unreleased

- Prepare and confirm the touched application/window before posting its first click. Buffer contact movement and release during preparation; reject an unconfirmed target without a speculative click. Inactive Safari sibling-window counter hits passed on the tested single-panel setup.
- Capture the exact keyboard-focus control for restoration. Revoke restoration after observed physical mouse-down, typing or scrolling. Restore a captured control only through supported operations; do not substitute a window-only raise. Handle verified floating panels and windowless foreground applications without replacing the captured typing recipient. Browser and demo Stream Deck typing restoration passed on the tested setup.
- Check coherent cached release values on supported replacement HID endpoints after source loss, and reject raw packets older than that release. Retain the release barrier when evidence is unavailable. Qualify complete monitor power resets separately from cached release; first-tap delivery passed after idle reconnect and interrupted held contacts on the captured controller/hub profile.
- Buffer fresh contacts during synthetic mouse-up cleanup within fixed event/contact limits. Preserve their moves and releases without shortening the previous press, and let them finish cursor cleanup after mouse-up. Renew held-contact watchdog deadlines without allocating a delayed task for every report.
- Keep the same driver process waiting after Input Monitoring denial. Retry HID open only after access is positively granted, and expose read-only permission and cached-input diagnostics.

- Prevent early mouse-button release during a stationary hold while touch reports continue. Keep other HID interfaces from interrupting the active touch. Silent input still uses the default two-second safety timeout. Unqualified replacement hardware retains the release barrier; the qualified power-reset path accepts the first fresh tap on the tested profile. A single-panel hardware session verified stationary hold, drag, fresh taps and recovery after a neutral release. See [hardware validation](docs/HARDWARE-VALIDATION-2026-10-05.md) for results and limits.

- Stop routing touch input when multiple valid displays are equally preferred, including duplicate reported serials. Detected ambiguity cancels any active gesture and clears stale mapping; routing resumes when a unique best match is found. Configured serial filtering stays strict and expected-size preference is unchanged.
- Keep mapped touch points inside the target rectangle by clamping the final global coordinates below its excluded maximum edges. Existing interior coordinates stay unchanged. Reject bounds whose positive dimensions round to equal minimum and maximum edges. This establishes mathematical containment; four named corner controls passed on the tested nonzero-origin display; rotations and multiple panels remain unvalidated.
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
