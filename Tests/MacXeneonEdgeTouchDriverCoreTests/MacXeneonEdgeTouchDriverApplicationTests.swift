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

    func testFocusAndCursorOptionsIndependentlyPreserveTapInput() {
        for option in restorationOptions {
            let fixture = makeRestorationFixture(focus: option.focus, cursor: option.cursor)
            let restoreFocus = option.focus ?? true
            let returnCursor = option.cursor ?? true
            let mode = "focus=\(String(describing: option.focus)), cursor=\(String(describing: option.cursor))"
            let point = CGPoint(x: 100, y: 200)

            fixture.application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
            fixture.application.handleTouchEvent(touchEvent(.up, rawX: 0, rawY: 0))

            XCTAssertEqual(fixture.input.calls, [.mouseDown(point), .mouseUp(point)], mode)
            XCTAssertEqual(fixture.cursor.calls, [.borrow(point), returnCursor ? .returnToOrigin : .forceShow], mode)
            XCTAssertEqual(fixture.focus.calls, restoreFocus ? [.capture, .restore] : [], mode)
            let expectedOrder: [ApplicationInteractionRecorder.Call] =
                (restoreFocus ? [.capture] : []) +
                [.borrow, .mouseDown, .mouseUp, returnCursor ? .returnToOrigin : .forceShow] +
                (restoreFocus ? [.restore] : [])
            XCTAssertEqual(fixture.interactions.calls, expectedOrder, mode)
        }
    }

    func testFocusAndCursorOptionsIndependentlyPreserveImmediateDrag() {
        for option in restorationOptions {
            let fixture = makeRestorationFixture(focus: option.focus, cursor: option.cursor)
            let restoreFocus = option.focus ?? true
            let returnCursor = option.cursor ?? true
            let mode = "focus=\(String(describing: option.focus)), cursor=\(String(describing: option.cursor))"
            let start = CGPoint(x: 100, y: 200)
            let end = CGPoint(x: 2_660, y: 920)

            fixture.application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
            fixture.application.handleTouchEvent(touchEvent(.move,
                rawX: XeneonEdgeDevice.rawXRange.upperBound, rawY: XeneonEdgeDevice.rawYRange.upperBound))
            fixture.application.handleTouchEvent(touchEvent(.up,
                rawX: XeneonEdgeDevice.rawXRange.upperBound, rawY: XeneonEdgeDevice.rawYRange.upperBound))

            XCTAssertEqual(fixture.input.calls, [.mouseDown(start), .mouseDragged(end), .mouseUp(end)], mode)
            XCTAssertEqual(fixture.cursor.calls, [.borrow(start), .update(end), returnCursor ? .returnToOrigin : .forceShow], mode)
            XCTAssertEqual(fixture.focus.calls, restoreFocus ? [.capture, .restore] : [], mode)
            let expectedOrder: [ApplicationInteractionRecorder.Call] =
                (restoreFocus ? [.capture] : []) +
                [.borrow, .mouseDown, .update, .mouseDragged, .mouseUp, returnCursor ? .returnToOrigin : .forceShow] +
                (restoreFocus ? [.restore] : [])
            XCTAssertEqual(fixture.interactions.calls, expectedOrder, mode)
        }
    }

    func testFocusAndCursorOptionsPreserveFailedBorrowCleanup() {
        for option in restorationOptions {
            let fixture = makeRestorationFixture(focus: option.focus, cursor: option.cursor, borrowSucceeds: false)
            let restoreFocus = option.focus ?? true
            let mode = "focus=\(String(describing: option.focus)), cursor=\(String(describing: option.cursor))"

            fixture.application.handleTouchEvent(touchEvent(.down, rawX: 0, rawY: 0))
            fixture.application.handleTouchEvent(touchEvent(.up, rawX: 0, rawY: 0))

            XCTAssertEqual(fixture.input.calls, [], mode)
            XCTAssertEqual(fixture.cursor.calls, [.borrow(CGPoint(x: 100, y: 200))], mode)
            XCTAssertEqual(fixture.focus.calls, restoreFocus ? [.capture, .discard] : [], mode)
            XCTAssertEqual(fixture.interactions.calls, restoreFocus ? [.capture, .borrow, .discard] : [.borrow], mode)
        }
    }

    private let restorationOptions: [(focus: Bool?, cursor: Bool?)] = [
        (nil, nil), (true, true), (true, false), (false, true), (false, false)
    ]

    private func makeRestorationFixture(focus restoreFocus: Bool?, cursor returnCursor: Bool?,
                                        borrowSucceeds: Bool = true) -> RestorationConfigurationFixture {
        var configuration = immediateConfiguration()
        if let restoreFocus {
            configuration.focus.restorePreviousWindow = restoreFocus
        }
        if let returnCursor {
            configuration.cursor.returnToPreviousPosition = returnCursor
        }
        let displays = [xeneonDisplay()]
        let interactions = ApplicationInteractionRecorder()
        let input = ApplicationRecordingInputSink(interactions: interactions)
        let cursor = ApplicationRecordingCursorController(borrowSucceeds: borrowSucceeds, interactions: interactions)
        let focus = ApplicationFocusCallRecorder(interactions: interactions)
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: configuration,
            displayResolver: DisplayResolver(activeDisplayProvider: { displays }),
            inputSink: input,
            cursorController: cursor,
            focusRestorer: focus
        )
        return RestorationConfigurationFixture(application: application, input: input, cursor: cursor,
                                               focus: focus, interactions: interactions)
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

