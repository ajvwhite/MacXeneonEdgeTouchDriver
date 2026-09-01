import CoreGraphics
import MacXeneonEdgeTouchDriverCore
import XCTest

final class GestureControllerTests: XCTestCase {
    func testTouchDownDoesNotBorrowOrMoveCursorBeforeGestureClassification() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(input: input, cursor: cursor)

        controller.handle(event(.down, rawX: 0, rawY: 0))

        XCTAssertTrue(cursor.calls.isEmpty)
        XCTAssertTrue(input.calls.isEmpty)
        guard case .singleTouch(let context) = controller.state else {
            return XCTFail("Expected a pending touch")
        }
        XCTAssertEqual(context.phase, .pending)
    }

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

    func testImmediateMovementPostsPixelScrollWithoutMouseDown() {
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
                .returnToOrigin
            ]
        )
        XCTAssertEqual(
            input.calls,
            [
                .scroll(deltaX: 2_560, deltaY: 720, phase: .began),
                .scroll(deltaX: 0, deltaY: 0, phase: .ended)
            ]
        )
    }

    func testScrollBeginsWithCumulativeMovementPastThreshold() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(input: input, cursor: cursor)

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.handle(event(.move, rawX: 30, rawY: 0))
        controller.handle(event(.move, rawX: 100, rawY: 0))

        guard case .scroll(let deltaX, let deltaY, let phase) = input.calls.first else {
            return XCTFail("Expected a scroll event")
        }
        XCTAssertEqual(phase, .began)
        XCTAssertEqual(deltaY, 0)
        XCTAssertEqual(deltaX, 2_560 * 100 / 16_383, accuracy: 0.001)
    }

    func testForceCancelEndsScrollAndReturnsCursor() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(input: input, cursor: cursor)

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.handle(event(.move, rawX: 16_383, rawY: 9_599))
        controller.forceCancel()

        XCTAssertEqual(input.calls.last, .scroll(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(cursor.calls.last, .returnToOrigin)
        XCTAssertEqual(controller.state, .idle)
    }

    func testIdleTimeoutUsesForceCancelPath() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(input: input, cursor: cursor)

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.handleIdleTimeout()

        XCTAssertTrue(input.calls.isEmpty)
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

    func testNearbySecondTapWithinSystemIntervalPostsDoubleClick() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(
            input: input,
            cursor: cursor,
            doubleClickIntervalProvider: { 0.5 }
        )

        controller.handle(event(.down, rawX: 0, rawY: 0, timestampNanoseconds: 1_000_000_000))
        controller.handle(event(.up, rawX: 0, rawY: 0, timestampNanoseconds: 1_050_000_000))
        controller.handle(event(.down, rawX: 0, rawY: 0, timestampNanoseconds: 1_200_000_000))
        controller.handle(event(.up, rawX: 0, rawY: 0, timestampNanoseconds: 1_250_000_000))

        XCTAssertEqual(input.mouseClickCounts, [1, 1, 2, 2])
    }

    func testThirdTapStartsNewClickSequence() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(input: input, cursor: cursor)

        for timestamp in [1_000_000_000, 1_200_000_000, 1_400_000_000] as [UInt64] {
            controller.handle(event(.down, rawX: 0, rawY: 0, timestampNanoseconds: timestamp))
            controller.handle(event(.up, rawX: 0, rawY: 0, timestampNanoseconds: timestamp + 50_000_000))
        }

        XCTAssertEqual(input.mouseClickCounts, [1, 1, 2, 2, 1, 1])
    }

    func testLateOrDistantSecondTapRemainsSingleClick() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(
            input: input,
            cursor: cursor,
            doubleClickIntervalProvider: { 0.5 }
        )

        controller.handle(event(.down, rawX: 0, rawY: 0, timestampNanoseconds: 1_000_000_000))
        controller.handle(event(.up, rawX: 0, rawY: 0, timestampNanoseconds: 1_050_000_000))
        controller.handle(event(.down, rawX: 100, rawY: 0, timestampNanoseconds: 1_200_000_000))
        controller.handle(event(.up, rawX: 100, rawY: 0, timestampNanoseconds: 1_250_000_000))
        controller.handle(event(.down, rawX: 100, rawY: 0, timestampNanoseconds: 2_000_000_000))
        controller.handle(event(.up, rawX: 100, rawY: 0, timestampNanoseconds: 2_050_000_000))

        XCTAssertEqual(input.mouseClickCounts, [1, 1, 1, 1, 1, 1])
    }

    func testScrollResetsDoubleClickSequence() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(input: input, cursor: cursor)

        controller.handle(event(.down, rawX: 0, rawY: 0, timestampNanoseconds: 1_000_000_000))
        controller.handle(event(.up, rawX: 0, rawY: 0, timestampNanoseconds: 1_050_000_000))
        controller.handle(event(.down, rawX: 0, rawY: 0, timestampNanoseconds: 1_100_000_000))
        controller.handle(event(.move, rawX: 1_000, rawY: 0, timestampNanoseconds: 1_150_000_000))
        controller.handle(event(.up, rawX: 1_000, rawY: 0, timestampNanoseconds: 1_200_000_000))
        controller.handle(event(.down, rawX: 0, rawY: 0, timestampNanoseconds: 1_250_000_000))
        controller.handle(event(.up, rawX: 0, rawY: 0, timestampNanoseconds: 1_300_000_000))

        XCTAssertEqual(input.mouseClickCounts, [1, 1, 1, 1])
    }

    func testBorrowFailureDropsTapBeforeSyntheticInput() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let focus = RecordingFocusRestorer()
        cursor.shouldBorrow = false
        let controller = makeController(input: input, cursor: cursor, focus: focus)

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.handle(event(.up, rawX: 0, rawY: 0))

        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200))])
        XCTAssertEqual(focus.calls, [.captureFocusedWindow, .discardCapturedWindow])
        XCTAssertTrue(input.calls.isEmpty)
        XCTAssertEqual(controller.state, .idle)
    }

    func testSingleTapDefersFocusUntilDoubleClickWindowExpires() {
        let queue = DispatchQueue(label: "MacXeneonEdgeTouchDriverTests.single-tap-focus")
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let focus = RecordingFocusRestorer()
        var cleanupOrder: [String] = []
        cursor.onCall = { call in
            if case .returnToOrigin = call {
                cleanupOrder.append("cursorReturn")
            }
        }
        let controller = makeController(
            input: input,
            cursor: cursor,
            focus: focus,
            doubleClickIntervalProvider: { 0.05 },
            schedulingQueue: queue
        )
        let focusRestored = expectation(description: "single tap focus restored after double-click interval")
        focus.onCall = { call in
            if case .restoreCapturedWindow = call {
                cleanupOrder.append("focusRestore")
                focusRestored.fulfill()
            }
        }

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.handle(event(.up, rawX: 0, rawY: 0))

        XCTAssertEqual(focus.calls, [.captureFocusedWindow])
        XCTAssertEqual(cleanupOrder, ["cursorReturn"])

        wait(for: [focusRestored], timeout: 1)
        XCTAssertEqual(focus.calls, [.captureFocusedWindow, .restoreCapturedWindow])
        XCTAssertEqual(cleanupOrder, ["cursorReturn", "focusRestore"])
    }

    func testDoubleClickRestoresFocusOnceAfterSecondClick() {
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let focus = RecordingFocusRestorer()
        let controller = makeController(
            input: input,
            cursor: cursor,
            focus: focus,
            doubleClickIntervalProvider: { 0.5 }
        )

        controller.handle(event(.down, rawX: 0, rawY: 0, timestampNanoseconds: 1_000_000_000))
        controller.handle(event(.up, rawX: 0, rawY: 0, timestampNanoseconds: 1_050_000_000))

        XCTAssertEqual(input.mouseClickCounts, [1, 1])
        XCTAssertEqual(focus.calls, [.captureFocusedWindow])

        controller.handle(event(.down, rawX: 0, rawY: 0, timestampNanoseconds: 1_200_000_000))
        controller.handle(event(.up, rawX: 0, rawY: 0, timestampNanoseconds: 1_250_000_000))

        XCTAssertEqual(input.mouseClickCounts, [1, 1, 2, 2])
        XCTAssertEqual(focus.calls, [.captureFocusedWindow, .restoreCapturedWindow])
    }

    func testFastSecondTouchCompletesFirstCleanupAndBypassesTapDebounce() {
        let queue = DispatchQueue(label: "MacXeneonEdgeTouchDriverTests.fast-double-click")
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let focus = RecordingFocusRestorer()
        let controller = makeController(
            input: input,
            cursor: cursor,
            focus: focus,
            timing: GestureTiming(
                warpToClickDelayMs: 0,
                downToUpDelayMs: 50,
                clickToWarpBackDelayMs: 50,
                tapDebounceMs: 50
            ),
            doubleClickIntervalProvider: { 0.5 },
            schedulingQueue: queue
        )
        let cleanupSettled = expectation(description: "fast double-click cleanup settled")

        controller.handle(event(.down, rawX: 0, rawY: 0, timestampNanoseconds: 1_000_000_000))
        controller.handle(event(.up, rawX: 0, rawY: 0, timestampNanoseconds: 1_010_000_000))
        controller.handle(event(.down, rawX: 0, rawY: 0, timestampNanoseconds: 1_020_000_000))
        controller.handle(event(.up, rawX: 0, rawY: 0, timestampNanoseconds: 1_040_000_000))
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) {
            cleanupSettled.fulfill()
        }

        wait(for: [cleanupSettled], timeout: 1)
        XCTAssertEqual(input.mouseClickCounts, [1, 1, 2, 2])
        XCTAssertEqual(cursor.calls, [
            .borrow(CGPoint(x: 100, y: 200)),
            .returnToOrigin,
            .borrow(CGPoint(x: 100, y: 200)),
            .returnToOrigin
        ])
        XCTAssertEqual(focus.calls, [.captureFocusedWindow, .restoreCapturedWindow])
        XCTAssertEqual(controller.state, .idle)
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

    func testMoveBeforeHoldCancelsPendingDragAndScrolls() {
        let queue = DispatchQueue(label: "MacXeneonEdgeTouchDriverTests.delayed-move")
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
            schedulingQueue: queue
        )
        let delayedWorkSettled = expectation(description: "delayed mouse-down work settled")

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.handle(event(.move, rawX: 16_383, rawY: 9_599))
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) {
            delayedWorkSettled.fulfill()
        }

        wait(for: [delayedWorkSettled], timeout: 1.0)
        XCTAssertEqual(
            input.calls,
            [
                .scroll(deltaX: 2_560, deltaY: 720, phase: .began)
            ]
        )
    }

    func testHoldThenMovePostsMouseDrag() {
        let queue = DispatchQueue(label: "MacXeneonEdgeTouchDriverTests.hold-drag")
        let input = RecordingInputSink()
        let cursor = RecordingCursorController()
        let controller = makeController(
            input: input,
            cursor: cursor,
            timing: GestureTiming(
                warpToClickDelayMs: 0,
                downToUpDelayMs: 0,
                clickToWarpBackDelayMs: 0,
                tapDebounceMs: 0,
                holdToDragMs: 30
            ),
            schedulingQueue: queue
        )
        let held = expectation(description: "hold classified as drag")

        controller.handle(event(.down, rawX: 0, rawY: 0))
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
            controller.handle(self.event(.move, rawX: 16_383, rawY: 9_599))
            controller.handle(self.event(.up, rawX: 16_383, rawY: 9_599))
            held.fulfill()
        }

        wait(for: [held], timeout: 1)
        XCTAssertEqual(input.calls, [
            .mouseDown(CGPoint(x: 100, y: 200)),
            .mouseDragged(CGPoint(x: 2_660, y: 920)),
            .mouseUp(CGPoint(x: 2_660, y: 920))
        ])
    }

    func testDelayedTapSchedulesMouseUpThenCursorReturn() {
        let queue = DispatchQueue(label: "MacXeneonEdgeTouchDriverTests.delayed-tap")
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
            schedulingQueue: queue
        )
        let becameIdle = expectation(description: "controller became idle after delayed tap")
        controller.onBecameIdle = {
            becameIdle.fulfill()
        }

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.handle(event(.up, rawX: 0, rawY: 0))

        XCTAssertEqual(input.calls, [.mouseDown(CGPoint(x: 100, y: 200))])
        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200))])

        wait(for: [becameIdle], timeout: 1.0)
        XCTAssertEqual(input.calls, [.mouseDown(CGPoint(x: 100, y: 200)), .mouseUp(CGPoint(x: 100, y: 200))])
        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200)), .returnToOrigin])
        XCTAssertEqual(controller.state, .idle)
    }

    func testForceCancelCancelsPendingMouseDownWork() {
        let queue = DispatchQueue(label: "MacXeneonEdgeTouchDriverTests.cancel-pending")
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
            schedulingQueue: queue
        )
        let delayedWorkSettled = expectation(description: "pending mouse-down work settled")

        controller.handle(event(.down, rawX: 0, rawY: 0))
        controller.forceCancel()
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) {
            delayedWorkSettled.fulfill()
        }

        wait(for: [delayedWorkSettled], timeout: 1.0)
        XCTAssertTrue(input.calls.isEmpty)
        XCTAssertEqual(cursor.calls, [.returnToOrigin])
        XCTAssertEqual(controller.state, .idle)
    }

    private func makeController(
        input: RecordingInputSink,
        cursor: RecordingCursorController,
        focus: FocusRestorer = NoOpFocusRestorer(),
        timing: GestureTiming = .immediate,
        doubleClickIntervalProvider: @escaping () -> TimeInterval = { 0.5 },
        schedulingQueue: DispatchQueue? = nil
    ) -> GestureController {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 100, y: 200, width: 2_560, height: 720))
        return GestureController(
            mapperProvider: { mapper },
            inputSink: input,
            cursorController: cursor,
            focusRestorer: focus,
            timing: timing,
            doubleClickIntervalProvider: doubleClickIntervalProvider,
            schedulingQueue: schedulingQueue
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
        case scroll(deltaX: CGFloat, deltaY: CGFloat, phase: SyntheticScrollPhase)
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var recordedMouseClickCounts: [Int] = []

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    var mouseClickCounts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMouseClickCounts
    }

    func postMouseDown(at point: CGPoint, clickCount: Int) {
        append(.mouseDown(point), clickCount: clickCount)
    }

    func postMouseUp(at point: CGPoint, clickCount: Int) {
        append(.mouseUp(point), clickCount: clickCount)
    }

    func postMouseDragged(to point: CGPoint) {
        append(.mouseDragged(point))
    }

    func postScroll(deltaX: CGFloat, deltaY: CGFloat, phase: SyntheticScrollPhase) {
        append(.scroll(deltaX: deltaX, deltaY: deltaY, phase: phase))
    }

    private func append(_ call: Call, clickCount: Int? = nil) {
        lock.lock()
        recordedCalls.append(call)
        if let clickCount {
            recordedMouseClickCounts.append(clickCount)
        }
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
