import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

/// Creates inert manager objects, but never opens, schedules, or seizes a device.
final class HIDManagerCallbackRegistrationTests: XCTestCase {
    func testValidTokenPromotesOnlyItsLiveMonitor() {
        let monitor = makeMonitor()
        let registration = HIDManagerCallbackRegistration(monitor: monitor)
        XCTAssertTrue(HIDManagerCallbackRegistration.monitor(for: registration.context) === monitor)
        registration.invalidate()
        XCTAssertNil(HIDManagerCallbackRegistration.monitor(for: registration.context))
        registration.invalidate()
    }

    func testLateContextAfterMonitorReleaseCannotResolveReplacement() {
        var monitor: HIDDeviceMonitor? = makeMonitor()
        let weakMonitor = { [weak monitor] in monitor }
        var registration: HIDManagerCallbackRegistration? = HIDManagerCallbackRegistration(monitor: monitor!)
        let oldContext = registration!.context
        monitor = nil
        XCTAssertNil(weakMonitor(), "Registry entries must not retain a monitor")
        XCTAssertNil(HIDManagerCallbackRegistration.monitor(for: oldContext))
        registration = nil
        let nextMonitor = makeMonitor()
        let next = HIDManagerCallbackRegistration(monitor: nextMonitor)
        XCTAssertNotEqual(oldContext, next.context)
        XCTAssertNil(HIDManagerCallbackRegistration.monitor(for: oldContext))
        XCTAssertTrue(HIDManagerCallbackRegistration.monitor(for: next.context) === nextMonitor)
    }

    func testRegistrationReleaseRetiresTokenWhileMonitorRemainsAlive() {
        let monitor = makeMonitor()
        var registration: HIDManagerCallbackRegistration? = HIDManagerCallbackRegistration(monitor: monitor)
        let context = registration!.context
        registration = nil
        XCTAssertNil(HIDManagerCallbackRegistration.monitor(for: context))
        withExtendedLifetime(monitor) {}
    }

    func testUnexpectedThreadDoesNotPromoteOrAccessMonitor() {
        let monitor = makeMonitor()
        let registration = HIDManagerCallbackRegistration(monitor: monitor)
        let token = UInt(bitPattern: registration.context)
        let finished = expectation(description: "Off-main callback rejected")
        DispatchQueue(label: "hid-manager.unexpected-callback").async {
            XCTAssertNil(HIDManagerCallbackRegistration.monitor(for: UnsafeMutableRawPointer(bitPattern: token)))
            finished.fulfill()
        }
        guard XCTWaiter.wait(for: [finished], timeout: 2) == .completed else {
            XCTFail("Unexpected-thread check did not complete")
            return
        }
        XCTAssertTrue(HIDManagerCallbackRegistration.monitor(for: registration.context) === monitor)
    }

    func testNilAndUnknownContextsAreRejected() {
        XCTAssertNil(HIDManagerCallbackRegistration.monitor(for: nil))
        XCTAssertNil(HIDManagerCallbackRegistration.monitor(for: UnsafeMutableRawPointer(bitPattern: UInt.max)))
    }

    private func makeMonitor() -> HIDDeviceMonitor {
        HIDDeviceMonitor(eventQueue: DispatchQueue(label: "hid-manager.inert-events"), seizeDevice: false,
                         touchEventHandler: { _ in XCTFail("No HID input is scheduled") },
                         deviceRemovalHandler: { XCTFail("No HID input is scheduled") })
    }
}
