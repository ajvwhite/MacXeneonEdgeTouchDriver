import Foundation

/// Observations invalidate work; they never establish the current focused window.
enum FocusObservationEvent {
    case focusChanged
    case keyboardFocusChanged
    case lifecycleChanged
}

/// A short lock protects eligibility only. It is never held across a main/AX call.
/// Invalidating this token cannot cancel an AX mutation already in progress.
final class FocusOperationToken {
    private enum Phase { case preparing, targetPreparing, touching, released, restoring, mutatingRestore, invalidated }
    private let lock = NSLock()
    private let now: () -> UInt64
    private let inputPermit: () -> Bool
    private var phase: Phase = .preparing
    private var deadline: UInt64?
    private var focusRevision: UInt64 = 0
    private var certifiedRevision: UInt64?
    private var enrollmentRequested = false
    private var enrollmentStarted = false

    init(preparationMilliseconds: UInt64 = 30, now: @escaping () -> UInt64,
         inputPermit: @escaping () -> Bool = { true }) {
        self.now = now
        self.inputPermit = inputPermit
        deadline = now() &+ preparationMilliseconds * 1_000_000
    }

    var isPermitted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return permittedWhileLocked()
    }

    func invalidate() {
        lock.lock()
        phase = .invalidated
        lock.unlock()
    }

    /// Returns true once per touch to request a coalesced main-queue enrollment.
    @discardableResult func observe(_ event: FocusObservationEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if event == .keyboardFocusChanged && (phase == .touching || phase == .targetPreparing || phase == .released || phase == .mutatingRestore) {
            return false
        }
        if event == .focusChanged && phase == .mutatingRestore {
            // The committed action can change its own app/window focus. Physical
            // input still revokes the permit; final AX/Workspace verification is mandatory.
            return false
        }
        if event == .focusChanged && phase == .targetPreparing {
            focusRevision &+= 1
            certifiedRevision = nil
            return false
        }
        if event == .lifecycleChanged || phase != .touching {
            phase = .invalidated
            return false
        }
        focusRevision &+= 1
        certifiedRevision = nil
        guard !enrollmentRequested else { return false }
        enrollmentRequested = true
        return true
    }

    func beginTouch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .preparing, permittedWhileLocked() else { return false }
        phase = .touching
        deadline = nil
        certifiedRevision = focusRevision
        return true
    }

    func beginTargetActivation() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .touching, permittedWhileLocked(), !enrollmentStarted else { return false }
        phase = .targetPreparing
        deadline = now() &+ 150_000_000
        return true
    }

    func endTargetActivation() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .targetPreparing, permittedWhileLocked() else { return false }
        phase = .touching
        enrollmentRequested = true
        return true
    }

    func beginEnrollment(budgetMilliseconds: UInt64 = 150) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .touching, enrollmentRequested, !enrollmentStarted,
              permittedWhileLocked() else { return nil }
        enrollmentStarted = true
        deadline = now() &+ budgetMilliseconds * 1_000_000
        return focusRevision
    }

    func permitsEnrollment(revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return phase == .touching && enrollmentStarted && focusRevision == revision && permittedWhileLocked()
    }

    func certifyEnrollment(revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .touching, enrollmentStarted, focusRevision == revision,
              permittedWhileLocked() else { return false }
        certifiedRevision = revision
        deadline = nil
        return true
    }

    func beginRestore(budgetMilliseconds: UInt64 = 150) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .released, permittedWhileLocked() else { return false }
        phase = .restoring
        deadline = now() &+ budgetMilliseconds * 1_000_000
        return true
    }

    func beginRestoreMutation() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .restoring, permittedWhileLocked() else { return false }
        phase = .mutatingRestore
        return true
    }

    /// Freeze once at the accepted HID release. Synthetic release and cancellation
    /// may repeat this call, but cannot replace the baseline or revoke a valid freeze.
    @discardableResult func inputDidEnd() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .released, .restoring, .mutatingRestore, .invalidated:
            return false
        case .preparing, .targetPreparing:
            phase = .invalidated
            return false
        case .touching:
            break
        }
        guard certifiedRevision == focusRevision, permittedWhileLocked() else {
            phase = .invalidated
            return false
        }
        phase = .released
        return true
    }

    private func permittedWhileLocked() -> Bool {
        guard phase != .invalidated else { return false }
        guard inputPermit() else { phase = .invalidated; return false }
        if let deadline, now() >= deadline {
            phase = .invalidated
            return false
        }
        return true
    }
}

/// Tracks the actual pipeline, not just its deadline. A timed-out job retains its slot
/// until its main/AX stages and cleanup really return, so requests cannot build a queue.
final class FocusOperationState {
    private let lock = NSLock()
    private var stopped = false
    private var occupied = false
    private var currentToken: FocusOperationToken?

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func beginPreparation(token: FocusOperationToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        currentToken?.invalidate()
        currentToken = nil
        guard !stopped, !occupied else { return false }
        occupied = true
        currentToken = token
        return true
    }

    func beginRestoration(token: FocusOperationToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, !occupied, currentToken === token, token.beginRestore() else { return false }
        occupied = true
        return true
    }

    func beginEnrollment(token: FocusOperationToken) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, !occupied, currentToken === token,
              let revision = token.beginEnrollment() else { return nil }
        occupied = true
        return revision
    }

    func invalidate(shutdown: Bool = false) {
        lock.lock()
        if shutdown { stopped = true }
        currentToken?.invalidate()
        lock.unlock()
    }

    func observe(_ event: FocusObservationEvent) {
        lock.lock()
        currentToken?.observe(event)
        lock.unlock()
    }

    @discardableResult func inputDidEnd() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentToken?.inputDidEnd() ?? false
    }

    /// Reserve the otherwise-idle worker to remove an invalidated capture's observers.
    func beginCleanup() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !occupied else { return false }
        occupied = true
        return true
    }

    func finishOperation() {
        lock.lock()
        occupied = false
        lock.unlock()
    }
}
