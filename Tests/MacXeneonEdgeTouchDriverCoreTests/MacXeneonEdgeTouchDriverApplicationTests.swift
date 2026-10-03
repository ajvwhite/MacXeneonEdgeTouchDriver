import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class MacXeneonEdgeTouchDriverApplicationTests: XCTestCase {
    func testTouchDownDropsStaleMappingWhenPreviouslyMatchedDisplayIsMissing() {
        var displays = [xeneonDisplay()]
        let resolver = DisplayResolver(activeDisplayProvider: { displays })
        let input = ApplicationRecordingInputSink()
        let cursor = ApplicationRecordingCursorController()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: cursor
        )

        application.handleDeviceMatched()
        displays = []

        application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
        application.handleTouchEvent(touchEvent(.up, rawX: 0, rawY: 0))

        XCTAssertEqual(cursor.calls, [.forceShow])
        XCTAssertTrue(input.calls.isEmpty)
        XCTAssertNil(resolver.currentMapper)
    }

    func testTouchEventRefreshesMissingDisplayMapperBeforeDropping() {
        let displays = [xeneonDisplay()]
        let resolver = DisplayResolver(activeDisplayProvider: { displays })
        let input = ApplicationRecordingInputSink()
        let cursor = ApplicationRecordingCursorController()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: cursor
        )

        application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
        application.handleTouchEvent(touchEvent(.up, rawX: 0, rawY: 0))

        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200)), .returnToOrigin])
        XCTAssertEqual(input.calls, [.mouseDown(CGPoint(x: 100, y: 200)), .mouseUp(CGPoint(x: 100, y: 200))])
    }

    func testTouchDownRefreshesDisplayMapperAfterDisplayMoves() {
        var displays = [xeneonDisplay()]
        let resolver = DisplayResolver(activeDisplayProvider: { displays })
        let input = ApplicationRecordingInputSink()
        let cursor = ApplicationRecordingCursorController()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: cursor
        )

        application.handleDeviceMatched()
        application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
        application.handleTouchEvent(touchEvent(.up, rawX: 0, rawY: 0))

        // Simulate the user moving the panel in System Settings > Displays > Arrange without any
        // reconfiguration callback being delivered to the driver.
        displays = [xeneonDisplay(origin: CGPoint(x: -300, y: 1_440))]

        application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
        application.handleTouchEvent(touchEvent(.up, rawX: 0, rawY: 0))

        XCTAssertEqual(
            cursor.calls,
            [
                .borrow(CGPoint(x: 100, y: 200)), .returnToOrigin,
                .forceShow, .borrow(CGPoint(x: -300, y: 1_440)), .returnToOrigin,
            ]
        )
        XCTAssertEqual(
            input.calls,
            [
                .mouseDown(CGPoint(x: 100, y: 200)), .mouseUp(CGPoint(x: 100, y: 200)),
                .mouseDown(CGPoint(x: -300, y: 1_440)), .mouseUp(CGPoint(x: -300, y: 1_440)),
            ]
        )
    }

    func testDeviceRemovalAfterMouseUpDoesNotPostAnotherMouseUp() {
        let fixture = delayedFixture()
        fixture.application.handleTouchEvent(touchEvent(.down, at: fixture.scheduler))
        fixture.application.handleTouchEvent(touchEvent(.up, at: fixture.scheduler))
        fixture.scheduler.advance(toMilliseconds: 25)

        fixture.application.handleDeviceRemoval()
        fixture.application.handleDeviceRemoval()
        fixture.scheduler.advance(toMilliseconds: 2_000)

        XCTAssertEqual(fixture.input.calls, [.mouseDown(origin), .mouseUp(origin)])
        XCTAssertEqual(fixture.cursor.calls.filter { $0 == .returnToOrigin }.count, 1)
        XCTAssertEqual(fixture.focus.restoreCount, 1)
    }

    func testDeviceRemovalCancelsPendingCleanupBeforeSameIDGesture() {
        let fixture = delayedFixture()
        fixture.application.handleTouchEvent(touchEvent(.down, at: fixture.scheduler))
        fixture.application.handleTouchEvent(touchEvent(.up, at: fixture.scheduler))
        fixture.scheduler.advance(toMilliseconds: 10)
        fixture.application.handleDeviceRemoval()
        fixture.application.handleTouchEvent(touchEvent(.down, at: fixture.scheduler))

        fixture.scheduler.advance(toMilliseconds: 25)
        XCTAssertEqual(fixture.input.calls, [.mouseDown(origin), .mouseUp(origin), .mouseDown(origin)])
        XCTAssertEqual(fixture.focus.restoreCount, 1)

        fixture.application.handleTouchEvent(touchEvent(.up, at: fixture.scheduler))
        fixture.scheduler.advance(toMilliseconds: 145)
        XCTAssertEqual(fixture.input.calls, [.mouseDown(origin), .mouseUp(origin), .mouseDown(origin), .mouseUp(origin)])
        XCTAssertEqual(fixture.cursor.calls.filter { $0 == .returnToOrigin }.count, 2)
        XCTAssertEqual(fixture.focus.restoreCount, 2)
    }

    func testShutdownTeardownCancelsEachDelayedPhase() {
        // Exercise the exact teardown called inside stop(), without starting HID or requesting permissions.
        for cancellationTime: UInt64 in [10, 25, 45] {
            var configuration = immediateConfiguration()
            configuration.timing.warpToClickDelayMs = 20
            configuration.timing.downToUpDelayMs = 20
            configuration.timing.clickToWarpBackDelayMs = 100
            let fixture = makeFixture(configuration: configuration)
            fixture.application.handleTouchEvent(touchEvent(.down, at: fixture.scheduler))
            if cancellationTime > 20 {
                fixture.scheduler.advance(toMilliseconds: 20)
                fixture.application.handleTouchEvent(touchEvent(.up, at: fixture.scheduler))
            }
            fixture.scheduler.advance(toMilliseconds: cancellationTime)

            fixture.application.cancelActiveGesture()
            fixture.application.cancelActiveGesture()
            fixture.scheduler.advance(toMilliseconds: 2_000)

            let expected: [ApplicationRecordingInputSink.Call] = cancellationTime < 20
                ? [] : [.mouseDown(origin), .mouseUp(origin)]
            XCTAssertEqual(fixture.input.calls, expected, "Cancelled at \(cancellationTime) ms")
            XCTAssertEqual(fixture.cursor.calls.filter { $0 == .returnToOrigin }.count, 1)
            XCTAssertEqual(fixture.focus.restoreCount, 1)
        }
    }

    func testCancelledWatchdogCannotCancelNewGestureWithSameContactID() {
        var configuration = immediateConfiguration()
        configuration.timing.stuckGestureTimeoutMs = 100
        let fixture = makeFixture(configuration: configuration)
        fixture.application.handleTouchEvent(touchEvent(.down, at: fixture.scheduler))
        fixture.application.handleTouchEvent(touchEvent(.up, at: fixture.scheduler))
        fixture.scheduler.advance(toMilliseconds: 50)
        fixture.application.handleTouchEvent(touchEvent(.down, at: fixture.scheduler))

        fixture.scheduler.advance(toMilliseconds: 100)
        XCTAssertEqual(fixture.input.calls, [.mouseDown(origin), .mouseUp(origin), .mouseDown(origin)])
        XCTAssertEqual(fixture.focus.restoreCount, 1)

        fixture.scheduler.advance(toMilliseconds: 150)
        XCTAssertEqual(fixture.input.calls, [.mouseDown(origin), .mouseUp(origin), .mouseDown(origin), .mouseUp(origin)])
        XCTAssertEqual(fixture.focus.restoreCount, 2)
    }

    func testMoveReschedulesWatchdogWithoutStaleTimeoutCleaningUpGesture() {
        var configuration = immediateConfiguration()
        configuration.timing.stuckGestureTimeoutMs = 100
        let fixture = makeFixture(configuration: configuration)
        fixture.application.handleTouchEvent(touchEvent(.down, at: fixture.scheduler))
        fixture.scheduler.advance(toMilliseconds: 50)
        fixture.application.handleTouchEvent(touchEvent(.move, at: fixture.scheduler))

        fixture.scheduler.advance(toMilliseconds: 100)
        XCTAssertEqual(fixture.input.calls, [.mouseDown(origin), .mouseDragged(origin)])
        XCTAssertEqual(fixture.focus.restoreCount, 0)

        fixture.scheduler.advance(toMilliseconds: 150)
        XCTAssertEqual(fixture.input.calls, [.mouseDown(origin), .mouseDragged(origin), .mouseUp(origin)])
        XCTAssertEqual(fixture.focus.restoreCount, 1)
        fixture.scheduler.advance(toMilliseconds: 1_000)
        XCTAssertEqual(fixture.focus.restoreCount, 1)
    }

    func testOverlappingCleanupCannotCancelLaterGesturesWatchdog() {
        var configuration = immediateConfiguration()
        configuration.timing.downToUpDelayMs = 20
        configuration.timing.clickToWarpBackDelayMs = 100
        configuration.timing.tapDebounceMs = 50
        configuration.timing.stuckGestureTimeoutMs = 200
        let fixture = makeFixture(configuration: configuration)
        fixture.application.handleTouchEvent(touchEvent(.down, at: fixture.scheduler))
        fixture.scheduler.advance(toMilliseconds: 1)
        fixture.application.handleTouchEvent(touchEvent(.up, at: fixture.scheduler))
        fixture.scheduler.advance(toMilliseconds: 10)
        fixture.application.handleTouchEvent(touchEvent(.down, at: fixture.scheduler))
        fixture.scheduler.advance(toMilliseconds: 20)
        fixture.application.handleTouchEvent(touchEvent(.up, at: fixture.scheduler))
        fixture.scheduler.advance(toMilliseconds: 130)
        fixture.application.handleTouchEvent(touchEvent(.down, at: fixture.scheduler))

        // Old cursor return and watchdog callbacks must leave the later gesture active.
        fixture.scheduler.advance(toMilliseconds: 329)
        XCTAssertEqual(fixture.input.calls, [.mouseDown(origin), .mouseUp(origin), .mouseDown(origin)])
        XCTAssertEqual(fixture.focus.restoreCount, 1)

        fixture.scheduler.advance(toMilliseconds: 330)
        XCTAssertEqual(fixture.input.calls, [.mouseDown(origin), .mouseUp(origin), .mouseDown(origin), .mouseUp(origin)])
        XCTAssertEqual(fixture.focus.restoreCount, 2)
    }

    func testDelayedCompletionCancelsWatchdogWithoutRunningApplication() {
        let fixture = delayedFixture()
        fixture.application.handleTouchEvent(touchEvent(.down, at: fixture.scheduler))
        fixture.application.handleTouchEvent(touchEvent(.up, at: fixture.scheduler))
        fixture.scheduler.advance(toMilliseconds: 120)
        let completedCursorCalls = fixture.cursor.calls

        fixture.scheduler.advance(toMilliseconds: 2_000)

        XCTAssertEqual(fixture.input.calls, [.mouseDown(origin), .mouseUp(origin)])
        XCTAssertEqual(fixture.cursor.calls, completedCursorCalls)
        XCTAssertEqual(fixture.focus.restoreCount, 1)
        XCTAssertEqual(fixture.focus.discardCount, 0)
    }

    private let origin = CGPoint(x: 100, y: 200)

    private func delayedFixture() -> ApplicationFixture {
        var configuration = immediateConfiguration()
        configuration.timing.downToUpDelayMs = 20
        configuration.timing.clickToWarpBackDelayMs = 100
        return makeFixture(configuration: configuration)
    }

    private func makeFixture(configuration: DriverConfiguration) -> ApplicationFixture {
        let scheduler = TestGestureScheduler(executeCancelledActions: true)
        let input = ApplicationRecordingInputSink()
        let cursor = ApplicationRecordingCursorController()
        let focus = ApplicationRecordingFocusRestorer()
        let displays = [xeneonDisplay()]
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: configuration,
            displayResolver: DisplayResolver(activeDisplayProvider: { displays }),
            inputSink: input,
            cursorController: cursor,
            focusRestorer: focus,
            scheduler: scheduler
        )
        return ApplicationFixture(application: application, scheduler: scheduler, input: input, cursor: cursor, focus: focus)
    }

    private func touchEvent(_ kind: TouchEvent.Kind, at scheduler: TestGestureScheduler) -> TouchEvent {
        TouchEvent(kind: kind, contactID: 0, rawX: 0, rawY: 0, timestamp: scheduler.now)
    }

    private func immediateConfiguration() -> DriverConfiguration {
        var configuration = DriverConfiguration.defaults
        configuration.timing.warpToClickDelayMs = 0
        configuration.timing.downToUpDelayMs = 0
        configuration.timing.clickToWarpBackDelayMs = 0
        configuration.timing.tapDebounceMs = 0
        configuration.timing.stuckGestureTimeoutMs = 1_000
        return configuration
    }

    private func xeneonDisplay(origin: CGPoint = CGPoint(x: 100, y: 200)) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: 42,
            vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber,
            serialNumber: CapturedXeneonDisplay.observedSerialNumber,
            bounds: CGRect(origin: origin, size: CGSize(width: 2_560, height: 720)),
            pixelsWide: CapturedXeneonDisplay.expectedWidth,
            pixelsHigh: CapturedXeneonDisplay.expectedHeight
        )
    }

    private func touchEvent(_ kind: TouchEvent.Kind, rawX: Int, rawY: Int) -> TouchEvent {
        TouchEvent(kind: kind, contactID: 0, rawX: rawX, rawY: rawY, timestamp: .now())
    }
}

private struct ApplicationFixture {
    let application: MacXeneonEdgeTouchDriverApplication
    let scheduler: TestGestureScheduler
    let input: ApplicationRecordingInputSink
    let cursor: ApplicationRecordingCursorController
    let focus: ApplicationRecordingFocusRestorer
}

private final class ApplicationRecordingFocusRestorer: FocusRestorer {
    private(set) var restoreCount = 0
    private(set) var discardCount = 0

    func captureFocusedWindow() {}

    func restoreCapturedWindow() {
        restoreCount += 1
    }

    func discardCapturedWindow() {
        discardCount += 1
    }
}

private final class ApplicationRecordingInputSink: SyntheticInputSink {
    enum Call: Equatable {
        case mouseDown(CGPoint)
        case mouseUp(CGPoint)
        case mouseDragged(CGPoint)
    }

    private(set) var calls: [Call] = []

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

private final class ApplicationRecordingCursorController: CursorController {
    enum Call: Equatable {
        case borrow(CGPoint)
        case update(CGPoint)
        case returnToOrigin
        case forceShow
    }

    private(set) var calls: [Call] = []

    func borrow(warpingTo point: CGPoint) -> Bool {
        calls.append(.borrow(point))
        return true
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
