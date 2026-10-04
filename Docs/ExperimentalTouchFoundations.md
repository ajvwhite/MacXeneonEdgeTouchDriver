# Experimental touch foundations

This branch prepares optional touch features without enabling them in the driver. The normal secondary-dashboard interaction path keeps the existing configuration, single-touch decoding, click/drag timing, cursor cleanup, and focus restoration behavior.

## Runtime status

None of the experimental features can currently start live input. The explicit startup gate recognizes requests and reports why they are unavailable before constructing the application, input source, focus backend, permission coordinator, or HID monitor. Parser acceptance is not feature support.

The following command syntax is reserved for explicit experimental requests:

```sh
MacXeneonEdgeTouchDriver --experimental-config /absolute/path/to/experiment.json
```

An example request is:

```json
{
  "schemaVersion": 1,
  "features": ["spatialDoubleClick", "twoFingerScroll", "explicitRouting"]
}
```

Today this exits with status 78 and a readiness diagnostic. It does not run the driver or fall back to normal input. No installer, LaunchAgent, existing config, or hardware setting is changed. Without an experimental option, the original startup path is used and no experimental file is read.

Only this two-argument spelling is accepted; missing paths, repeated flags, `--experimental-config=...`, and unknown experimental options are rejected. Requests use a UTF-8 JSON object with exactly the two keys shown. The schema version must be 1 and the feature list must be nonempty, known, and unique. Unknown fields, duplicate object keys (including escaped equivalent spellings), unsupported types, unreadable files, and files larger than 64 KiB are rejected. A `verified: true` field cannot establish hardware readiness.

There are intentionally no persistent selectors, app allowlists, or tuning keys in this first request schema. Those contracts require evidence before they become user-facing configuration.

## Implemented inactive components

- Source epochs distinguish callback registrations across sessions and reconnections. Contact tokens include source, contact lifecycle sequence, and hardware contact ID. These are runtime identities, not proof of physical panel identity
- Binding models use explicit observed identities and reject ambiguity. Global cursor ownership is represented by a lease; another contact cannot take ownership until cleanup is acknowledged for the exact lease
- The pure double-click reducer classifies bounded source/context-matched tap sequences using receipt and proposed post times. Failed input, movement, cancellation, stale identity, and incomplete cleanup prevent pairing. It does not delay the first click or resolve an app recipient
- The pure two-contact reducer accepts complete, source-scoped contact frames. Two contacts must be present in the first admitted frame. It never turns an already admitted single-contact mouse press into scrolling
- An additive managed mouse-down overload accepts explicit single/double click metadata and freezes it for both fresh and reserved fallback mouse-up events. The existing managed and raw calls retain their metadata behavior. No production gesture path calls the experimental overload

The pure reducers only return decisions. They do not read HID reports, call AX, create scroll events, move a cursor, acquire permissions, or post input. Fake tests verify state and invocation contracts, not event delivery or application handling.

## Qualification still needed

The current captured hardware evidence reports single-touch input. Two interfaces from one controller must never be treated as two fingers, and a callback registration must not be mistaken for a physical panel.

A bounded live routing experiment first needs trace evidence that one attributed, exclusively selected endpoint supplies a complete contact lifecycle and maps uniquely to one selected display. Multiple bindings also need trustworthy physical grouping/provenance. Neither serial numbers nor USB location alone prove that relationship.

The owner model accepts trusted, ordered observations. A future adapter must reject stale queued neutral samples and route snapshots before calling it, advance revisions for geometry and topology changes, and avoid treating an old all-up observation as a fresh rearm. The reducer alone does not establish freshness for same-registration observations. If a scroll ownership request becomes invalid after a global lease was allocated but before began was accepted, the dispatcher must explicitly finish that rejected admission's exact lease; the scroll reducer cannot silently release another component's ownership.

A live spatial/time double-click trial would additionally need explicit opt-in, focus restoration disabled, source-scoped lifecycle attribution, bounded target-context assumptions, and invalidation for available app/Space/display changes. Matching revisions still cannot guarantee an unchanged recipient or absence of unrelated physical input. No per-app allowlist behavior is implemented or claimed.

Two-finger scrolling requires verified complete simultaneous-contact frames and stable contact identity from this hardware. The current single-touch report format and capability constant remain unchanged. A successful build does not establish any of these hardware capabilities.

## Validation

The original 475 XCTest identities are retained unchanged. New tests use explicit fake observations, complete frames, virtual timestamps, fake event factories/posters, and startup spies. Run the complete native test suite and debug/release builds before trying any new branch build. Hardware qualification is a separate, controlled step; no experimental runtime feature is currently enabled by these checks.
