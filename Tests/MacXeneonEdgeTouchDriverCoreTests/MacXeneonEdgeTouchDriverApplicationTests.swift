import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class MacXeneonEdgeTouchDriverApplicationTests: XCTestCase {
    func testEachControllerGetsIndependentFocusRestorer() {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        var focusRestorerCount = 0
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            focusRestorerProvider: {
                focusRestorerCount += 1
                return NoOpFocusRestorer()
            },
            pairingStore: pairingStore(),
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )

        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 1))
        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 2))

        XCTAssertEqual(focusRestorerCount, 2)
    }

    func testTwoPersistedControllersRouteToDifferentDisplays() throws {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        let store = pairingStore()
        let first = TouchDeviceIdentity(locationID: 1)
        let second = TouchDeviceIdentity(locationID: 2)
        let devices: Set = [first, second]
        try store.assign(device: first, to: left, connectedDevices: devices, displays: [left, right])
        try store.assign(device: second, to: right, connectedDevices: devices, displays: [left, right])
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

    func testStormOnOneControllerProducesNoInputAndDoesNotDisableOtherController() throws {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        let store = pairingStore()
        let storming = TouchDeviceIdentity(locationID: 11)
        let healthy = TouchDeviceIdentity(locationID: 12)
        let devices: Set = [storming, healthy]
        try store.assign(device: storming, to: left, connectedDevices: devices, displays: [left, right])
        try store.assign(device: healthy, to: right, connectedDevices: devices, displays: [left, right])
        let input = ApplicationRecordingInputSink()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )

        application.handleDeviceMatched(storming)
        application.handleDeviceMatched(healthy)
        application.handleTouchEvent(deviceEvent(
            storming,
            .down,
            rawX: 10_410,
            rawY: 6_120,
            timestampNanoseconds: 1_000_000_000
        ))
        application.handleTouchEvent(deviceEvent(
            storming,
            .move,
            rawX: 11_264,
            rawY: 4_533,
            timestampNanoseconds: 1_008_000_000
        ))

        XCTAssertTrue(input.calls.isEmpty)
        XCTAssertTrue(application.hasStormRecoveryTimer(for: storming))

        application.handleTouchEvent(deviceEvent(
            healthy,
            .down,
            rawX: 0,
            rawY: 0,
            timestampNanoseconds: 2_000_000_000
        ))
        application.handleTouchEvent(deviceEvent(
            healthy,
            .up,
            rawX: 0,
            rawY: 0,
            timestampNanoseconds: 2_100_000_000
        ))

        XCTAssertEqual(input.calls, [
            .mouseDown(CGPoint(x: 2_000, y: 200)),
            .mouseUp(CGPoint(x: 2_000, y: 200))
        ])

        application.handleStormRecoveryTick(
            for: storming,
            at: DispatchTime(uptimeNanoseconds: 2_100_000_000)
        )
        XCTAssertFalse(application.hasStormRecoveryTimer(for: storming))
    }

    func testStormingControllerRoutesAConfidentTapAndDropsInterleavedOutliers() throws {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 0)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let device = TouchDeviceIdentity(locationID: 11)
        try store.assign(device: device, to: target, connectedDevices: [device], displays: [target])
        let input = ApplicationRecordingInputSink()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )
        application.handleDeviceMatched(device)

        let reports: [(TouchEvent.Kind, Int, Int, UInt64)] = [
            (.down, 10_410, 6_120, 1_000_000_000),
            (.move, 11_264, 4_533, 1_008_000_000),
            (.down, 8_000, 4_000, 1_020_000_000),
            (.move, 200, 9_000, 1_028_000_000),
            (.move, 8_010, 4_005, 1_036_000_000),
            (.move, 15_000, 300, 1_044_000_000),
            (.move, 8_020, 4_010, 1_052_000_000),
            (.move, 8_030, 4_015, 1_068_000_000),
            (.up, 8_032, 4_015, 1_084_000_000)
        ]
        for report in reports {
            application.handleTouchEvent(deviceEvent(
                device,
                report.0,
                rawX: report.1,
                rawY: report.2,
                timestampNanoseconds: report.3
            ))
        }

        XCTAssertEqual(input.calls.count, 2)
        guard case .mouseDown(let downPoint) = input.calls[0],
              case .mouseUp(let upPoint) = input.calls[1] else {
            return XCTFail("Expected one recovered click")
        }
        XCTAssertEqual(downPoint.x, upPoint.x, accuracy: 0.001)
        let expectedX = target.bounds.minX + target.bounds.width * 8_000 / 16_383
        XCTAssertEqual(downPoint.x, expectedX, accuracy: 0.001)
        application.handleDeviceRemoval(device)
    }

    func testRawTouchPairsControllerToDisplayedTargetAndSuppressesThatContact() {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let overlay = ApplicationRecordingPairingOverlay()
        let device = TouchDeviceIdentity(locationID: 1)
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

        XCTAssertEqual(
            store.resolveDisplay(for: device, connectedDevices: [device], displays: [target]),
            target
        )
        XCTAssertEqual(overlay.calls.prefix(2), [.show("TARGET", 1, 1), .confirmation("TARGET")])
        XCTAssertTrue(input.calls.isEmpty)
    }

    func testAlreadyPairedControllerCannotStealSecondPairingTarget() throws {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        let store = pairingStore()
        let paired = TouchDeviceIdentity(locationID: 1)
        let unpaired = TouchDeviceIdentity(locationID: 2)
        let devices: Set = [paired, unpaired]
        try store.assign(device: paired, to: left, connectedDevices: devices, displays: [left, right])
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

        XCTAssertEqual(
            store.resolveDisplay(for: paired, connectedDevices: devices, displays: [left, right]),
            left
        )
        XCTAssertNil(store.resolveDisplay(
            for: unpaired,
            connectedDevices: devices,
            displays: [left, right]
        ))
    }

    func testDisplayBoundsChangeUpdatesDestinationWithoutRecalibration() throws {
        var currentDisplay = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [currentDisplay] })
        let store = pairingStore()
        let device = TouchDeviceIdentity(locationID: 1)
        try store.assign(
            device: device,
            to: currentDisplay,
            connectedDevices: [device],
            displays: [currentDisplay]
        )
        let input = ApplicationRecordingInputSink()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: input,
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )
        application.handleDeviceMatched(device)
        application.handleTouchEvent(deviceEvent(device, .down, rawX: 0, rawY: 0))
        application.handleTouchEvent(deviceEvent(device, .up, rawX: 0, rawY: 0))

        currentDisplay = display(id: 41, runtimeIdentifier: "TARGET", x: 2_000)
        application.refreshDisplayMappings(reason: "test arrangement change")
        application.handleTouchEvent(deviceEvent(device, .down, rawX: 0, rawY: 0))
        application.handleTouchEvent(deviceEvent(device, .up, rawX: 0, rawY: 0))

        XCTAssertEqual(input.calls, [
            .mouseDown(CGPoint(x: 100, y: 200)),
            .mouseUp(CGPoint(x: 100, y: 200)),
            .mouseDown(CGPoint(x: 2_000, y: 200)),
            .mouseUp(CGPoint(x: 2_000, y: 200))
        ])
    }

    func testControllerRemovalInvalidatesBootSessionPairing() throws {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let device = TouchDeviceIdentity(locationID: 1)
        try store.assign(device: device, to: target, connectedDevices: [device], displays: [target])
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )

        application.handleDeviceMatched(device)
        application.handleDeviceRemoval(device)

        XCTAssertTrue(store.pairings.isEmpty)
    }

    func testDisplayMembershipChangeInvalidatesBootSessionPairingAndHidesOverlay() throws {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let overlay = ApplicationRecordingPairingOverlay()
        let device = TouchDeviceIdentity(locationID: 1)
        try store.assign(device: device, to: target, connectedDevices: [device], displays: [target])
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: overlay
        )

        application.handleDeviceMatched(device)
        application.handleDisplayReconfiguration(displayID: target.displayID, flags: .removeFlag)
        waitForAsyncWork(milliseconds: 100)

        XCTAssertTrue(store.pairings.isEmpty)
        XCTAssertTrue(overlay.calls.contains(.hide))
    }

    func testBoundsOnlyDisplayChangePreservesBootSessionPairing() throws {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let device = TouchDeviceIdentity(locationID: 1)
        try store.assign(device: device, to: target, connectedDevices: [device], displays: [target])
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: ApplicationRecordingPairingOverlay()
        )

        application.handleDeviceMatched(device)
        application.handleDisplayReconfiguration(displayID: target.displayID, flags: .movedFlag)
        waitForAsyncWork(milliseconds: 100)

        XCTAssertEqual(store.pairings.count, 1)
        XCTAssertEqual(
            store.resolveDisplay(for: device, connectedDevices: [device], displays: [target]),
            target
        )
    }

    func testUnavailableOverlayDoesNotAuthorizeTouchRouting() {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let overlay = ApplicationRecordingPairingOverlay(canShow: false)
        let device = TouchDeviceIdentity(locationID: 1)
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
        application.refreshDisplayMappings(reason: "test screen readiness lag")
        application.handleTouchEvent(deviceEvent(device, .down, rawX: 0, rawY: 0))

        XCTAssertTrue(store.pairings.isEmpty)
        XCTAssertTrue(input.calls.isEmpty)
    }

    func testStagedDeviceEnumerationIsDebouncedIntoOneReconciliation() {
        let left = display(id: 41, runtimeIdentifier: "LEFT", x: 0)
        let right = display(id: 42, runtimeIdentifier: "RIGHT", x: 2_000)
        let resolver = DisplayResolver(activeDisplayProvider: { [left, right] })
        let overlay = ApplicationRecordingPairingOverlay()
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: pairingStore(),
            pairingOverlay: overlay
        )

        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 1))
        application.handleDeviceMatched(TouchDeviceIdentity(locationID: 2))
        waitForAsyncWork(milliseconds: 400)

        XCTAssertEqual(overlay.calls.filter {
            if case .show = $0 { return true }
            return false
        }, [.show("LEFT", 1, 2)])
    }

    func testPairingOverlayRetriesUntilAppKitScreenBecomesReady() {
        let target = display(id: 41, runtimeIdentifier: "TARGET", x: 100)
        let resolver = DisplayResolver(activeDisplayProvider: { [target] })
        let store = pairingStore()
        let overlay = ApplicationRecordingPairingOverlay(failuresBeforeSuccess: 2)
        let device = TouchDeviceIdentity(locationID: 1)
        let application = MacXeneonEdgeTouchDriverApplication(
            configuration: immediateConfiguration(),
            displayResolver: resolver,
            inputSink: ApplicationRecordingInputSink(),
            cursorController: ApplicationRecordingCursorController(),
            pairingStore: store,
            pairingOverlay: overlay
        )

        application.handleDeviceMatched(device)
        application.refreshDisplayMappings(reason: "test initial screen readiness")
        waitForAsyncWork(milliseconds: 1_100)
        application.handleTouchEvent(deviceEvent(device, .down, rawX: 0, rawY: 0))
        application.handleTouchEvent(deviceEvent(device, .up, rawX: 0, rawY: 0))

        XCTAssertEqual(overlay.calls.filter {
            if case .show = $0 { return true }
            return false
        }.count, 3)
        XCTAssertEqual(store.pairings.count, 1)
    }

    private func immediateConfiguration() -> DriverConfiguration {
        var configuration = DriverConfiguration.defaults
        configuration.timing.downToUpDelayMs = 0
        configuration.timing.clickToWarpBackDelayMs = 0
        configuration.timing.tapDebounceMs = 0
        configuration.timing.stuckGestureTimeoutMs = 1_000
        return configuration
    }

    private func display(id: CGDirectDisplayID, runtimeIdentifier: String, x: CGFloat) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: id,
            runtimeIdentifier: runtimeIdentifier,
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
        rawY: Int,
        timestampNanoseconds: UInt64? = nil
    ) -> DeviceTouchEvent {
        DeviceTouchEvent(
            device: device,
            touch: TouchEvent(
                kind: kind,
                contactID: 0,
                rawX: rawX,
                rawY: rawY,
                timestamp: timestampNanoseconds.map(DispatchTime.init(uptimeNanoseconds:)) ?? .now()
            )
        )
    }

    private func waitForAsyncWork(milliseconds: Int) {
        let expectation = expectation(description: "asynchronous driver work")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: Double(milliseconds) / 1_000 + 1)
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
    func postMouseDown(at point: CGPoint, clickCount: Int) { calls.append(.mouseDown(point)) }
    func postMouseUp(at point: CGPoint, clickCount: Int) { calls.append(.mouseUp(point)) }
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
    private let lock = NSLock()
    private var storedCalls: [Call] = []
    private let canShow: Bool
    private var failuresBeforeSuccess: Int
    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }
    init(canShow: Bool = true, failuresBeforeSuccess: Int = 0) {
        self.canShow = canShow
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }
    func show(on display: DisplaySnapshot, step: Int, total: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storedCalls.append(.show(display.runtimeIdentifier, step, total))
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            return false
        }
        return canShow
    }
    func showConfirmation(on display: DisplaySnapshot) {
        lock.lock()
        storedCalls.append(.confirmation(display.runtimeIdentifier))
        lock.unlock()
    }
    func hide() {
        lock.lock()
        storedCalls.append(.hide)
        lock.unlock()
    }
}
