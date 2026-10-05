import Darwin
import Foundation
import IOKit
import IOKit.hid
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

/// Opt-in, read-only check of the production cached-release reader. Stop any
/// seizing driver first. This test never prompts or posts synthetic input.
final class HIDRecoveryHardwareTests: XCTestCase {
    func testAttachedControllerHasInitializedCoherentNeutralCache() throws {
        guard ProcessInfo.processInfo.environment["XENEON_RUN_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Set XENEON_RUN_HARDWARE_TESTS=1 with the driver stopped and fingers lifted.")
        }
        guard Thread.isMainThread else { XCTFail("Hardware diagnostics must run on main"); return }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            XCTFail("HID listen access is not granted; no permission request was made.")
            return
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: XeneonEdgeDevice.vendorID,
            kIOHIDProductIDKey: XeneonEdgeDevice.productID] as CFDictionary)
        let opened = IOHIDManagerOpen(manager, 0)
        XCTAssertEqual(opened, kIOReturnSuccess, "Stop the seizing driver before this diagnostic.")
        guard opened == kIOReturnSuccess else { return }
        defer { XCTAssertEqual(IOHIDManagerClose(manager, 0), kIOReturnSuccess) }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        XCTAssertFalse(devices.isEmpty, "No XENEON controller is attached.")
        let readers = devices.compactMap { HIDNeutralStateReader(device: $0) }
        XCTAssertEqual(readers.count, 1, "This diagnostic covers one supported report-7 endpoint.")
        guard let reader = readers.first else { return }
        let neutral = reader.read(after: 0)
        XCTAssertNotNil(neutral, "Lift all fingers; all six cached input fields must be initialized and coherent.")
        guard let neutral else { return }
        print("Native cached-release reader confirmed supported descriptor; timestamp=\(neutral.reportTimestamp)")
        XCTAssertNil(reader.read(after: neutral.reportTimestamp),
                     "The same release must not be reused as evidence after a newer owner loss.")
    }
}
