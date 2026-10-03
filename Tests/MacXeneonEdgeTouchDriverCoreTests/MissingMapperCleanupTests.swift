import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class MissingMapperCleanupTests: XCTestCase {
    func testMapperLostDuringFocusCaptureRejectsContactBeforeCursorBorrow() {
        let fixture = MissingMapperFixture()
        fixture.focus.onCapture = { fixture.hasMapper = false }
        fixture.send(.down, at: 0)

        XCTAssertEqual(fixture.controller.state, .idle)
        XCTAssertTrue(fixture.input.calls.isEmpty)
        XCTAssertTrue(fixture.cursor.calls.isEmpty)
        XCTAssertEqual(fixture.focus.calls, [.capture, .discard])
        XCTAssertEqual(fixture.cleanupEffects, [.discardFocus])
        XCTAssertFalse(fixture.focus.hasCapturedWindow)

        fixture.focus.onCapture = nil
        fixture.hasMapper = true
        fixture.send(.down, at: 1, far: true)
        fixture.send(.move, at: 2, far: true)
        XCTAssertTrue(fixture.input.calls.isEmpty, "The rejected contact must remain rejected until its up")
        fixture.send(.up, at: 3, far: true)
        fixture.send(.down, at: 4, far: true)
        fixture.send(.up, at: 5, far: true)

        XCTAssertEqual(fixture.input.calls, [.down(missingMapperFar), .up(missingMapperFar)])
        XCTAssertEqual(fixture.focus.calls, [.capture, .discard, .capture, .restore])
        fixture.assertBalanced()
    }

    func testPendingDownCancelsWhenMapperDisappearsWithoutAnotherTouchEvent() {
        let fixture = MissingMapperFixture(timing: missingMapperTiming(warp: 100))
        fixture.send(.down, at: 0)
        fixture.hasMapper = false
        fixture.clock.advance(toMilliseconds: 100)

        XCTAssertEqual(fixture.controller.state, .idle)
        XCTAssertTrue(fixture.input.calls.isEmpty)
        XCTAssertEqual(fixture.cursor.calls, [.borrow(missingMapperNear), .returned])
        XCTAssertEqual(fixture.focus.calls, [.capture, .discard, .restore])
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.assertMissingMapperCleanup(releasingButton: false)

        fixture.hasMapper = true
        fixture.send(.down, at: 101, far: true)
        fixture.clock.advance(toMilliseconds: 201)
        fixture.send(.up, at: 202, far: true)

        XCTAssertEqual(fixture.input.calls, [.down(missingMapperFar), .up(missingMapperFar)])
        XCTAssertEqual(fixture.idleCount, 2)
        fixture.assertBalanced()
    }

    func testMapperLostWhilePostingDownPreventsMoveAndReleasesSavedPoint() {
        let fixture = MissingMapperFixture(timing: missingMapperTiming(warp: 100))
        fixture.send(.down, at: 0)
        fixture.input.onMouseDown = { fixture.hasMapper = false }
        fixture.send(.move, at: 1, far: true)

        XCTAssertEqual(fixture.input.calls, [.down(missingMapperNear), .up(missingMapperNear)])
        XCTAssertEqual(fixture.cursor.calls, [.borrow(missingMapperNear), .returned])
        XCTAssertEqual(fixture.focus.calls, [.capture, .discard, .restore])
        XCTAssertEqual(fixture.controller.state, .idle)
        fixture.assertMissingMapperCleanup(releasingButton: true)

        fixture.input.onMouseDown = nil
        fixture.hasMapper = true
        fixture.send(.down, at: 2, far: true)
        fixture.clock.advance(toMilliseconds: 100)
        XCTAssertEqual(fixture.input.calls, [.down(missingMapperNear), .up(missingMapperNear)])
        fixture.clock.advance(toMilliseconds: 102)
        fixture.send(.up, at: 103, far: true)

        XCTAssertEqual(fixture.input.calls, [.down(missingMapperNear), .up(missingMapperNear), .down(missingMapperFar), .up(missingMapperFar)])
        fixture.assertBalanced()
    }

    func testStaleCancelledDownCannotCancelRecoveredGestureWhenMapperIsMissingAgain() {
        let fixture = MissingMapperFixture(timing: missingMapperTiming(warp: 100))
        fixture.send(.down, at: 0)
        fixture.hasMapper = false
        fixture.send(.move, at: 1)
        fixture.assertMissingMapperCleanup(releasingButton: false)
        fixture.hasMapper = true
        fixture.send(.down, at: 2, far: true)

        fixture.hasMapper = false
        fixture.clock.advance(toMilliseconds: 100)
        XCTAssertEqual(fixture.idleCount, 1, "A stale callback must check its generation before cancelling current work")
        XCTAssertEqual(fixture.cursor.calls, [.borrow(missingMapperNear), .returned, .borrow(missingMapperFar)])
        guard case .singleTouch = fixture.controller.state else {
            return XCTFail("Stale cancelled callback ended the recovered contact")
        }

        fixture.hasMapper = true
        fixture.clock.advance(toMilliseconds: 102)
        fixture.send(.up, at: 103, far: true)

        XCTAssertEqual(fixture.input.calls, [.down(missingMapperFar), .up(missingMapperFar)])
        XCTAssertEqual(fixture.idleCount, 2)
        fixture.assertBalanced()
    }

    func testMissingMapperCancelsPendingDownBeforeItCanPressRecoveredGesture() {
        let fixture = MissingMapperFixture(timing: missingMapperTiming(warp: 100))
        fixture.send(.down, at: 0)
        fixture.hasMapper = false
        fixture.send(.move, at: 1, far: true)

        XCTAssertEqual(fixture.controller.state, .idle)
        XCTAssertTrue(fixture.input.calls.isEmpty)
        XCTAssertEqual(fixture.cursor.calls, [.borrow(missingMapperNear), .returned])
        XCTAssertEqual(fixture.focus.calls, [.capture, .discard, .restore])
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.assertMissingMapperCleanup(releasingButton: false)

        fixture.hasMapper = true
        fixture.send(.down, at: 10, far: true)
        fixture.clock.advance(toMilliseconds: 100)
        XCTAssertTrue(fixture.input.calls.isEmpty, "Cancelled down must not press the recovered contact early")
        fixture.clock.advance(toMilliseconds: 110)
        XCTAssertEqual(fixture.input.calls, [.down(missingMapperFar)])
        fixture.send(.up, at: 111, far: true)

        XCTAssertEqual(fixture.input.calls, [.down(missingMapperFar), .up(missingMapperFar)])
        XCTAssertEqual(fixture.idleCount, 2)
        fixture.assertBalanced()
    }

    func testMissingMapperReleasesHeldDragAtLastMappedPointAndReturnsCursor() {
        let fixture = MissingMapperFixture()
        fixture.send(.down, at: 0)
        fixture.send(.move, at: 1, far: true)
        fixture.hasMapper = false
        fixture.send(.up, at: 2)
        fixture.send(.move, at: 3)
        fixture.send(.up, at: 4)

        XCTAssertEqual(fixture.input.calls, [.down(missingMapperNear), .drag(missingMapperFar), .up(missingMapperFar)])
        XCTAssertEqual(fixture.cursor.calls, [.borrow(missingMapperNear), .update(missingMapperFar), .returned])
        XCTAssertEqual(fixture.focus.calls, [.capture, .discard, .restore])
        XCTAssertEqual(fixture.controller.state, .idle)
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.assertMissingMapperCleanup(releasingButton: true)
        fixture.assertBalanced()
    }

    func testMissingMapperCompletesDelayedUpWithoutReleasingRecoveredContact() {
        let fixture = MissingMapperFixture(timing: missingMapperTiming(up: 100))
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1, far: true)
        fixture.hasMapper = false
        fixture.send(.move, at: 2)

        XCTAssertEqual(fixture.input.calls, [.down(missingMapperNear), .up(missingMapperFar)])
        XCTAssertEqual(fixture.cursor.calls, [.borrow(missingMapperNear), .returned])
        XCTAssertEqual(fixture.focus.calls, [.capture, .discard, .restore])
        XCTAssertEqual(fixture.controller.state, .idle)
        fixture.assertMissingMapperCleanup(releasingButton: true)

        fixture.hasMapper = true
        fixture.send(.down, at: 3, far: true)
        fixture.clock.advance(toMilliseconds: 101)
        XCTAssertEqual(fixture.input.calls, [.down(missingMapperNear), .up(missingMapperFar), .down(missingMapperFar)])
        XCTAssertTrue(fixture.isPressed, "Cancelled delayed up must not release the recovered contact")
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.send(.up, at: 102, far: true)
        fixture.clock.advance(toMilliseconds: 202)

        XCTAssertEqual(fixture.idleCount, 2)
        fixture.assertBalanced()
    }

    func testMissingMapperCompletesCursorReturnWithoutIdlingRecoveredContact() {
        let fixture = MissingMapperFixture(timing: missingMapperTiming(back: 100))
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1)
        fixture.hasMapper = false
        fixture.send(.move, at: 2)

        XCTAssertEqual(fixture.input.calls, [.down(missingMapperNear), .up(missingMapperNear)])
        XCTAssertEqual(fixture.cursor.calls, [.borrow(missingMapperNear), .returned])
        XCTAssertEqual(fixture.focus.calls, [.capture, .discard, .restore])
        XCTAssertEqual(fixture.controller.state, .idle)
        fixture.assertMissingMapperCleanup(releasingButton: false, after: [.mouseUp])

        fixture.hasMapper = true
        fixture.send(.down, at: 3, far: true)
        fixture.clock.advance(toMilliseconds: 101)
        XCTAssertTrue(fixture.isPressed, "Cancelled cursor return must not idle the recovered contact")
        XCTAssertEqual(fixture.cursor.calls, [.borrow(missingMapperNear), .returned, .borrow(missingMapperFar)])
        XCTAssertEqual(fixture.focus.calls, [.capture, .discard, .restore, .capture])
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.send(.up, at: 102, far: true)
        fixture.clock.advance(toMilliseconds: 202)

        XCTAssertEqual(fixture.cursor.calls, [.borrow(missingMapperNear), .returned, .borrow(missingMapperFar), .returned])
        XCTAssertEqual(fixture.focus.calls, [.capture, .discard, .restore, .capture, .restore])
        XCTAssertEqual(fixture.idleCount, 2)
        fixture.assertBalanced()
    }

    func testDelayedUpWithMissingMapperDiscardsFocusAndReleasesWithoutAnotherTouchEvent() {
        let fixture = MissingMapperFixture(timing: missingMapperTiming(up: 100, back: 100))
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1, far: true)
        fixture.hasMapper = false
        fixture.clock.advance(toMilliseconds: 101)

        XCTAssertEqual(fixture.input.calls, [.down(missingMapperNear), .up(missingMapperFar)])
        XCTAssertEqual(fixture.cursor.calls, [.borrow(missingMapperNear), .returned])
        XCTAssertEqual(fixture.focus.calls, [.capture, .discard, .restore])
        XCTAssertEqual(fixture.controller.state, .idle)
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.assertMissingMapperCleanup(releasingButton: true)

        fixture.clock.advance(toMilliseconds: 1_000)
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.assertMissingMapperCleanup(releasingButton: true)
        fixture.assertBalanced()
    }

    func testDelayedCursorReturnWithMissingMapperDiscardsFocusWithoutAnotherTouchEvent() {
        let fixture = MissingMapperFixture(timing: missingMapperTiming(back: 100))
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1)
        fixture.hasMapper = false
        fixture.clock.advance(toMilliseconds: 101)

        XCTAssertEqual(fixture.input.calls, [.down(missingMapperNear), .up(missingMapperNear)])
        XCTAssertEqual(fixture.cursor.calls, [.borrow(missingMapperNear), .returned])
        XCTAssertEqual(fixture.focus.calls, [.capture, .discard, .restore])
        XCTAssertEqual(fixture.controller.state, .idle)
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.assertMissingMapperCleanup(releasingButton: false, after: [.mouseUp])

        fixture.clock.advance(toMilliseconds: 1_000)
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.assertMissingMapperCleanup(releasingButton: false, after: [.mouseUp])
        fixture.assertBalanced()
    }

    func testDownWithoutMapperRemainsRejectedUntilUpAfterMapperRecovers() {
        let fixture = MissingMapperFixture()
        fixture.hasMapper = false
        fixture.send(.down, at: 0)
        fixture.hasMapper = true
        fixture.send(.down, at: 1, far: true)
        fixture.send(.move, at: 2, far: true)

        XCTAssertTrue(fixture.input.calls.isEmpty)
        XCTAssertTrue(fixture.cursor.calls.isEmpty)
        XCTAssertTrue(fixture.focus.calls.isEmpty)
        XCTAssertEqual(fixture.idleCount, 0)

        fixture.send(.up, at: 3, far: true)
        fixture.send(.down, at: 4, far: true)
        fixture.send(.up, at: 5, far: true)

        XCTAssertEqual(fixture.input.calls, [.down(missingMapperFar), .up(missingMapperFar)])
        XCTAssertEqual(fixture.idleCount, 1)
        fixture.assertBalanced()
    }

    func testDownWithoutMapperCancelsActiveGestureBeforeRejectingContactUntilUp() {
        let fixture = MissingMapperFixture()
        fixture.send(.down, at: 0)
        fixture.hasMapper = false
        fixture.send(.down, at: 1, far: true)

        XCTAssertEqual(fixture.controller.state, .idle)
        XCTAssertEqual(fixture.input.calls, [.down(missingMapperNear), .up(missingMapperNear)])
        XCTAssertEqual(fixture.cursor.calls, [.borrow(missingMapperNear), .returned])
        fixture.assertMissingMapperCleanup(releasingButton: true)

        fixture.hasMapper = true
        fixture.send(.down, at: 2, far: true)
        fixture.send(.move, at: 3, far: true)
        XCTAssertEqual(fixture.input.calls, [.down(missingMapperNear), .up(missingMapperNear)])
        fixture.send(.up, at: 4, far: true)
        fixture.send(.down, at: 5, far: true)
        fixture.send(.up, at: 6, far: true)

        XCTAssertEqual(fixture.input.calls, [.down(missingMapperNear), .up(missingMapperNear), .down(missingMapperFar), .up(missingMapperFar)])
        XCTAssertEqual(fixture.focus.calls, [.capture, .discard, .restore, .capture, .restore])
        XCTAssertEqual(fixture.idleCount, 2)
        fixture.assertBalanced()
    }
}

