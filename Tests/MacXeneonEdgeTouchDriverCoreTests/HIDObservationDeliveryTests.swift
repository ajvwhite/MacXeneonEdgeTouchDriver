import Foundation
import IOKit
import IOKit.hid
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

/// Exercises the production queue-delivery seam without opening HID hardware.
final class HIDObservationDeliveryTests: XCTestCase {
    func testObservationHandlerReplacesNormalizedCallbackAndKeepsDuplicates() {
        onMain {
            var pending: [(HIDTouchObservation, HIDSourceRetirementFence)] = []
            let registration = makeRegistration { pending.append(($0, $1)) }
            write(registration, pressed: true)
            let firstTime = deliver(registration, timestamp: 100)
            let secondTime = deliver(registration, timestamp: 200)
            write(registration, pressed: false)
            let thirdTime = deliver(registration, timestamp: 300)
            var received: [HIDTouchObservation] = []
            for (observation, fence) in pending {
                HIDDeviceMonitor.deliverObservation(
                    observation, fence: fence,
                    touchEventHandler: { _ in XCTFail("Observation mode must not also dispatch a normalized event") },
                    observationHandler: { received.append($0); XCTAssertTrue($1 === fence) }
                )
            }
            XCTAssertEqual(received.count, 3)
            XCTAssertEqual(received.compactMap(\.event).map(\.kind), [.down, .up])
            XCTAssertEqual(received.map(\.timestamp), [firstTime, secondTime, thirdTime])
            XCTAssertEqual(received.map(\.contactEpoch), [1, 1, 1])
            XCTAssertNil(received[1].event)
            XCTAssertTrue(received[1].isPressed)
        }
    }

    func testNormalizedCallbackKeepsPublicEventOnlyCompatibility() {
        onMain {
            var pending: [(HIDTouchObservation, HIDSourceRetirementFence)] = []
            let registration = makeRegistration { pending.append(($0, $1)) }
            write(registration, pressed: true)
            let downTime = deliver(registration, timestamp: 100)
            deliver(registration, timestamp: 200)
            write(registration, pressed: true, x: 11)
            let moveTime = deliver(registration, timestamp: 300)
            write(registration, pressed: false, x: 11)
            let upTime = deliver(registration, timestamp: 400)
            deliver(registration, timestamp: 500)
            var events: [TouchEvent] = []
            for (observation, fence) in pending {
                HIDDeviceMonitor.deliverObservation(
                    observation, fence: fence, touchEventHandler: { events.append($0) },
                    observationHandler: nil
                )
            }
            XCTAssertEqual(events.map(\.kind), [.down, .move, .up])
            XCTAssertEqual(events.map(\.timestamp), [downTime, moveTime, upTime])
        }
    }

    func testRetiredQueuedObservationCannotReachEitherDeliveryMode() {
        onMain {
            var pending: [(HIDTouchObservation, HIDSourceRetirementFence)] = []
            let registration = makeRegistration { pending.append(($0, $1)) }
            write(registration, pressed: true)
            deliver(registration, timestamp: 100)
            deliver(registration, timestamp: 200)
            registration.invalidate()
            for (observation, fence) in pending {
                XCTAssertTrue(fence.isRetired)
                HIDDeviceMonitor.deliverObservation(
                    observation, fence: fence,
                    touchEventHandler: { _ in XCTFail("A retired report must not emit events") },
                    observationHandler: { _, _ in XCTFail("A retired report must not emit liveness") }
                )
                HIDDeviceMonitor.deliverObservation(
                    observation, fence: fence,
                    touchEventHandler: { _ in XCTFail("The legacy path must also reject retired reports") },
                    observationHandler: nil
                )
            }
            XCTAssertEqual(pending.count, 2)
        }
    }

    func testRetiringOneSourceDoesNotFenceAnotherOrResetItsParser() {
        onMain {
            var pending: [(HIDTouchObservation, HIDSourceRetirementFence)] = []
            let first = makeRegistration { pending.append(($0, $1)) }
            let second = makeRegistration { pending.append(($0, $1)) }
            write(first, pressed: true)
            deliver(first, timestamp: 100)
            write(second, pressed: true)
            deliver(second, timestamp: 200)
            first.invalidate()
            deliver(second, timestamp: 300)
            var received: [HIDTouchObservation] = []
            for (observation, fence) in pending {
                HIDDeviceMonitor.deliverObservation(
                    observation, fence: fence, touchEventHandler: { _ in XCTFail("Observation mode only") },
                    observationHandler: { received.append($0); XCTAssertFalse($1.isRetired) }
                )
            }
            XCTAssertEqual(received.map(\.sourceID), [second.sourceID, second.sourceID])
            XCTAssertEqual(received.map(\.contactEpoch), [1, 1])
            XCTAssertEqual(received.compactMap(\.event).map(\.kind), [.down])
        }
    }

    func testObservationAndFenceAreSendableWithoutRegistration() {
        onMain {
            var pending: [(HIDTouchObservation, HIDSourceRetirementFence)] = []
            var registration: HIDInputReportRegistration? = makeRegistration { pending.append(($0, $1)) }
            write(registration!, pressed: true)
            deliver(registration!, timestamp: 100)
            let (observation, fence) = pending[0]
            let sourceID = registration!.sourceID
            weak var weakRegistration: HIDInputReportRegistration?
            weakRegistration = registration
            registration = nil
            XCTAssertNil(weakRegistration)
            let completed = DispatchSemaphore(value: 0)
            Thread {
                XCTAssertEqual(observation.sourceID, sourceID)
                XCTAssertTrue(fence.isRetired)
                HIDDeviceMonitor.deliverObservation(
                    observation, fence: fence,
                    touchEventHandler: { _ in XCTFail("Retired across queues") },
                    observationHandler: { _, _ in XCTFail("Retired across queues") }
                )
                completed.signal()
            }.start()
            completed.wait()
        }
    }

    private func makeRegistration(
        receive: @escaping (HIDTouchObservation, HIDSourceRetirementFence) -> Void
    ) -> HIDInputReportRegistration {
        HIDInputReportRegistration(sender: UnsafeMutableRawPointer(bitPattern: 0x1000)!, length: 16,
                                   receiveObservation: receive)
    }

    private func write(_ registration: HIDInputReportRegistration, pressed: Bool, x: UInt8 = 10) {
        for (index, byte) in [UInt8(7), pressed ? 1 : 0, x, 0, 20, 0, 0].enumerated() {
            registration.buffer[index] = byte
        }
    }

    @discardableResult
    private func deliver(_ registration: HIDInputReportRegistration, timestamp: UInt64) -> DispatchTime {
        let receiptTime = DispatchTime(uptimeNanoseconds: timestamp)
        HIDInputReportRegistration.handleCallback(
            context: registration.context, result: kIOReturnSuccess,
            sender: UnsafeMutableRawPointer(bitPattern: 0x1000), type: kIOHIDReportTypeInput,
            reportID: 7, report: registration.buffer, reportLength: 7,
            timestamp: receiptTime
        )
        return receiptTime
    }

    private func onMain(_ action: () -> Void) {
        if Thread.isMainThread { action() }
        else { DispatchQueue.main.sync(execute: action) }
    }
}
