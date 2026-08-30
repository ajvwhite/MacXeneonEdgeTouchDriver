# Double-Click Design

## Goal

Make two deliberate taps behave like an uninterrupted standard macOS double-click while keeping the first click immediate, returning the cursor promptly, restoring the previously focused application and exact window, and leaving scroll and hold-to-drag behavior unchanged.

The driver must never synthesize a focus-restoration mouse click. Every synthetic mouse event must represent the user's touch at the mapped touchscreen point.

## Behavior

- The first completed tap posts mouse-down and mouse-up with click count `1` immediately.
- A second completed tap posts click count `2` when it lands within a configurable point-distance tolerance and within `NSEvent.doubleClickInterval` of the first tap.
- A legitimate second touch is accepted even if it begins during the first click's delayed mouse-up or cursor-return cleanup. The first cleanup completes immediately and the second contact continues the same click sequence.
- Tap debounce does not reject a second touch that is otherwise eligible for the current double-click sequence.
- The sequence resets after click count `2`; triple-click is deliberately unsupported.
- A distant tap, a late tap, scrolling, dragging, cancellation, or timeout resets the pending double-click sequence.
- Click counting remains isolated per controller/display session.
- Cursor return remains prompt after each completed click.
- Focus restoration is deferred while a second click remains possible. A double-click restores focus immediately after its second mouse-up; a single click restores focus after the system double-click interval expires.

## Architecture

- Extend `SyntheticInputSink` so mouse-down and mouse-up carry an explicit click count.
- `CGEventInputSink` writes that value to `mouseEventClickState` on both events.
- `GestureController` owns a tap-sequence transaction containing the first eligible tap, the original focus capture, and scheduled focus finalization.
- The controller can finish a pending first mouse-up/cursor return synchronously when a valid second down arrives, rather than dropping that contact.
- `MacXeneonEdgeTouchDriverApplication` supplies the live macOS double-click interval through an injected provider.
- Add `gesture.doubleClickDistancePoints` as an optional backward-compatible configuration value.
- `AXFocusRestorer` captures the application process and exact window. Restoration activates the captured `NSRunningApplication` with default documented options, then assigns and raises the exact Accessibility window.
- Focus restoration contains no `CGEvent`, cursor warp, screen-coordinate guess, or title-bar hit testing. Failure is logged and never falls back to a click.

## Event order

For a double-click:

1. Capture the previously focused application and window.
2. Post touchscreen mouse-down/up with click count `1`.
3. Return the cursor, retain the focus transaction, and wait for the remaining double-click interval.
4. Accept the eligible second touch and post touchscreen mouse-down/up with click count `2`.
5. Return the cursor and restore the captured application and exact window without mouse input.

For a single click, steps 1-3 are identical. When the interval expires without an eligible second touch, restore focus without mouse input.

A distant or incompatible next gesture closes the previous focus transaction before it begins its own independent gesture transaction.

## Verification

Automated tests cover:

- a successful ordinary double-click with click counts `1` then `2`;
- a fast second down during first-click cleanup;
- bypassing debounce only for a valid second-click candidate;
- immediate first-click delivery and prompt cursor return;
- one deferred focus restoration after a single click;
- one post-sequence focus restoration after a double-click;
- no focus restoration between the two clicks;
- taps outside the time or distance tolerance and resets after click two or non-tap gestures.

A source audit verifies that the focus restorer contains no synthetic mouse event or coordinate-based title-bar logic. Local signed acceptance verifies exact application/window activation and confirms that failures log without clicking.

Existing tap, scrolling, hold-to-drag, routing, persistence, and startup tests must continue to pass with warnings treated as errors, followed by a release build and local signed reinstall. Manual acceptance covers Spotify track playback and a browser double-click target; neither receives app-specific code.
