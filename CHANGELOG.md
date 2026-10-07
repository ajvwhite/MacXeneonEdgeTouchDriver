# Changelog

## Unreleased

- Check inconsistent touch reports and track clear, deliberate touches through noise. Release a track when it loses support, then recover automatically when the stream settles.
- Add double-clicks for nearby taps on the same window and control, with an option to keep separate clicks.
- Add optional single-finger scrolling. Quick taps click; holding before moving starts a drag. Direct dragging remains the default.
- Skip outdated movement during established drags while preserving the first movement, final point and button release.
- Use Interactive process scheduling for the installed service to avoid background timer delays.
- Add optional timing summaries and offline report replay to investigate performance without posting mouse input.

- Make the first tap work on an inactive window by preparing it before sending the click. If the window cannot be confirmed, drop the touch rather than click an uncertain target.
- Return typing to the original text field after touch, including after virtual Stream Deck actions. Later mouse clicks, typing or scrolling cancel further focus restoration.
- Recover the first fresh tap after USB reconnect on the tested controller and hub, including disconnects during a held touch. Other hardware still requires a release before accepting a new touch.
- Keep stationary holds active while touch reports continue. Missing reports still trigger the default two-second safety timeout. Other USB interfaces can no longer interrupt the active touch.
- Let fresh taps wait briefly for the previous mouse-button release, within fixed queue and time limits. Preserve movement and release order, and use one pending timer for the hold timeout.
- Wait for Input Monitoring permission in the same process instead of repeatedly restarting. Add commands to check permissions and inspect saved USB input values without requesting access.
- Recognise new permission approvals even when macOS keeps an old answer. Refresh startup once if needed, with a limit that prevents repeated restarts.
- Close failed device-open attempts before retrying, and keep focus restoration working after a temporary device-access failure.
- Pause touch input when several displays match equally well. Resume once there is one clear match, instead of guessing or keeping an outdated display mapping.
- Keep touch coordinates inside the target display, including its outer edges. Refresh the display selection and position before each touch.
- Add optional signing during installation with `CODESIGN_IDENTITY`. Sign and verify the new executable before replacing installed files.

## 1.0.0 - 2026-05-03

- Initial release of the single-touch Mac Xeneon Edge Touch Driver.
- Supports tapping, holding to drag, and dragging to select. Returns the cursor to its previous position afterward.
- Includes user-level install, uninstall, and release build scripts.
- Creates default user configuration and writes driver diagnostics to `~/Library/Logs/MacXeneonEdgeTouchDriver/driver.log`.
- Uses the configured log level and includes tests for click timing.
- Updates the touch display automatically when USB or display connections change.
- Writes file diagnostics using the machine's local timezone.
- Restores focus to the exact previously focused window after touch gestures.
