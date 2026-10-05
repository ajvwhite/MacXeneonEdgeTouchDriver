import CoreFoundation
import Foundation

/// Best-effort focus transactions. Main owns Workspace and observer run-loop sources;
/// a single worker owns AX. Neither queue waits synchronously for the other.
public final class AXFocusRestorer: FocusRestorer {
    // Each executor must enqueue once, asynchronously and FIFO on its assigned
    // serial queue. Main owns Workspace/source attachment; worker owns AX and
    // observation disposal; callback owns the caller's gesture state. A stage
    // transfers its work to the next queue only after its own mutations finish.
    // This is an execution/ownership contract, not a Sendable claim about the
    // injected backend, Workspace monitor, Session, clock or client completion.
    typealias Enqueue = (@escaping () -> Void) -> Void

    private final class Session {
        let token: FocusOperationToken
        var captured: AXFocusTarget?
        // Published under sessionLock while touching, then frozen by inputDidEnd.
        var certifiedBaseline: AXFocusTarget?
        var releasedBaseline: AXFocusTarget?
        var inputDestinationPID: pid_t?
        var inputDestinationIsPassive = false
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
    private let preparationMilliseconds: UInt64
    private let captureInputPermit: () -> PhysicalInputGuard.Permit
    private let retryOnMain: Enqueue
    private let state = FocusOperationState()
    private let sessionLock = NSLock()
    private var session: Session?
    private var hasStarted = false
    private var independentTargetActivation = false
    private var isShutdown = false
    private var independentActivationGeneration: UInt64 = 0

