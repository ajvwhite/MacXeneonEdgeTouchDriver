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
