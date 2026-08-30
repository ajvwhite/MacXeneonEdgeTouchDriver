# Changelog

## Unreleased

- Uses documented IOHID, CoreGraphics, AppKit, and Foundation APIs for dynamic multi-display pairing and display-change observation.
- Reuses exact runtime assignments only within the current boot and restores across boots only when both public hardware identities are unique.
- Requests calibration after reboot for identical panels with duplicate controller serials or zero display serials instead of guessing from display position.
- Debounces HID and display changes, follows live display bounds, and retries calibration presentation while AppKit finishes login-time display enumeration.
- Migrates version-one runtime UUID pairings safely to an atomic version-two pairing file.
- Lets local installers supply a stable signing identity so macOS privacy approval can survive executable upgrades.

## 1.0.0 - 2026-05-03

- Initial release of the single-touch Mac Xeneon Edge Touch Driver.
- Supports single tap, touch-hold drag, and drag-to-select using cursor borrow and return.
- Includes user-level install, uninstall, and release build scripts.
- Creates default user configuration and writes driver diagnostics to `~/Library/Logs/MacXeneonEdgeTouchDriver/driver.log`.
- Honors configured file-log verbosity and covers delayed gesture sequencing in tests.
- Recovers display mapping automatically after HID or display hotplug events.
- Writes file diagnostics using the machine's local timezone.
- Restores focus to the exact previously focused window after touch gestures.
