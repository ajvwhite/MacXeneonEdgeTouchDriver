import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class MacXeneonEdgeTouchDriverApplicationTests: XCTestCase {
    func testTwoPersistedControllersRouteToDifferentDisplays() throws {
        let left = display(id: 41, uuid: "LEFT", x: 0)
        let right = display(id: 42, uuid: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        let store = pairingStore()
        let first = TouchDeviceIdentity(locationID: 0x0014_0000)
        let second = TouchDeviceIdentity(locationID: 0x0110_0000)
        try store.assign(device: first, toDisplayUUID: left.uuid)
        try store.assign(device: second, toDisplayUUID: right.uuid)
        let input = ApplicationRecordingInputSink()
        let cursor = ApplicationRecordingCursorController()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: cursor,
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )

        application.handleDeviceMatched(first)
        application.handleDeviceMatched(second)
        application.handleTouchEvent(deviceEvent(first, .down, rawX: 0, rawY: 0))
        application.handleTouchEvent(deviceEvent(first, .up, rawX: 0, rawY: 0))
        application.handleTouchEvent(deviceEvent(second, .down, rawX: 0, rawY: 0))
        application.handleTouchEvent(deviceEvent(second, .up, rawX: 0, rawY: 0))

        XCTAssertEqual(input.calls, [
            .mouseDown(CGPoint(x: 0, y: 200)),
            .mouseUp(CGPoint(x: 0, y: 200)),
            .mouseDown(CGPoint(x: 2_000, y: 200)),
            .mouseUp(CGPoint(x: 2_000, y: 200))
        ])
    }

    func testRawTouchPairsControllerToDisplayedTargetAndSuppressesThatContact() {
        let target = display(id: 41, uuid: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let overlay = ApplicationRecordingPairingOverlay()
        let device = TouchDeviceIdentity(locationID: 0x0014_0000)
        let input = ApplicationRecordingInputSink()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: overlay
        )

        application.handleDeviceMatched(device)
        application.handleTouchEvent(deviceEvent(device, .down, rawX: 5_000, rawY: 5_000))
        application.handleTouchEvent(deviceEvent(device, .up, rawX: 5_000, rawY: 5_000))

        XCTAssertEqual(store.displayUUID(for: device), "TARGET")
        XCTAssertEqual(overlay.calls.prefix(2), [.show("TARGET", 1, 1), .confirmation("TARGET")])
        XCTAssertTrue(input.calls.isEmpty)
    }

    func testAlreadyPairedControllerCannotStealSecondPairingTarget() throws {
        let left = display(id: 41, uuid: "LEFT", x: 0)
        let right = display(id: 42, uuid: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        let store = pairingStore()
        let paired = TouchDeviceIdentity(locationID: 1)
        let unpaired = TouchDeviceIdentity(locationID: 2)
        try store.assign(device: paired, toDisplayUUID: left.uuid)
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )

        application.handleDeviceMatched(paired)
        application.handleDeviceMatched(unpaired)
        application.handleTouchEvent(deviceEvent(paired, .down, rawX: 0, rawY: 0))

        XCTAssertEqual(store.displayUUID(for: paired), "LEFT")
        XCTAssertNil(store.displayUUID(for: unpaired))
    }

    private func immediateConfiguration() -> DriverConfiguration {
        var configuration = DriverConfiguration.defaults
        configuration.timing.downToUpDelayMs = 0
        configuration.timing.clickToWarpBackDelayMs = 0
        configuration.timing.tapDebounceMs = 0
        configuration.timing.stuckGestureTimeoutMs = 1_000
        return configuration
    }

    private func display(id: CGDirectDisplayID, uuid: String, x: CGFloat) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: id,
            uuid: uuid,
            vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber,
            serialNumber: 0,
            bounds: CGRect(
                x: x,
                y: 200,
                width: CGFloat(CapturedXeneonDisplay.expectedWidth),
                height: CGFloat(CapturedXeneonDisplay.expectedHeight)
            ),
            pixelsWide: CapturedXeneonDisplay.expectedWidth,
            pixelsHigh: CapturedXeneonDisplay.expectedHeight
        )
    }

    private func pairingStore() -> PairingStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacXeneonEdgeTouchDriverTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return PairingStore(url: directory.appendingPathComponent("pairings.json"))
    }

    private func deviceEvent(
        _ device: TouchDeviceIdentity,
        _ kind: TouchEvent.Kind,
        rawX: Int,
        rawY: Int
    ) -> DeviceTouchEvent {
        DeviceTouchEvent(
            device: device,
            touch: TouchEvent(kind: kind, contactID: 0, rawX: rawX, rawY: rawY, timestamp: .now())
        )
    }
}

private final class ApplicationRecordingInputSink: SyntheticInputSink {
    enum Call: Equatable {
        case mouseDown(CGPoint)
        case mouseUp(CGPoint)
        case mouseDragged(CGPoint)
        case scroll(CGFloat, CGFloat, SyntheticScrollPhase)
    }

    private(set) var calls: [Call] = []
    func postMouseDown(at point: CGPoint) { calls.append(.mouseDown(point)) }
    func postMouseUp(at point: CGPoint) { calls.append(.mouseUp(point)) }
    func postMouseDragged(to point: CGPoint) { calls.append(.mouseDragged(point)) }
    func postScroll(deltaX: CGFloat, deltaY: CGFloat, phase: SyntheticScrollPhase) {
        calls.append(.scroll(deltaX, deltaY, phase))
    }
}

private final class ApplicationRecordingCursorController: CursorController {
    enum Call: Equatable { case borrow(CGPoint), update(CGPoint), returnToOrigin, forceShow }
    private(set) var calls: [Call] = []
    func borrow(warpingTo point: CGPoint) -> Bool { calls.append(.borrow(point)); return true }
    func updatePosition(_ point: CGPoint) { calls.append(.update(point)) }
    func returnToOrigin() { calls.append(.returnToOrigin) }
    func forceShow() { calls.append(.forceShow) }
}

private final class ApplicationRecordingPairingOverlay: PairingOverlayPresenting {
    enum Call: Equatable {
        case show(String, Int, Int)
        case confirmation(String)
        case hide
    }
    private(set) var calls: [Call] = []
    func show(on display: DisplaySnapshot, step: Int, total: Int) {
        calls.append(.show(display.uuid, step, total))
    }
    func showConfirmation(on display: DisplaySnapshot) { calls.append(.confirmation(display.uuid)) }
    func hide() { calls.append(.hide) }
}
