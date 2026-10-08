@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class HIDUSBPowerResetTests: XCTestCase {
    private func identity(controller: UInt64 = 1, hub: UInt64 = 10, location: Int = 100,
                          revision: Int = 0x150, vendor: Int = 0x1a40, product: Int = 0x801) -> HIDUSBPowerIdentity {
        HIDUSBPowerIdentity(controllerID: controller, hubID: hub, locationID: location,
            deviceRevision: revision, hubVendorID: vendor, hubProductID: product)
    }

    func testInitialAttachmentAndWarmAliasCannotQualify() {
        var tracker = HIDUSBPowerResetTracker()
        XCTAssertFalse(tracker.qualifies(identity(), now: 0))
        tracker.removed(identity())
        XCTAssertFalse(tracker.qualifies(identity(), now: 0))
        XCTAssertFalse(tracker.qualifies(identity(controller: 2), now: 0))
    }

    func testPhysicalHubResetQualifiesAndCarriesThroughSecondBootEnumeration() {
        var tracker = HIDUSBPowerResetTracker()
        tracker.removed(identity())
        let boot = identity(controller: 2, hub: 20)
        XCTAssertTrue(tracker.qualifies(boot, now: 100))
        tracker.removed(boot)
        XCTAssertTrue(tracker.qualifies(identity(controller: 3, hub: 20), now: 5_000_000_100))
    }

    func testBootQualificationHasFixedDeadlineAndCannotBeRenewedByPolling() {
        var tracker = HIDUSBPowerResetTracker()
        tracker.removed(identity())
        let boot = identity(controller: 2, hub: 20)
        XCTAssertTrue(tracker.qualifies(boot, now: 100))
        XCTAssertTrue(tracker.qualifies(boot, now: 9_000_000_100))
        XCTAssertFalse(tracker.qualifies(boot, now: 10_000_000_100))
        tracker.removed(boot)
        XCTAssertFalse(tracker.qualifies(identity(controller: 3, hub: 20), now: 10_000_000_101))
    }

    func testStopStartInvalidatesBootQualification() {
        var tracker = HIDUSBPowerResetTracker()
        tracker.removed(identity())
        let boot = identity(controller: 2, hub: 20)
        XCTAssertTrue(tracker.qualifies(boot, now: 0))
        tracker.removed(boot)
        tracker.invalidate()
        XCTAssertFalse(tracker.qualifies(identity(controller: 3, hub: 20), now: 1))
    }

    func testDifferentPortAndUnknownHardwareCannotBorrowQualification() {
        for other in [identity(controller: 2, hub: 20, location: 200),
                      identity(controller: 2, hub: 20, revision: 0x151),
                      identity(controller: 2, hub: 20, vendor: 1),
                      identity(controller: 2, hub: 20, product: 1)] {
            var tracker = HIDUSBPowerResetTracker()
            tracker.removed(identity())
            XCTAssertFalse(tracker.qualifies(other, now: 0))
        }
    }

    func testUnknownPreviousHardwareCannotQualifyKnownReplacement() {
        var tracker = HIDUSBPowerResetTracker()
        tracker.removed(identity(revision: 0))
        XCTAssertFalse(tracker.qualifies(identity(controller: 2, hub: 20), now: 0))
    }

    func testInvalidIdentityAndDeadlineOverflowFailClosed() {
        for invalid in [identity(controller: 0, hub: 20), identity(controller: 2, hub: 0),
                        identity(controller: 20, hub: 20), identity(controller: 2, hub: 20, location: 0), identity(controller: 2, hub: 20, location: -1)] {
            var tracker = HIDUSBPowerResetTracker()
            tracker.removed(identity())
            XCTAssertFalse(tracker.qualifies(invalid, now: 0))
        }
        var tracker = HIDUSBPowerResetTracker()
        tracker.removed(identity())
        XCTAssertFalse(tracker.qualifies(identity(controller: 2, hub: 20), now: UInt64.max))
    }

    func testExpiredBootCanOnlyBeReplacedByAnotherPhysicalHubGeneration() {
        var tracker = HIDUSBPowerResetTracker()
        tracker.removed(identity())
        let boot = identity(controller: 2, hub: 20)
        XCTAssertTrue(tracker.qualifies(boot, now: 0))
        tracker.removed(boot)
        XCTAssertFalse(tracker.qualifies(identity(controller: 3, hub: 20), now: 20_000_000_000))
        XCTAssertTrue(tracker.qualifies(identity(controller: 3, hub: 30), now: 20_000_000_000))
    }
}
