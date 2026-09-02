# Changelog

## Unreleased

- Re-resolves the Xeneon Edge display bounds on each touch-down so taps stay accurate after the display is rearranged in System Settings, even when no display reconfiguration callback is delivered to the background LaunchAgent. The last-known mapping is kept if the panel is momentarily absent.
- `install.sh` honours `CODESIGN_IDENTITY` so rebuilt binaries keep their Accessibility and Input Monitoring grants.

## 1.0.0 - 2026-05-03

- Initial release of the single-touch Mac Xeneon Edge Touch Driver.
- Supports single tap, touch-hold drag, and drag-to-select using cursor borrow and return.
- Includes user-level install, uninstall, and release build scripts.
- Creates default user configuration and writes driver diagnostics to `~/Library/Logs/MacXeneonEdgeTouchDriver/driver.log`.
- Honors configured file-log verbosity and covers delayed gesture sequencing in tests.
- Recovers display mapping automatically after HID or display hotplug events.
- Writes file diagnostics using the machine's local timezone.
- Restores focus to the exact previously focused window after touch gestures.
