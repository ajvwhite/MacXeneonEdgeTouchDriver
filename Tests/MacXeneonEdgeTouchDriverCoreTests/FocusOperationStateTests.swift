import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class FocusOperationStateTests: XCTestCase {
    func testOwnedClickFocusHintsAfterRawLiftRequireFreshRestorationButDoNotRevokeIt() {
        var now: UInt64 = 0
        var physicalUnchanged = true
        let token = FocusOperationToken(now: { now }, inputPermit: { physicalUnchanged })
        XCTAssertTrue(token.beginTouch())
        XCTAssertTrue(token.beginSyntheticInput())
        XCTAssertTrue(token.inputDidEnd())
        XCTAssertFalse(token.observe(.focusChanged))
        XCTAssertTrue(token.beginRestore())
        XCTAssertFalse(token.observe(.focusChanged))
        physicalUnchanged = false
        XCTAssertFalse(token.beginRestoreMutation(), "Actual later input must still win over owned click delivery.")
        now = 1
    }

    func testOwnedClickDeliveryCannotSurviveLifecycleLossOrReleaseDeadline() {
        for lifecycle in [false, true] {
            var now: UInt64 = 0
            let token = FocusOperationToken(now: { now })
            XCTAssertTrue(token.beginTouch()); XCTAssertTrue(token.beginSyntheticInput())
            XCTAssertTrue(token.inputDidEnd())
            if lifecycle { token.observe(.lifecycleChanged) } else { now = 150_000_000 }
            XCTAssertFalse(token.beginRestore())
        }
    }

    func testOwnedRestoreNotificationsPermitVerificationButPhysicalChoiceRevokesIt() {
        var unchanged = true
        let token = FocusOperationToken(now: { 0 }, inputPermit: { unchanged })
        XCTAssertTrue(token.beginTouch())
        XCTAssertTrue(token.inputDidEnd())
        XCTAssertTrue(token.beginRestore())
        XCTAssertTrue(token.beginRestoreMutation())
        XCTAssertFalse(token.observe(.focusChanged))
        XCTAssertFalse(token.observe(.keyboardFocusChanged))
        XCTAssertTrue(token.isPermitted)
        unchanged = false
        XCTAssertFalse(token.isPermitted)
    }

    func testWindowChoiceBeforeRestoreCommitStillInvalidatesToken() {
        let token = FocusOperationToken(now: { 0 })
        XCTAssertTrue(token.beginTouch())
        XCTAssertTrue(token.inputDidEnd())
        XCTAssertTrue(token.beginRestore())
        token.observe(.focusChanged)
        XCTAssertFalse(token.beginRestoreMutation())
    }

    func testControlFocusChangesDuringTouchDoNotConsumeWindowEnrollment() {
        let token = FocusOperationToken(now: { 0 })
        XCTAssertTrue(token.beginTouch())
        XCTAssertFalse(token.observe(.keyboardFocusChanged))
        XCTAssertTrue(token.inputDidEnd())
        XCTAssertTrue(token.beginRestore())
    }

    func testTargetActivationHintsWaitForExplicitConfirmation() {
        let token = FocusOperationToken(now: { 0 })
        XCTAssertTrue(token.beginTouch())
        XCTAssertTrue(token.beginTargetActivation())
        XCTAssertFalse(token.observe(.focusChanged))
        XCTAssertFalse(token.observe(.keyboardFocusChanged))
        XCTAssertNil(token.beginEnrollment())
        XCTAssertTrue(token.endTargetActivation())
        let revision = token.beginEnrollment()!
        XCTAssertTrue(token.certifyEnrollment(revision: revision))
        XCTAssertTrue(token.inputDidEnd())
    }

    func testPhysicalChoiceDuringPreparationPermanentlyRevokesToken() {
        var unchanged = true
        let token = FocusOperationToken(now: { 0 }, inputPermit: { unchanged })
        unchanged = false
        XCTAssertFalse(token.beginTouch())
        unchanged = true
        XCTAssertFalse(token.isPermitted)
    }

    func testPhysicalChoiceAfterLiftPreventsRestoreEvenWithoutAXNotification() {
        var unchanged = true
        let token = FocusOperationToken(now: { 0 }, inputPermit: { unchanged })
        XCTAssertTrue(token.beginTouch())
        XCTAssertTrue(token.inputDidEnd())
        unchanged = false
        XCTAssertFalse(token.beginRestore())
        XCTAssertFalse(token.isPermitted)
    }

    func testRepeatedCleanupReleaseKeepsFirstFreezeAndRestorationDeadline() {
        var now: UInt64 = 0
        let token = FocusOperationToken(now: { now })
        XCTAssertTrue(token.beginTouch())
        XCTAssertTrue(token.inputDidEnd())
        XCTAssertFalse(token.inputDidEnd(), "Synthetic release must not freeze again.")
        XCTAssertTrue(token.isPermitted)
        XCTAssertTrue(token.beginRestore())
        now = 100_000_000
        XCTAssertFalse(token.inputDidEnd(), "Cancellation cleanup cannot restart restoration.")
        XCTAssertTrue(token.isPermitted)
        now = 150_000_000
        XCTAssertFalse(token.isPermitted, "Repeated release must not extend the restoration deadline.")
        XCTAssertFalse(token.inputDidEnd())
        XCTAssertFalse(token.beginRestore())
    }

    func testReleaseDuringPreparationCannotBeRevivedByCaptureOrRepeatedCleanup() {
        let token = FocusOperationToken(now: { 0 })
        XCTAssertFalse(token.inputDidEnd())
        XCTAssertFalse(token.beginTouch())
        XCTAssertFalse(token.inputDidEnd())
        XCTAssertFalse(token.isPermitted)
    }

    func testRepeatedReleaseCannotRevivePostReleaseFocusInvalidation() {
        let token = FocusOperationToken(now: { 0 })
        XCTAssertTrue(token.beginTouch())
        XCTAssertTrue(token.inputDidEnd())
        token.observe(.focusChanged)
        XCTAssertFalse(token.inputDidEnd())
        XCTAssertFalse(token.isPermitted)
        XCTAssertFalse(token.beginRestore())
    }

    func testPreparationDeadlineCannotBeRevivedByLateCompletion() {
        var now: UInt64 = 0
        let token = FocusOperationToken(now: { now })
        now = 30_000_000
        XCTAssertFalse(token.isPermitted)
        XCTAssertFalse(token.beginTouch())
    }

    func testFocusChangesAllowedOnlyBeforeInputEnds() {
        let token = FocusOperationToken(now: { 0 })
        XCTAssertTrue(token.beginTouch())
        token.observe(.focusChanged)
        XCTAssertTrue(token.isPermitted)
        let revision = token.beginEnrollment()!
        XCTAssertTrue(token.certifyEnrollment(revision: revision))
        XCTAssertTrue(token.inputDidEnd())
        token.observe(.focusChanged)
        XCTAssertFalse(token.isPermitted)
        XCTAssertFalse(token.beginRestore())
    }

    func testDirtyUncertifiedReleaseCannotBeRevivedByLateEnrollment() {
        let token = FocusOperationToken(now: { 0 })
        XCTAssertTrue(token.beginTouch())
        XCTAssertTrue(token.observe(.focusChanged))
        let revision = token.beginEnrollment()!
        XCTAssertFalse(token.inputDidEnd())
        XCTAssertFalse(token.permitsEnrollment(revision: revision))
        XCTAssertFalse(token.certifyEnrollment(revision: revision))
        XCTAssertFalse(token.beginRestore())
    }

    func testFocusHintsCoalesceBeforeOneEnrollmentAndDirtyCertificateAfterward() {
        let token = FocusOperationToken(now: { 0 })
        XCTAssertTrue(token.beginTouch())
        XCTAssertTrue(token.observe(.focusChanged))
        for _ in 0..<100 { XCTAssertFalse(token.observe(.focusChanged)) }
        let revision = token.beginEnrollment()!
        XCTAssertEqual(revision, 101)
        XCTAssertTrue(token.certifyEnrollment(revision: revision))
        XCTAssertFalse(token.observe(.focusChanged))
        XCTAssertNil(token.beginEnrollment())
        XCTAssertFalse(token.inputDidEnd())
        XCTAssertFalse(token.beginRestore())
    }

    func testHintDuringEnrollmentRejectsCertificationForOldRevision() {
        let token = FocusOperationToken(now: { 0 })
        XCTAssertTrue(token.beginTouch())
        token.observe(.focusChanged)
        let revision = token.beginEnrollment()!
        token.observe(.focusChanged)
        XCTAssertFalse(token.permitsEnrollment(revision: revision))
        XCTAssertFalse(token.certifyEnrollment(revision: revision))
        XCTAssertNil(token.beginEnrollment())
        XCTAssertFalse(token.inputDidEnd())
    }

    func testEnrollmentBudgetCannotBeExtendedByFocusHints() {
        var now: UInt64 = 0
        let token = FocusOperationToken(now: { now })
        XCTAssertTrue(token.beginTouch())
        token.observe(.focusChanged)
        let revision = token.beginEnrollment()!
        now = 150_000_000
        XCTAssertFalse(token.permitsEnrollment(revision: revision))
        XCTAssertFalse(token.certifyEnrollment(revision: revision))
        XCTAssertFalse(token.inputDidEnd())
    }

    func testReleasedEnrollmentRetainsActualSlotUntilCleanupReturns() {
        let state = FocusOperationState()
        let token = FocusOperationToken(now: { 0 })
        XCTAssertTrue(state.beginPreparation(token: token))
        state.finishOperation()
        XCTAssertTrue(token.beginTouch())
        token.observe(.focusChanged)
        XCTAssertNotNil(state.beginEnrollment(token: token))
        XCTAssertFalse(state.inputDidEnd())
        XCTAssertFalse(state.beginRestoration(token: token))
        XCTAssertFalse(state.beginCleanup())
        XCTAssertFalse(state.beginPreparation(token: FocusOperationToken(now: { 0 })))
        state.finishOperation()
        XCTAssertTrue(state.beginPreparation(token: FocusOperationToken(now: { 0 })))
    }

    func testLifecycleInvalidationDuringTouchIsImmediate() {
        let token = FocusOperationToken(now: { 0 })
        XCTAssertTrue(token.beginTouch())
        token.observe(.lifecycleChanged)
        XCTAssertFalse(token.isPermitted)
    }

    func testRestorationBudgetStartsAfterCursorCleanupDelay() {
        var now: UInt64 = 0
        let token = FocusOperationToken(now: { now })
        XCTAssertTrue(token.beginTouch())
        token.inputDidEnd()
        now = 1_000_000_000
        XCTAssertTrue(token.beginRestore())
        now += 149_000_000
        XCTAssertTrue(token.isPermitted)
        now += 1_000_000
        XCTAssertFalse(token.isPermitted)
    }

    func testRestoreRequiresInputRelease() {
        let token = FocusOperationToken(now: { 0 })
        XCTAssertTrue(token.beginTouch())
        XCTAssertFalse(token.beginRestore())
        token.inputDidEnd()
        XCTAssertTrue(token.beginRestore())
        XCTAssertFalse(token.beginRestore())
    }

    func testTimeoutDoesNotFreeActualOperationSlot() {
        var now: UInt64 = 0
        let state = FocusOperationState()
        let first = FocusOperationToken(now: { now })
        XCTAssertTrue(state.beginPreparation(token: first))
        now = 40_000_000
        XCTAssertFalse(first.isPermitted)
        XCTAssertFalse(state.beginPreparation(token: FocusOperationToken(now: { now })))
        XCTAssertFalse(state.beginCleanup())
        state.finishOperation()
        XCTAssertTrue(state.beginPreparation(token: FocusOperationToken(now: { now })))
    }

    func testShutdownNeverAdmitsAnotherPreparationButAllowsActualCleanup() {
        let state = FocusOperationState()
        let token = FocusOperationToken(now: { 0 })
        XCTAssertTrue(state.beginPreparation(token: token))
        state.invalidate(shutdown: true)
        XCTAssertTrue(state.isStopped)
        XCTAssertFalse(token.isPermitted)
        state.finishOperation()
        XCTAssertFalse(state.beginPreparation(token: FocusOperationToken(now: { 0 })))
        XCTAssertTrue(state.beginCleanup())
        XCTAssertFalse(state.beginCleanup())
    }
}
