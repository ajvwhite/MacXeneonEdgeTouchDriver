# Changelog

## Unreleased

- Uses documented IOHID, CoreGraphics, AppKit, and Foundation APIs for dynamic multi-display pairing and display-change observation.
- Reuses exact runtime assignments only within the current boot and restores across boots only when both public hardware identities are unique.
- Requests calibration after reboot for identical panels with duplicate controller serials or zero display serials instead of guessing from display position.
- Debounces HID and display changes, follows live display bounds, and retries calibration presentation while AppKit finishes login-time display enumeration.
- Migrates version-one runtime UUID pairings safely to an atomic version-two pairing file.
- Lets local installers supply a stable signing identity so macOS privacy approval can survive executable upgrades.
- Recognizes a fast second tap even when it arrives during the first click's delayed cleanup and emits the macOS click-count sequence `1`, then `2`.
- Restores the previously focused application and exact window with documented activation and Accessibility APIs, without a synthetic title-bar click.
- Rejects same-boot controller or display IDs when their current public descriptors no longer match the saved pairing.
- Invalidates ambiguous runtime pairings on hardware membership changes while preserving mappings across bounds-only rearrangement.
- Verifies AppKit screen identity and geometry before showing calibration, retrying instead of placing the overlay on another display.
- Uses the documented kernel boot time for same-boot persistence so sleep does not invalidate pairings, and prunes expired runtime records on load.
- Rejects physically implausible per-controller touch storms before they can move the cursor or produce clicks, scrolling, or dragging, without disabling other attached touchscreens.
- Switches only a confirmed storming controller into bounded confidence tracking so coherent intentional taps and movement can be recovered from interleaved outliers.
- Logs storm entry, periodic aggregate activity, and automatic recovery after one second of raw-report silence using a storm-only one-second GCD interval.
- Holds unconfirmed normal contacts outside gesture synthesis, preventing the hold-to-drag timer from turning an initial storm report into a click.
- Extends `HIDDump` with wall-clock timestamps and dynamic controller location IDs for evidence-based multi-controller diagnostics.

## 1.0.0 - 2026-05-03

- Initial release of the single-touch Mac Xeneon Edge Touch Driver.
- Supports single tap, touch-hold drag, and drag-to-select using cursor borrow and return.
- Includes user-level install, uninstall, and release build scripts.
- Creates default user configuration and writes driver diagnostics to `~/Library/Logs/MacXeneonEdgeTouchDriver/driver.log`.
- Honors configured file-log verbosity and covers delayed gesture sequencing in tests.
- Recovers display mapping automatically after HID or display hotplug events.
- Writes file diagnostics using the machine's local timezone.
- Restores focus to the exact previously focused window after touch gestures.
