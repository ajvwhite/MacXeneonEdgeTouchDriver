import AppKit
import CoreGraphics
import Foundation

/// Preparation is separate from restoration: focus-off still needs a first click
/// to reach an inactive view. The gesture queue owns prepare/cancel and completion.
protocol TouchTargetPreparing: AnyObject {
    var requiresPreparation: Bool { get }
    var preparedTargetProcessIdentifier: pid_t? { get }
    var preparedTargetIsPassive: Bool { get }
    var preparedTargetIdentity: TouchTargetIdentity? { get }
    func beginContact()
    func prepare(at point: CGPoint, completion: @escaping (Bool) -> Void)
    func cancel()
}

extension TouchTargetPreparing {
    func beginContact() {}
    var preparedTargetProcessIdentifier: pid_t? { nil }
    var preparedTargetIsPassive: Bool { false }
    var preparedTargetIdentity: TouchTargetIdentity? { nil }
}

final class NoOpTouchTargetPreparer: TouchTargetPreparing {
    let requiresPreparation = false
    func prepare(at point: CGPoint, completion: @escaping (Bool) -> Void) { completion(true) }
    func cancel() {}
}

protocol TouchTargetApplication: AnyObject {
    var isActive: Bool { get }
    var isTerminated: Bool { get }
    var isHidden: Bool { get }
    func activate() -> Bool
}

private final class SystemTouchTargetApplication: TouchTargetApplication {
    private let application: NSRunningApplication
    init?(_ pid: pid_t) {
        guard let application = NSRunningApplication(processIdentifier: pid) else { return nil }
        self.application = application
    }
    var isActive: Bool { application.isActive }
    var isTerminated: Bool { application.isTerminated }
    var isHidden: Bool { application.isHidden }
    func activate() -> Bool { application.activate(options: [.activateIgnoringOtherApps]) }
}

/// No synthetic activation click is emitted. Resolve the control under the mapped
/// point, activate its exact window, and confirm it before the one real down.
/// Main owns application access; the serial worker owns all AX IPC. Cancellation
/// invalidates queued stages but retains the occupied slot until they finish.
final class AXTouchTargetPreparer: TouchTargetPreparing {
    typealias Enqueue = (@escaping () -> Void) -> Void
    let requiresPreparation = true
    private let backend: AXTouchTargetResolving
    private let onWorker: Enqueue
    private let onMain: Enqueue
    private let onCallback: Enqueue
    private let retryOnMain: Enqueue
    private let now: () -> UInt64
    private let application: (pid_t) -> TouchTargetApplication?
    private let captureInputPermit: () -> PhysicalInputGuard.Permit
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var busy = false
    private var contactInputPermit: PhysicalInputGuard.Permit?
    private var preparedPID: pid_t?
    private var preparedPassive = false
    private var preparedIdentity: TouchTargetIdentity?
    var preparedTargetIdentity: TouchTargetIdentity? {
        lock.lock(); defer { lock.unlock() }; return preparedIdentity
    }
    var preparedTargetIsPassive: Bool {
        lock.lock(); defer { lock.unlock() }; return preparedPassive
    }
    var preparedTargetProcessIdentifier: pid_t? {
        lock.lock(); defer { lock.unlock() }; return preparedPID
    }

