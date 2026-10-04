# Experimental gesture foundations

These are pure value/state models, not enabled driver features. They do not open
HID devices, interpret report bytes, create or post CGEvents, move the cursor,
read Accessibility state, or identify an application. The production gesture path
and its default one-finger click/drag behavior remain unchanged.

## Scope and identity

Inputs explicitly carry registration epoch, logical contact token, route identity,
binding/topology revisions, policy revision, available activation revision and
target-observation revision. Bounds, identity, membership and rotation changes
must advance topology revision. Equal revision numbers only mean the caller has
not reported a change; they do not prove an unchanged event recipient.

Contact sequences are source-wide monotonic **contact lifecycle** numbers, not
frame numbers or a shared two-finger-session generation. Each newly started
contact receives a distinct sequence, even when two contacts first appear in
one frame. It retains that sequence until lift; changing frame order changes
neither lifecycle token. The eventual decoder owns truthful allocation.

The shared global arbiter supplies a non-reused owner lease. One double-click
reducer belongs to one owner session; one scroll reducer additionally belongs to
one source registration epoch. Replace a reducer only after its old lease has
been safely retired. Never use replacement to forget unresolved input ownership.

## Double-click model

`ExperimentalDoubleClickReducer` proposes counts 1, 2, 1, 2. It never proposes
triples. A first-click candidate is created only after a successful down, release
and matching cleanup acknowledgment. Movement, cancellation, failed input,
observed context changes and conflicting new admission invalidate pairing.
Delayed callbacks for an older lease cannot invalidate a newer press.

The caller supplies both report-receipt times and poster-boundary time samples,
on the same monotonic nanosecond clock. The down sample is taken immediately
before the proposed post, because the count must be chosen first. It does not
retrospectively establish when a delayed poster ran or when the OS delivered an
event. Down-to-down intervals must fit the supplied interval on both timelines.
A new down cannot pair with
timestamps before the previous release. This is a deliberately conservative
driver policy, not an implementation of every macOS mouse heuristic. There is no
change to debounce, cleanup admission or existing scheduled delays.

Once proposed, the count is fixed for that press. If count 2 was posted and a later
move becomes a drag, the already delivered action cannot be undone. Release must
still carry the owned press metadata; future pairing is invalidated. A failed
release cannot be hidden by a cleanup acknowledgment or a later retry result.

