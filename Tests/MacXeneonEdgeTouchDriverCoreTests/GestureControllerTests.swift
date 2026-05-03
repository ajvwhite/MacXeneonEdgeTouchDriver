import CoreGraphics
import MacXeneonEdgeTouchDriverCore
import XCTest

final class GestureControllerTests: XCTestCase {
    func testSingleTapBorrowsClicksAndReturnsCursor() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(input: input, cursor: cursor)

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.handle(event(.up, rawX: 0, rawY: 0))

        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200)), .returnToOrigin])
        XCTAssertEqual(input.calls, [.mouseDown(CGPoint(x: 100, y: 200)), .mouseUp(CGPoint(x: 100, y: 200))])
        XCTAssertEqual(controller.state, .idle)
    }

    func testDragUpdatesCursorAndPostsDraggedEvents() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(input: input, cursor: cursor)

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.handle(event(.move, rawX: 16_383, rawY: 9_599))
        controller.handle(event(.up, rawX: 16_383, rawY: 9_599))

        XCTAssertEqual(
            cursor.calls,
            [
                .borrow(CGPoint(x: 100, y: 200)),
                .update(CGPoint(x: 2_660, y: 920)),
                .returnToOrigin
            ]
        )
        XCTAssertEqual(
            input.calls,
            [
                .mouseDown(CGPoint(x: 100, y: 200)),
                .mouseDragged(CGPoint(x: 2_660, y: 920)),
                .mouseUp(CGPoint(x: 2_660, y: 920))
            ]
        )
    }

    func testForceCancelPostsMouseUpAndReturnsCursor() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(input: input, cursor: cursor)

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.handle(event(.move, rawX: 16_383, rawY: 9_599))
        controller.forceCancel()

        XCTAssertEqual(input.calls.last, .mouseUp(CGPoint(x: 2_660, y: 920)))
        XCTAssertEqual(cursor.calls.last, .returnToOrigin)
        XCTAssertEqual(controller.state, .idle)
    }

    func testIdleTimeoutUsesForceCancelPath() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(input: input, cursor: cursor)

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.handleIdleTimeout()

        XCTAssertEqual(input.calls.last, .mouseUp(CGPoint(x: 100, y: 200)))
        XCTAssertEqual(cursor.calls.last, .returnToOrigin)
        XCTAssertEqual(controller.state, .idle)
    }

    func testTapDebounceIgnoresImmediateSecondTouch() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(
            input: input,
            cursor: cursor,
            timing: GestureTiming(
                warpToClickDelayMs: 0,
                downToUpDelayMs: 0,
                clickToWarpBackDelayMs: 0,
                tapDebounceMs: 50
            )
        )

        controller.handle(event(.down, rawX: 0, rawY: 0, timestampNanoseconds: 1_000_000_000))
        controller.handle(event(.up, rawX: 0, rawY: 0, timestampNanoseconds: 1_010_000_000))
        controller.handle(event(.down, rawX: 16_383, rawY: 9_599, timestampNanoseconds: 1_020_000_000))

        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200)), .returnToOrigin])
        XCTAssertEqual(input.calls, [.mouseDown(CGPoint(x: 100, y: 200)), .mouseUp(CGPoint(x: 100, y: 200))])
        XCTAssertEqual(controller.state, .idle)
    }

    private func makeController(
        input: RecordingInputSink,
        cursor: RecordingCursorController,
        timing: GestureTiming = .immediate
    ) -> GestureController {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 100, y: 200, width: 2_560, height: 720))
        return GestureController(
            mapperProvider: { mapper },
            inputSink: input,
            cursorController: cursor,
            timing: timing
        )
    }

    private func event(
        _ kind: TouchEvent.Kind,
        rawX: Int,
        rawY: Int,
        timestampNanoseconds: UInt64? = nil
    ) -> TouchEvent {
        let timestamp = timestampNanoseconds.map(DispatchTime.init(uptimeNanoseconds:)) ?? .now()
        return TouchEvent(kind: kind, contactID: 0, rawX: rawX, rawY: rawY, timestamp: timestamp)
    }
}

private final class RecordingInputSink: SyntheticInputSink {
    enum Call: Equatable {
        case mouseDown(CGPoint)
        case mouseUp(CGPoint)
        case mouseDragged(CGPoint)
    }

    var calls: [Call] = []

    func postMouseDown(at point: CGPoint) {
        calls.append(.mouseDown(point))
    }

    func postMouseUp(at point: CGPoint) {
        calls.append(.mouseUp(point))
    }

    func postMouseDragged(to point: CGPoint) {
        calls.append(.mouseDragged(point))
    }
}

private final class RecordingCursorController: CursorController {
    enum Call: Equatable {
        case borrow(CGPoint)
        case update(CGPoint)
        case returnToOrigin
        case forceShow
    }

    var calls: [Call] = []

    func borrow(warpingTo point: CGPoint) {
        calls.append(.borrow(point))
    }

    func updatePosition(_ point: CGPoint) {
        calls.append(.update(point))
    }

    func returnToOrigin() {
        calls.append(.returnToOrigin)
    }

    func forceShow() {
        calls.append(.forceShow)
    }
}
