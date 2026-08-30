# Topology-based touch pairing design

## Goal

Preserve touchscreen calibration across login, reboot, and ordinary device enumeration changes without guessing a display from its current position. Require `Touch this display` only when a physical connection route changes or the available identities are genuinely ambiguous.

## Identity model

CoreGraphics display IDs and UUIDs and complete USB HID location IDs are runtime observations, not persisted pairing authority. A saved pairing associates a normalized touchscreen connection fingerprint with a normalized display connection fingerprint.

Each fingerprint retains enough descriptive data for diagnostics, but matching is based on connection topology. Identical EDID data, zero display serials, and duplicate USB serials are expected and must not silently collapse two devices into one identity.

Display bounds are never identity evidence. Once a display connection has been resolved, its live CoreGraphics bounds define the coordinate destination and automatically follow arrangement changes.

## Reconciliation

The driver builds a live topology snapshot after HID and display enumeration settles. It compares that snapshot with saved versioned pairings:

1. If both saved connection fingerprints resolve uniquely, bind the current runtime HID and CoreGraphics identifiers without calibration.
2. If an affected connection fingerprint changed or no longer resolves uniquely, leave only that pairing unresolved.
3. Present `Touch this display` for unresolved compatible displays one at a time.
4. Persist the newly calibrated topology association and keep runtime identifiers session-local.

Enumeration is event-driven and debounced rather than based on an assumed display count. Display reconfiguration, AppKit screen-parameter changes, HID arrival, and HID removal all schedule reconciliation. A bounded retry handles the interval where CoreGraphics has announced a display but AppKit cannot yet create a window on its `NSScreen`.

## Safety and ambiguity

The driver must never guess from left-to-right order, display coordinates, enumeration order, stale UUIDs, or model name alone. While a pairing is unresolved, events from that controller are consumed but do not create synthetic mouse input.

A physical route change is treated as a potentially new arrangement and requires calibration for the affected route. Unchanged normalized topology may reuse calibration even when macOS assigns different runtime IDs after reboot.

## Persistence and migration

The pairing file moves to a versioned topology schema. Existing version-one runtime-ID pairings are read safely but are not silently trusted when their endpoints cannot be proven against current topology. The first run after upgrade may request one calibration pass and then writes the new schema atomically.

## Verification

Tests must cover:

- unchanged topology with changed USB location IDs and display UUIDs;
- identical display EDID and duplicate USB serial values;
- changed USB or display connection routes requiring calibration;
- live display-bound changes with unchanged topology;
- staged login enumeration and debounced reconciliation;
- CoreGraphics/AppKit screen-readiness lag and overlay retry;
- hot removal and reattachment affecting only the relevant pairing;
- safe version-one migration and atomic version-two persistence.

The full existing gesture, focus, display, configuration, and logging test suite remains part of acceptance. Installation is local only unless the user separately approves a PR update.