private let missingMapperNear = CGPoint(x: 100, y: 200)
private let missingMapperFar = CGPoint(x: 2_660, y: 920)

private func missingMapperTiming(warp: Int = 0, up: Int = 0, back: Int = 0) -> GestureTiming {
    GestureTiming(warpToClickDelayMs: warp, downToUpDelayMs: up, clickToWarpBackDelayMs: back, tapDebounceMs: 0)
}

private enum MissingMapperCleanupEffect: Equatable {
    case discardFocus
    case mouseUp
    case returnCursor
    case restoreFocus(wasEligible: Bool)
}

private final class MissingMapperFixture {
    // Deliver cancelled callbacks as well, to exercise the generation checks.
    let clock = TestGestureScheduler(executeCancelledActions: true)
    let input = MissingMapperInputSink()
    let cursor = MissingMapperCursorController()
    let focus = MissingMapperFocusRestorer()
    var hasMapper = true
    var idleCount = 0
    var cleanupEffects: [MissingMapperCleanupEffect] = []
    private(set) var controller: GestureController!

    init(timing: GestureTiming = .immediate) {
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
        input.onMouseUp = { [weak self] in self?.cleanupEffects.append(.mouseUp) }
        cursor.onReturn = { [weak self] in self?.cleanupEffects.append(.returnCursor) }
        focus.onDiscard = { [weak self] in self?.cleanupEffects.append(.discardFocus) }
        focus.onRestore = { [weak self] wasEligible in
            self?.cleanupEffects.append(.restoreFocus(wasEligible: wasEligible))
        }
    }

