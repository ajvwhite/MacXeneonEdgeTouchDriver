import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class GestureCleanupTests: XCTestCase {
    func testOverlappingTapCleanupCannotEndLaterGestureWithReusedContactID() {
        let fixture = Fixture(timing: timing(up: 20, back: 100, debounce: 50))
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1)
        fixture.send(.down, at: 10, far: true)
        fixture.send(.up, at: 20, far: true)
        fixture.clock.advance(toMilliseconds: 121)
        XCTAssertEqual(fixture.controller.state, .idle)

        fixture.send(.down, at: 130, far: true)
        fixture.clock.advance(toMilliseconds: 140)
        XCTAssertTrue(fixture.isPressed, "An earlier cursor-return callback must not idle the new gesture")
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.send(.up, at: 150, far: true)
        fixture.clock.advance(toMilliseconds: 270)

        XCTAssertEqual(fixture.input.calls, [.down(near), .up(near), .down(far), .up(far)])
        XCTAssertEqual(fixture.cursor.calls, [.borrow(near), .returned, .borrow(far), .returned])
        XCTAssertEqual(fixture.focus.calls, [.capture, .restore, .capture, .restore])
        XCTAssertEqual(fixture.idleCount, 2)
        fixture.assertBalanced()
    }

    func testIgnoredContactNeverDragsOrReleasesTapDuringCleanup() {
        for gestureTiming in [GestureTiming(configuration: DriverConfiguration.defaults.timing), timing(up: 20, back: 100, debounce: 50)] {
            let fixture = Fixture(timing: gestureTiming)
            fixture.send(.down, at: 0)
            fixture.send(.up, at: 1)
            fixture.send(.down, at: 10, far: true)
            fixture.send(.move, at: 12, far: true)
            fixture.send(.up, at: 20, far: true)
            fixture.clock.advance(toMilliseconds: 500)

            XCTAssertEqual(fixture.input.calls, [.down(near), .up(near)])
            XCTAssertEqual(fixture.cursor.calls, [.borrow(near), .returned])
            XCTAssertEqual(fixture.idleCount, 1)
            fixture.assertBalanced()
        }
    }

    func testMoveAndRepeatedUpAfterPhysicalUpDoNotRestartCleanup() {
        let fixture = Fixture(timing: timing(up: 20, back: 100))
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1)
        fixture.send(.up, at: 10, far: true)
        fixture.clock.advance(toMilliseconds: 21)
        XCTAssertFalse(fixture.isPressed, "Posting mouse-up must release button ownership")
        fixture.send(.move, at: 22, far: true)
        fixture.send(.up, at: 23, far: true)
        fixture.clock.advance(toMilliseconds: 121)

        XCTAssertEqual(fixture.input.calls, [.down(near), .up(near)])
        XCTAssertEqual(fixture.cursor.calls, [.borrow(near), .returned])
        XCTAssertEqual(fixture.idleCount, 1)
        XCTAssertEqual(fixture.controller.state, .idle)
        fixture.clock.advance(toMilliseconds: 1_000)
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.assertBalanced()
    }

    func testRejectedContactStaysRejectedAfterCleanupUntilItsUp() {
        let fixture = Fixture(timing: timing(up: 20, back: 10, debounce: 50))
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1)
        fixture.send(.down, at: 10, far: true)
        fixture.clock.advance(toMilliseconds: 31)
        fixture.send(.move, at: 60, far: true)
        fixture.send(.down, at: 61, far: true)
        XCTAssertEqual(fixture.input.calls, [.down(near), .up(near)])
        fixture.send(.up, at: 62, far: true)
        fixture.send(.down, at: 63, far: true)
        fixture.send(.up, at: 64, far: true)
        fixture.clock.advance(toMilliseconds: 100)

        XCTAssertEqual(fixture.input.calls, [.down(near), .up(near), .down(far), .up(far)])
        fixture.assertBalanced()
    }

    func testQuarantinedUpIsConsumedEvenWithoutMapper() {
        let fixture = Fixture(timing: timing(up: 20, back: 10))
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1)
        fixture.send(.down, at: 10, far: true)
        fixture.hasMapper = false
        fixture.send(.up, at: 20, far: true)
        fixture.clock.advance(toMilliseconds: 31)
        fixture.hasMapper = true
        fixture.send(.down, at: 32, far: true)
        fixture.send(.up, at: 33, far: true)
        fixture.clock.advance(toMilliseconds: 100)

        XCTAssertEqual(fixture.input.calls, [.down(near), .up(near), .down(far), .up(far)])
        fixture.assertBalanced()
    }

    func testDebouncedContactStaysRejectedUntilUpWithoutMovingDebounceBoundary() {
        let fixture = Fixture(timing: timing(debounce: 50))
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1)
        fixture.send(.down, at: 50, far: true)
        fixture.send(.down, at: 51, far: true)
        XCTAssertEqual(fixture.input.calls, [.down(near), .up(near)])
        fixture.send(.up, at: 52, far: true)
        fixture.send(.down, at: 53, far: true)
        fixture.send(.up, at: 54, far: true)

        XCTAssertEqual(fixture.input.calls, [.down(near), .up(near), .down(far), .up(far)])
        fixture.assertBalanced()
    }

    func testDebounceAcceptsExactBoundary() {
        for downTime: UInt64 in [50, 51] {
            let fixture = Fixture(timing: timing(debounce: 50))
            fixture.send(.down, at: 0)
            fixture.send(.up, at: 1)
            fixture.send(.down, at: downTime, far: true)
            fixture.send(.up, at: downTime + 1, far: true)
            XCTAssertEqual(fixture.input.calls.count, downTime == 50 ? 2 : 4)
            fixture.assertBalanced()
        }
    }

    func testBorrowFailureRejectsContactUntilUp() {
        let fixture = Fixture(timing: .immediate)
        fixture.cursor.shouldBorrow = false
        fixture.send(.down, at: 0)
        fixture.cursor.shouldBorrow = true
        fixture.send(.down, at: 1, far: true)
        fixture.send(.move, at: 2, far: true)
        XCTAssertTrue(fixture.input.calls.isEmpty)
        fixture.send(.up, at: 3)
        fixture.send(.down, at: 4, far: true)
        fixture.send(.up, at: 5, far: true)

        XCTAssertEqual(fixture.input.calls, [.down(far), .up(far)])
        fixture.assertBalanced()
    }

    func testDuplicateDownForActiveHardwareIDCancelsThenRejectsAmbiguousContact() {
        let fixture = Fixture(timing: .immediate)
        fixture.send(.down, at: 0)
        fixture.send(.down, at: 1, far: true)
        fixture.send(.move, at: 2, far: true)
        fixture.send(.up, at: 3, far: true)

        XCTAssertEqual(fixture.input.calls, [.down(near), .up(near)])
        XCTAssertEqual(fixture.cursor.calls, [.borrow(near), .returned])
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.send(.down, at: 4, far: true)
        fixture.send(.up, at: 5, far: true)
        fixture.assertBalanced()
    }

    func testDifferentContactCannotMoveOrReleaseAcceptedDrag() {
        let fixture = Fixture(timing: .immediate)
        fixture.send(.down, at: 0)
        fixture.send(.down, at: 1, far: true, contactID: 1)
        fixture.send(.move, at: 2, far: true, contactID: 1)
        fixture.send(.up, at: 3, far: true, contactID: 1)
        XCTAssertEqual(fixture.input.calls, [.down(near)])
        fixture.send(.move, at: 4, far: true)
        fixture.send(.up, at: 5, far: true)

        XCTAssertEqual(fixture.input.calls, [.down(near), .drag(far), .up(far)])
        fixture.assertBalanced()
    }

    func testCancelledMouseDownCannotPressLaterGestureWithSameContactID() {
        let fixture = Fixture(timing: timing(warp: 100), deliverCancelled: true)
        fixture.send(.down, at: 0)
        fixture.clock.advance(toMilliseconds: 1)
        fixture.controller.forceCancel()
        fixture.send(.down, at: 10, far: true)
        fixture.clock.advance(toMilliseconds: 100)
        XCTAssertTrue(fixture.input.calls.isEmpty)
        fixture.clock.advance(toMilliseconds: 110)
        fixture.send(.up, at: 111, far: true)

        XCTAssertEqual(fixture.input.calls, [.down(far), .up(far)])
        fixture.assertBalanced()
    }

    func testCancelledMouseUpCannotReleaseLaterGestureWithSameContactID() {
        let fixture = Fixture(timing: timing(up: 20, back: 100), deliverCancelled: true)
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1)
        fixture.clock.advance(toMilliseconds: 10)
        fixture.controller.forceCancel()
        fixture.send(.down, at: 11, far: true)
        fixture.clock.advance(toMilliseconds: 21)
        XCTAssertEqual(fixture.input.calls, [.down(near), .up(near), .down(far)])
        XCTAssertTrue(fixture.isPressed)
        fixture.send(.up, at: 22, far: true)
        fixture.clock.advance(toMilliseconds: 142)

        XCTAssertEqual(fixture.input.calls, [.down(near), .up(near), .down(far), .up(far)])
        XCTAssertEqual(fixture.idleCount, 2)
        fixture.assertBalanced()
    }

    func testCancelledCursorReturnCannotIdleLaterGestureWithSameContactID() {
        let fixture = Fixture(timing: timing(back: 100), deliverCancelled: true)
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1)
        fixture.clock.advance(toMilliseconds: 10)
        fixture.controller.forceCancel()
        fixture.send(.down, at: 11, far: true)
        fixture.clock.advance(toMilliseconds: 101)
        XCTAssertTrue(fixture.isPressed)
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.send(.up, at: 102, far: true)
        fixture.clock.advance(toMilliseconds: 202)

        XCTAssertEqual(fixture.input.calls, [.down(near), .up(near), .down(far), .up(far)])
        XCTAssertEqual(fixture.idleCount, 2)
        fixture.assertBalanced()
    }

    func testCancelledDelayedDownCannotRepressGestureDuringCursorReturn() {
        let fixture = Fixture(timing: timing(warp: 100, up: 20, back: 200), deliverCancelled: true)
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1)
        fixture.clock.advance(toMilliseconds: 100)
        XCTAssertEqual(fixture.input.calls, [.down(near), .up(near)])
        XCTAssertFalse(fixture.isPressed)
        fixture.clock.advance(toMilliseconds: 221)
        fixture.assertBalanced()
    }

    func testCancellationIsIdempotentBeforeAndAfterMouseUp() {
        for cancelTime: UInt64 in [10, 21, 25, 121] {
            let fixture = Fixture(timing: timing(up: 20, back: 100), deliverCancelled: true)
            fixture.send(.down, at: 0)
            fixture.send(.up, at: 1)
            fixture.clock.advance(toMilliseconds: cancelTime)
            fixture.controller.forceCancel()
            fixture.controller.forceCancel()
            fixture.clock.advance(toMilliseconds: 1_000)

            XCTAssertEqual(fixture.input.calls, [.down(near), .up(near)])
            XCTAssertEqual(fixture.cursor.calls.filter { $0 == .returned }.count, 1)
            XCTAssertEqual(fixture.focus.calls.filter { $0 == .restore }.count, 1)
            XCTAssertEqual(fixture.idleCount, 1)
            XCTAssertEqual(fixture.controller.state, .idle)
            fixture.assertBalanced()
        }
    }

    func testTapAndImmediateDragPreservedAcrossZeroDefaultAndCustomDelays() {
        let timings = [.immediate, GestureTiming(configuration: DriverConfiguration.defaults.timing),
                       timing(warp: 100, up: 50, back: 200), timing(warp: 1, up: 1, back: 1)]
        for gestureTiming in timings {
            for isDrag in [false, true] {
                let fixture = Fixture(timing: gestureTiming)
                fixture.send(.down, at: 0)
                if isDrag {
                    fixture.send(.move, at: 1, far: true)
                    XCTAssertEqual(fixture.input.calls, [.down(near), .drag(far)])
                }
                fixture.send(.up, at: 2, far: isDrag)
                if isDrag {
                    XCTAssertEqual(fixture.input.calls.last, .up(far), "Drags release immediately")
                }
                fixture.clock.advance(toMilliseconds: 1_000)
                XCTAssertEqual(fixture.input.calls, isDrag ? [.down(near), .drag(far), .up(far)] : [.down(near), .up(near)])
                XCTAssertEqual(fixture.focus.calls, [.capture, .restore])
                XCTAssertEqual(fixture.idleCount, 1)
                XCTAssertEqual(fixture.controller.state, .idle)
                fixture.assertBalanced()
            }
        }
    }
}

