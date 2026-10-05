import Dispatch
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class SendableValueContractsTests: XCTestCase {
    func testConfigurationAndNestedValuesCanBeCapturedBySendableClosures() {
        let configuration = DriverConfiguration.defaults
        let snapshot = sendableSnapshot(configuration)
        var edited = configuration
        edited.timing.tapDebounceMs += 1
        edited.focus.restorePreviousWindow.toggle()
        edited.cursor.returnToPreviousPosition.toggle()

        XCTAssertEqual(snapshot(), .defaults)
        XCTAssertNotEqual(snapshot(), edited)
        XCTAssertEqual(sendableSnapshot(configuration.timing)(), configuration.timing)
        XCTAssertEqual(sendableSnapshot(configuration.display)(), configuration.display)
        XCTAssertEqual(sendableSnapshot(configuration.focus)(), configuration.focus)
        XCTAssertEqual(sendableSnapshot(configuration.cursor)(), configuration.cursor)
        XCTAssertEqual(sendableSnapshot(configuration.gesture)(), configuration.gesture)
        XCTAssertEqual(sendableSnapshot(configuration.gesture.pinchModifies)(), configuration.gesture.pinchModifies)
        XCTAssertEqual(sendableSnapshot(configuration.diagnostics)(), configuration.diagnostics)

        let result = ConfigurationLoadResult(configuration: configuration, warnings: ["Value snapshot"])
        XCTAssertEqual(sendableSnapshot(result)(), result)
    }

    func testGestureTimingCanBeCapturedBySendableClosure() {
        let timing = GestureTiming(configuration: DriverConfiguration.defaults.timing)
        XCTAssertEqual(sendableSnapshot(timing)(), timing)
        XCTAssertEqual(sendableSnapshot(GestureTiming.immediate)(), .immediate)
    }

    func testTouchEventsAndKindsCanBeCapturedBySendableClosures() {
        let kinds: [TouchEvent.Kind] = [.down, .move, .up]
        for kind in kinds {
            let event = TouchEvent(
                kind: kind,
                contactID: 0,
                rawX: 123,
                rawY: 456,
                timestamp: DispatchTime(uptimeNanoseconds: 1_000_000)
            )
            XCTAssertEqual(sendableSnapshot(kind)(), kind)
            XCTAssertEqual(sendableSnapshot(event)(), event)
        }
    }

    func testHIDObservationsAndRetirementFenceCanCrossQueues() {
        let sourceID = HIDSourceID(rawValue: 123)
        let observation = HIDTouchObservation(
            sourceID: sourceID, contactEpoch: 456, isPressed: true,
            timestamp: DispatchTime(uptimeNanoseconds: 789), event: nil
        )
        let fence = HIDSourceRetirementFence(sourceID: sourceID)
        XCTAssertEqual(sendableSnapshot(sourceID)(), sourceID)
        XCTAssertEqual(sendableSnapshot(observation)(), observation)
        let capturedFence = sendableSnapshot(fence)
        XCTAssertTrue(capturedFence() === fence)
        XCTAssertFalse(capturedFence().isRetired)
        fence.retire()
        XCTAssertTrue(capturedFence().isRetired)
    }

    func testWorkspaceEventHintsCanBeCapturedBySendableClosure() {
        let snapshot = sendableSnapshot(WorkspaceFocusMonitor.Event.sessionActive(false))
        guard case .sessionActive(false) = snapshot() else {
            return XCTFail("Expected the captured session hint to be preserved")
        }
    }
}

// The generic constraint keeps these value contracts checked at compile time.
private func sendableSnapshot<Value: Sendable>(_ value: Value) -> @Sendable () -> Value {
    { value }
}
