import CoreFoundation
import Foundation

/// Best-effort focus transactions. Main owns Workspace and observer run-loop sources;
/// a single worker owns AX. Neither queue waits synchronously for the other.
public final class AXFocusRestorer: FocusRestorer {
    typealias Enqueue = (@escaping () -> Void) -> Void

    private final class Session {
        let token: FocusOperationToken
        var captured: AXFocusTarget?
        // Successive pipeline stages own these; callbacks touch the token only.
        var observations: [AXFocusObservationProtocol] = []
        var attachedSources: [CFRunLoopSource] = []

        init(token: FocusOperationToken) { self.token = token }
    }

    private let backend: AXFocusBackendProtocol
    private let workspace: WorkspaceFocusMonitoring
    private let onMain: Enqueue
    private let onWorker: Enqueue
    private var onCallback: Enqueue
    private let now: () -> UInt64
    private let state = FocusOperationState()
    private let sessionLock = NSLock()
    private var session: Session?
    private var hasStarted = false

    /// Callback delivery belongs to the caller's serial gesture queue.
    public convenience init(callbackQueue: DispatchQueue = .main) {
        let worker = DispatchQueue(label: "\(DriverLoggers.subsystem).focus-ax")
        self.init(
            backend: AXFocusBackend(), workspace: WorkspaceFocusMonitor(),
            onMain: { DispatchQueue.main.async(execute: $0) },
            onWorker: { worker.async(execute: $0) },
            onCallback: { callbackQueue.async(execute: $0) },
            now: { DispatchTime.now().uptimeNanoseconds }
        )
    }

    init(backend: AXFocusBackendProtocol, workspace: WorkspaceFocusMonitoring,
         onMain: @escaping Enqueue, onWorker: @escaping Enqueue,
         onCallback: @escaping Enqueue, now: @escaping () -> UInt64) {
        self.backend = backend
        self.workspace = workspace
        self.onMain = onMain
        self.onWorker = onWorker
        self.onCallback = onCallback
        self.now = now
    }

    deinit {
        state.invalidate(shutdown: true)
        let remaining = session
        let monitor = workspace
        let worker = onWorker
        onMain {
            monitor.stop()
            guard let remaining else { return }
            remaining.attachedSources.forEach { CFRunLoopRemoveSource(CFRunLoopGetMain(), $0, .commonModes) }
            remaining.attachedSources.removeAll()
            worker {
                remaining.observations.forEach { $0.invalidate() }
                remaining.observations.removeAll()
            }
        }
    }

    public func captureFocusedWindow() {
        // A caller of the legacy synchronous entry point can post input as soon as
        // it returns. Async capture here could therefore capture post-input focus.
        discardCapturedWindow()
        log("Focus capture requires the preparation completion boundary; legacy capture skipped.")
    }

    public func prepareFocusedWindow(completion: @escaping () -> Void) {
        let next = Session(token: FocusOperationToken(now: now))
        sessionLock.lock()
        hasStarted = true
        let previous = session
        let admitted = state.beginPreparation(token: next.token)
        session = admitted ? next : nil
        sessionLock.unlock()

        guard admitted else {
            // A timed-out operation still occupies the worker until it actually returns.
            deliverPreparation(completion)
            return
        }
        if let previous {
            dispose(previous, finishOperation: false) { self.startPreparation(next, completion: completion) }
        } else {
            startPreparation(next, completion: completion)
        }
    }

