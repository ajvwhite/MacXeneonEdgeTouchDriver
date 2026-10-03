import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class CGCursorControllerTests: XCTestCase {
    private let origin = CGPoint(x: 40, y: 50)
    private let touch = CGPoint(x: 200, y: 300)
    private let drag = CGPoint(x: 250, y: 350)

    func testReturnToOriginPreservesCleanupOrderAndBalancesHide() {
        let effects = RecordingCursorOperations(position: origin)
        let cursor = makeCursor(effects)

        XCTAssertTrue(cursor.borrow(warpingTo: touch))
        cursor.returnToOrigin()

        XCTAssertEqual(effects.calls, [.position, .hide(7), .associate(false), .warp(touch),
                                       .associate(true), .warp(origin), .show(7)])
        XCTAssertEqual(effects.position, origin)
        XCTAssertEqual(effects.hideBalance, 0)
        XCTAssertTrue(effects.isAssociated)
    }

    func testReleaseWithoutReturnAfterDragDoesNotWarpToOrigin() {
        let effects = RecordingCursorOperations(position: origin)
        let cursor = makeCursor(effects)

        XCTAssertTrue(cursor.borrow(warpingTo: touch))
        cursor.updatePosition(drag)
        cursor.releaseBorrow(returnToPreviousPosition: false)

        XCTAssertEqual(effects.calls, [.position, .hide(7), .associate(false), .warp(touch),
                                       .warp(drag), .associate(true), .show(7)])
        XCTAssertEqual(effects.position, drag)
        XCTAssertEqual(effects.hideBalance, 0)
        XCTAssertTrue(effects.isAssociated)
    }

    func testReleaseWithoutReturnPreservesPhysicalPositionChangeAndClearsBorrow() {
        let effects = RecordingCursorOperations(position: origin)
        let cursor = makeCursor(effects)
        let physicalPosition = CGPoint(x: 900, y: 700)
        XCTAssertTrue(cursor.borrow(warpingTo: touch))
        cursor.updatePosition(drag)
        effects.position = physicalPosition

        cursor.releaseBorrow(returnToPreviousPosition: false)
        let releasedCalls = effects.calls
        cursor.updatePosition(touch)

        XCTAssertEqual(effects.position, physicalPosition)
        XCTAssertEqual(effects.calls, releasedCalls, "A released borrow must reject later touch warps.")
        XCTAssertEqual(effects.hideBalance, 0)
        XCTAssertTrue(effects.isAssociated)
    }

    func testRepeatedReleaseDoesNotWarpOrShowAgain() {
        for shouldReturn in [true, false] {
            let effects = RecordingCursorOperations(position: origin)
            let cursor = makeCursor(effects)
            XCTAssertTrue(cursor.borrow(warpingTo: touch))
            cursor.releaseBorrow(returnToPreviousPosition: shouldReturn)
            let releasedCalls = effects.calls

            cursor.releaseBorrow(returnToPreviousPosition: true)
            cursor.forceShow()

            XCTAssertEqual(effects.calls, releasedCalls)
            XCTAssertEqual(effects.hideBalance, 0)
            XCTAssertTrue(effects.isAssociated)
        }
    }

    func testNextBorrowCapturesNewOriginAfterReleaseWithoutReturn() {
        let effects = RecordingCursorOperations(position: origin)
        let cursor = makeCursor(effects)
        XCTAssertTrue(cursor.borrow(warpingTo: touch))
        cursor.releaseBorrow(returnToPreviousPosition: false)
        let nextOrigin = CGPoint(x: 700, y: 800)
        effects.position = nextOrigin

        XCTAssertTrue(cursor.borrow(warpingTo: drag))
        cursor.releaseBorrow(returnToPreviousPosition: true)

        XCTAssertEqual(effects.position, nextOrigin)
        XCTAssertEqual(effects.calls.filter { $0 == .position }.count, 2)
        XCTAssertEqual(effects.calls.filter { $0 == .hide(7) }.count, 2)
        XCTAssertEqual(effects.calls.filter { $0 == .show(7) }.count, 2)
        XCTAssertEqual(effects.hideBalance, 0)
    }

    func testMissingPositionRefusesBorrowWithoutCursorEffects() {
        let effects = RecordingCursorOperations(position: nil)
        let cursor = makeCursor(effects)

        XCTAssertFalse(cursor.borrow(warpingTo: touch))
        cursor.releaseBorrow(returnToPreviousPosition: false)

        XCTAssertEqual(effects.calls, [.position])
        XCTAssertEqual(effects.hideBalance, 0)
        XCTAssertTrue(effects.isAssociated)
    }

    func testInitialWarpFailureRollsBackBorrow() {
        let effects = RecordingCursorOperations(position: origin)
        effects.warpResults = [.failure]
        let cursor = makeCursor(effects)

        XCTAssertFalse(cursor.borrow(warpingTo: touch))
        cursor.releaseBorrow(returnToPreviousPosition: true)
        cursor.updatePosition(drag)

        XCTAssertEqual(effects.calls, [.position, .hide(7), .associate(false), .warp(touch),
                                       .associate(true), .show(7)])
        XCTAssertEqual(effects.position, origin)
        XCTAssertEqual(effects.hideBalance, 0)
        XCTAssertTrue(effects.isAssociated)
    }

    func testFailedWarpDuringExistingBorrowRetainsOwnershipUntilRelease() {
        let effects = RecordingCursorOperations(position: origin)
        effects.warpResults = [.success, .failure]
        let cursor = makeCursor(effects)
        XCTAssertTrue(cursor.borrow(warpingTo: touch))

        XCTAssertFalse(cursor.borrow(warpingTo: drag))
        XCTAssertEqual(effects.hideBalance, 1)
        XCTAssertFalse(effects.isAssociated)
        cursor.releaseBorrow(returnToPreviousPosition: true)

        XCTAssertEqual(effects.calls.filter { $0 == .position }.count, 1)
        XCTAssertEqual(effects.calls.filter { $0 == .hide(7) }.count, 1)
        XCTAssertEqual(effects.position, origin)
        XCTAssertEqual(effects.hideBalance, 0)
    }

    func testFailedHideDoesNotCauseUnbalancedShowAndNextBorrowRetriesHide() {
        let effects = RecordingCursorOperations(position: origin)
        effects.hideResults = [.failure, .success]
        let cursor = makeCursor(effects)
        XCTAssertTrue(cursor.borrow(warpingTo: touch))
        cursor.releaseBorrow(returnToPreviousPosition: false)
        XCTAssertFalse(effects.calls.contains(.show(7)))

        XCTAssertTrue(cursor.borrow(warpingTo: drag))
        cursor.releaseBorrow(returnToPreviousPosition: false)

        XCTAssertEqual(effects.calls.filter { $0 == .hide(7) }.count, 2)
        XCTAssertEqual(effects.calls.filter { $0 == .show(7) }.count, 1)
        XCTAssertEqual(effects.hideBalance, 0)
        XCTAssertTrue(effects.isAssociated)
    }

    func testFailedShowIsRetriedWithoutRepeatingOriginWarp() {
        let effects = RecordingCursorOperations(position: origin)
        effects.showResults = [.failure, .success]
        let cursor = makeCursor(effects)
        XCTAssertTrue(cursor.borrow(warpingTo: touch))
        cursor.releaseBorrow(returnToPreviousPosition: true)
        XCTAssertEqual(effects.hideBalance, 1)

        cursor.releaseBorrow(returnToPreviousPosition: true)
        cursor.forceShow()

        XCTAssertEqual(effects.calls.filter { $0 == .warp(origin) }.count, 1)
        XCTAssertEqual(effects.calls.filter { $0 == .show(7) }.count, 2)
        XCTAssertEqual(effects.hideBalance, 0)
        XCTAssertTrue(effects.isAssociated)
    }

    func testNewBorrowAfterFailedShowDoesNotHideTwice() {
        let effects = RecordingCursorOperations(position: origin)
        effects.showResults = [.failure, .success]
        let cursor = makeCursor(effects)
        XCTAssertTrue(cursor.borrow(warpingTo: touch))
        cursor.releaseBorrow(returnToPreviousPosition: false)

        XCTAssertTrue(cursor.borrow(warpingTo: drag))
        cursor.releaseBorrow(returnToPreviousPosition: false)

        XCTAssertEqual(effects.calls.filter { $0 == .hide(7) }.count, 1)
        XCTAssertEqual(effects.calls.filter { $0 == .show(7) }.count, 2)
        XCTAssertEqual(effects.hideBalance, 0)
        XCTAssertTrue(effects.isAssociated)
    }

    func testFailedReassociationStillShowsAndLaterReleaseRetriesOnlyAssociation() {
        let effects = RecordingCursorOperations(position: origin)
        effects.associationResults = [.success, .failure, .success]
        let cursor = makeCursor(effects)
        XCTAssertTrue(cursor.borrow(warpingTo: touch))
        cursor.releaseBorrow(returnToPreviousPosition: false)
        XCTAssertEqual(effects.hideBalance, 0)
        XCTAssertFalse(effects.isAssociated)

        cursor.forceShow()

        XCTAssertEqual(effects.calls, [.position, .hide(7), .associate(false), .warp(touch),
                                       .associate(true), .show(7), .associate(true)])
        XCTAssertTrue(effects.isAssociated)
        XCTAssertEqual(effects.position, touch)
    }

    func testFailedDisassociationIsRetriedOnNextBorrow() {
        let effects = RecordingCursorOperations(position: origin)
        effects.associationResults = [.failure, .success, .success]
        let cursor = makeCursor(effects)
        XCTAssertTrue(cursor.borrow(warpingTo: touch))
        XCTAssertTrue(effects.isAssociated)
        cursor.releaseBorrow(returnToPreviousPosition: false)

        XCTAssertTrue(cursor.borrow(warpingTo: drag))
        XCTAssertFalse(effects.isAssociated)
        cursor.releaseBorrow(returnToPreviousPosition: false)

        XCTAssertEqual(effects.calls.filter { $0 == .associate(false) }.count, 2)
        XCTAssertEqual(effects.calls.filter { $0 == .associate(true) }.count, 1)
        XCTAssertEqual(effects.hideBalance, 0)
        XCTAssertTrue(effects.isAssociated)
    }

    func testFailedOriginWarpDoesNotPreventRecoveryOrLeaveStaleOrigin() {
        let effects = RecordingCursorOperations(position: origin)
        effects.warpResults = [.success, .failure]
        let cursor = makeCursor(effects)
        XCTAssertTrue(cursor.borrow(warpingTo: touch))

        cursor.releaseBorrow(returnToPreviousPosition: true)
        cursor.releaseBorrow(returnToPreviousPosition: true)

        XCTAssertEqual(effects.calls.filter { $0 == .warp(origin) }.count, 1)
        XCTAssertEqual(effects.position, touch)
        XCTAssertEqual(effects.hideBalance, 0)
        XCTAssertTrue(effects.isAssociated)
    }

    func testFailedBorrowRollbackRetainsRecoveryFailuresForRetry() {
        let effects = RecordingCursorOperations(position: origin)
        effects.warpResults = [.failure]
        effects.associationResults = [.success, .failure, .success]
        effects.showResults = [.failure, .success]
        let cursor = makeCursor(effects)
        XCTAssertFalse(cursor.borrow(warpingTo: touch))
        XCTAssertEqual(effects.hideBalance, 1)
        XCTAssertFalse(effects.isAssociated)

        cursor.releaseBorrow(returnToPreviousPosition: false)

        XCTAssertEqual(effects.hideBalance, 0)
        XCTAssertTrue(effects.isAssociated)
        XCTAssertEqual(effects.calls.filter { $0 == .hide(7) }.count, 1)
        XCTAssertEqual(effects.calls.filter { $0 == .show(7) }.count, 2)
        XCTAssertEqual(effects.calls.filter { $0 == .warp(touch) }.count, 1)
    }

    func testDefaultReleaseImplementationSupportsExistingConformers() {
        let cursor: CursorController = LegacyCursorController()
        cursor.releaseBorrow(returnToPreviousPosition: true)
        cursor.releaseBorrow(returnToPreviousPosition: false)

        XCTAssertEqual((cursor as? LegacyCursorController)?.calls, ["return", "forceShow"])
    }

    private func makeCursor(_ effects: RecordingCursorOperations) -> CGCursorController {
        CGCursorController(displayIDProvider: { 7 }, operations: effects.operations)
    }
}

