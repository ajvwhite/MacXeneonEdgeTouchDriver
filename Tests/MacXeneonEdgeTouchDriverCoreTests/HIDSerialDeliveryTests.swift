import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class HIDSerialDeliveryTests: XCTestCase {
    func testConstructionAndEnqueueNeverInvokeInline() {
        let queue = DispatchQueue(label: "hid-delivery.async")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let recorder = HIDDeliveryRecorder<Int>()
        let delivery = HIDSerialDelivery<Int>(queue: queue) { value in
            dispatchPrecondition(condition: .onQueue(queue))
            recorder.append(value)
        }
        XCTAssertEqual(recorder.snapshot(), [])
        delivery.enqueue(1)
        delivery.enqueue(2)
        XCTAssertEqual(recorder.snapshot(), [], "A blocked target queue must prevent callback invocation")
        gate.signal()
        queue.sync {}
        XCTAssertEqual(recorder.snapshot(), [1, 2])
    }

    func testEnqueueFromTargetQueueStillDefersUntilCurrentOperationEnds() {
        let queue = DispatchQueue(label: "hid-delivery.reentrant-enqueue")
        let recorder = HIDDeliveryRecorder<Int>()
        let delivery = HIDSerialDelivery<Int>(queue: queue) { value in
            recorder.append(value)
        }
        queue.sync {
            delivery.enqueue(2)
            recorder.append(1)
            XCTAssertEqual(recorder.snapshot(), [1])
        }
        queue.sync {}
        XCTAssertEqual(recorder.snapshot(), [1, 2])
    }

    func testObservationAndRemovalOwnersPreserveSharedQueueOrder() {
        let queue = DispatchQueue(label: "hid-delivery.source-order")
        let recorder = HIDDeliveryRecorder<String>()
        let sources = [HIDSourceID(rawValue: 11), HIDSourceID(rawValue: 22)]
        let observations = HIDSerialDelivery<HIDObservationDeliveryPayload>(queue: queue) { payload in
            HIDDeviceMonitor.deliverObservation(
                payload.observation, fence: payload.fence,
                touchEventHandler: { _ in XCTFail("Observation delivery must not emit a second event") },
                observationHandler: { observation, _ in
                    dispatchPrecondition(condition: .onQueue(queue))
                    recorder.append("observation:\(observation.sourceID.rawValue):\(observation.contactEpoch)")
                }
            )
        }
        let removals = HIDSerialDelivery<[HIDSourceID]>(queue: queue) { sourceIDs in
            dispatchPrecondition(condition: .onQueue(queue))
            sourceIDs.forEach { recorder.append("removal:\($0.rawValue)") }
        }
        observations.enqueue(payload(sourceID: sources[0], epoch: 1))
        removals.enqueue([sources[0]])
        observations.enqueue(payload(sourceID: sources[1], epoch: 2))
        removals.enqueue([sources[1], sources[0]])
        queue.sync {}
        XCTAssertEqual(recorder.snapshot(), [
            "observation:11:1", "removal:11", "observation:22:2", "removal:22", "removal:11"
        ])
    }

    func testRetirementBeforeQueuedInvocationDropsObservationButKeepsRemoval() {
        let queue = DispatchQueue(label: "hid-delivery.retirement")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let recorder = HIDDeliveryRecorder<String>()
        let sourceID = HIDSourceID(rawValue: 33)
        let pending = payload(sourceID: sourceID, epoch: 1)
        let observations = HIDSerialDelivery<HIDObservationDeliveryPayload>(queue: queue) { value in
            HIDDeviceMonitor.deliverObservation(
                value.observation, fence: value.fence,
                touchEventHandler: { _ in recorder.append("unexpected event") },
                observationHandler: { _, _ in recorder.append("unexpected observation") }
            )
        }
        let removals = HIDSerialDelivery<[HIDSourceID]>(queue: queue) { sourceIDs in
            sourceIDs.forEach { recorder.append("removal:\($0.rawValue)") }
        }
        observations.enqueue(pending)
        pending.fence.retire()
        removals.enqueue([sourceID])
        gate.signal()
        queue.sync {}
        XCTAssertEqual(recorder.snapshot(), ["removal:33"])
    }

    func testValuePayloadAndLockedFenceAreTheOnlyQueuedObservationState() {
        let queue = DispatchQueue(label: "hid-delivery.payload-values")
        let recorder = HIDDeliveryRecorder<HIDTouchObservation>()
        let pending = payload(sourceID: HIDSourceID(rawValue: 44), epoch: 7)
        let delivery = HIDSerialDelivery<HIDObservationDeliveryPayload>(queue: queue) { value in
            dispatchPrecondition(condition: .onQueue(queue))
            HIDDeviceMonitor.deliverObservation(
                value.observation, fence: value.fence,
                touchEventHandler: { _ in XCTFail("Observation mode must remain atomic") },
                observationHandler: { observation, fence in
                    XCTAssertEqual(fence.sourceID, observation.sourceID)
                    recorder.append(observation)
                }
            )
        }
        delivery.enqueue(pending)
        queue.sync {}
        XCTAssertEqual(recorder.snapshot(), [pending.observation])
    }

    private func payload(sourceID: HIDSourceID, epoch: UInt64) -> HIDObservationDeliveryPayload {
        HIDObservationDeliveryPayload(
            observation: HIDTouchObservation(
                sourceID: sourceID, contactEpoch: epoch, isPressed: true,
                timestamp: DispatchTime(uptimeNanoseconds: 1_000), event: nil
            ),
            fence: HIDSourceRetirementFence(sourceID: sourceID)
        )
    }
}

/// Only the test's recorded value array crosses the test/dispatch-queue boundary.
/// Every read and write is locked; no fixture or arbitrary callback is wrapped.
private final class HIDDeliveryRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
