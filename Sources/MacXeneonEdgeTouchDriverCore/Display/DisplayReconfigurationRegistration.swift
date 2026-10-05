import CoreGraphics
import Foundation

/// Owns CoreGraphics registration on main. Callback ingress may arrive on any
/// thread, but only records the mapper gate and enqueues a gesture decision.
/// The opaque context never addresses an application or an allocation.
final class DisplayReconfigurationRegistration {
    struct Operations {
        let register: (CGDisplayReconfigurationCallBack, UnsafeMutableRawPointer) -> CGError
        let remove: (CGDisplayReconfigurationCallBack, UnsafeMutableRawPointer) -> CGError

        static var live: Operations {
            Operations(register: { CGDisplayRegisterReconfigurationCallback($0, $1) },
                       remove: { CGDisplayRemoveReconfigurationCallback($0, $1) })
        }
    }

    /// A callback can temporarily become this object's final owner on any thread.
    /// Keep platform operations and client-provided captures in the main-owned
    /// registration, not in this lock-protected ingress carrier.
    private final class Ingress {
        private weak var application: MacXeneonEdgeTouchDriverApplication?
        private let lock = NSLock()
        private var acceptsCallbacks = true

        init(application: MacXeneonEdgeTouchDriverApplication) { self.application = application }

        func invalidate() {
            lock.lock()
            acceptsCallbacks = false
            lock.unlock()
        }

        func deliver(flags: CGDisplayChangeSummaryFlags) {
            lock.lock()
            let target = acceptsCallbacks ? application : nil
            // Only the mapper gate and queue submission occur here. Display
            // resolution and all client work happen later, outside these locks.
            target?.enqueueDisplayReconfiguration(flags: flags)
            lock.unlock()
            // Even a never-run test application's final release must occur after
            // unlocking, since its injected dependency teardown is client code.
            withExtendedLifetime(target) {}
        }
    }

    private final class WeakIngress {
        weak var value: Ingress?
        init(_ value: Ingress) { self.value = value }
    }

    /// Only this container is Sendable. The counter/map are always locked;
    /// promotion produces a strong ingress owner before unlocking. The only
    /// cross-thread operation on that owner is deliver(), guarded by its own
    /// admission lock. Neither arbitrary client closures nor application state
    /// are executed under this registry lock.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var nextToken: UInt = 0
        private var entries: [UInt: WeakIngress] = [:]

        func allocateToken() -> UInt {
            lock.lock()
            defer { lock.unlock() }
            precondition(nextToken < UInt.max, "Display callback tokens exhausted.")
            nextToken += 1
            return nextToken
        }

        func insert(_ ingress: Ingress, token: UInt) {
            lock.lock()
            entries[token] = WeakIngress(ingress)
            lock.unlock()
        }

        func remove(_ token: UInt) {
            lock.lock()
            entries.removeValue(forKey: token)
            lock.unlock()
        }

        func ingress(for token: UInt) -> Ingress? {
            lock.lock()
            let ingress = entries[token]?.value
            lock.unlock()
            return ingress
        }
    }

    private static let registry = Registry()
    private let operations: Operations
    private let token: UInt
    let context: UnsafeMutableRawPointer
    private let ingress: Ingress
    // Accessed by main-thread start/stop only. This registration cannot restart.
    private enum State: Equatable { case idle, registering, registered, stopped }
    private var state = State.idle

    init(application: MacXeneonEdgeTouchDriverApplication, operations: Operations = .live) {
        precondition(Thread.isMainThread, "Display registration must use the main thread.")
        let token = Self.registry.allocateToken()
        self.token = token
        self.context = UnsafeMutableRawPointer(bitPattern: token)!
        self.ingress = Ingress(application: application)
        self.operations = operations
        Self.registry.insert(ingress, token: token)
    }

    deinit {
        // The application explicitly stops this owner while run() is alive.
        // Do not call platform removal or client code from an arbitrary final
        // release. Even a failed removal retains no application/context pointer.
        invalidate()
    }

    func start() {
        precondition(Thread.isMainThread, "Display registration must use the main thread.")
        guard state == .idle else { return }
        state = .registering
        let result = operations.register(displayReconfigurationCallback, context)
        if result == .success {
            if state == .stopped {
                // A reentrant stop cannot remove an acquisition until register
                // returns; finish that removal exactly once after unwinding.
                removeCallback()
            } else {
                state = .registered
            }
        } else {
            state = .stopped
            invalidate()
            DriverLoggers.log(.error, category: .display, "CGDisplayRegisterReconfigurationCallback failed with \(result.rawValue).")
        }
    }

    func stop() {
        precondition(Thread.isMainThread, "Display registration must use the main thread.")
        // Wait only for short ingress, never for gesture work. Everything admitted
        // before this lock was acquired is enqueued before the caller's drain.
        invalidate()
        let previous = state
        state = .stopped
        guard previous == .registered else { return }
        removeCallback()
    }

    private func removeCallback() {
        let result = operations.remove(displayReconfigurationCallback, context)
        if result != .success {
            DriverLoggers.log(.error, category: .display, "CGDisplayRemoveReconfigurationCallback failed with \(result.rawValue).")
        }
    }

    private func invalidate() {
        ingress.invalidate()
        Self.registry.remove(token)
    }

    /// Production callback and deterministic tests use exactly the same lookup.
    static func handleCallback(context: UnsafeMutableRawPointer?, flags: CGDisplayChangeSummaryFlags) {
        prepareCallback(context: context, flags: flags)?()
    }

    /// Separates lookup from ingress for deterministic selected-before-stop tests.
    /// The returned callback owns only the ingress carrier, never Operations.
    static func prepareCallback(context: UnsafeMutableRawPointer?, flags: CGDisplayChangeSummaryFlags) -> (() -> Void)? {
        guard let context,
              let ingress = registry.ingress(for: UInt(bitPattern: context)) else { return nil }
        return { ingress.deliver(flags: flags) }
    }
}

private func displayReconfigurationCallback(
    _ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
    _ context: UnsafeMutableRawPointer?
) {
    DisplayReconfigurationRegistration.handleCallback(context: context, flags: flags)
}
