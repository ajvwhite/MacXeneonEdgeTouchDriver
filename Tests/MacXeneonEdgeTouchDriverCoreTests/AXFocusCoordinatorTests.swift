import ApplicationServices
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class AXFocusCoordinatorTests: XCTestCase {
    func testAcceptedPhysicalUpPreventsPostReleaseEnrollmentDuringSyntheticUpDelay() {
        for upDelay in [0, 20, 1_000] {
            let f = CoordinatorGestureFixture(upDelay: upDelay)
            f.send(.down, at: 0)
            f.focus.pump()
            XCTAssertEqual(f.effects.actions, [.borrow, .down])
            f.send(.up, at: 100)

            // A deliberate B/B2 choice follows physical finger release, while a
            // nonzero synthetic-up delay still owns the pressed mouse button.
            f.advance(to: upDelay == 1_000 ? 200 : 105)
            let chosen = coordinatorTarget(pid: 20, window: "chosen-after-finger-release")
            f.focus.backend.focused = chosen
            f.focus.workspace.frontmost = chosen.workspaceApplication
            f.focus.workspace.emit(.focusChanged)
            f.focus.backend.emit(.focusChanged, processIdentifier: 20)
            f.focus.pump()
            XCTAssertEqual(f.focus.backend.attemptCount, 0)
            XCTAssertEqual(f.effects.actions, upDelay == 0 ? [.borrow, .down, .up] : [.borrow, .down])
            f.focus.backend.onAttempt = {
                f.focus.backend.focused = f.focus.captured
                f.focus.workspace.frontmost = f.focus.captured.workspaceApplication
            }

            f.advance(to: 100 + UInt64(upDelay) + 100)
            f.focus.pump()
            XCTAssertEqual(f.focus.backend.attemptCount, 0,
                           "Physical release must forbid later enrollment during a \(upDelay) ms synthetic-up delay.")
            XCTAssertEqual(f.focus.backend.relationship(f.focus.backend.focused, chosen), .same)
            XCTAssertEqual(f.effects.actions, [.borrow, .down, .up, .release(true)])
            XCTAssertEqual(f.controller.state, .idle)
        }
    }

    func testCertifiedDuringTouchFocusSurvivesDelayedSyntheticUpWithoutExtraActions() {
        for upDelay in [0, 20, 1_000] {
            let f = CoordinatorGestureFixture(upDelay: upDelay)
            f.send(.down, at: 0)
            f.focus.pump()
            f.advance(to: 50)
            f.focus.changeFocusDuringTouch()
            XCTAssertEqual(f.focus.backend.observers.count, 2)
            f.focus.backend.onAttempt = {
                f.focus.backend.focused = f.focus.captured
                f.focus.workspace.frontmost = f.focus.captured.workspaceApplication
            }
            f.send(.up, at: 100)
            f.focus.pump()
            if upDelay > 0 {
                f.advance(to: 100 + UInt64(upDelay) - 1)
                f.focus.pump()
                XCTAssertEqual(f.effects.actions, [.borrow, .down])
                XCTAssertEqual(f.focus.backend.attemptCount, 0)
            }
            f.advance(to: 100 + UInt64(upDelay))
            f.focus.pump()
            XCTAssertEqual(f.effects.actions, [.borrow, .down, .up])
            XCTAssertEqual(f.focus.backend.attemptCount, 0, "Focus must wait for cursor cleanup.")
            f.advance(to: 100 + UInt64(upDelay) + 99)
            f.focus.pump()
            XCTAssertEqual(f.effects.actions, [.borrow, .down, .up])
            XCTAssertEqual(f.focus.backend.attemptCount, 0)

            f.advance(to: 100 + UInt64(upDelay) + 100)
            f.focus.pump()
            XCTAssertEqual(f.focus.backend.attemptCount, 1,
                           "Synthetic mouse-up must not erase the physical-release baseline.")
            XCTAssertEqual(f.focus.backend.relationship(f.focus.backend.focused, f.focus.captured), .same)
            XCTAssertEqual(f.effects.actions, [.borrow, .down, .up, .release(true)])
            XCTAssertEqual(f.controller.state, .idle)
            f.advance(to: 100 + UInt64(upDelay) + 500)
            f.focus.pump()
            XCTAssertEqual(f.focus.backend.attemptCount, 1)
            XCTAssertEqual(f.effects.actions, [.borrow, .down, .up, .release(true)])
        }
    }

    func testPhysicalReleaseFreezesFocusBeforeForcingDelayedMouseDown() {
        for upDelay in [20, 1_000] {
            let f = CoordinatorGestureFixture(upDelay: upDelay, warpDelay: 200)
            f.send(.down, at: 0)
            f.focus.pump()
            XCTAssertEqual(f.effects.actions, [.borrow])
            let chosen = coordinatorTarget(pid: 20, window: "activated-by-forced-down")
            f.effects.onMouseDown = {
                f.focus.backend.focused = chosen
                f.focus.workspace.frontmost = chosen.workspaceApplication
                f.focus.workspace.emit(.focusChanged)
                f.focus.backend.emit(.focusChanged, processIdentifier: 20)
            }

            // This up forces the still-delayed down. Its synchronous focus side
            // effect must already be outside the physical-touch enrollment window.
            f.send(.up, at: 100)
            f.focus.pump()
            XCTAssertEqual(f.effects.actions, [.borrow, .down])
            XCTAssertEqual(f.focus.backend.attemptCount, 0)
            f.advance(to: 100 + UInt64(upDelay) + 100)
            f.focus.pump()
            XCTAssertEqual(f.focus.backend.attemptCount, 0)
            XCTAssertEqual(f.focus.backend.relationship(f.focus.backend.focused, chosen), .same)
            XCTAssertEqual(f.effects.actions, [.borrow, .down, .up, .release(true)])
            XCTAssertEqual(f.controller.state, .idle)
        }
    }

    func testPreparationUsesFreshReadsThenDeliversOnCallbackQueue() {
        let f = FocusCoordinatorFixture()
        var completed = false
        f.restorer.prepareFocusedWindow { completed = true }
        f.pump(includeCallbacks: false)
        XCTAssertFalse(completed)
        XCTAssertEqual(f.backend.resolveCount, 2)
        XCTAssertEqual(f.backend.observers.count, 1)
        f.callbacks.runAll()
        XCTAssertTrue(completed)
    }

    func testBusyPreparationsNeverAccumulateAXJobs() {
        let f = FocusCoordinatorFixture()
        f.restorer.prepareFocusedWindow {}
        f.main.runAll()
        XCTAssertEqual(f.worker.jobs.count, 1)
        for _ in 0..<100 { f.restorer.prepareFocusedWindow {} }
        XCTAssertEqual(f.worker.jobs.count, 1)
        XCTAssertEqual(f.main.jobs.count, 0)
        f.pump()
        XCTAssertEqual(f.backend.resolveCount, 0, "The admitted but superseded job is invalid before AX begins.")
        f.prepare()
        XCTAssertEqual(f.backend.resolveCount, 2)
    }

    func testLateCaptureCannotAuthorizeObservationOrRestoration() {
        let f = FocusCoordinatorFixture()
        f.backend.onResolve = { f.clock.nanoseconds = 40_000_000 }
        f.prepare()
        f.restorer.inputDidEnd()
        f.restorer.restoreCapturedWindow()
        f.pump()
        XCTAssertEqual(f.backend.resolveCount, 1)
        XCTAssertTrue(f.backend.observers.isEmpty)
        XCTAssertEqual(f.backend.attemptCount, 0)
    }

    func testCaptureObserverFailureStillCompletesTouchPreparation() {
        let f = FocusCoordinatorFixture()
        f.backend.observationSucceeds = false
        var completed = false
        f.restorer.prepareFocusedWindow { completed = true }
        f.pump()
        XCTAssertTrue(completed)
        f.restorer.inputDidEnd()
        f.restorer.restoreCapturedWindow()
        f.pump()
        XCTAssertEqual(f.backend.attemptCount, 0)
    }

    func testBaselineObserverFailureNeverMutates() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.backend.observationSucceeds = false
        f.changeFocusDuringTouch()
        f.releaseAndRestore()
        XCTAssertEqual(f.backend.attemptCount, 0)
        XCTAssertEqual(f.backend.observers.first?.invalidations, 1)
    }

    func testChangedFocusDuringTouchCanRestoreOnceAfterRelease() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch()
        f.backend.onAttempt = {
            f.backend.focused = f.captured
            f.workspace.frontmost = f.captured.workspaceApplication
        }
        f.releaseAndRestore()
        XCTAssertEqual(f.backend.attemptCount, 1)
        XCTAssertEqual(f.backend.resolveCount, 6)
        XCTAssertEqual(f.backend.observers.count, 2)
        XCTAssertTrue(f.backend.observers.allSatisfy { $0.invalidations == 1 })
    }

    func testAlreadyFocusedWindowSkipsMutation() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.releaseAndRestore()
        XCTAssertEqual(f.backend.attemptCount, 0)
        XCTAssertEqual(f.backend.observers.count, 1)
    }

    func testFocusChangeWhileCallbackQueuedRevokesCaptureButDeliversTouch() {
        let f = FocusCoordinatorFixture()
        var completed = false
        f.restorer.prepareFocusedWindow { completed = true }
        f.pump(includeCallbacks: false)
        f.backend.observers.first?.emit(.focusChanged)
        f.callbacks.runAll()
        XCTAssertTrue(completed)
        f.restorer.inputDidEnd()
        f.restorer.restoreCapturedWindow()
        f.pump()
        XCTAssertEqual(f.backend.attemptCount, 0)
        XCTAssertEqual(f.backend.observers.first?.invalidations, 1)
    }

    func testPostReleaseFocusChangeBeforeCursorReturnRevokesRestoration() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch()
        f.restorer.inputDidEnd()
        f.backend.emit(.focusChanged, processIdentifier: f.other.workspaceApplication.processIdentifier)
        f.clock.nanoseconds += 100_000_000
        f.restorer.restoreCapturedWindow()
        f.pump()
        XCTAssertEqual(f.backend.attemptCount, 0)
    }

    func testSiblingWindowChangeInTouchDestinationAfterReleaseDoesNotRestoreOriginalWindow() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch(enroll: false)
        XCTAssertEqual(f.backend.observers.count, 1,
                       "Only the original application's observer exists during the touch.")
        XCTAssertTrue(f.backend.observers.allSatisfy { f.backend.relationship($0.target, f.captured) == .same })
        XCTAssertFalse(f.backend.observers.contains {
            CFEqual($0.target.application.rawValue, f.other.application.rawValue)
        }, "The touch destination application is not observed before mouse-up.")
        f.restorer.inputDidEnd()

        let workspaceRevision = f.workspace.revision
        let sibling = coordinatorTarget(pid: f.other.workspaceApplication.processIdentifier, window: "other-sibling")
        f.backend.focused = sibling
        // B1 -> B2 stays inside the touch destination app. Route its event only
        // to registered B observers; the captured A observer cannot see it.
        XCTAssertEqual(f.backend.emit(.focusChanged, processIdentifier: sibling.workspaceApplication.processIdentifier), 0)
        XCTAssertEqual(f.workspace.revision, workspaceRevision)
        XCTAssertEqual(f.backend.observers.count, 1)
        var mutations = 0
        f.backend.onAttempt = {
            mutations += 1
            f.backend.focused = f.captured
            f.workspace.frontmost = f.captured.workspaceApplication
        }

        f.clock.nanoseconds += 100_000_000
        f.restorer.restoreCapturedWindow()
        f.pump()

        XCTAssertEqual(f.backend.attemptCount, 0,
                       "A later baseline read must not authorize overriding a post-release sibling-window choice.")
        XCTAssertEqual(mutations, 0, "The original window must not be raised over the user's newer focus choice.")
        XCTAssertEqual(f.backend.relationship(f.backend.focused, sibling), .same)
    }

    func testCoveredDestinationSiblingChangeAfterReleaseRevokesRestoration() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch()
        XCTAssertEqual(f.backend.observers.count, 2)
        f.restorer.inputDidEnd()
        let revision = f.workspace.revision
        let sibling = coordinatorTarget(pid: 20, window: "other-sibling")
        f.backend.focused = sibling
        XCTAssertEqual(f.backend.emit(.focusChanged, processIdentifier: 20), 1)
        XCTAssertEqual(f.workspace.revision, revision)
        f.clock.nanoseconds += 100_000_000
        f.restorer.restoreCapturedWindow()
        f.pump()
        XCTAssertEqual(f.backend.attemptCount, 0)
        XCTAssertEqual(f.backend.relationship(f.backend.focused, sibling), .same)
    }

    func testSilentPostReleaseMismatchCannotReplaceCertifiedBaseline() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch()
        f.restorer.inputDidEnd()
        f.backend.focused = coordinatorTarget(pid: 20, window: "other-sibling")
        f.clock.nanoseconds += 100_000_000
        f.restorer.restoreCapturedWindow()
        f.pump()
        XCTAssertEqual(f.backend.attemptCount, 0, "Fresh reads confirm the release witness; they cannot replace it.")
    }

    func testSameApplicationEnrollmentReusesCapturedApplicationObserver() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.backend.focused = coordinatorTarget(pid: 10, window: "captured-sibling")
        XCTAssertEqual(f.backend.emit(.focusChanged, processIdentifier: 10), 1)
        f.pump()
        XCTAssertEqual(f.backend.observers.count, 1)
        f.releaseAndRestore()
        XCTAssertEqual(f.backend.attemptCount, 1)
    }

    func testReleaseBeforeEnrollmentStartsNeverInstallsDestinationObserver() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch(enroll: false)
        f.releaseAndRestore()
        XCTAssertEqual(f.backend.resolveCount, 2)
        XCTAssertEqual(f.backend.observers.count, 1)
        XCTAssertEqual(f.backend.attemptCount, 0)
        XCTAssertEqual(f.backend.observers.first?.invalidations, 1)
    }

    func testReleaseWhileEnrollmentIsInFlightRetainsSlotUntilActualCleanup() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch(enroll: false)
        f.main.runAll()
        XCTAssertEqual(f.worker.jobs.count, 1)
        f.backend.onResolve = {
            f.restorer.inputDidEnd()
            f.restorer.restoreCapturedWindow()
            for _ in 0..<100 { f.restorer.prepareFocusedWindow {} }
            XCTAssertTrue(f.worker.jobs.isEmpty, "Busy requests cannot queue behind an in-flight AX read.")
        }
        f.worker.runAll()
        f.backend.onResolve = nil
        f.pump()
        XCTAssertEqual(f.backend.resolveCount, 3)
        XCTAssertEqual(f.backend.attemptCount, 0)
        XCTAssertEqual(f.backend.observers.count, 1)
        XCTAssertEqual(f.backend.observers.first?.invalidations, 1)
        f.prepare()
        XCTAssertEqual(f.backend.resolveCount, 5, "The slot becomes reusable only after actual cleanup.")
    }

    func testReleaseBeforeFinalEnrollmentPublicationRejectsLateCertificate() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch(enroll: false)
        f.main.runAll()
        f.worker.runAll()
        f.main.runAll()
        f.worker.runAll()
        XCTAssertEqual(f.backend.resolveCount, 4)
        XCTAssertEqual(f.backend.observers.count, 2)
        f.restorer.inputDidEnd()
        f.pump()
        f.restorer.restoreCapturedWindow()
        f.pump()
        XCTAssertEqual(f.backend.attemptCount, 0)
        XCTAssertTrue(f.backend.observers.allSatisfy { $0.invalidations == 1 })
    }

    func testFocusHintBurstUsesOneEnrollmentAndLaterChangeDoesNotRetry() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch(enroll: false)
        for _ in 0..<100 {
            f.workspace.emit(.focusChanged)
            f.backend.emit(.focusChanged, processIdentifier: 10)
        }
        XCTAssertEqual(f.main.jobs.count, 1)
        XCTAssertTrue(f.worker.jobs.isEmpty)
        f.main.runAll()
        XCTAssertEqual(f.worker.jobs.count, 1)
        f.pump()
        XCTAssertEqual(f.backend.resolveCount, 4)
        XCTAssertEqual(f.backend.observers.count, 2)
        f.backend.focused = coordinatorTarget(pid: 20, window: "other-sibling")
        f.backend.emit(.focusChanged, processIdentifier: 20)
        XCTAssertTrue(f.main.jobs.isEmpty)
        XCTAssertTrue(f.worker.jobs.isEmpty)
        f.releaseAndRestore()
        XCTAssertEqual(f.backend.resolveCount, 4)
        XCTAssertEqual(f.backend.attemptCount, 0)
    }

    func testNewGestureAndShutdownDuringEnrollmentCleanUpBothObservers() {
        for shutdown in [false, true] {
            let f = FocusCoordinatorFixture()
            f.prepare()
            f.changeFocusDuringTouch(enroll: false)
            f.main.runAll()
            f.worker.runAll()
            XCTAssertEqual(f.backend.observers.count, 2)
            if shutdown { f.restorer.shutdown() }
            else { f.restorer.prepareFocusedWindow {} }
            f.pump()
            XCTAssertEqual(f.backend.attemptCount, 0)
            XCTAssertTrue(f.backend.observers.allSatisfy { $0.invalidations == 1 })
            XCTAssertEqual(f.backend.resolveCount, 3)
        }
    }

    func testLifecycleChangeDuringTouchRevokesRestoration() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.workspace.emit(.lifecycleChanged)
        f.changeFocusDuringTouch()
        f.releaseAndRestore()
        XCTAssertEqual(f.backend.attemptCount, 0)
    }

    func testFreshBaselineChangeBeforeMutationRevokesRestoration() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch()
        f.restorer.inputDidEnd()
        f.restorer.restoreCapturedWindow()
        f.main.runAll()
        f.worker.runAll()
        XCTAssertEqual(f.backend.observers.count, 2)
        f.backend.observers.last?.emit(.focusChanged)
        f.pump()
        XCTAssertEqual(f.backend.attemptCount, 0)
    }

    func testTimedOutMutationIsNeverRetriedOrFollowedByVerification() {
        let f = FocusCoordinatorFixture()
        f.prepare()
        f.changeFocusDuringTouch()
        f.backend.onAttempt = {
            f.clock.nanoseconds += 160_000_000
            f.restorer.prepareFocusedWindow {}
            f.backend.focused = f.captured // An issued operation can still take effect late.
        }
        f.releaseAndRestore()
        XCTAssertEqual(f.backend.attemptCount, 1)
        XCTAssertEqual(f.backend.resolveCount, 5)
        XCTAssertTrue(f.backend.observers.allSatisfy { $0.invalidations == 1 })
    }

    func testShutdownSuppressesAlreadyQueuedPreparationCompletion() {
        let f = FocusCoordinatorFixture()
        var completions = 0
        f.restorer.prepareFocusedWindow { completions += 1 }
        f.pump(includeCallbacks: false)
        f.restorer.shutdown()
        f.restorer.prepareFocusedWindow { completions += 1 }
        f.pump()
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(f.backend.observers.first?.invalidations, 1)
        XCTAssertGreaterThan(f.workspace.stopCount, 0)
    }

    func testAdmittedPreparationCanFinishAfterNonblockingShutdown() {
        let f = FocusCoordinatorFixture()
        let callbackQueue = DispatchQueue(label: "test.focus.admitted-callback")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "admitted callback and queue fence returned")
        let effect = FocusLockedFlag()
        let gateTimedOut = FocusLockedFlag()
        f.restorer.prepareFocusedWindow {
            dispatchPrecondition(condition: .onQueue(callbackQueue))
            entered.signal()
            if release.wait(timeout: .now() + 5) != .success { gateTimedOut.set() }
            effect.set()
        }
        f.pump(includeCallbacks: false)
        XCTAssertEqual(f.callbacks.jobs.count, 1)

        // Transfer the manual callback executor to a real serial queue for this
        // phase. Do not read it again until the marker after runAll has returned.
        callbackQueue.async { [callbacks = f.callbacks] in
            callbacks.runAll()
            finished.fulfill()
        }
        defer { release.signal() }
        guard entered.wait(timeout: .now() + 2) == .success else {
            XCTFail("Preparation completion was not admitted")
            return
        }

        f.restorer.shutdown()
        XCTAssertFalse(effect.isSet, "Shutdown must return while an admitted client is still blocked")
        // Main and AX cleanup are independent of the blocked client completion.
        f.pump(includeCallbacks: false)
        XCTAssertEqual(f.backend.observers.first?.invalidations, 1)
        XCTAssertGreaterThan(f.workspace.stopCount, 0)
        release.signal()
        guard XCTWaiter.wait(for: [finished], timeout: 2) == .completed else {
            XCTFail("Admitted completion did not finish; dependent fixture reads are unsafe")
            return
        }
        XCTAssertFalse(gateTimedOut.isSet)
        XCTAssertTrue(effect.isSet, "Admission, not shutdown return, owns this completion")
        f.restorer.inputDidEnd()
        f.restorer.restoreCapturedWindow()
        f.pump()
        XCTAssertEqual(f.backend.attemptCount, 0, "An admitted completion cannot revive stopped focus work")
        XCTAssertEqual(f.backend.observers.first?.invalidations, 1)
    }

    func testPreparationCompletionCanReenterShutdownWithoutHoldingSessionLock() {
        for observationSucceeds in [true, false] {
            let f = FocusCoordinatorFixture()
            f.backend.observationSucceeds = observationSucceeds
            let callbackQueue = DispatchQueue(label: "test.focus.reentrant-callback")
            let finished = expectation(description: "reentrant completion returned: \(observationSucceeds)")
            let completed = FocusLockedFlag()
            let lateCompletion = FocusLockedFlag()
            f.restorer.prepareFocusedWindow {
                dispatchPrecondition(condition: .onQueue(callbackQueue))
                f.restorer.inputDidEnd()
                f.restorer.discardCapturedWindow()
                f.restorer.shutdown()
                f.restorer.prepareFocusedWindow { lateCompletion.set() }
                completed.set()
            }
            f.pump(includeCallbacks: false)
            callbackQueue.async { [callbacks = f.callbacks] in
                // Main/worker executors are quiescent while the callback enqueues
                // its reentrant cleanup. The completion marker transfers them back.
                callbacks.runAll()
                finished.fulfill()
            }
            guard XCTWaiter.wait(for: [finished], timeout: 2) == .completed else {
                XCTFail("Client completion deadlocked during reentrant shutdown; no dependent fixture access follows")
                return
            }
            XCTAssertTrue(completed.isSet)
            f.pump()
            XCTAssertFalse(lateCompletion.isSet)
            XCTAssertEqual(f.backend.attemptCount, 0)
            XCTAssertTrue(f.backend.observers.allSatisfy { $0.invalidations == 1 })
        }
    }

    func testSerialGestureCancellationFencesInputFromAnAdmittedCompletion() {
        let f = CoordinatorGestureFixture(upDelay: 20, executeCancelledActions: true)
        let callbackQueue = DispatchQueue(label: "test.focus.gesture-drain")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let drained = expectation(description: "serial gesture cancellation returned")
        let gateTimedOut = FocusLockedFlag()
        f.effects.onMouseDown = {
            dispatchPrecondition(condition: .onQueue(callbackQueue))
            entered.signal()
            if release.wait(timeout: .now() + 5) != .success { gateTimedOut.set() }
        }
        f.send(.down, at: 0)
        f.focus.pump(includeCallbacks: false)
        callbackQueue.async { [callbacks = f.focus.callbacks] in callbacks.runAll() }
        defer { release.signal() }
        guard entered.wait(timeout: .now() + 2) == .success else {
            XCTFail("Admitted gesture did not reach fake mouse-down")
            return
        }

        // This is the application's ordering: terminal focus invalidation first,
        // then cancellation on the same serial queue as the admitted completion.
        f.focus.restorer.shutdown()
        callbackQueue.async { [controller = f.controller] in
            controller.forceCancel()
            drained.fulfill()
        }
        release.signal()
        guard XCTWaiter.wait(for: [drained], timeout: 2) == .completed else {
            XCTFail("Gesture queue did not drain; no dependent fixture access follows")
            return
        }
        XCTAssertFalse(gateTimedOut.isSet)
        XCTAssertEqual(f.effects.actions, [.borrow, .down, .up, .release(true)])
        XCTAssertEqual(f.controller.state, .idle)
        let afterDrain = f.effects.actions
        f.focus.pump()
        f.advance(to: 2_000)
        f.focus.pump()
        XCTAssertEqual(f.effects.actions, afterDrain, "Late focus/timer work must not recreate input after cancellation")
        XCTAssertEqual(f.focus.backend.attemptCount, 0)
        XCTAssertTrue(f.focus.backend.observers.allSatisfy { $0.invalidations == 1 })
    }

    func testDiscardBeforeMainStageDoesNotStartWorkspaceOrAX() {
        let f = FocusCoordinatorFixture()
        f.restorer.prepareFocusedWindow {}
        f.restorer.discardCapturedWindow()
        f.pump()
        XCTAssertEqual(f.workspace.startCount, 0)
        XCTAssertEqual(f.backend.resolveCount, 0)
    }

    func testLegacyCaptureNeverStartsPostInputAXRead() {
        let f = FocusCoordinatorFixture()
        f.restorer.captureFocusedWindow()
        f.pump()
        XCTAssertEqual(f.backend.resolveCount, 0)
        XCTAssertEqual(f.workspace.startCount, 0)
    }

    func testDroppingPreparedRestorerRetainsObserversUntilOrderedCleanup() {
        let main = FocusManualExecutor()
        let worker = FocusManualExecutor()
        let callbacks = FocusManualExecutor()
        let target = coordinatorTarget(pid: 10, window: "first")
        let backend = CoordinatorBackendFake(focused: target)
        var sourceContext = CFRunLoopSourceContext()
        let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceContext)!
        backend.observationSource = source
        defer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        let workspace = CoordinatorWorkspaceFake(application: target.workspaceApplication)
        var restorer: AXFocusRestorer? = AXFocusRestorer(
            backend: backend, workspace: workspace, onMain: main.enqueue, onWorker: worker.enqueue,
            onCallback: callbacks.enqueue, now: { 0 })
        restorer?.prepareFocusedWindow {}
        for _ in 0..<5 { main.runAll(); worker.runAll(); callbacks.runAll() }
        XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .defaultMode))
        let weakRestorer = FocusWeakReference(restorer)
        let weakObserver = FocusWeakReference(backend.observers.first)
        var invalidated = false
        backend.observers.first?.onInvalidate = {
            XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .defaultMode),
                           "Main must detach the source before worker-side observer invalidation.")
            invalidated = true
        }
        backend.observers.removeAll()
        XCTAssertNotNil(weakObserver.value, "The session must own the observer independently of the backend fake.")
        restorer = nil
        XCTAssertNil(weakRestorer.value)
        XCTAssertNotNil(weakObserver.value, "Pending main detach must retain the observer and its callback context.")
        XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .defaultMode))
        main.runAll()
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .defaultMode))
        XCTAssertNotNil(weakObserver.value, "The detached observer must survive until worker invalidation.")
        XCTAssertFalse(invalidated)
        worker.runAll()
        XCTAssertTrue(invalidated)
        XCTAssertNil(weakObserver.value, "Completed cleanup must release the observer.")
    }

    func testMainShutdownReturnsWhileRealWorkerIsBlocked() {
        let entered = expectation(description: "fake AX entered")
        let exited = expectation(description: "fake AX exited")
        let workerExited = FocusLockedFlag()
        let gate = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.focus.blocked-worker")
        let target = coordinatorTarget(pid: 10, window: "first")
        let backend = CoordinatorBackendFake(focused: target)
        backend.onResolve = {
            entered.fulfill()
            if gate.wait(timeout: .now() + 2) != .success {
                XCTFail("Shutdown must return while fake AX is still blocked; only the test may release it.")
            }
            workerExited.set()
            exited.fulfill()
        }
        let workspace = CoordinatorWorkspaceFake(application: target.workspaceApplication)
        let restorer = AXFocusRestorer(backend: backend, workspace: workspace,
            onMain: { DispatchQueue.main.async(execute: $0) },
            onWorker: { queue.async(execute: $0) },
            onCallback: { DispatchQueue.main.async(execute: $0) },
            now: { DispatchTime.now().uptimeNanoseconds })
        var completed = false
        let preparationStart = DispatchTime.now().uptimeNanoseconds
        restorer.prepareFocusedWindow { completed = true }
        let preparationMs = Double(DispatchTime.now().uptimeNanoseconds - preparationStart) / 1_000_000
        wait(for: [entered], timeout: 1)
        let shutdownStart = DispatchTime.now().uptimeNanoseconds
        restorer.shutdown()
        let shutdownMs = Double(DispatchTime.now().uptimeNanoseconds - shutdownStart) / 1_000_000
        XCTAssertFalse(workerExited.isSet, "Shutdown must finish before the in-flight AX operation returns.")
        XCTAssertFalse(completed)
        print("Fake-blocked AX: prepare returned in \(preparationMs) ms; main shutdown returned in \(shutdownMs) ms")
        gate.signal()
        wait(for: [exited], timeout: 1)
        let returned = expectation(description: "actual worker returned")
        queue.async { returned.fulfill() }
        wait(for: [returned], timeout: 1)
        XCTAssertFalse(completed)
        XCTAssertEqual(backend.resolveCount, 1)
        XCTAssertEqual(backend.attemptCount, 0)
        XCTAssertTrue(backend.observers.isEmpty)
    }
}