    convenience init(callbackQueue: DispatchQueue) {
        let worker = DispatchQueue(label: "\(DriverLoggers.subsystem).touch-target-ax")
        self.init(backend: AXTouchTargetBackend(timeout: 0.05),
                  onWorker: { worker.async(execute: DispatchWorkItem(block: $0)) },
                  onMain: { DispatchQueue.main.async(execute: DispatchWorkItem(block: $0)) },
                  onCallback: { callbackQueue.async(execute: DispatchWorkItem(block: $0)) },
                  retryOnMain: { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5), execute: DispatchWorkItem(block: $0)) },
                  now: { DispatchTime.now().uptimeNanoseconds },
                  application: { SystemTouchTargetApplication($0) },
                  captureInputPermit: { PhysicalInputGuard.system.capture() })
    }

    /// Executors enqueue asynchronously on their designated serial queues; the
    /// retry executor uses main after a bounded delay. The clock is thread-safe.
    init(backend: AXTouchTargetResolving, onWorker: @escaping Enqueue,
         onMain: @escaping Enqueue, onCallback: @escaping Enqueue,
         retryOnMain: @escaping Enqueue, now: @escaping () -> UInt64,
         application: @escaping (pid_t) -> TouchTargetApplication?,
         captureInputPermit: @escaping () -> PhysicalInputGuard.Permit = { { true } }) {
        self.backend = backend; self.onWorker = onWorker; self.onMain = onMain
        self.onCallback = onCallback; self.retryOnMain = retryOnMain
        self.now = now; self.application = application
        self.captureInputPermit = captureInputPermit
    }

    func beginContact() {
        let permit = captureInputPermit()
        lock.lock(); generation &+= 1; preparedPID = nil; preparedPassive = false; preparedIdentity = nil; contactInputPermit = permit; lock.unlock()
    }

    func cancel() { lock.lock(); generation &+= 1; preparedPID = nil; preparedPassive = false; preparedIdentity = nil; contactInputPermit = nil; lock.unlock() }

    func prepare(at point: CGPoint, completion: @escaping (Bool) -> Void) {
        lock.lock()
        generation &+= 1
        let current = generation
        guard !busy else { lock.unlock(); completion(false); return }
        busy = true
        let priorPermit = contactInputPermit
        contactInputPermit = nil
        lock.unlock()
        let inputPermit = priorPermit ?? captureInputPermit()
        let permit = { [weak self] in self?.isCurrent(current) == true && inputPermit() }
        onWorker {
            guard permit(), let target = self.backend.resolve(at: point, permit: permit) else {
                self.finish(current, accepted: false, inputPermit: inputPermit, completion: completion); return
            }
            self.lock.lock()
            if self.generation == current {
                self.preparedPID = target.pid
                self.preparedPassive = !target.requiresActivation
                self.preparedIdentity = TouchTargetIdentity(pid: target.pid,
                    application: target.application.rawValue, window: target.window.rawValue)
            }
            self.lock.unlock()
            self.onMain {
                guard permit(), let application = self.application(target.pid),
                      !application.isTerminated, !application.isHidden else {
                    self.finish(current, accepted: false, inputPermit: inputPermit, completion: completion); return
                }
                if !target.requiresActivation {
                    self.onWorker {
                        guard permit(), self.backend.focusWindow(target, at: point, permit: permit) else {
                            self.finish(current, accepted: false, inputPermit: inputPermit, completion: completion); return
                        }
                        self.onMain {
                            let available = !application.isTerminated && !application.isHidden
                            self.finish(current, accepted: available && permit(), inputPermit: inputPermit, completion: completion)
                        }
                    }
                    return
                }
                let activated = application.isActive || application.activate()
                guard activated, permit() else {
                    self.finish(current, accepted: false, inputPermit: inputPermit, completion: completion); return
                }
                self.awaitActivation(application, deadline: self.now() + 80_000_000,
                                     permit: permit) { active in
                    guard active else { self.finish(current, accepted: false, inputPermit: inputPermit, completion: completion); return }
                    self.onWorker {
                        guard permit(), self.backend.focusWindow(target, at: point, permit: permit) else {
                            self.finish(current, accepted: false, inputPermit: inputPermit, completion: completion); return
                        }
                        self.onMain {
                            let active = !application.isTerminated && !application.isHidden && application.isActive
                            self.finish(current, accepted: active && permit(), inputPermit: inputPermit, completion: completion)
                        }
                    }
                }
            }
        }
    }

    /// A successful request is not proof of activation. Sample actual state on
    /// main under a deadline; no worker or gesture queue waits.
    private func awaitActivation(_ application: TouchTargetApplication, deadline: UInt64,
                                 permit: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        guard permit(), !application.isTerminated, !application.isHidden else { completion(false); return }
        guard now() < deadline else { completion(false); return }
        if application.isActive { completion(true); return }
        retryOnMain {
            self.awaitActivation(application, deadline: deadline, permit: permit, completion: completion)
        }
    }

    private func isCurrent(_ expected: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == expected
    }

    private func finish(_ expected: UInt64, accepted: Bool, inputPermit: @escaping PhysicalInputGuard.Permit, completion: @escaping (Bool) -> Void) {
        lock.lock(); busy = false; lock.unlock()
        onCallback {
            guard self.isCurrent(expected) else { return }
            let confirmed = accepted && inputPermit()
            if !confirmed {
                self.lock.lock(); self.preparedIdentity = nil; self.lock.unlock()
            }
            if !confirmed { DriverLoggers.log(.warning, category: .focus, "Touch target activation could not be confirmed; contact rejected.") }
            completion(confirmed)
        }
    }
}