    var isPressed: Bool {
        guard case .singleTouch(let context) = controller.state else { return false }
        return context.isMouseDownPosted
    }

    func send(_ kind: TouchEvent.Kind, at milliseconds: UInt64, far: Bool = false) {
        clock.advance(toMilliseconds: milliseconds)
        controller.handle(TouchEvent(
            kind: kind,
            contactID: 0,
            rawX: far ? 16_383 : 0,
            rawY: far ? 9_599 : 0,
            timestamp: clock.now
        ))
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
        XCTAssertEqual(controller.state, .idle, file: file, line: line)
    }

    func assertMissingMapperCleanup(
        releasingButton: Bool,
        after previousEffects: [MissingMapperCleanupEffect] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let release: [MissingMapperCleanupEffect] = releasingButton ? [.mouseUp] : []
        XCTAssertEqual(
            cleanupEffects,
            previousEffects + [.discardFocus] + release + [.returnCursor, .restoreFocus(wasEligible: false)],
            "Discard focus before releasing input or attempting focus restoration",
            file: file,
            line: line
        )
        XCTAssertFalse(focus.hasCapturedWindow, file: file, line: line)
        XCTAssertEqual(focus.restoredWindowCount, 0, file: file, line: line)
    }
}

private final class MissingMapperInputSink: SyntheticInputSink {
    enum Call: Equatable { case down(CGPoint), up(CGPoint), drag(CGPoint) }
    var calls: [Call] = []
    var onMouseDown: (() -> Void)?
    var onMouseUp: (() -> Void)?
    func postMouseDown(at point: CGPoint) {
        calls.append(.down(point))
        onMouseDown?()
    }
    func postMouseUp(at point: CGPoint) {
        calls.append(.up(point))
        onMouseUp?()
    }
    func postMouseDragged(to point: CGPoint) { calls.append(.drag(point)) }
}

