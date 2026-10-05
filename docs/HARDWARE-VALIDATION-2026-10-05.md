# Hardware validation, 5 October 2026

The PR19 candidate at b91a517736c1abb66492a70ed3ff170aadd670cb was tested on Apple Silicon with one landscape Xeneon Edge, a built-in Retina display and an M28U. The candidate ran separately while the original launch service was stopped. Original binary and launch plist stayed in place. The session ended with original config bytes, display arrangement and service restored, followed by a successful physical counter hit and normal mouse operation.

## Observed behavior

Active-window touches, hold then drag, lift then fresh tap and five rapid taps worked. An exported browser event trace records 8477 ms of stationary hold before movement. Cursor-return-off behavior worked in both tested focus combinations. After a touch, an explicit mouse selection of another window retained typed text across a two-second wait. A controlled shutdown during a held contact exited cleanly; the mouse then moved and clicked without a stuck drag.

Four browser corner controls worked at display origin (-2560,0) after mouse activation and confirmed text-field focus. Sleep/wake and idle USB data/power reconnect each settled and delivered a physical counter hit. Wake briefly logged an unresolved display before later reacquisition. Current-session reconnect logs contained no BadArgument close errors; older evidence contains those errors and is preserved.

Disconnecting USB during a held contact consumed the first post-reconnect tap on two trials, including after confirmed text-field focus. A subsequent fresh tap worked without restarting. This matches the documented release barrier: when a pressed source disappears, the replacement must report release before a fresh down can be accepted. A release while disconnected may be invisible to the driver.

## Remaining focus limitations

The first touch in an inactive Safari window could activate it without delivering the counter click. The same sibling-window failure reproduced under the original driver. A virtual Stream Deck demo also failed to preserve the text field: its Bet up, Bet down and Spin actions left Window A's URL bar focused. The owner confirmed this issue existed before the candidate. These results do not establish successful focus restoration or inactive-window click-through.

One cross-app trial with focus restoration enabled and cursor return disabled also failed typing continuation. Its original-driver comparison was not run. Focus restoration remains best effort; this PR does not claim to fix inactive-window first-click delivery or restore the exact text insertion point.

## Coverage limits

Browser event logs cannot identify the physical input source; hardware attribution comes from the owner's observations. The tests cover one landscape panel and browser controls, not every bezel coordinate. Rotation, multiple panels, Intel execution, macOS 13 execution, actual installation/uninstallation, signing and installed-path permission retention were not tested live. The separate optional multi-panel and gesture foundations remain experimental.

Historical native Debug, Release, strict-concurrency, ASan and TSan suites each passed 541 cases on corrected tree 9f32e87c84f24029d025d5db330a41daba1ab1ef. The hardware candidate differs from that tree only in README and CHANGELOG. Strict-concurrency checks retain existing warnings. The documentation update containing this report changes no executable source.
