import Foundation

/// Owns a callback whose captured mutable state belongs to one serial queue.
///
/// The caller must supply the same serial queue that owns all accesses to the
/// handler's captured state. HIDDeviceMonitor already requires this contract;
/// production supplies the application's serial gesture queue. Construction only
/// stores the callback. The sole delivery entry point enqueues Sendable values,
/// and the private invocation checks the queue before accessing the callback.
///
/// This narrow unchecked conformance covers immutable storage plus serialized
/// callback access. It does not make the callback's captures, monitor, parser or
/// registration generally Sendable. The submitting caller cannot invoke the
/// handler inline; delivery runs only on the designated queue, which production
/// configures as its non-main serial gesture queue.
final class HIDSerialDelivery<Payload: Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let handler: (Payload) -> Void

    init(queue: DispatchQueue, handler: @escaping (Payload) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    func enqueue(_ payload: Payload) {
        queue.async { [self, payload] in
            invoke(payload)
        }
    }

    private func invoke(_ payload: Payload) {
        dispatchPrecondition(condition: .onQueue(queue))
        handler(payload)
    }
}

/// The only observation state submitted to queue-confined delivery. Neither the
/// report buffer nor its main-run-loop registration/parser can enter this value.
struct HIDObservationDeliveryPayload: Sendable {
    let observation: HIDTouchObservation
    let fence: HIDSourceRetirementFence
}
