# Supported touch pairing and reconciliation design

## Goal

Route each touchscreen to its paired display without guessing from display position. Reuse a pairing across driver restarts in the same boot and across boots only when both endpoints expose genuinely unique hardware identities. Require `Touch this display` after a reboot when identical hardware makes the relationship ambiguous.

## Identity model

CoreGraphics display IDs and USB HID location IDs identify current runtime endpoints. They are valid pairing authority only for the current boot. The implementation uses documented CoreGraphics, AppKit, Foundation, and IOHID APIs; it does not bridge unavailable symbols, inspect private I/O Registry properties, or use legacy display-service APIs.

A saved pairing records runtime identifiers, the current boot-session marker, and available public hardware descriptors. A pairing may cross a boot only when the controller and display descriptors are both non-empty and unique among the recorded and currently attached compatible endpoints. Identical EDID data, zero display serials, and duplicate USB serials must never silently collapse two devices into one identity.

Display bounds are never identity evidence. Once a display has been resolved, its live CoreGraphics bounds convert panel-local touch coordinates into the global desktop coordinates required by synthetic mouse events. Arrangement, resolution, and bounds changes therefore update routing without changing the pairing.

## Reconciliation

The driver reconciles the current HID controllers, compatible CoreGraphics displays, and saved versioned pairings after enumeration settles:

1. Reuse an exact runtime pairing when its boot-session marker still matches and both endpoints remain attached.
2. Across boots, reuse only a pairing whose public controller and display hardware identities both resolve uniquely.
3. Leave every ambiguous or missing association unresolved instead of guessing.
4. Present `Touch this display` for unresolved compatible displays one at a time.
5. Persist the new association atomically with the current boot-session marker and public descriptors.

Enumeration is event-driven and debounced rather than based on an assumed display count. Display reconfiguration, AppKit screen-parameter changes, HID arrival, and HID removal all schedule reconciliation. A bounded retry handles the interval where CoreGraphics has announced a display but AppKit cannot yet create a window on its `NSScreen`.

## Safety and ambiguity

The driver must never guess a controller-to-display relationship from left-to-right order, display coordinates, enumeration order, stale runtime identifiers, or model name alone. Display order is used only to choose which unpaired display shows the next calibration prompt. While a pairing is unresolved, events from that controller are consumed but do not create synthetic mouse input.

Hotplug or a display-bounds change triggers reconciliation. Exact current-boot mappings survive ordinary rearrangement and driver restart. Identical devices whose public identifiers cannot prove their relationship require calibration once in each new boot session.

## Persistence and migration

The pairing file moves to a version-two schema. Existing version-one runtime-ID/UUID pairings are parsed safely but never trusted across the migration because neither endpoint can be proven. The first run after upgrade requests calibration and writes the new schema atomically.

The boot-session marker is derived from documented Foundation wall-clock and system-uptime values. If clock correction makes the marker uncertain, the safe failure mode is another calibration rather than an incorrect click destination.

## Verification

Tests must cover:

- same-boot process restart with unchanged runtime identifiers;
- new boot with ambiguous or changed runtime identifiers;
- cross-boot restoration only with unique public hardware descriptors;
- identical display EDID and duplicate USB serial values;
- live display-bound changes with unchanged topology;
- staged login enumeration and debounced reconciliation;
- CoreGraphics/AppKit screen-readiness lag and overlay retry;
- hot removal and reattachment affecting only the relevant pairing;
- safe version-one migration and atomic version-two persistence.

The full existing gesture, focus, display, configuration, and logging test suite remains part of acceptance.
