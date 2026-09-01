# Display Topology Reconciliation Design

## Goal

Keep calibration overlays and touch mappings attached to the intended compatible display when displays are disconnected, replaced, rearranged, or assigned reused CoreGraphics display IDs. Never show `Touch this display` on an incompatible display, and never route touch through a stale runtime pairing.

## Observed failure

After replacing the connected display topology without rebooting, CoreGraphics reported one non-touch main display and two compatible touch displays with newly assigned runtime IDs.

The driver correctly chose a compatible touch display as the next pairing target, but its AppKit overlay window appeared at the main-display origin. A fresh process saw the correct `NSScreen` geometry while the long-running driver retained stale geometry. The pairing file also retained an older same-boot record in which the current main-display ID had described a touch panel, proving that numeric display IDs can be reused during one boot after a topology replacement.

Installation testing exposed a related persistence defect: deriving boot time from wall clock minus `ProcessInfo.systemUptime` changed after sleep because that uptime does not include the full sleeping interval on this Mac. The documented Darwin `sysctlbyname` interface exposes `KERN_BOOTTIME` as a `timeval`; that kernel value becomes the boot-session authority. If it is unavailable, the driver uses a namespaced conservative fallback that may request extra calibration but cannot match a kernel-backed marker accidentally.

## Considered approaches

### Restart after every topology change

Restarting refreshes AppKit and currently works as a manual recovery step. It does not protect a user who reconnects displays while the LaunchAgent remains running, and it leaves stale runtime pairings in storage. This is a workaround, not the fix.

### Validate only persisted pairings

Comparing the stored display vendor, model, and serial with the current display prevents a reused ID from resolving to an incompatible display. It does not prevent AppKit from placing a correctly targeted calibration window on the wrong screen while its screen geometry is settling.

### Layered reconciliation

The selected approach validates both identity and presentation. It rejects stale runtime pairings, treats public add/remove callbacks as topology changes, waits for AppKit and CoreGraphics to agree on target geometry, and verifies the window after presentation. This keeps ordinary bounds-only rearrangement automatic while requiring calibration after an ambiguous endpoint replacement.

## Pairing authority

A same-boot runtime pairing is valid only when all of the following remain true:

- the controller location ID is attached;
- the saved controller serial agrees with the current public serial value;
- the saved display ID is still among compatible displays;
- the current display vendor, model, and serial agree with the saved descriptor.

Invalid same-boot pairings are removed atomically. Hardware-scoped pairings continue to resolve across runtime-ID changes only under the existing uniqueness rules.

Loading persistence also prunes records from older boot sessions and rewrites the file. This prevents ignored runtime IDs from accumulating or becoming visible as apparently current state. The kernel boot time, not process uptime, defines the current boot session.

An explicit HID removal invalidates that controller's boot-session pairing. A CoreGraphics add, remove, enable, or disable event ends the current calibration presentation and schedules reconciliation after the display transaction. Bounds-only movement, main-display changes, and mode changes retain pairings and update the mapper from live bounds.

## Overlay readiness and placement

`PairingOverlayController` must treat display placement as a checked operation:

1. Resolve a fresh `NSScreen` by `NSScreenNumber` on the main thread; never cache `NSScreen` instances.
2. Convert the target CoreGraphics bounds into AppKit global coordinates using the current primary screen coordinate relationship.
3. Require the resolved screen frame to match those expected bounds within a small floating-point tolerance.
4. Create and place the borderless window only after that agreement exists.
5. After ordering the window, verify its screen number and frame still match the target.
6. If any check fails, hide the window, return `false`, and let the existing bounded readiness retry reconcile again.

The overlay does not join every Space. It remains stationary on its selected display and may participate as a fullscreen auxiliary window without being eligible for relocation across displays.

## Reconfiguration flow

The CoreGraphics callback forwards the display ID and documented change flags. A begin-configuration callback immediately hides calibration and marks the display transaction unsettled. Post-change callbacks distinguish membership changes from bounds-only changes, then schedule the existing debounced reconciliation. The AppKit screen-parameters notification remains the readiness signal for refreshed `NSScreen` state.

Touches received while the overlay is hidden or rejected cannot create a pairing or synthetic input. A touch pairs a controller only while a verified overlay is visibly assigned to the current target.

## Failure handling

- A reused display ID with different public descriptors is rejected and removed from same-boot persistence.
- Missing or mismatched AppKit geometry produces a readiness retry, not a main-screen fallback.
- Exhausted retries leave touch unrouted and wait for the next HID or display event.
- Removal during an active touch cancels only that device session and invalidates only ambiguous runtime authority.
- Persistence errors remain logged and do not authorize routing.

## Verification

Automated tests cover:

- same-boot display-ID reuse with a different vendor/model/serial;
- same-boot controller-location reuse with a different public serial;
- stable kernel boot identity across sleep and a conservative fallback when it is unavailable;
- physical pruning of records from expired boot sessions;
- pruning obsolete compatible-display records;
- preserving a pairing across a bounds-only rearrangement;
- invalidating boot-session authority after controller removal;
- hiding and retrying calibration when AppKit geometry disagrees;
- accepting the overlay only when screen ID and frame agree;
- preventing touch from pairing while presentation is unverified;
- all existing routing, gesture, focus, startup, persistence, and configuration behavior.

Acceptance finishes with warnings-as-errors tests, a release build, signed local installation, and live verification with a non-touch main display plus two matching touch panels. The overlay must appear only on the requested touch panel after a topology change.

## Release boundary

This fix is committed and installed locally. Updating the existing pull request requires separate explicit approval.
