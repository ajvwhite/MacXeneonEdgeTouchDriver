import Foundation
import IOKit
import IOKit.hid

/// Owns one input buffer and validates the callback before reading that buffer.
/// Registration, delivery, and retirement all run on the main HID run loop.
final class HIDInputReportRegistration {
    private final class WeakRegistration {
        weak var value: HIDInputReportRegistration?

        init(_ value: HIDInputReportRegistration) {
            self.value = value
        }
    }

    /// The only shared container is Sendable: its counter and weak-entry map are
    /// protected by the lock on every access. Registrations, their buffers and
    /// receivers are not Sendable and remain confined to the main HID run loop.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var nextToken: UInt = 0
        private var registrations: [UInt: WeakRegistration] = [:]

        func allocateToken() -> UInt {
            lock.lock()
            defer { lock.unlock() }
            precondition(nextToken < UInt.max, "HID callback tokens exhausted.")
            nextToken += 1
            return nextToken
        }

        func insert(_ registration: HIDInputReportRegistration, for token: UInt) {
            precondition(Thread.isMainThread, "HID registrations must use the main thread.")
            let entry = WeakRegistration(registration)
            lock.lock()
            registrations[token] = entry
            lock.unlock()
        }

        func remove(_ token: UInt) {
            lock.lock()
            registrations.removeValue(forKey: token)
            lock.unlock()
        }

        func registration(for token: UInt) -> HIDInputReportRegistration? {
            precondition(Thread.isMainThread, "HID registrations must use the main thread.")
            lock.lock()
            let registration = registrations[token]?.value
            lock.unlock()
            // Promote the weak entry under the lock, then return the strong
            // reference. Report copying, receivers and IOKit run after unlock.
            return registration
        }
    }

    // Context is an opaque, never-dereferenced token, not an object address.
    // Never reuse a token, even after a buffer or device address is reused.
    private static let registry = Registry()

    let buffer: UnsafeMutablePointer<UInt8>
    let length: CFIndex
    let context: UnsafeMutableRawPointer
    let sourceID: HIDSourceID
    let retirementFence: HIDSourceRetirementFence

    private let parser = HIDValueParser()
    private var neutralState: HIDNeutralState?
    private(set) var hasParsedPressedReport = false
    private let receiveObservation: (HIDTouchObservation, HIDSourceRetirementFence) -> Void
    private let token: UInt
    private let sender: UnsafeMutableRawPointer
    private let receive: (UInt32, [UInt8], DispatchTime) -> Void

    init(
        sender: UnsafeMutableRawPointer,
        length: Int,
        receiveObservation: @escaping (HIDTouchObservation, HIDSourceRetirementFence) -> Void = { _, _ in },
        receive: @escaping (UInt32, [UInt8], DispatchTime) -> Void = { _, _, _ in }
    ) {
        precondition(Thread.isMainThread, "HID registrations must use the main thread.")
        precondition(length >= XeneonEdgeDevice.touchReportLength)
        let token = Self.registry.allocateToken()
        let sourceID = HIDSourceID(rawValue: token)
        self.sourceID = sourceID
        self.retirementFence = HIDSourceRetirementFence(sourceID: sourceID)
        self.receiveObservation = receiveObservation
        self.token = token
        self.context = UnsafeMutableRawPointer(bitPattern: token)!
        self.sender = sender
        self.length = CFIndex(length)
        self.receive = receive
        self.buffer = .allocate(capacity: length)
        self.buffer.initialize(repeating: 0, count: length)
        Self.registry.insert(self, for: token)
    }

    deinit {
        invalidate()
        buffer.deinitialize(count: Int(length))
        buffer.deallocate()
    }

    /// Reject late callbacks before the caller unschedules/unregisters the device.
    func invalidate() {
        precondition(Thread.isMainThread, "HID registrations must use the main thread.")
        // Fence queued observations before unregistering ingress or scheduling
        // a removal notification. The fence outlives this main-only object.
        retirementFence.retire()
        Self.registry.remove(token)
    }

    /// A cache certificate may precede queued older raw packets. It is installed
    /// only before this registration has admitted a pressed report.
    @discardableResult
    func installNeutralState(_ state: HIDNeutralState) -> Bool {
        precondition(Thread.isMainThread)
        guard !retirementFence.isRetired, !hasParsedPressedReport,
              state.reportTimestamp > 0 else { return false }
        neutralState = state
        return true
    }

    /// The production C callback and deterministic tests share this exact ingress.
    static func handleCallback(
        context: UnsafeMutableRawPointer?,
        result: IOReturn,
        sender: UnsafeMutableRawPointer?,
        type: IOHIDReportType,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex,
        timestamp: DispatchTime = .now(),
        providerTimestamp: UInt64? = nil
    ) {
        // The manager is scheduled only on the main run loop. Do not access the
        // registry or parser if a callback unexpectedly arrives elsewhere.
        guard Thread.isMainThread,
              result == kIOReturnSuccess,
              type == kIOHIDReportTypeInput,
              reportID == UInt32(XeneonEdgeDevice.touchReportID),
              reportLength >= XeneonEdgeDevice.touchReportLength,
              let context,
              let registration = registry.registration(for: UInt(bitPattern: context)),
              sender == registration.sender,
              report == registration.buffer,
              reportLength <= registration.length else {
            return
        }

        if let neutral = registration.neutralState {
            guard let providerTimestamp else { return }
            if providerTimestamp == 0 {
                // Old IOKit providers may omit timestamps. Never infer ordering
                // for a held packet; an explicit raw release restores that path.
                guard registration.buffer[1] == 0 else { return }
                registration.neutralState = nil
            } else {
                guard providerTimestamp > neutral.reportTimestamp else { return }
            }
        }

        // Both the pointer and its bound now refer to a live owned allocation.
        // The local strong reference keeps it alive through copying and delivery.
        let bytes = Array(UnsafeBufferPointer(start: registration.buffer, count: Int(reportLength)))
        withExtendedLifetime(registration) {
            guard let observation = registration.parser.parseObservation(
                sourceID: registration.sourceID, reportID: Int(reportID),
                bytes: bytes, timestamp: timestamp
            ) else { return }
            if observation.isPressed { registration.hasParsedPressedReport = true }
            registration.receiveObservation(observation, registration.retirementFence)
            registration.receive(reportID, bytes, timestamp)
        }
    }
}