private final class MissingMapperCursorController: CursorController {
    enum Call: Equatable { case borrow(CGPoint), update(CGPoint), returned, show }
    var calls: [Call] = []
    var onReturn: (() -> Void)?
    func borrow(warpingTo point: CGPoint) -> Bool { calls.append(.borrow(point)); return true }
    func updatePosition(_ point: CGPoint) { calls.append(.update(point)) }
    func returnToOrigin() {
        calls.append(.returned)
        onReturn?()
    }
    func forceShow() { calls.append(.show) }
}

private final class MissingMapperFocusRestorer: FocusRestorer {
    enum Call: Equatable { case capture, restore, discard }
    var calls: [Call] = []
    var onCapture: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onRestore: ((Bool) -> Void)?
    private(set) var hasCapturedWindow = false
    private(set) var restoredWindowCount = 0
    func captureFocusedWindow() {
        calls.append(.capture)
        hasCapturedWindow = true
        onCapture?()
    }
    func restoreCapturedWindow() {
        calls.append(.restore)
        onRestore?(hasCapturedWindow)
        if hasCapturedWindow {
            restoredWindowCount += 1
        }
        hasCapturedWindow = false
    }
    func discardCapturedWindow() {
        calls.append(.discard)
        hasCapturedWindow = false
        onDiscard?()
    }
}
