# Settings

Most people can use the defaults. To enable one-finger scrolling:

1. In Finder, choose Go > Go to Folder and paste `~/Library/Application Support/MacXeneonEdgeTouchDriver`.
2. Open `config.json` with a plain-text editor and make a copy before changing it.
3. Find the `"gesture"` section. Inside it, find `"mode": "direct"` and change only `"direct"` to `"scroll"`. Keep the quotation marks and comma, and leave the rest of the file as it is.
4. Save the file and [restart the driver](TROUBLESHOOTING.md#restart-the-driver).

The `~` in the folder path means your home folder. The reference below describes the other settings. To leave the cursor on the Edge, set `cursor.returnToPreviousPosition` to `false`; to keep the touched app active, set `focus.restorePreviousWindow` to `false`.

The installer creates this settings file:

```text
~/Library/Application Support/MacXeneonEdgeTouchDriver/config.json
```

All fields are optional. Edit the existing file with a plain-text editor, keep its JSON format, then [restart the driver](TROUBLESHOOTING.md#restart-the-driver). At runtime, a missing or malformed config falls back to defaults and logs a warning. The installer instead rejects an invalid existing file before replacing anything.
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

For details about holds and reconnect recovery, see the [technical reference](TECHNICAL-REFERENCE.md#held-touches-and-usb-reconnect).