    /// Callback delivery belongs to the caller's serial gesture queue. Use the same
    /// queue for gesture handling, timers and final cancellation. Do not supply a
    /// concurrent queue or mutate completion-owned state from another queue.
    public convenience init(callbackQueue: DispatchQueue = .main) {
        let worker = DispatchQueue(label: "\(DriverLoggers.subsystem).focus-ax")
        self.init(
            backend: AXFocusBackend(timeout: 0.05), workspace: WorkspaceFocusMonitor(),
            onMain: { DispatchQueue.main.async(execute: DispatchWorkItem(block: $0)) },
            onWorker: { worker.async(execute: DispatchWorkItem(block: $0)) },
            onCallback: { callbackQueue.async(execute: DispatchWorkItem(block: $0)) },
            now: { DispatchTime.now().uptimeNanoseconds },
            preparationMilliseconds: 150,
            captureInputPermit: { PhysicalInputGuard.system.capture() },
            retryOnMain: { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5), execute: DispatchWorkItem(block: $0)) }
        )
    }

    /// Injected executors obey the ownership contract above. The clock must support
    /// concurrent reads from all callers; backend and Workspace access stay on their
    /// designated queues. Captured dependencies must outlive pending queued work.
    init(backend: AXFocusBackendProtocol, workspace: WorkspaceFocusMonitoring,
         onMain: @escaping Enqueue, onWorker: @escaping Enqueue,
         onCallback: @escaping Enqueue, now: @escaping () -> UInt64,
         preparationMilliseconds: UInt64 = 30,
         captureInputPermit: @escaping () -> PhysicalInputGuard.Permit = { { true } },
         retryOnMain: Enqueue? = nil) {
        self.backend = backend
        self.workspace = workspace
        self.onMain = onMain
        self.onWorker = onWorker
        self.onCallback = onCallback
        self.now = now
        self.preparationMilliseconds = preparationMilliseconds
        self.captureInputPermit = captureInputPermit
        self.retryOnMain = retryOnMain ?? onMain
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
        let next = Session(token: FocusOperationToken(preparationMilliseconds: preparationMilliseconds, now: now,
                                                     inputPermit: captureInputPermit()))
        sessionLock.lock()
        hasStarted = true
        independentTargetActivation = false
        independentActivationGeneration &+= 1
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
        onCallback = { queue.async(execute: DispatchWorkItem(block: $0)) }
    }

    public func beginTargetActivation() -> Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard !isShutdown else { return false }
        guard let current = session, current.captured != nil else {
            // Unavailable original focus disables restoration, not a separately
            // verified target click. The native target preparer still confirms
            // its exact application/window and physical-input permit.
            independentTargetActivation = true
            return true
        }
        independentTargetActivation = false
        return current.token.beginTargetActivation()
    }

    public func confirmTargetActivation(completion: @escaping (Bool) -> Void) {
        sessionLock.lock()
        if independentTargetActivation && !isShutdown {
            independentTargetActivation = false
            let generation = independentActivationGeneration
            sessionLock.unlock()
            onCallback {
                self.sessionLock.lock()
                let valid = !self.isShutdown && self.independentActivationGeneration == generation
                self.sessionLock.unlock()
                completion(valid)
            }
            return
        }
        let current = session
        let eligible = current?.token.endTargetActivation() == true
        sessionLock.unlock()
        guard eligible, let current else { onCallback { completion(false) }; return }
        onMain { self.startEnrollment(current, completion: completion) }
    }

    public func syntheticInputWillBegin(targetProcessIdentifier: Int32?, permitsWindowlessDestination: Bool = false) {
        guard let pid = targetProcessIdentifier, pid > 0 else { return }
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard let current = session, current.token.beginSyntheticInput() else { return }
        current.inputDestinationPID = pid
        current.inputDestinationIsPassive = permitsWindowlessDestination
    }

    public func inputDidEnd() {
        sessionLock.lock()
        if state.inputDidEnd(), let current = session {
            current.releasedBaseline = current.certifiedBaseline
        }
        sessionLock.unlock()
    }

    public func restoreCapturedWindow() {
        sessionLock.lock()
        let current = session
        let admitted = current.map {
            $0.captured != nil && $0.releasedBaseline != nil && state.beginRestoration(token: $0.token)
        } ?? false
        sessionLock.unlock()
        guard admitted, let current, let captured = current.captured,
              let baseline = current.releasedBaseline else {
            log("Focus restoration not admitted; captured=\(current?.captured != nil), releasedBaseline=\(current?.releasedBaseline != nil), \(current?.token.diagnosticState ?? "no session").")
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
                guard case let .known(confirmed) = resolution else {
                    if current.inputDestinationIsPassive,
                       current.inputDestinationPID == baselineWorkspace.application?.processIdentifier,
                       captured.focusedElement != nil,
                       let empty = self.backend.resolveWindowlessApplication(workspace: baselineWorkspace.application,
                                                                           permit: { current.token.isPermitted }),
                       self.backend.canRestoreExactRecipient(captured, permit: { current.token.isPermitted }) {
                        self.restoreFromWindowlessDestination(empty, snapshot: baselineWorkspace, session: current, captured: captured)
                    } else {
                        self.logUnknown(resolution, context: "Post-release focus baseline unavailable")
                        self.finish(current)
                    }
                    return
                }
                let effectiveBaseline: AXFocusTarget
                if let destination = current.inputDestinationPID {
                    let currentPID = confirmed.workspaceApplication.processIdentifier
                    guard currentPID == destination || currentPID == captured.workspaceApplication.processIdentifier else {
                        self.log("Post-delivery focus belongs to neither captured source nor verified touch destination; restoration skipped.")
                        self.finish(current); return
                    }
                    effectiveBaseline = confirmed
                } else { effectiveBaseline = baseline }
                guard self.backend.windowRelationship(effectiveBaseline, confirmed) == .same else {
                    self.log("Focus changed from the certified pre-release baseline; restoration skipped.")
                    self.finish(current)
                    return
                }
                if self.backend.relationship(captured, effectiveBaseline) == .same {
                    self.log("Captured window is already focused; no mutation needed.")
                    self.finish(current)
                    return
                }
                self.onMain {
                    guard current.token.isPermitted else { self.finish(current); return }
                    let refreshedWorkspace = self.workspace.snapshot()
                    let capturedApplication = self.workspace.application(
                        processIdentifier: captured.workspaceApplication.processIdentifier)
                    guard self.sameWorkspace(baselineWorkspace, refreshedWorkspace), current.token.isPermitted else {
                        self.finish(current)
                        return
                    }
                    self.onWorker {
                        guard current.token.beginRestoreMutation() else { self.finish(current); return }
                        let result = self.backend.attemptRestore(
                            captured: captured, baseline: effectiveBaseline,
                            workspace: refreshedWorkspace.application, capturedApplication: capturedApplication,
                            permit: { current.token.isPermitted })
                        self.completeAttempt(result, session: current, captured: captured)
                    }
                }
            }
        }
    }

    /// A verified passive destination has no keyboard window to compare with the
    /// captured source. First prove that explicit state twice, then activate the
    /// retained source once. Actual activation and fresh AX ownership must be
    /// confirmed before the exact recipient setter; no speculative window fallback.
    private func restoreFromWindowlessDestination(_ empty: AXWindowlessFocusTarget,
        snapshot: WorkspaceFocusSnapshot, session current: Session, captured: AXFocusTarget) {
        onMain {
            guard current.token.isPermitted, self.sameWorkspace(snapshot, self.workspace.snapshot()),
                  let source = self.workspace.application(processIdentifier: captured.workspaceApplication.processIdentifier),
                  source.isSameApplication(as: captured.workspaceApplication), !source.isHidden, !source.isTerminated else {
                self.finish(current); return
            }
            self.onWorker {
                guard current.token.isPermitted,
                      let confirmed = self.backend.resolveWindowlessApplication(workspace: snapshot.application,
                                                                                permit: { current.token.isPermitted }),
                      confirmed.workspaceApplication.isSameApplication(as: empty.workspaceApplication) else {
                    self.finish(current); return
                }
                self.onMain {
                    guard current.token.isPermitted, self.sameWorkspace(snapshot, self.workspace.snapshot()),
                          current.token.beginRestoreMutation() else { self.finish(current); return }
                    self.log("Verified windowless click destination; activating captured source once.")
                    guard self.workspace.activate(source) else { self.finish(current); return }
                    self.awaitRestoredSource(source, session: current, captured: captured, retries: 16)
                }
            }
        }
    }

    private func awaitRestoredSource(_ source: AXFocusWorkspaceApplication, session current: Session,
                                     captured: AXFocusTarget, retries: Int) {
        guard current.token.isPermitted else { finish(current); return }
        let observed = workspace.snapshot()
        guard observed.sessionActive else { finish(current); return }
        guard workspace.isActive(source), observed.application?.isSameApplication(as: source) == true else {
            guard retries > 0 else { finish(current); return }
            retryOnMain { self.awaitRestoredSource(source, session: current, captured: captured, retries: retries - 1) }
            return
        }
        onWorker {
            guard current.token.isPermitted else { self.finish(current); return }
            let resolution = self.backend.resolve(workspace: observed.application, permit: { current.token.isPermitted })
            guard case let .known(baseline) = resolution else {
                if retries > 0, self.canRetryRead(resolution) {
                    self.onMain {
                        guard current.token.isPermitted, self.sameWorkspace(observed, self.workspace.snapshot()),
                              self.workspace.isActive(source) else { self.finish(current); return }
                        self.retryOnMain { self.awaitRestoredSource(source, session: current, captured: captured, retries: retries - 1) }
                    }
                } else {
                    self.logUnknown(resolution, context: "Activated source has no verified keyboard window")
                    self.finish(current)
                }
                return
            }
            self.onMain {
                guard current.token.isPermitted, self.sameWorkspace(observed, self.workspace.snapshot()),
                      self.workspace.isActive(source) else { self.finish(current); return }
                self.onWorker {
                    guard current.token.isPermitted else { self.finish(current); return }
                    let result = self.backend.attemptRestore(captured: captured, baseline: baseline,
                        workspace: observed.application, capturedApplication: source, permit: { current.token.isPermitted })
                    self.completeAttempt(result, session: current, captured: captured)
                }
            }
        }
    }

    public func discardCapturedWindow() { invalidate(shutdown: false) }

    /// Terminal for this coordinator; restarting the driver creates a new instance.
    /// Prevents new preparation-callback admission, but does not wait for an already
    /// admitted completion. After stopping new input producers, the caller must
    /// cancel/drain its serial gesture queue if it needs a final input-effect fence.
    public func shutdown() {
        invalidate(shutdown: true)
        // This never waits for AX, including observer deregistration.
        onMain { self.workspace.stop() }
    }

    private func invalidate(shutdown: Bool) {
        sessionLock.lock()
        state.invalidate(shutdown: shutdown)
        independentTargetActivation = false
        independentActivationGeneration &+= 1
        if shutdown { isShutdown = true }
        let previous = session
        let cleanup = previous != nil && state.beginCleanup()
        if cleanup { session = nil }
        sessionLock.unlock()
        if cleanup, let previous { dispose(previous, finishOperation: true) }
    }

    private func startPreparation(_ current: Session, completion: @escaping () -> Void) {
        onMain {
            guard current.token.isPermitted else { self.finish(current, completion: completion); return }
            self.workspace.start(observation: self.observationHandler(current))
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
                        onChange: self.observationHandler(current)) else {
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
                                current.certifiedBaseline = confirmed
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
                            self.log("Pre-input focus captured; recipientPresent=\(confirmed.focusedElement != nil), \(current.token.diagnosticState).")
                            self.deliverPreparation(completion, prepared: current)
                        }
                    }
                }
            }
        }
    }

    private func observationHandler(_ current: Session) -> (FocusObservationEvent) -> Void {
        { [weak self, weak current, token = current.token] event in
            // Dirty the certificate immediately, even if main is busy. The single
            // queued request samples after a burst of activation/deactivation hints.
            let requested = token.observe(event)
            self?.log("Focus observation \(event); \(token.diagnosticState), enrollmentRequested=\(requested).")
            guard requested, let self, let current else { return }
            self.onMain { [weak self, weak current] in
                guard let self, let current else { return }
                self.startEnrollment(current)
            }
        }
    }

    /// One attempt per touch, sharing the actual-operation slot with all AX work.
    /// If release wins any stage, its invalidated permit prevents late certification.
    private func startEnrollment(_ current: Session, completion: ((Bool) -> Void)? = nil) {
        sessionLock.lock()
        let captured = current.captured
        let revision = session === current && captured != nil ? state.beginEnrollment(token: current.token) : nil
        sessionLock.unlock()
        guard let revision, let captured else { if let completion { onCallback { completion(false) } }; return }
        let permit = { current.token.permitsEnrollment(revision: revision) }
        let before = workspace.snapshot()
        guard before.sessionActive, permit() else { finish(current, completion: completion.map { callback in { callback(false) } }); return }
        onWorker {
            guard permit() else { self.finish(current, completion: completion.map { callback in { callback(false) } }); return }
            let resolution = self.backend.resolve(workspace: before.application, permit: permit)
            guard case let .known(target) = resolution else {
                self.logUnknown(resolution, context: "During-touch focus baseline unavailable")
                self.finish(current, completion: completion.map { callback in { callback(false) } })
                return
            }
            guard permit() else { self.finish(current, completion: completion.map { callback in { callback(false) } }); return }
            // The original observer already watches its application's focused-window
            // changes. A different application needs one additional observer.
            if !target.workspaceApplication.isSameApplication(as: captured.workspaceApplication) {
                guard let observation = self.backend.prepareObservation(
                    target: target, permit: permit, onChange: self.observationHandler(current)) else {
                    self.log("During-touch baseline observation unavailable; restoration skipped.")
                    self.finish(current, completion: completion.map { callback in { callback(false) } })
                    return
                }
                current.observations.append(observation)
            }
            self.onMain {
                guard permit() else { self.finish(current, completion: completion.map { callback in { callback(false) } }); return }
                self.attachSources(current)
                let observed = self.workspace.snapshot()
                guard self.sameWorkspace(before, observed), permit() else { self.finish(current, completion: completion.map { callback in { callback(false) } }); return }
                self.onWorker {
                    guard permit() else { self.finish(current, completion: completion.map { callback in { callback(false) } }); return }
                    let confirmation = self.backend.resolve(workspace: observed.application, permit: permit)
                    guard case let .known(confirmed) = confirmation else {
                        self.logUnknown(confirmation, context: "During-touch focus confirmation unavailable")
                        self.finish(current, completion: completion.map { callback in { callback(false) } })
                        return
                    }
                    guard self.backend.windowRelationship(target, confirmed) == .same, permit() else {
                        self.finish(current, completion: completion.map { callback in { callback(false) } })
                        return
                    }
                    self.onMain {
                        let final = self.workspace.snapshot()
                        self.sessionLock.lock()
                        let accepted = self.session === current && self.sameWorkspace(observed, final)
                            && current.token.certifyEnrollment(revision: revision)
                        if accepted {
                            current.certifiedBaseline = confirmed
                            self.state.finishOperation()
                        }
                        self.sessionLock.unlock()
                        if accepted, let completion {
                            self.onCallback { completion(current.token.isPermitted) }
                        }
                        if !accepted { self.finish(current, completion: completion.map { callback in { callback(false) } }) }
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
            verifyRestoreAttempt(current, captured: captured, retries: 16)
        }
    }

    private func canRetryRead(_ resolution: AXFocusResolution) -> Bool {
        guard case let .unknown(problem) = resolution else { return false }
        return problem.error == .noValue || problem.error == .cannotComplete
    }

    /// Poll only observations after the committed action. Never repeat activation
    /// or an AX setter merely because its result is not visible yet.
    private func verifyRestoreAttempt(_ current: Session, captured: AXFocusTarget, retries: Int) {
        onMain {
            guard current.token.isPermitted else { self.finish(current); return }
            let after = self.workspace.snapshot()
            guard after.sessionActive else { self.finish(current); return }
            self.onWorker {
                guard current.token.isPermitted else { self.finish(current); return }
                let verification = self.backend.resolve(workspace: after.application, permit: { current.token.isPermitted })
                guard case let .known(verified) = verification else {
                    if retries > 0, self.canRetryRead(verification) {
                        self.retryOnMain { self.verifyRestoreAttempt(current, captured: captured, retries: retries - 1) }
                    } else {
                        self.logUnknown(verification, context: "Focus mutation has no fresh verification result")
                        self.finish(current)
                    }
                    return
                }
                let restored = self.backend.relationship(captured, verified) == .same
                self.onMain {
                    let final = self.workspace.snapshot()
                    guard current.token.isPermitted, self.sameWorkspace(after, final) else {
                        self.log("Focus verification became stale before main-thread revalidation.")
                        self.finish(current); return
                    }
                    if !restored, retries > 0,
                       verified.workspaceApplication.isSameApplication(as: captured.workspaceApplication) {
                        self.retryOnMain { self.verifyRestoreAttempt(current, captured: captured, retries: retries - 1) }
                        return
                    }
                    self.log(restored
                        ? "Fresh AX verification found the captured window and keyboard recipient focused."
                        : "Fresh AX verification did not find the captured window and keyboard recipient focused.")
                    self.finish(current)
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
        log("Focus transaction finishing; \(current.token.diagnosticState).")
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
            // Admission is the stopped check, not completion return. Shutdown can
            // invalidate the token immediately after this check. Calling client
            // code under sessionLock (or waiting for it in shutdown) would break
            // reentrant completion and nonblocking shutdown; the caller's serial
            // gesture queue provides the subsequent cancellation/drain boundary.
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
