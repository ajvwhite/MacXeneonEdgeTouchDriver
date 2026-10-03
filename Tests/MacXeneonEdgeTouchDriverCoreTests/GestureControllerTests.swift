import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
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
                .update(CGPoint(x: CGFloat(2_660).nextDown, y: CGFloat(920).nextDown)),
                .returnToOrigin
            ]
        )
        XCTAssertEqual(
            input.calls,
            [
                .mouseDown(CGPoint(x: 100, y: 200)),
                .mouseDragged(CGPoint(x: CGFloat(2_660).nextDown, y: CGFloat(920).nextDown)),
                .mouseUp(CGPoint(x: CGFloat(2_660).nextDown, y: CGFloat(920).nextDown))
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

        XCTAssertEqual(input.calls.last, .mouseUp(CGPoint(x: CGFloat(2_660).nextDown, y: CGFloat(920).nextDown)))
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

    func testBorrowFailureDropsTouchDown() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let focus = RecordingFocusRestorer()
        cursor.shouldBorrow = false
        let controller = makeController(input: input, cursor: cursor, focus: focus)

        controller.handle(event(.down, rawX: 0, rawY: 0))

        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200))])
        XCTAssertEqual(focus.calls, [.captureFocusedWindow, .discardCapturedWindow])
        XCTAssertTrue(input.calls.isEmpty)
        XCTAssertEqual(controller.state, .idle)
    }

    func testSingleTapCapturesAndRestoresFocusedWindow() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let focus = RecordingFocusRestorer()
        var cleanupOrder: [String] = []
        cursor.onCall = { call in
            if case .returnToOrigin = call {
                cleanupOrder.append("cursorReturn")
            }
        }
        focus.onCall = { call in
            if case .restoreCapturedWindow = call {
                cleanupOrder.append("focusRestore")
            }
        }
        let controller = makeController(input: input, cursor: cursor, focus: focus)

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.handle(event(.up, rawX: 0, rawY: 0))

        XCTAssertEqual(focus.calls, [.captureFocusedWindow, .restoreCapturedWindow])
        XCTAssertEqual(cleanupOrder, ["cursorReturn", "focusRestore"])
    }

    func testForceCancelRestoresFocusedWindow() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let focus = RecordingFocusRestorer()
        let controller = makeController(input: input, cursor: cursor, focus: focus)

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.forceCancel()

        XCTAssertEqual(focus.calls, [.captureFocusedWindow, .restoreCapturedWindow])
    }

    func testMoveBeforeDelayedMouseDownCancelsPendingMouseDown() {
        let scheduler = TestGestureScheduler()
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(
            input: input,
            cursor: cursor,
            timing: GestureTiming(
                warpToClickDelayMs: 100,
                downToUpDelayMs: 0,
                clickToWarpBackDelayMs: 0,
                tapDebounceMs: 0
            ),
            scheduler: scheduler
        )

        controller.handle(event(.down, rawX: 0, rawY: 0))
        XCTAssertTrue(input.calls.isEmpty)
        controller.handle(event(.move, rawX: 16_383, rawY: 9_599))

        scheduler.advance(byMilliseconds: 150)
        XCTAssertEqual(
            input.calls,
            [
                .mouseDown(CGPoint(x: 100, y: 200)),
                .mouseDragged(CGPoint(x: CGFloat(2_660).nextDown, y: CGFloat(920).nextDown))
            ]
        )
    }

    func testDelayedTapSchedulesMouseUpThenCursorReturn() {
        let scheduler = TestGestureScheduler()
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(
            input: input,
            cursor: cursor,
            timing: GestureTiming(
                warpToClickDelayMs: 0,
                downToUpDelayMs: 50,
                clickToWarpBackDelayMs: 50,
                tapDebounceMs: 0
            ),
            scheduler: scheduler
        )
        var idleTransitions = 0
        controller.onBecameIdle = { idleTransitions += 1 }

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.handle(event(.up, rawX: 0, rawY: 0))

        XCTAssertEqual(input.calls, [.mouseDown(CGPoint(x: 100, y: 200))])
        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200))])

        scheduler.advance(toMilliseconds: 49)
        XCTAssertEqual(input.calls, [.mouseDown(CGPoint(x: 100, y: 200))])
        scheduler.advance(toMilliseconds: 50)
        XCTAssertEqual(input.calls, [.mouseDown(CGPoint(x: 100, y: 200)), .mouseUp(CGPoint(x: 100, y: 200))])
        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200))])
        scheduler.advance(toMilliseconds: 99)
        XCTAssertEqual(idleTransitions, 0)
        scheduler.advance(toMilliseconds: 100)
        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200)), .returnToOrigin])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(idleTransitions, 1)
    }

    func testForceCancelCancelsPendingMouseDownWork() {
        let scheduler = TestGestureScheduler()
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(
            input: input,
            cursor: cursor,
            timing: GestureTiming(
                warpToClickDelayMs: 100,
                downToUpDelayMs: 0,
                clickToWarpBackDelayMs: 0,
                tapDebounceMs: 0
            ),
            scheduler: scheduler
        )

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.forceCancel()

        scheduler.advance(byMilliseconds: 150)
        XCTAssertTrue(input.calls.isEmpty)
        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200)), .returnToOrigin])
        XCTAssertEqual(controller.state, .idle)
    }

    private func makeController(
        input: RecordingInputSink,
        cursor: RecordingCursorController,
        focus: FocusRestorer = NoOpFocusRestorer(),
        timing: GestureTiming = .immediate,
        scheduler: GestureScheduler = DispatchGestureScheduler(queue: nil)
    ) -> GestureController {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 100, y: 200, width: 2_560, height: 720))
        return GestureController(
            mapperProvider: { mapper },
            inputSink: input,
            cursorController: cursor,
            focusRestorer: focus,
            timing: timing,
            scheduler: scheduler
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

private final class RecordingFocusRestorer: FocusRestorer {
    enum Call: Equatable {
        case captureFocusedWindow
        case restoreCapturedWindow
        case discardCapturedWindow
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    var onCall: ((Call) -> Void)?

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func captureFocusedWindow() {
        append(.captureFocusedWindow)
    }

    func restoreCapturedWindow() {
        append(.restoreCapturedWindow)
    }

    func discardCapturedWindow() {
        append(.discardCapturedWindow)
    }

    private func append(_ call: Call) {
        lock.lock()
        recordedCalls.append(call)
        lock.unlock()
        onCall?(call)
    }
}

private final class RecordingInputSink: SyntheticInputSink {
    enum Call: Equatable {
        case mouseDown(CGPoint)
        case mouseUp(CGPoint)
        case mouseDragged(CGPoint)
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func postMouseDown(at point: CGPoint) {
        append(.mouseDown(point))
    }

    func postMouseUp(at point: CGPoint) {
        append(.mouseUp(point))
    }

    func postMouseDragged(to point: CGPoint) {
        append(.mouseDragged(point))
    }

    private func append(_ call: Call) {
        lock.lock()
        recordedCalls.append(call)
        lock.unlock()
    }
}

private final class RecordingCursorController: CursorController {
    enum Call: Equatable {
        case borrow(CGPoint)
        case update(CGPoint)
        case returnToOrigin
        case forceShow
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    var shouldBorrow = true
    var onCall: ((Call) -> Void)?

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func borrow(warpingTo point: CGPoint) -> Bool {
        append(.borrow(point))
        return shouldBorrow
    }

    func updatePosition(_ point: CGPoint) {
        append(.update(point))
    }

    func returnToOrigin() {
        append(.returnToOrigin)
    }

    func forceShow() {
        append(.forceShow)
    }

    private func append(_ call: Call) {
        lock.lock()
        recordedCalls.append(call)
        lock.unlock()
        onCall?(call)
    }
}