private final class FocusManualExecutor {
    var jobs: [() -> Void] = []
    func enqueue(_ action: @escaping () -> Void) { jobs.append(action) }
    @discardableResult func runAll() -> Bool {
        let pending = jobs
        jobs.removeAll()
        pending.forEach { $0() }
        return !pending.isEmpty
    }
}

private final class CoordinatorClock { var nanoseconds: UInt64 = 0 }

private final class FocusWeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
}

private final class FocusLockedFlag {
    private let lock = NSLock()
    private var storage = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private final class FocusCoordinatorFixture {
    let main = FocusManualExecutor()
    let worker = FocusManualExecutor()
    let callbacks = FocusManualExecutor()
    let clock = CoordinatorClock()
    let captured = coordinatorTarget(pid: 10, window: "first")
    let other = coordinatorTarget(pid: 20, window: "other")
    let backend: CoordinatorBackendFake
    let workspace: CoordinatorWorkspaceFake
    let restorer: AXFocusRestorer

    init(now: (() -> UInt64)? = nil) {
        backend = CoordinatorBackendFake(focused: captured)
        workspace = CoordinatorWorkspaceFake(application: captured.workspaceApplication)
        let clock = self.clock
        restorer = AXFocusRestorer(backend: backend, workspace: workspace,
            onMain: main.enqueue, onWorker: worker.enqueue, onCallback: callbacks.enqueue,
            now: now ?? { clock.nanoseconds })
    }

    func prepare() {
        restorer.prepareFocusedWindow {}
        pump()
    }

    func changeFocusDuringTouch(enroll: Bool = true) {
        backend.focused = other
        workspace.frontmost = other.workspaceApplication
        workspace.emit(.focusChanged)
        backend.emit(.focusChanged, processIdentifier: captured.workspaceApplication.processIdentifier)
        if enroll { pump() }
    }

    func releaseAndRestore() {
        restorer.inputDidEnd()
        restorer.restoreCapturedWindow()
        pump()
    }

    func pump(includeCallbacks: Bool = true) {
        for _ in 0..<30 {
            let didMain = main.runAll()
            let didWorker = worker.runAll()
            let didCallbacks = includeCallbacks && callbacks.runAll()
            if !didMain && !didWorker && !didCallbacks { return }
        }
        XCTFail("Focus pipeline did not quiesce within its bounded stages")
    }
}

/// Exercises the actual gesture/coordinator release boundary with one virtual clock.
private final class CoordinatorGestureFixture {
    let scheduler: TestGestureScheduler
    let focus: FocusCoordinatorFixture
    let effects = CoordinatorGestureEffects()
    let controller: GestureController

