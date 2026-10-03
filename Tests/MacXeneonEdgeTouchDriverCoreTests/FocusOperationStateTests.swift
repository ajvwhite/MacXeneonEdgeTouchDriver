import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class FocusOperationStateTests: XCTestCase {
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
        token.inputDidEnd()
        token.observe(.focusChanged)
        XCTAssertFalse(token.isPermitted)
        XCTAssertFalse(token.beginRestore())
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
