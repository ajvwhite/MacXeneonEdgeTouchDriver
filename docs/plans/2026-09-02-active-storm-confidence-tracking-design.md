# Active Storm Confidence Tracking Design

## Goal

Keep a touchscreen usable when its controller is continuously producing the already observed incoherent HID report storm. Preserve the ordinary low-latency path while the controller is healthy, switch only the affected controller into a conservative confidence-tracking mode after a storm is confirmed, and return it to normal automatically after the raw stream becomes quiet.

Safety remains the primary boundary: ambiguous data must not become clicks, scrolling, dragging, cursor movement, or focus changes. Confidence tracking can recover a real finger only when genuine samples remain distinguishable as a spatially and temporally coherent path inside the mixed report stream. Software cannot reconstruct a finger position if the controller completely replaces real samples with unrelated coordinates.

## Per-controller operating modes

Every `DeviceTouchSession` owns an independent validator and storm state.

### Normal

Normal mode keeps the existing fast plausibility checks. A contact begins as a short candidate and cannot start a hold timer or synthesize input until the candidate is plausible. Stable taps are emitted as a buffered down/up pair when released, while coherent motion is released after the short probation window.

An impossible speed, repeated discontinuity, overlapping raw down, or chaotic path confirms a storm and moves only that controller into storm mode. Any pending unconfirmed contact is discarded without synthetic cleanup because no synthetic input has begun.

### Storm active

Storm mode replaces whole-controller quiet-period suppression with a bounded confidence tracker:

- it retains a fixed-size, short rolling window of raw samples;
- it acquires a finger only after several samples form a stable cluster or a physically continuous trajectory;
- it accepts samples that remain within the acquired path's distance and speed gate;
- it treats distant coordinate jumps, overlapping downs, and isolated releases as outliers rather than canceling the whole controller;
- it ends an acquired contact after no inlier sample has appeared for a bounded interval;
- it emits a tap only after a stable acquired contact and a confident release;
- it never forwards an unconfirmed down to gesture synthesis.

The tracker uses constant-size state and constant-time calculations per HID report. There is no unbounded clustering, history, or per-report file logging.

### Recovery

The working mouse interface is normally silent while untouched. Recovery therefore uses raw-report silence rather than trying to infer health from application gestures.

When storm mode begins, the application creates one documented GCD `DispatchSourceTimer` for that controller on the existing serial gesture queue. It repeats once per second with timer leeway. Incoming HID reports only update the validator's monotonic `lastReportTimestamp`; they do not create or reschedule timers.

On each tick, the driver compares the current monotonic time with the last raw report. One full second of silence ends storm mode, cancels the timer, resets confidence state, and restores normal validation. A continuous storm causes only one timer callback per second. No timer exists outside storm mode.

If an intermittent storm returns after recovery, normal probation prevents the new burst from producing synthetic input and immediately re-enters storm mode.

## Event flow

1. `HIDDeviceMonitor` parses a raw report into a per-controller `DeviceTouchEvent`.
2. `TouchStreamValidator` processes the event in normal or storm mode.
3. The validator returns zero or more validated events plus explicit storm lifecycle information.
4. The application starts or stops that controller's recovery timer from lifecycle transitions.
5. Only validated events reach `GestureController`.
6. The gesture controller borrows the cursor or synthesizes input only after validation has emitted a confirmed contact.

The other controller's validator, timer, gesture state, pairing, and mapper remain independent.

## Diagnostics

Storm diagnostics are incident-oriented rather than report-oriented:

- entry: controller identity, monotonic/wall-clock start, and detection reason;
- periodic summary: duration, total reports, acquired inliers, rejected outliers, ignored raw transitions, and recovered contacts;
- exit: last-report time, confirmation time, duration, and aggregate totals;
- re-entry: a new incident with a new summary.

A bounded sample of reports surrounding storm entry may be retained for diagnostics. The production log must not write every 120 Hz report or grow unboundedly.

## Failure handling

- If confidence never becomes sufficient, the controller remains safe but unavailable for gestures.
- If an acquired track loses confidence, the driver ends scrolling safely but does not convert the ambiguous contact into a tap.
- Storm recovery never generates synthetic input.
- Device removal cancels the recovery timer and discards all validator state.
- Display reconciliation or pairing loss cancels active gestures, timers, and confidence state for the affected session.
- Driver shutdown cancels all timers before releasing HID seizure.

## Verification

Automated tests must cover:

- unchanged healthy tap, double-click, scroll, fast swipe, and hold-to-drag behavior;
- no hold timer or synthetic input before normal probation succeeds;
- transition from normal to storm mode with an explicit reason;
- coherent stationary taps extracted from interleaved random storm samples;
- coherent moving paths extracted while distant storm samples are discarded;
- isolated false releases and overlapping downs ignored during an acquired track;
- ambiguous storm data producing no gestures;
- one controller storming while the other remains fully functional;
- one recovery timer per storming controller and no timer in normal mode;
- no per-report timer churn;
- recovery after one second of raw silence, with lifecycle summaries;
- renewed storm detection after recovery;
- device removal and application shutdown canceling recovery timers.

Physical verification should exercise single taps, double-clicks, slow and fast scrolling, and hold-to-drag on both panels in healthy mode. While a spontaneous storm is active, the affected panel should accept coherent intentional gestures without allowing the background reports to move the cursor or activate unrelated UI.
