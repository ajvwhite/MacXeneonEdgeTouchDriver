import IOKit
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class HIDManagerOpenAttemptTests: XCTestCase {
    func testDeniedOpenIsClosedBeforeRetryActuallyOpensDevices() {
        var managerIsOpen = false
        var permissionGranted = false
        var successfulDeviceOpens = 0
        var calls: [String] = []
        let open: () -> IOReturn = {
            calls.append("open")
            // IOHIDManager marks itself open before opening its devices. A second
            // call returns success immediately if the first was not closed.
            if managerIsOpen { return kIOReturnSuccess }
            managerIsOpen = true
            guard permissionGranted else { return kIOReturnNotPermitted }
            successfulDeviceOpens += 1
            return kIOReturnSuccess
        }
        let close: () -> IOReturn = {
            calls.append("close")
            managerIsOpen = false
            return kIOReturnSuccess
        }
        XCTAssertEqual(HIDManagerOpenAttempt.perform(open: open, close: close), kIOReturnNotPermitted)
        XCTAssertFalse(managerIsOpen)
        permissionGranted = true
        XCTAssertEqual(HIDManagerOpenAttempt.perform(open: open, close: close), kIOReturnSuccess)
        XCTAssertEqual(successfulDeviceOpens, 1)
        XCTAssertEqual(calls, ["open", "close", "open"])
    }

    func testCleanupFailureDoesNotHideOriginalOpenError() {
        var closes = 0
        XCTAssertEqual(HIDManagerOpenAttempt.perform(open: { kIOReturnNotPermitted }, close: {
            closes += 1
            return kIOReturnNotOpen
        }), kIOReturnNotPermitted)
        XCTAssertEqual(closes, 1)
    }

    func testSuccessfulOpenKeepsDeviceOwnership() {
        XCTAssertEqual(HIDManagerOpenAttempt.perform(open: { kIOReturnSuccess }, close: {
            XCTFail("A successful open must retain its devices until normal shutdown")
            return kIOReturnSuccess
        }), kIOReturnSuccess)
    }
}