    init(upDelay: Int, warpDelay: Int = 0, executeCancelledActions: Bool = false) {
        let scheduler = TestGestureScheduler(executeCancelledActions: executeCancelledActions)
        let focus = FocusCoordinatorFixture(now: { scheduler.now.uptimeNanoseconds })
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 100, y: 200, width: 2_560, height: 720))
        self.scheduler = scheduler
        self.focus = focus
        controller = GestureController(
            mapperProvider: { mapper }, inputSink: effects, cursorController: effects,
            focusRestorer: focus.restorer,
            timing: GestureTiming(warpToClickDelayMs: warpDelay, downToUpDelayMs: upDelay,
                                  clickToWarpBackDelayMs: 100, tapDebounceMs: 0),
            scheduler: scheduler)
    }

    func advance(to milliseconds: UInt64) { scheduler.advance(toMilliseconds: milliseconds) }

    func send(_ kind: TouchEvent.Kind, at milliseconds: UInt64) {
        advance(to: milliseconds)
        controller.handle(TouchEvent(kind: kind, contactID: 0, rawX: 0, rawY: 0, timestamp: scheduler.now))
    }
}

private final class CoordinatorGestureEffects: SyntheticInputSink, CursorController {
    enum Action: Equatable { case borrow, down, drag, up, update, release(Bool), show }
    var actions: [Action] = []
    var onMouseDown: (() -> Void)?
    func borrow(warpingTo point: CGPoint) -> Bool { actions.append(.borrow); return true }
    func updatePosition(_ point: CGPoint) { actions.append(.update) }
    func returnToOrigin() { releaseBorrow(returnToPreviousPosition: true) }
    func releaseBorrow(returnToPreviousPosition: Bool) { actions.append(.release(returnToPreviousPosition)) }
    func forceShow() { actions.append(.show) }
    func postMouseDown(at point: CGPoint) { actions.append(.down); onMouseDown?() }
    func postMouseUp(at point: CGPoint) { actions.append(.up) }
    func postMouseDragged(to point: CGPoint) { actions.append(.drag) }
}

