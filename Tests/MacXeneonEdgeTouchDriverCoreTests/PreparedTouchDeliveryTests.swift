import CoreGraphics
import Foundation
import XCTest
@testable import MacXeneonEdgeTouchDriverCore

final class PreparedTouchDeliveryTests: XCTestCase {
    func testQuickTapWaitsForExactTargetThenDeliversOneBalancedClick() {
        let f = PreparedDeliveryFixture()
        f.send(.down)
        f.send(.up)
        XCTAssertTrue(f.events.isEmpty)
        f.preparer.complete(true)
        XCTAssertEqual(f.events, ["borrow", "down", "up", "release"])
        XCTAssertEqual(f.controller.state, .idle)
    }

    func testBufferedDragPreservesEveryPointAndReleaseInOrder() {
        let f = PreparedDeliveryFixture()
        f.send(.down)
        for x in [100, 200, 300] { f.send(.move, x: x) }
        f.send(.up, x: 300)
        XCTAssertTrue(f.events.isEmpty)
        f.preparer.complete(true)
        XCTAssertEqual(f.events, ["borrow", "down", "move:100", "drag:100", "move:200", "drag:200", "move:300", "drag:300", "up", "release"])
    }

    func testRejectedTargetCannotSendASpeculativeClick() {
        let f = PreparedDeliveryFixture()
        f.send(.down); f.send(.up)
        f.preparer.complete(false)
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertEqual(f.controller.state, .idle)
        f.send(.down); f.send(.up)
        f.preparer.complete(true)
        XCTAssertEqual(f.events, ["borrow", "down", "up", "release"])
    }

    func testTargetTimeoutAndLateCompletionCannotPostInput() {
        let f = PreparedDeliveryFixture()
        f.send(.down); f.send(.up)
        f.clock.advance(toMilliseconds: 150)
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertEqual(f.controller.state, .idle)
        f.preparer.complete(true)
        XCTAssertTrue(f.events.isEmpty)
    }

    func testLateTargetCallbackCannotBeatAnOverdueTimerOnABusyGestureQueue() {
        let f = PreparedDeliveryFixture()
        f.send(.down); f.send(.up)
        f.clock.advance(toNanoseconds: 150_000_000, beforeDueActions: {
            f.preparer.complete(true)
        })
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertEqual(f.controller.state, .idle)
    }

    func testCancellationAfterPhysicalLiftCancelsQueuedTap() {
        let f = PreparedDeliveryFixture()
        f.send(.down); f.send(.up)
        f.controller.forceCancel()
        f.preparer.complete(true)
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertEqual(f.controller.state, .idle)
    }

    func testBufferOverflowCancelsWithoutDroppingIntoABrokenDrag() {
        let f = PreparedDeliveryFixture()
        f.send(.down)
        for x in 0...256 { f.send(.move, x: x) }
        f.send(.up)
        f.preparer.complete(true)
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertEqual(f.controller.state, .idle)
    }
}

private final class PreparedDeliveryFixture: SyntheticInputSink, CursorController {
    let clock = TestGestureScheduler(executeCancelledActions: true)
    let preparer = PendingTargetPreparer()
    var events: [String] = []
    lazy var controller = GestureController(
        mapperProvider: { CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 16384, height: 9600)) },
        inputSink: self, cursorController: self, scheduler: clock, targetPreparer: preparer)
    func send(_ kind: TouchEvent.Kind, x: Int = 0) {
        controller.handle(TouchEvent(kind: kind, contactID: 0, rawX: x, rawY: 0, timestamp: clock.now))
    }
    func postMouseDown(at point: CGPoint) { events.append("down") }
    func postMouseUp(at point: CGPoint) { events.append("up") }
    func postMouseDragged(to point: CGPoint) { events.append("drag:\(Int(point.x))") }
    func borrow(warpingTo point: CGPoint) -> Bool { events.append("borrow"); return true }
    func updatePosition(_ point: CGPoint) { events.append("move:\(Int(point.x))") }
    func releaseBorrow(returnToPreviousPosition: Bool) { events.append("release") }
    func returnToOrigin() { events.append("release") }
    func forceShow() {}
}

private final class PendingTargetPreparer: TouchTargetPreparing {
    let requiresPreparation = true
    var pending: [(Bool) -> Void] = []
    func prepare(at point: CGPoint, completion: @escaping (Bool) -> Void) { pending.append(completion) }
    func cancel() {}
    func complete(_ accepted: Bool) { pending.removeFirst()(accepted) }
}
