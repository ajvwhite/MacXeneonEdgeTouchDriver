# Changelog

## Unreleased

- Check the current target display before each touch-down, so missed display callbacks no longer leave taps at an old origin.
- Drop new touches when the target is missing or has invalid bounds, instead of using its last-known coordinates. A configured display serial must match; it no longer falls back to another same-model panel. Without a configured serial, the existing pixel-size preference remains.
- Pause routing during display reconfiguration and refresh after the change. Release owned input, return the cursor, and invalidate pending gesture and focus work before a changed mapping can drive another touch.

## 1.0.0 - 2026-05-03

- Initial release of the single-touch Mac Xeneon Edge Touch Driver.
- Supports single tap, touch-hold drag, and drag-to-select using cursor borrow and return.
- Includes user-level install, uninstall, and release build scripts.
- Creates default user configuration and writes driver diagnostics to `~/Library/Logs/MacXeneonEdgeTouchDriver/driver.log`.
- Honors configured file-log verbosity and covers delayed gesture sequencing in tests.
- Recovers display mapping automatically after HID or display hotplug events.
- Writes file diagnostics using the machine's local timezone.
- Restores focus to the exact previously focused window after touch gestures.