    /// Application construction may bind an injected live restorer before it starts.
    func bindCallbackQueue(_ queue: DispatchQueue) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        precondition(!hasStarted, "Bind the focus callback queue before preparing a gesture")
        onCallback = { queue.async(execute: $0) }
    }

    public func inputDidEnd() { state.inputDidEnd() }

    public func restoreCapturedWindow() {
        sessionLock.lock()
        let current = session
        let admitted = current.map { state.beginRestoration(token: $0.token) } ?? false
        sessionLock.unlock()
        guard admitted, let current, let captured = current.captured else {
            discardCapturedWindow()
            return
        }

        onMain {
            guard current.token.isPermitted else { self.finish(current); return }
            let baselineWorkspace = self.workspace.snapshot()
            guard baselineWorkspace.sessionActive else { self.finish(current); return }
            self.onWorker {
                guard current.token.isPermitted else { self.finish(current); return }
                let resolution = self.backend.resolve(workspace: baselineWorkspace.application,
                                                       permit: { current.token.isPermitted })
                guard case let .known(baseline) = resolution else {
                    self.logUnknown(resolution, context: "Post-release focus baseline unavailable")
                    self.finish(current)
                    return
                }
                if self.backend.relationship(captured, baseline) == .same {
                    self.log("Captured window is already focused; no mutation needed.")
                    self.finish(current)
                    return
                }
                guard let observation = self.backend.prepareObservation(
                    target: baseline, permit: { current.token.isPermitted },
                    onChange: { [token = current.token] in token.observe($0) }) else {
                    self.log("Focus restoration skipped because baseline observation is unavailable.")
                    self.finish(current)
                    return
                }
                current.observations.append(observation)
                self.onMain {
                    guard current.token.isPermitted else { self.finish(current); return }
                    self.attachSources(current)
                    let refreshedWorkspace = self.workspace.snapshot()
                    let capturedApplication = self.workspace.application(
                        processIdentifier: captured.workspaceApplication.processIdentifier)
                    guard self.sameWorkspace(baselineWorkspace, refreshedWorkspace), current.token.isPermitted else {
                        self.finish(current)
                        return
                    }
                    self.onWorker {
                        let result = self.backend.attemptRestore(
                            captured: captured, baseline: baseline,
                            workspace: refreshedWorkspace.application, capturedApplication: capturedApplication,
                            permit: { current.token.isPermitted })
                        self.completeAttempt(result, session: current, captured: captured)
                    }
                }
            }
        }
    }

    public func discardCapturedWindow() { invalidate(shutdown: false) }

    /// Terminal for this coordinator; restarting the driver creates a new instance.
    public func shutdown() {
        invalidate(shutdown: true)
        // This never waits for AX, including observer deregistration.
        onMain { self.workspace.stop() }
    }

    private func invalidate(shutdown: Bool) {
        sessionLock.lock()
        state.invalidate(shutdown: shutdown)
        let previous = session
        let cleanup = previous != nil && state.beginCleanup()
        if cleanup { session = nil }
        sessionLock.unlock()
        if cleanup, let previous { dispose(previous, finishOperation: true) }
    }

    private func startPreparation(_ current: Session, completion: @escaping () -> Void) {
        onMain {
            guard current.token.isPermitted else { self.finish(current, completion: completion); return }
            let operationState = self.state
            self.workspace.start { [weak operationState] event in operationState?.observe(event) }
            let before = self.workspace.snapshot()
            guard before.sessionActive else { self.finish(current, completion: completion); return }
            self.onWorker {
                guard current.token.isPermitted else { self.finish(current, completion: completion); return }
                let resolution = self.backend.resolve(workspace: before.application,
                                                       permit: { current.token.isPermitted })
                guard case let .known(target) = resolution else {
                    self.logUnknown(resolution, context: "Pre-input focus capture unavailable")
                    self.finish(current, completion: completion)
                    return
                }
                guard current.token.isPermitted else { self.finish(current, completion: completion); return }
                guard let observation = self.backend.prepareObservation(
                        target: target, permit: { current.token.isPermitted },
                        onChange: { [token = current.token] in token.observe($0) }) else {
                    self.log("Pre-input focus capture skipped because target observation is unavailable.")
                    self.finish(current, completion: completion)
                    return
                }
                current.observations.append(observation)
                self.onMain {
                    guard current.token.isPermitted else { self.finish(current, completion: completion); return }
                    self.attachSources(current)
                    let observed = self.workspace.snapshot()
                    guard self.sameWorkspace(before, observed) else {
                        self.finish(current, completion: completion)
                        return
                    }
                    // Observer registration is not a snapshot. Re-resolve after attachment.
                    self.onWorker {
                        guard current.token.isPermitted else { self.finish(current, completion: completion); return }
                        let confirmation = self.backend.resolve(workspace: observed.application,
                                                                permit: { current.token.isPermitted })
                        guard case let .known(confirmed) = confirmation else {
                            self.logUnknown(confirmation, context: "Pre-input focus confirmation unavailable")
                            self.finish(current, completion: completion)
                            return
                        }
                        guard self.backend.relationship(target, confirmed) == .same else {
                            self.log("Pre-input focus changed while observation was installed; capture skipped.")
                            self.finish(current, completion: completion)
                            return
                        }
                        self.onMain {
                            guard current.token.isPermitted else { self.finish(current, completion: completion); return }
                            let final = self.workspace.snapshot()
                            self.sessionLock.lock()
                            let accepted = self.session === current && self.sameWorkspace(observed, final)
                                && current.token.isPermitted
                            if accepted {
                                current.captured = confirmed
                                self.state.finishOperation()
                            }
                            self.sessionLock.unlock()
                            guard accepted else {
                                self.finish(current, completion: completion)
                                return
                            }
                            if let systemError = confirmed.systemWideError {
                                self.log("Capture corroborated after system-wide AX error \(systemError.rawValue).")
                            }
                            self.deliverPreparation(completion, prepared: current)
                        }
                    }
                }
            }
        }
    }

    private func completeAttempt(_ result: AXFocusAttemptResult, session current: Session, captured: AXFocusTarget) {
        switch result {
        case .skipped:
            log("Focus restoration abstained; no mutation issued.")
            finish(current)
        case .unknown(let failure):
            logUnknown(.unknown(failure), context: "Focus restoration abstained")
            finish(current)
        case .attempted(let error):
            log("Issued one focus mutation; AX=\(error.rawValue). Timeout does not cancel an issued action.")
            guard current.token.isPermitted else { finish(current); return }
            onMain {
                guard current.token.isPermitted else { self.finish(current); return }
                let after = self.workspace.snapshot()
                guard after.sessionActive else { self.finish(current); return }
                self.onWorker {
                    guard current.token.isPermitted else { self.finish(current); return }
                    let verification = self.backend.resolve(workspace: after.application,
                                                           permit: { current.token.isPermitted })
                    guard case let .known(verified) = verification else {
                        self.logUnknown(verification, context: "Focus mutation has no fresh verification result")
                        self.finish(current)
                        return
                    }
                    let restored = self.backend.relationship(captured, verified) == .same
                    self.onMain {
                        let final = self.workspace.snapshot()
                        guard current.token.isPermitted, self.sameWorkspace(after, final) else {
                            self.log("Focus verification became stale before main-thread revalidation.")
                            self.finish(current)
                            return
                        }
                        self.log(restored
                            ? "Fresh AX verification found the captured window focused."
                            : "Fresh AX verification did not find the captured window focused.")
                        self.finish(current)
                    }
                }
            }
        }
    }

    private func sameWorkspace(_ lhs: WorkspaceFocusSnapshot, _ rhs: WorkspaceFocusSnapshot) -> Bool {
        guard lhs.sessionActive, rhs.sessionActive, lhs.revision == rhs.revision,
              let left = lhs.application, let right = rhs.application,
              !left.isTerminated, !right.isTerminated, !left.isHidden, !right.isHidden else { return false }
        return left.processIdentifier == right.processIdentifier && left.isSameApplication(as: right)
    }

    /// Main only. Each source is attached once; callbacks only invalidate eligibility.
    private func attachSources(_ current: Session) {
        for observation in current.observations {
            guard let source = observation.source,
                  !current.attachedSources.contains(where: { CFEqual($0, source) }) else { continue }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            current.attachedSources.append(source)
        }
    }

    private func finish(_ current: Session, completion: (() -> Void)? = nil) {
        current.token.invalidate()
        dispose(current, finishOperation: true) {
            if let completion { self.deliverPreparation(completion) }
        }
    }

    /// Keep the actual-operation slot until worker-side observer cleanup returns too.
    private func dispose(_ current: Session, finishOperation: Bool, completion: (() -> Void)? = nil) {
        onMain {
            for source in current.attachedSources {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            current.attachedSources.removeAll()
            self.onWorker {
                current.observations.forEach { $0.invalidate() }
                current.observations.removeAll()
                self.sessionLock.lock()
                if self.session === current { self.session = nil }
                if finishOperation { self.state.finishOperation() }
                self.sessionLock.unlock()
                completion?()
            }
        }
    }

    private func log(_ message: String) { DriverLoggers.log(.debug, category: .focus, message) }

    private func logUnknown(_ resolution: AXFocusResolution, context: String) {
        guard case let .unknown(failure) = resolution else { return }
        log("\(context): \(failure.stage); AX=\(failure.error?.rawValue.description ?? "none"), systemWideAX=\(failure.systemWideError?.rawValue.description ?? "none").")
    }

    private func deliverPreparation(_ completion: @escaping () -> Void, prepared: Session? = nil) {
        onCallback { [weak self] in
            guard let self, !self.state.isStopped else { return }
            if let prepared {
                self.sessionLock.lock()
                let current = self.session === prepared
                let eligible = current && prepared.token.beginTouch()
                let cleanup = current && !eligible && self.state.beginCleanup()
                if cleanup { self.session = nil }
                self.sessionLock.unlock()
                if cleanup { self.dispose(prepared, finishOperation: true) }
            }
            completion()
        }
    }
}
