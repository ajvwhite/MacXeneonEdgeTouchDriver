import Foundation

/// Manager callbacks use a never-reused token rather than a monitor address.
/// Resolution and all monitor access are restricted to the main HID run loop.
final class HIDManagerCallbackRegistration {
    private final class WeakMonitor {
        weak var value: HIDDeviceMonitor?
        init(_ value: HIDDeviceMonitor) { self.value = value }
    }

    /// Only the token counter and weak map cross threads, always under this lock.
    /// Weak promotion is allowed only on main; no monitor method runs locked.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var nextToken: UInt = 0
        private var entries: [UInt: WeakMonitor] = [:]

        func insert(_ monitor: HIDDeviceMonitor) -> UInt {
            precondition(Thread.isMainThread, "HID registrations must use the main thread.")
            lock.lock()
            defer { lock.unlock() }
            precondition(nextToken < UInt.max, "HID manager callback tokens exhausted.")
            nextToken += 1
            entries[nextToken] = WeakMonitor(monitor)
            return nextToken
        }

        func remove(_ token: UInt) {
            lock.lock()
            entries.removeValue(forKey: token)
            lock.unlock()
        }

        func monitor(for token: UInt) -> HIDDeviceMonitor? {
            precondition(Thread.isMainThread, "HID callbacks must use the main run loop.")
            lock.lock()
            let monitor = entries[token]?.value
            lock.unlock()
            return monitor
        }
    }

    private static let registry = Registry()
    private let token: UInt
    let context: UnsafeMutableRawPointer

    init(monitor: HIDDeviceMonitor) {
        token = Self.registry.insert(monitor)
        context = UnsafeMutableRawPointer(bitPattern: token)!
    }

    deinit { invalidate() }

    func invalidate() { Self.registry.remove(token) }

    static func monitor(for context: UnsafeMutableRawPointer?) -> HIDDeviceMonitor? {
        guard Thread.isMainThread, let context else { return nil }
        return registry.monitor(for: UInt(bitPattern: context))
    }
}