private func coordinatorTarget(pid: pid_t, window: String) -> AXFocusTarget {
    AXFocusTarget(application: AXFocusElement(rawValue: "app-\(pid)" as NSString),
        window: AXFocusElement(rawValue: window as NSString),
        workspaceApplication: AXFocusWorkspaceApplication(processIdentifier: pid,
            identity: "process-\(pid)" as NSString, isTerminated: false, isHidden: false))
}

private final class CoordinatorObservationFake: AXFocusObservationProtocol {
    let target: AXFocusTarget
    let source: CFRunLoopSource?
    var invalidations = 0
    var onInvalidate: (() -> Void)?
    let change: (FocusObservationEvent) -> Void
    init(target: AXFocusTarget, change: @escaping (FocusObservationEvent) -> Void, source: CFRunLoopSource? = nil) {
        self.target = target
        self.change = change
        self.source = source
    }
    func emit(_ event: FocusObservationEvent) { change(event) }
    func invalidate() { onInvalidate?(); invalidations += 1 }
}

private final class CoordinatorBackendFake: AXFocusBackendProtocol {
    var focused: AXFocusTarget
    var observationSucceeds = true
    var observationSource: CFRunLoopSource?
    var resolveCount = 0
    var attemptCount = 0
    var observers: [CoordinatorObservationFake] = []
    var onResolve: (() -> Void)?
    var onAttempt: (() -> Void)?
    init(focused: AXFocusTarget) { self.focused = focused }