Apple documents [click state 1/2/3](https://developer.apple.com/documentation/coregraphics/cgeventfield/mouseeventclickstate)
and [matching down/up event numbers](https://developer.apple.com/kr/documentation/coregraphics/cgeventfield/mouseeventnumber).
A future additive managed sink must freeze the count and down event number and
apply both to ordinary and pre-reserved emergency releases. Preserve the old raw
and default paths. [CGEvent timestamps](https://developer.apple.com/documentation/coregraphics/cgeventtimestamp)
use nanoseconds since startup; do not backdate posts to HID receipt or use wall
time. Posting acknowledgment remains only a poster invocation.

An eventual adapter may sample [NSEvent.doubleClickInterval](https://developer.apple.com/documentation/appkit/nsevent/doubleclickinterval)
outside the input path and inject a validated value. The spatial threshold is
explicit driver policy. Apple also notes that a prolonged press may cease to
count as a click in [NSEvent.clickCount](https://developer.apple.com/documentation/appkit/nsevent/clickcount?changes=__3).

## Recipient limitations and focus policy

No app allowlist resolver is implemented. Apple's
[frontmostApplication](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication)
identifies the keyboard recipient. A
[window-information list](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)?language=_5)
provides metadata and bounds, not authoritative mouse hit testing. Neither is a
safe substitute for recipient identity.

[AXUIElementCopyElementAtPosition](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition?language=objc)
does z-order hit testing, and
[AXUIElementGetPid](https://developer.apple.com/documentation/applicationservices/1460337-axuielementgetpid)
can identify the element's process. Those calls provide observations separate from
[event posting](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:));
they do not create an atomic recipient lease. Asynchronous observation avoids a
gesture-queue wait but cannot make a stale observation current. An
[AX messaging timeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout?changes=l_4)
is not cancellation, and setting it on the system-wide object changes the
process-wide timeout. This experiment introduces neither AX waits nor timeout
changes.

Restoration-off would remove the driver's intentional focus bounce, but would
not detect all same-app window/overlay changes or unrelated physical input. Thus
a possible future global spatial/time trial must be explicitly limited to a
controlled benign fixture without concurrent external input. It cannot promise
unchanged recipient identity. Recipient-scoped production behavior remains
blocked; no permission or supported configuration is implied by these models.

## Complete-frame two-contact arbitration

`ExperimentalTwoContactScrollReducer` requires exactly two contacts in the first
complete nonempty frame. The caller must first classify that frame, before
admitting any mouse press. It then reserves **one** global owner lease for the
pair, using either original pair member as a canonical representative. Never
feed the second pair member as another down into the single-contact arbiter.
The granted lease must match the original source, contact and route.

The first frame requests ownership without emitting scroll. An explicit matching
grant proposes began at the most recent pair centroid. Subsequent frames retain
that pair and context. New pairs must use contact lifecycle sequences newer than
the highest sequence in the previous attempted pair; all-up does not permit reuse
of an old token. The decoder is still responsible for truthful lifecycle tokens,
and the global arbiter must observe source neutral before initial admission.
Reordered tokens are harmless. A third finger, replacement
logical contact, source/revision change, malformed/incomplete frame or nonfinite
delta cancels. The first lift ends normally only if any remaining contact belongs
to the original pair. Remaining fingers cannot become mouse input until all lift.

A single first contact or existing mouse/cleanup ownership suppresses scroll for
that contact session. A late second finger never converts a posted mouse down
into scrolling. A later chord-window design would require a separately explicit
latency policy; it is not present here.

Terminal actions are emitted once and identify the exact lease. The caller must
record successful terminal-poster invocation and acknowledge cleanup before the
model admits another sequence. A failed terminal result retains unresolved
ownership. Cancellation methods require the active lease ID or pending request
ID so stale callbacks cannot cancel newer work.

Changed actions contain unrounded mapped-screen-point deltas. A future scroll
encoder would explicitly convert them to
[CG pixel units](https://developer.apple.com/documentation/coregraphics/cgscrolleventunit/pixel?language=objc),
preserve fractional accumulation, validate integer conversion and use vertical
wheel1/horizontal wheel2 in the
[public constructor](https://developer.apple.com/documentation/coregraphics/cgevent/init(scrollwheelevent2source:units:wheelcount:wheel1:wheel2:wheel3:)?changes=_5).
Do not assume screen backing scale is the correct scroll multiplier.

Use public [scroll phases](https://developer.apple.com/documentation/coregraphics/cgscrollphase?changes=la_2)
and momentum none for the first encoder. Reserve terminal capacity before began.
Apple describes gesture routing from the view under the cursor at began in
[NSEvent.phase](https://developer.apple.com/documentation/appkit/nsevent/phase-swift.property).
Actual synthetic routing still needs native evidence. No momentum model, scroll
encoder or live dispatch exists in this increment.

## Validation boundary

Tests use synthetic frames, fake scope/revision tokens and fake post/cleanup
acknowledgments. They cover timing/distance boundaries, identity invalidation,
failure ownership, stale callbacks, fractional deltas, contact ordering and
mouse-versus-scroll exclusion. They establish neither real input delivery nor
native app compatibility.

Before a hardware adapter is enabled, traces must establish the authoritative
report source, true contact count, stable IDs, frame completeness and lifecycle.
Two interfaces or two reports do not prove two contacts. Existing single-touch
capability remains unchanged. Native builds, CG metadata observations and any
controlled live trial are separate validation stages.