private final class RecordingCursorOperations {
    enum Call: Equatable {
        case position
        case warp(CGPoint)
        case hide(CGDirectDisplayID)
        case show(CGDirectDisplayID)
        case associate(Bool)
    }

    var position: CGPoint?
    var warpResults: [CGError] = []
    var hideResults: [CGError] = []
    var showResults: [CGError] = []
    var associationResults: [CGError] = []
    private(set) var calls: [Call] = []
    private(set) var hideBalance = 0
    private(set) var isAssociated = true

    init(position: CGPoint?) { self.position = position }

    var operations: CGCursorController.Operations {
        CGCursorController.Operations(
            currentPosition: {
                self.calls.append(.position)
                return self.position
            },
            warp: { point in
                self.calls.append(.warp(point))
                let result = Self.nextResult(&self.warpResults)
                if result == .success { self.position = point }
                return result
            },
            hide: { display in
                self.calls.append(.hide(display))
                let result = Self.nextResult(&self.hideResults)
                if result == .success { self.hideBalance += 1 }
                return result
            },
            show: { display in
                self.calls.append(.show(display))
                let result = Self.nextResult(&self.showResults)
                if result == .success { self.hideBalance -= 1 }
                return result
            },
            associate: { associated in
                self.calls.append(.associate(associated))
                let result = Self.nextResult(&self.associationResults)
                if result == .success { self.isAssociated = associated }
                return result
            }
        )
    }

    private static func nextResult(_ results: inout [CGError]) -> CGError {
        results.isEmpty ? .success : results.removeFirst()
    }
}

private final class LegacyCursorController: CursorController {
    private(set) var calls: [String] = []
    func borrow(warpingTo point: CGPoint) -> Bool { true }
    func updatePosition(_ point: CGPoint) {}
    func returnToOrigin() { calls.append("return") }
    func forceShow() { calls.append("forceShow") }
}
