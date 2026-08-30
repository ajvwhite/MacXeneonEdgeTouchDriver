# Double-Click Design

## Goal

Make two deliberate taps behave like a standard macOS double-click while keeping single taps immediate and leaving scroll and hold-to-drag behavior unchanged.

## Behavior

- The first completed tap posts mouse-down and mouse-up with click count `1` immediately.
- A second completed tap posts click count `2` when it lands within a configurable point-distance tolerance and within `NSEvent.doubleClickInterval` of the first tap.
- The sequence resets after click count `2`; triple-click is deliberately unsupported.
- A distant tap, a late tap, scrolling, dragging, cancellation, or timeout resets the pending double-click sequence.
- Click counting remains isolated per controller/display session.

## Architecture

- Extend `SyntheticInputSink` so mouse-down and mouse-up carry an explicit click count.
- `CGEventInputSink` writes that value to `mouseEventClickState` on both events.
- `GestureController` retains only the last eligible tap's completion timestamp and mapped point.
- `MacXeneonEdgeTouchDriverApplication` supplies the live macOS double-click interval through an injected provider.
- Add `gesture.doubleClickDistancePoints` as an optional backward-compatible configuration value.

## Verification

Tests cover a successful double-click, taps outside the time or distance tolerance, reset after the second click, and reset after non-tap gestures. Existing tap, scrolling, hold-to-drag, routing, and persistence tests must continue to pass, followed by a release build and local reinstall.

## Release Boundary

This change remains local and unpushed. PR #3 is not modified without separate explicit approval.