    @discardableResult func emit(_ event: FocusObservationEvent, processIdentifier: pid_t) -> Int {
        let recipients = observers.filter {
            $0.invalidations == 0 && $0.target.workspaceApplication.processIdentifier == processIdentifier
        }
        recipients.forEach { $0.emit(event) }
        return recipients.count
    }

    func resolve(workspace: AXFocusWorkspaceApplication?, permit: () -> Bool) -> AXFocusResolution {
        resolveCount += 1
        onResolve?()
        return .known(focused) // Deliberately can return a stale answer after its permit expires.
    }

    func relationship(_ lhs: AXFocusTarget, _ rhs: AXFocusTarget) -> AXFocusRelationship {
        CFEqual(lhs.application.rawValue, rhs.application.rawValue)
            && CFEqual(lhs.window.rawValue, rhs.window.rawValue) ? .same : .different
    }

    func attemptRestore(captured: AXFocusTarget, baseline: AXFocusTarget,
        workspace: AXFocusWorkspaceApplication?, capturedApplication: AXFocusWorkspaceApplication?,
        permit: () -> Bool) -> AXFocusAttemptResult {
        guard permit() else { return .skipped }
        attemptCount += 1
        onAttempt?()
        return .attempted(.success)
    }

    func prepareObservation(target: AXFocusTarget, permit: () -> Bool,
        onChange: @escaping (FocusObservationEvent) -> Void) -> AXFocusObservationProtocol? {
        guard observationSucceeds, permit() else { return nil }
        let observer = CoordinatorObservationFake(target: target, change: onChange, source: observationSource)
        observers.append(observer)
        return observer
    }
}

private final class CoordinatorWorkspaceFake: WorkspaceFocusMonitoring {
    var frontmost: AXFocusWorkspaceApplication
    let original: AXFocusWorkspaceApplication
    var revision: UInt64 = 0
    var active = true
    var startCount = 0
    var stopCount = 0
    var observer: ((FocusObservationEvent) -> Void)?
    init(application: AXFocusWorkspaceApplication) { frontmost = application; original = application }
    func start(observation: @escaping (FocusObservationEvent) -> Void) { startCount += 1; observer = observation }
    func snapshot() -> WorkspaceFocusSnapshot {
        WorkspaceFocusSnapshot(application: frontmost, revision: revision, sessionActive: active)
    }
    func application(processIdentifier: pid_t) -> AXFocusWorkspaceApplication? {
        processIdentifier == original.processIdentifier ? original : frontmost
    }
    func emit(_ event: FocusObservationEvent) { revision += 1; observer?(event) }
    func stop() { stopCount += 1; observer = nil }
}
