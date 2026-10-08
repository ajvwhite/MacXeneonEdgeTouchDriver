import Foundation

/// Identifies one endpoint registration lifetime, not a physical panel or finger.
/// Values come from the never-reused opaque callback token, not a device address.
public struct HIDSourceID: Hashable, Sendable {
    public let rawValue: UInt
}

/// Immutable result of one validated report, including stationary pressed reports
/// that deliberately have no normalized move event.
public struct HIDTouchObservation: Equatable, Sendable {
    public let sourceID: HIDSourceID
    public let contactEpoch: UInt64
    public let isPressed: Bool
    public let timestamp: DispatchTime
    public let event: TouchEvent?
    public let rawX: Int?
    public let rawY: Int?

    public init(sourceID: HIDSourceID, contactEpoch: UInt64, isPressed: Bool,
                timestamp: DispatchTime, event: TouchEvent?, rawX: Int? = nil, rawY: Int? = nil) {
        self.sourceID = sourceID
        self.contactEpoch = contactEpoch
        self.isPressed = isPressed
        self.timestamp = timestamp
        self.event = event
        self.rawX = rawX
        self.rawY = rawY
    }
}

/// A registration may retire while its immutable reports wait on the event queue.
/// Only this locked fence, never the registration or its parser, crosses queues.
public final class HIDSourceRetirementFence: @unchecked Sendable {
    public let sourceID: HIDSourceID
    private let lock = NSLock()
    private var retired = false

    init(sourceID: HIDSourceID) {
        self.sourceID = sourceID
    }

    public var isRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retired
    }

    func retire() {
        lock.lock()
        retired = true
        lock.unlock()
    }
}