private let near = CGPoint(x: 100, y: 200)
private let far = CGPoint(x: CGFloat(2_660).nextDown, y: CGFloat(920).nextDown)

private func timing(warp: Int = 0, up: Int = 0, back: Int = 0, debounce: Int = 0) -> GestureTiming {
    GestureTiming(warpToClickDelayMs: warp, downToUpDelayMs: up, clickToWarpBackDelayMs: back, tapDebounceMs: debounce)
}

private final class Fixture {
    let clock: TestGestureScheduler
    let input = CleanupInputSink()
    let cursor = CleanupCursorController()
    let focus = CleanupFocusRestorer()
    var hasMapper = true
    var idleCount = 0
    private(set) var controller: GestureController!

    init(timing: GestureTiming, deliverCancelled: Bool = false) {
        clock = TestGestureScheduler(executeCancelledActions: deliverCancelled)
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 100, y: 200, width: 2_560, height: 720))
        controller = GestureController(
            mapperProvider: { [weak self] in self?.hasMapper == true ? mapper : nil },
            inputSink: input,
            cursorController: cursor,
            focusRestorer: focus,
            timing: timing,
            scheduler: clock
        )
        controller.onBecameIdle = { [weak self] in self?.idleCount += 1 }
    }

    var isPressed: Bool {
        guard case .singleTouch(let context) = controller.state else { return false }
        return context.isMouseDownPosted
    }

    func send(_ kind: TouchEvent.Kind, at milliseconds: UInt64, far: Bool = false, contactID: Int = 0) {
        clock.advance(toMilliseconds: milliseconds)
        controller.handle(TouchEvent(kind: kind, contactID: contactID, rawX: far ? 16_383 : 0,
                                     rawY: far ? 9_599 : 0, timestamp: clock.now))
    }

    func assertBalanced(file: StaticString = #filePath, line: UInt = #line) {
        var pressed = false
        for call in input.calls {
            switch call {
            case .down:
                XCTAssertFalse(pressed, "Repeated mouse-down without mouse-up", file: file, line: line)
                pressed = true
            case .up:
                XCTAssertTrue(pressed, "Mouse-up without button ownership", file: file, line: line)
                pressed = false
            case .drag:
                XCTAssertTrue(pressed, "Drag without button ownership", file: file, line: line)
            }
        }
        XCTAssertFalse(pressed, "Unreleased synthetic mouse button", file: file, line: line)
    }
}

private final class CleanupInputSink: SyntheticInputSink {
    enum Call: Equatable { case down(CGPoint), up(CGPoint), drag(CGPoint) }
    var calls: [Call] = []
    func postMouseDown(at point: CGPoint) { calls.append(.down(point)) }
    func postMouseUp(at point: CGPoint) { calls.append(.up(point)) }
    func postMouseDragged(to point: CGPoint) { calls.append(.drag(point)) }
}

private final class CleanupCursorController: CursorController {
    enum Call: Equatable { case borrow(CGPoint), update(CGPoint), returned, show }
    var calls: [Call] = []
    var shouldBorrow = true
    func borrow(warpingTo point: CGPoint) -> Bool { calls.append(.borrow(point)); return shouldBorrow }
    func updatePosition(_ point: CGPoint) { calls.append(.update(point)) }
    func returnToOrigin() { calls.append(.returned) }
    func forceShow() { calls.append(.show) }
}

private final class CleanupFocusRestorer: FocusRestorer {
    enum Call: Equatable { case capture, restore, discard }
    var calls: [Call] = []
    func captureFocusedWindow() { calls.append(.capture) }
    func restoreCapturedWindow() { calls.append(.restore) }
    func discardCapturedWindow() { calls.append(.discard) }
}