private struct RestorationConfigurationFixture {
    let application: MacXeneonEdgeTouchDriverApplication
    let input: ApplicationRecordingInputSink
    let cursor: ApplicationRecordingCursorController
    let focus: ApplicationFocusCallRecorder
    let interactions: ApplicationInteractionRecorder
}

private final class ApplicationInteractionRecorder {
    enum Call: Equatable {
        case capture, borrow, mouseDown, update, mouseDragged, mouseUp
        case returnToOrigin, forceShow, restore, discard
    }

    var calls: [Call] = []
}

private final class ApplicationFocusCallRecorder: FocusRestorer {
    enum Call: Equatable {
        case capture
        case restore
        case discard
    }

    private(set) var calls: [Call] = []
    private let interactions: ApplicationInteractionRecorder?

    init(interactions: ApplicationInteractionRecorder? = nil) {
        self.interactions = interactions
    }

    func captureFocusedWindow() {
        calls.append(.capture)
        interactions?.calls.append(.capture)
    }

    func restoreCapturedWindow() {
        calls.append(.restore)
        interactions?.calls.append(.restore)
    }

    func discardCapturedWindow() {
        calls.append(.discard)
        interactions?.calls.append(.discard)
    }
}

private final class ApplicationRecordingInputSink: SyntheticInputSink {
    enum Call: Equatable {
        case mouseDown(CGPoint)
        case mouseUp(CGPoint)
        case mouseDragged(CGPoint)
    }

    private(set) var calls: [Call] = []
    private let interactions: ApplicationInteractionRecorder?

    init(interactions: ApplicationInteractionRecorder? = nil) {
        self.interactions = interactions
    }

    func postMouseDown(at point: CGPoint) {
        calls.append(.mouseDown(point))
        interactions?.calls.append(.mouseDown)
    }

    func postMouseUp(at point: CGPoint) {
        calls.append(.mouseUp(point))
        interactions?.calls.append(.mouseUp)
    }

    func postMouseDragged(to point: CGPoint) {
        calls.append(.mouseDragged(point))
        interactions?.calls.append(.mouseDragged)
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
    private let interactions: ApplicationInteractionRecorder?

    init(borrowSucceeds: Bool = true, interactions: ApplicationInteractionRecorder? = nil) {
        self.borrowSucceeds = borrowSucceeds
        self.interactions = interactions
    }

    func borrow(warpingTo point: CGPoint) -> Bool {
        calls.append(.borrow(point))
        interactions?.calls.append(.borrow)
        return borrowSucceeds
    }

    func updatePosition(_ point: CGPoint) {
        calls.append(.update(point))
        interactions?.calls.append(.update)
    }

    func returnToOrigin() {
        calls.append(.returnToOrigin)
        interactions?.calls.append(.returnToOrigin)
    }

    func forceShow() {
        calls.append(.forceShow)
        interactions?.calls.append(.forceShow)
    }
}
