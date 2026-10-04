import Foundation
import IOKit

/// A main-run-loop callback context whose address is never dereferenced.
/// Tokens are never reused, including after an owner or its buffer is released.
public final class HIDDumpCallbackContext {
    private final class WeakOwner {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    /// Only this small container is Sendable. Every counter/map access is locked;
    /// weak owners are inserted and promoted only on the main HID run loop.
    /// Owners, buffers and receivers are not Sendable.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var nextToken: UInt = 0
        private var owners: [UInt: WeakOwner] = [:]

        func insert(_ owner: AnyObject) -> UInt {
            precondition(Thread.isMainThread, "HIDDump callbacks must use the main thread.")
            lock.lock()
            defer { lock.unlock() }
            precondition(nextToken < UInt.max, "HIDDump callback tokens exhausted.")
            nextToken += 1
            owners[nextToken] = WeakOwner(owner)
            return nextToken
        }

        func remove(_ token: UInt) {
            lock.lock()
            owners.removeValue(forKey: token)
            lock.unlock()
        }

        func owner(for token: UInt) -> AnyObject? {
            precondition(Thread.isMainThread, "HIDDump callbacks must use the main thread.")
            lock.lock()
            let owner = owners[token]?.value
            lock.unlock()
            // The promoted owner is strong; no receiver or IOKit call runs locked.
            return owner
        }
    }

    private static let registry = Registry()
    private let token: UInt
    public let context: UnsafeMutableRawPointer

    public init(owner: AnyObject) {
        token = Self.registry.insert(owner)
        context = UnsafeMutableRawPointer(bitPattern: token)!
    }

    deinit { invalidate() }

    public func invalidate() { Self.registry.remove(token) }

    public static func owner<Owner: AnyObject>(
        for context: UnsafeMutableRawPointer?,
        result: IOReturn,
        as type: Owner.Type
    ) -> Owner? {
        guard Thread.isMainThread, result == kIOReturnSuccess, let context else { return nil }
        return registry.owner(for: UInt(bitPattern: context)) as? Owner
    }
}
