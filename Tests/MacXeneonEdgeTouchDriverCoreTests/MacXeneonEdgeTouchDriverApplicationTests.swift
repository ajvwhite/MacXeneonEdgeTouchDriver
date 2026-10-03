import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class MacXeneonEdgeTouchDriverApplicationTests: XCTestCase {
    func testDeviceMatchRefreshesDisplayMapper() {
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

        XCTAssertEqual(cursor.calls, [.borrow(CGPoint(x: 100, y: 200)), .returnToOrigin])
        XCTAssertEqual(input.calls, [.mouseDown(CGPoint(x: 100, y: 200)), .mouseUp(CGPoint(x: 100, y: 200))])
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

    func testDefaultAndConfiguredFocusRestorationPreserveTapInput() {
        for enabled: Bool? in [nil, true, false] {
            var configuration = immediateConfiguration()
            if let enabled {
                configuration.focus.restorePreviousWindow = enabled
            }
            let fixture = makeFocusFixture(configuration: configuration)
            let mode = enabled.map { "explicit \($0)" } ?? "default"
            let point = CGPoint(x: 100, y: 200)

            fixture.application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
            fixture.application.handleTouchEvent(touchEvent(.up, rawX: 0, rawY: 0))

            XCTAssertEqual(fixture.input.calls, [.mouseDown(point), .mouseUp(point)], mode)
            XCTAssertEqual(fixture.cursor.calls, [.borrow(point), .returnToOrigin], mode)
            XCTAssertEqual(fixture.focus.calls, enabled == false ? [] : [.capture, .restore], mode)
        }
    }

    func testFocusOptionPreservesImmediateDragAndCursorReturn() {
        for enabled in [true, false] {
            var configuration = immediateConfiguration()
            configuration.focus.restorePreviousWindow = enabled
            let fixture = makeFocusFixture(configuration: configuration)
            let mode = "restorePreviousWindow=\(enabled)"
            let start = CGPoint(x: 100, y: 200)
            let end = CGPoint(x: 2_660, y: 920)

            fixture.application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
            fixture.application.handleTouchEvent(touchEvent(.move,
                rawX: XeneonEdgeDevice.rawXRange.upperBound, rawY: XeneonEdgeDevice.rawYRange.upperBound))
            fixture.application.handleTouchEvent(touchEvent(.up,
                rawX: XeneonEdgeDevice.rawXRange.upperBound, rawY: XeneonEdgeDevice.rawYRange.upperBound))

            XCTAssertEqual(fixture.input.calls, [.mouseDown(start), .mouseDragged(end), .mouseUp(end)], mode)
            XCTAssertEqual(fixture.cursor.calls, [.borrow(start), .update(end), .returnToOrigin], mode)
            XCTAssertEqual(fixture.focus.calls, enabled ? [.capture, .restore] : [], mode)
        }
    }

    func testDisabledFocusOptionSkipsCaptureAndDiscardWhenCursorBorrowFails() {
        for enabled in [true, false] {
            var configuration = immediateConfiguration()
            configuration.focus.restorePreviousWindow = enabled
            let fixture = makeFocusFixture(configuration: configuration, borrowSucceeds: false)
            let mode = "restorePreviousWindow=\(enabled)"

            fixture.application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
            fixture.application.handleTouchEvent(touchEvent(.up, rawX: 0, rawY: 0))

            XCTAssertEqual(fixture.input.calls, [], mode)
            XCTAssertEqual(fixture.cursor.calls, [.borrow(CGPoint(x: 100, y: 200))], mode)
            XCTAssertEqual(fixture.focus.calls, enabled ? [.capture, .discard] : [], mode)
        }
    }

    private func makeFocusFixture(configuration: DriverConfiguration, borrowSucceeds: Bool = true) -> FocusConfigurationFixture {
        let displays = [xeneonDisplay()]
        let input = ApplicationRecordingInputSink()
        let cursor = ApplicationRecordingCursorController(borrowSucceeds: borrowSucceeds)
        let focus = ApplicationFocusCallRecorder()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: configuration,
            displayResolver: DisplayResolver(activeDisplayProvider: { displays }),
            inputSink: input,
            cursorController: cursor,
            focusRestorer: focus
        )
        return FocusConfigurationFixture(application: application, input: input, cursor: cursor, focus: focus)
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

    private func xeneonDisplay() -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: 42,
            vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber,
            serialNumber: CapturedXeneonDisplay.observedSerialNumber,
            bounds: CGRect(x: 100, y: 200, width: 2_560, height: 720),
            pixelsWide: CapturedXeneonDisplay.expectedWidth,
            pixelsHigh: CapturedXeneonDisplay.expectedHeight
        )
    }

    private func touchEvent(_ kind: TouchEvent.Kind, rawX: Int, rawY: Int) -> TouchEvent {
        TouchEvent(kind: kind, contactID: 0, rawX: rawX, rawY: rawY, timestamp: .now())
    }
}

private struct FocusConfigurationFixture {
    let application: MacXeneonEdgeTouchDriverApplication
    let input: ApplicationRecordingInputSink
    let cursor: ApplicationRecordingCursorController
    let focus: ApplicationFocusCallRecorder
}

private final class ApplicationFocusCallRecorder: FocusRestorer {
    enum Call: Equatable {
        case capture
        case restore
        case discard
    }

    private(set) var calls: [Call] = []

    func captureFocusedWindow() { calls.append(.capture) }
    func restoreCapturedWindow() { calls.append(.restore) }
    func discardCapturedWindow() { calls.append(.discard) }
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
    private let borrowSucceeds: Bool

    init(borrowSucceeds: Bool = true) {
        self.borrowSucceeds = borrowSucceeds
    }

    func borrow(warpingTo point: CGPoint) -> Bool {
        calls.append(.borrow(point))
        return borrowSucceeds
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
