@testable import MacXeneonEdgeTouchDriverCore
import Darwin
import IOKit
import XCTest

final class FreshPermissionStartupTests: XCTestCase {
    private let denied = SyntheticPermissionSnapshot(postEventAccess: true, accessibilityTrusted: true,
        hidInputAccess: .denied, requiresAccessibility: true)
    private let granted = SyntheticPermissionSnapshot(postEventAccess: true, accessibilityTrusted: true,
        hidInputAccess: .granted, requiresAccessibility: true)

    private func harness(snapshot: SyntheticPermissionSnapshot) -> StartupTestHarness {
        let harness = StartupTestHarness(snapshot: snapshot)
        harness.useFreshWorker = true
        harness.permissions.supportsFreshSnapshots = true
        return harness
    }

    func testCachedDenialUsesOneCheckAtATimeAndStartsAfterFreshGrant() {
        let h = harness(snapshot: denied)
        h.permissions.currentFreshSnapshot = denied
        h.coordinator.start()
        h.polling.advance(bySeconds: 20)
        XCTAssertEqual(h.freshWorker.submissionCount, 1)
        XCTAssertEqual(h.hardwareStartCount, 0)
        h.freshWorker.runRequest(); h.freshWorker.completeRequest()
        XCTAssertEqual(h.freshWorker.submissionCount, 1, "Completion must not create a tight polling loop")
        h.permissions.currentFreshSnapshot = granted
        h.polling.advance(bySeconds: 2)
        h.freshWorker.runRequest(at: 1); h.freshWorker.completeRequest(at: 1)
        XCTAssertEqual(h.coordinator.state, .running)
        XCTAssertEqual(h.hardwareStartCount, 1)
        XCTAssertEqual(h.permissions.requestCount, 0, "Fresh checks never request permission")
        h.coordinator.stop()
    }

    func testFreshGrantIsIndependentOfABlockedInitialPermissionRequest() {
        let h = harness(snapshot: .notReady)
        h.permissions.currentFreshSnapshot = granted
        h.coordinator.start()
        XCTAssertEqual(h.worker.submissionCount, 1)
        XCTAssertEqual(h.freshWorker.submissionCount, 1)
        h.freshWorker.runRequest(); h.freshWorker.completeRequest()
        XCTAssertEqual(h.coordinator.state, .running)
        h.worker.runRequest(); h.worker.completeRequest()
        XCTAssertEqual(h.permissions.requestCount, 0)
        XCTAssertEqual(h.hardwareStartCount, 1)
        h.coordinator.stop()
    }

    func testStopBeforeCheckExecutesPreventsTheChildAndHardware() {
        let h = harness(snapshot: denied)
        h.permissions.currentFreshSnapshot = granted
        h.coordinator.start(); h.coordinator.stop()
        h.freshWorker.runRequest(); h.freshWorker.completeRequest()
        XCTAssertEqual(h.permissions.freshSnapshotCount, 0)
        XCTAssertEqual(h.hardwareStartCount, 0)
        XCTAssertEqual(h.coordinator.state, .stopped)
    }

    func testStopDuringCheckDiscardsLateApproval() {
        let h = harness(snapshot: denied)
        h.permissions.currentFreshSnapshot = granted
        h.permissions.onFreshSnapshot = { _ in h.signals.send(SIGTERM) }
        h.coordinator.start()
        h.freshWorker.runRequest(); h.freshWorker.completeRequest()
        XCTAssertEqual(h.hardwareStartCount, 0)
        XCTAssertEqual(h.coordinator.state, .stopped)
    }

    func testOldCompletionCannotClearANewerPendingCheck() {
        let h = harness(snapshot: denied)
        h.permissions.currentFreshSnapshot = denied
        h.coordinator.start(); h.freshWorker.runRequest(); h.freshWorker.completeRequest()
        h.polling.advance(bySeconds: 2)
        h.freshWorker.completeRequest()
        h.polling.advance(bySeconds: 10)
        XCTAssertEqual(h.freshWorker.submissionCount, 2)
        h.permissions.currentFreshSnapshot = granted
        h.freshWorker.runRequest(at: 1); h.freshWorker.completeRequest(at: 1)
        XCTAssertEqual(h.hardwareStartCount, 1)
        h.coordinator.stop()
    }

    func testHIDOpenDenialRequiresANewFreshGrantBeforeRetry() {
        let h = harness(snapshot: granted)
        h.hardwareError = HIDDeviceMonitorError.openFailed(kIOReturnNotPermitted)
        h.coordinator.start()
        XCTAssertEqual(h.hardwareStartCount, 1)
        XCTAssertEqual(h.hardwareStopCount, 1)
        h.polling.advance(bySeconds: 2)
        h.permissions.currentFreshSnapshot = nil
        h.freshWorker.runRequest(); h.freshWorker.completeRequest()
        XCTAssertEqual(h.hardwareStartCount, 1, "Cached approval cannot bypass the failed open")
        h.permissions.currentFreshSnapshot = denied
        h.polling.advance(bySeconds: 2)
        h.freshWorker.runRequest(at: 1); h.freshWorker.completeRequest(at: 1)
        XCTAssertEqual(h.hardwareStartCount, 1)
        h.permissions.currentFreshSnapshot = granted; h.hardwareError = nil
        h.polling.advance(bySeconds: 2)
        h.freshWorker.runRequest(at: 2); h.freshWorker.completeRequest(at: 2)
        XCTAssertEqual(h.coordinator.state, .running)
        XCTAssertEqual(h.hardwareStartCount, 2)
        h.coordinator.stop()
        XCTAssertEqual(h.hardwareStopCount, 2)
    }
}
