import CoreGraphics
import Darwin
import Foundation

/// Overrides external monitoring only for deterministic application tests.
struct DriverMonitoringHooks {
    let start: () throws -> Void
    let stop: () -> Void
}

/// Production application wiring for the Xeneon Edge single-touch driver.
public final class MacXeneonEdgeTouchDriverApplication {
    private let configuration: DriverConfiguration
    private let displayResolver: DisplayResolver
    private let mapperStore = CoordinateMapperStore()
    private let gestureQueue: DispatchQueue
    private let scheduler: GestureScheduler
    private let inputSink: SyntheticInputSink
    private let cursorController: CursorController
    private let focusRestorer: FocusRestorer

    private lazy var gestureController: GestureController = {
        let controller = GestureController(
            mapperProvider: { [mapperStore] in
                mapperStore.currentMapper
            },
            inputSink: inputSink,
            cursorController: cursorController,
            focusRestorer: focusRestorer,
            returnCursorToPreviousPosition: configuration.cursor.returnToPreviousPosition,
            timing: GestureTiming(configuration: configuration.timing),
            scheduler: scheduler
        )
        controller.onInputSessionEnded = { [weak self] session in
            self?.inputSessionEnded(session)
        }
        controller.onInputSessionInvalidated = { [weak self] session in
            self?.inputSessionInvalidated(session)
        }
        controller.onBecameIdle = { [weak self] in
            self?.cancelStuckGestureTimer()
        }
        return controller
    }()

    private lazy var hidMonitor = HIDDeviceMonitor(
        eventQueue: gestureQueue,
        seizeDevice: true,
        touchEventHandler: { [weak self] event in
            self?.handleTouchEvent(event)
        },
        deviceRemovalHandler: { [weak self] in
            self?.handleDeviceRemoval()
        },
        deviceMatchedHandler: { [weak self] in
            self?.handleDeviceMatched()
        },
        observationHandler: { [weak self] observation, fence in
            self?.handleTouchObservation(observation, fence: fence)
        },
        sourceRemovalHandler: { [weak self] sourceID in
            self?.handleSourceRemoval(sourceID)
        }
    )

    private struct SourceContact {
        var epoch: UInt64
        var isPressed: Bool
        var isClosed: Bool
        var isRejected: Bool
        var needsRelease: Bool
    }

    private struct HIDContact: Equatable {
        let sourceID: HIDSourceID
        let epoch: UInt64
    }

    private enum InputOrigin: Equatable {
        case hid(HIDContact)
        case normalized(UInt64)
    }

    private enum WatchdogMode: Equatable { case pressed, cleanup }

    private struct InputLease {
        let origin: InputOrigin
        let session: GestureInputSession
        let fence: HIDSourceRetirementFence?
        var mode: WatchdogMode
    }

    // All session/arbitration/watchdog state belongs to the serial gesture queue.
    private var sourceContacts: [HIDSourceID: SourceContact] = [:]
    private var resynchronizeNewSources = false
    private var inputLease: InputLease?
    private var normalizedSequence: UInt64 = 0
    private var normalizedOrigins: [Int: InputOrigin] = [:]
    private var stuckGestureTimer: GestureScheduledTask?
    private var stuckGestureTimerGeneration: UInt64 = 0
    private var currentDisplaySnapshot: DisplaySnapshot?
    private var displayCallbackRegistration: DisplayReconfigurationRegistration?
    private let startupDependencies: DriverStartupDependencies
    private let monitoringOverride: DriverMonitoringHooks?
    private var startupCoordinator: DriverStartupCoordinator?
    private var didShutdownFocus = false

    /// Creates a production application with CoreGraphics side effects.
    public convenience init(configuration: DriverConfiguration = .defaults) {
        self.init(
            configuration: configuration,
            displayResolver: DisplayResolver(configuration: configuration.display),
            inputSink: CGEventInputSink(),
            cursorController: CGCursorController(),
            focusFactory: { AXFocusRestorer(callbackQueue: $0) },
            scheduler: nil
        )
    }

    /// Creates an application with injectable side-effect dependencies.
    public convenience init(
        configuration: DriverConfiguration,
        displayResolver: DisplayResolver,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorer: FocusRestorer = NoOpFocusRestorer()
    ) {
        self.init(
            configuration: configuration,
            displayResolver: displayResolver,
            inputSink: inputSink,
            cursorController: cursorController,
            focusFactory: { _ in focusRestorer },
            scheduler: nil
        )
    }

    /// Supplies deterministic scheduling without starting HID or requesting permissions.
    convenience init(
        configuration: DriverConfiguration,
        displayResolver: DisplayResolver,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorer: FocusRestorer = NoOpFocusRestorer(),
        scheduler: GestureScheduler?,
        gestureQueue: DispatchQueue? = nil
    ) {
        self.init(
            configuration: configuration,
            displayResolver: displayResolver,
            inputSink: inputSink,
            cursorController: cursorController,
            focusFactory: { _ in focusRestorer },
            scheduler: scheduler,
            gestureQueue: gestureQueue
        )
    }

    /// Supplies deterministic startup without requesting permissions or opening HID.
    convenience init(
        configuration: DriverConfiguration,
        displayResolver: DisplayResolver,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorer: FocusRestorer = NoOpFocusRestorer(),
        startupDependencies: DriverStartupDependencies,
        monitoringOverride: DriverMonitoringHooks?,
        scheduler: GestureScheduler? = nil,
        gestureQueue: DispatchQueue? = nil
    ) {
        self.init(
            configuration: configuration,
            displayResolver: displayResolver,
            inputSink: inputSink,
            cursorController: cursorController,
            focusFactory: { _ in focusRestorer },
            scheduler: scheduler,
            gestureQueue: gestureQueue,
            startupDependencies: startupDependencies,
            monitoringOverride: monitoringOverride
        )
    }

    private init(
        configuration: DriverConfiguration,
        displayResolver: DisplayResolver,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusFactory: (DispatchQueue) -> FocusRestorer,
        scheduler: GestureScheduler?,
        gestureQueue: DispatchQueue? = nil,
        startupDependencies: DriverStartupDependencies = .live,
        monitoringOverride: DriverMonitoringHooks? = nil
    ) {
        let gestureQueue = gestureQueue ?? DispatchQueue(label: "\(DriverLoggers.subsystem).gesture-queue")
        self.gestureQueue = gestureQueue
        self.startupDependencies = startupDependencies
        self.monitoringOverride = monitoringOverride
        self.scheduler = scheduler ?? DispatchGestureScheduler(queue: gestureQueue)
        self.configuration = configuration
        self.displayResolver = displayResolver
        self.inputSink = inputSink
        self.cursorController = cursorController
        self.focusRestorer = configuration.focus.restorePreviousWindow ? focusFactory(gestureQueue) : NoOpFocusRestorer()
        (self.focusRestorer as? AXFocusRestorer)?.bindCallbackQueue(gestureQueue)
    }

    deinit {
        // run() owns the complete main-thread hardware lifecycle and pins self
        // until teardown is finished. A completed application's last reference
        // may be released by a gesture callback or by a library client off main;
        // destruction must not re-enter main-only lifecycle operations.
        shutdownFocus()
    }

    private func shutdownFocus() {
        guard !didShutdownFocus else { return }
        didShutdownFocus = true
        focusRestorer.shutdown()
    }

    /// Starts one driver lifecycle on the main thread, waiting for permission if needed.
    public func run() -> Int32 {
        precondition(Thread.isMainThread, "Driver lifecycle must run on the main thread.")
        if let startupCoordinator {
            // A repeated or nested run must not tear down the owning run.
            return startupCoordinator.run()
        }
        DriverLoggers.log(.notice, category: .lifecycle, "Starting Mac Xeneon Edge Touch Driver in single-touch mode.")
        startupCoordinator = DriverStartupCoordinator(
            dependencies: startupDependencies,
            startHardware: { [weak self] in try self?.startMonitoring() },
            stopHardware: { [weak self] in self?.stopMonitoring() }
        )
        return withExtendedLifetime(self) {
            // Waiting, startup failure, and normal exit all invalidate focus,
            // even when the coordinator never acquired hardware.
            defer { shutdownFocus() }
            return startupCoordinator!.run()
        }
    }

    /// Stops the lifecycle on the main thread. Waiting callbacks are invalidated before teardown.
    public func stop() {
        precondition(Thread.isMainThread, "Driver lifecycle must stop on the main thread.")
        guard let startupCoordinator else {
            shutdownFocus()
            return
        }
        startupCoordinator.stop()
        // Waiting has no hardware teardown; invalidate any remaining focus work too.
        shutdownFocus()
    }

    private func startMonitoring() throws {
        if let monitoringOverride {
            try monitoringOverride.start()
            return
        }
        registerDisplayReconfigurationCallback()
        gestureQueue.sync {
            refreshDisplayMapping(reason: "startup")
        }
        try hidMonitor.start()
    }

    private func stopMonitoring() {
        // Signal-driven coordinator teardown also needs early focus invalidation.
        shutdownFocus()
        if let monitoringOverride {
            monitoringOverride.stop()
        } else {
            hidMonitor.stop()
        }
        // Close callback admission before the drain. Removal is not assumed to
        // fence a callback already selected by CoreGraphics, including on error.
        unregisterDisplayReconfigurationCallback()
        gestureQueue.sync {
            handleHIDStop()
        }
    }

    func enqueueDisplayReconfiguration(flags: CGDisplayChangeSummaryFlags) {
        // Begin notifications must block already-queued input before this handler can run.
        let revision = mapperStore.recordReconfiguration(flags: flags)
        gestureQueue.async { [weak self] in
            self?.handleDisplayReconfiguration(flags: flags, revision: revision)
        }
    }

    /// Synchronous entry point for display decisions on the gesture queue.
    func handleDisplayReconfiguration(flags: CGDisplayChangeSummaryFlags) {
        let revision = mapperStore.recordReconfiguration(flags: flags)
        handleDisplayReconfiguration(flags: flags, revision: revision)
    }

    private func handleDisplayReconfiguration(flags: CGDisplayChangeSummaryFlags, revision: UInt64) {
        guard mapperStore.isCurrent(revision: revision) else { return }
        if flags.contains(.beginConfigurationFlag) {
            // Apple sends one begin callback per online display, without final geometry.
            // The post-change callback count can differ when a display is added or removed.
            commitDisplaySnapshot(nil, revision: revision, reason: "display reconfiguration began")
        } else {
            // All display state is current before any post-change callback is delivered.
            // A newer begin notification makes this queued decision obsolete.
            refreshDisplayMapping(reason: "display reconfiguration completed", completingRevision: revision)
        }
    }

    private func refreshDisplayMapping(reason: String, completingRevision: UInt64? = nil) {
        guard let revision = completingRevision ?? mapperStore.settledRevision,
              mapperStore.isCurrent(revision: revision) else { return }
        // Resolve once and commit that exact snapshot, including a missing target.
        commitDisplaySnapshot(
            displayResolver.resolve(),
            revision: revision,
            completesReconfiguration: completingRevision != nil,
            reason: reason
        )
    }

    private func commitDisplaySnapshot(
        _ snapshot: DisplaySnapshot?,
        revision: UInt64,
        completesReconfiguration: Bool = false,
        reason: String
    ) {
        guard mapperStore.isCurrent(revision: revision) else { return }
        let changed = snapshot != currentDisplaySnapshot || snapshot != displayResolver.currentSnapshot

        if changed, currentDisplaySnapshot != nil {
            // Release any owned button and invalidate delayed work before replacing geometry.
            // Keeping this inline prevents old loss cleanup from cancelling a recovered touch.
            cancelActiveGesture()
        }
        guard mapperStore.update(
            snapshot.map { CoordinateMapper(displayBounds: $0.bounds) },
            revision: revision,
            completesReconfiguration: completesReconfiguration
        ) else { return }
        currentDisplaySnapshot = snapshot
        displayResolver.update(with: snapshot)
        guard changed else { return }

        if let snapshot {
            let bounds = snapshot.bounds
            DriverLoggers.log(
                .notice,
                category: .display,
                "Resolved Xeneon Edge display \(snapshot.displayID) after \(reason): x=\(bounds.origin.x), y=\(bounds.origin.y), width=\(bounds.width), height=\(bounds.height)."
            )
        } else {
            DriverLoggers.log(.error, category: .display, "Could not resolve Xeneon Edge display after \(reason). Touch events will be dropped.")
        }
    }

    /// Compatibility seam for normalized-event clients. HID production always
    /// uses the source-scoped observation path below.
    func handleTouchEvent(_ event: TouchEvent) {
        if event.kind == .down {
            normalizedSequence &+= 1
            normalizedOrigins[event.contactID] = .normalized(normalizedSequence)
        }
        guard let origin = normalizedOrigins[event.contactID] else { return }
        handleNormalizedEvent(event, origin: origin, fence: nil)
        if event.kind == .up, normalizedOrigins[event.contactID] == origin {
            normalizedOrigins.removeValue(forKey: event.contactID)
        }
    }

    /// One ordered queue operation for both normalized effects and liveness.
    /// Suppressed stationary packets never enter GestureController.handle.
    func handleTouchObservation(_ observation: HIDTouchObservation, fence: HIDSourceRetirementFence) {
        guard observation.sourceID == fence.sourceID, !fence.isRetired else { return }
        let sourceID = observation.sourceID
        var contact = sourceContacts[sourceID] ?? SourceContact(
            epoch: 0, isPressed: false, isClosed: false, isRejected: false,
            needsRelease: resynchronizeNewSources)
        guard observation.contactEpoch >= contact.epoch else { return }
        if observation.contactEpoch > contact.epoch {
            contact.epoch = observation.contactEpoch
            contact.isPressed = false
            contact.isClosed = false
            contact.isRejected = false
        }
        let origin = InputOrigin.hid(HIDContact(sourceID: sourceID, epoch: observation.contactEpoch))

        if !observation.isPressed {
            // Release clears only this endpoint/contact's quarantine or recovery
            // barrier. Foreign up never enters the owner's focus/input path.
            let wasOpen = contact.isPressed
            contact.isPressed = false
            contact.isClosed = true
            contact.needsRelease = false
            contact.isRejected = false
            sourceContacts[sourceID] = contact
            if wasOpen, inputLease?.origin == origin,
               inputLease?.mode == .pressed, let event = observation.event, event.kind == .up {
                handleNormalizedEvent(event, origin: origin, fence: fence)
            }
            return
        }

        guard !contact.isClosed else { return }
        let isFreshDown = !contact.isPressed && observation.event?.kind == .down
        contact.isPressed = true
        if contact.needsRelease { contact.isRejected = true }
        sourceContacts[sourceID] = contact
        guard !contact.isRejected else { return }

        if isFreshDown {
            // The one global button/cursor cleanup lease cannot change owners.
            // A rejected contact remains rejected through its own physical up.
            guard inputLease == nil, gestureController.state == .idle else {
                sourceContacts[sourceID]?.isRejected = true
                return
            }
            guard let event = observation.event else { return }
            handleNormalizedEvent(event, origin: origin, fence: fence)
            if inputLease?.origin != origin,
               sourceContacts[sourceID]?.epoch == observation.contactEpoch {
                sourceContacts[sourceID]?.isRejected = true
            }
        } else if inputLease?.origin == origin, inputLease?.mode == .pressed {
            if let event = observation.event, event.kind == .move {
                handleNormalizedEvent(event, origin: origin, fence: fence)
            } else {
                renewPressedWatchdog(origin: origin)
            }
        }
    }

    private func handleNormalizedEvent(_ event: TouchEvent, origin: InputOrigin,
                                       fence: HIDSourceRetirementFence?) {
        if event.kind == .down {
            refreshDisplayMapping(reason: "touch down")
            if case .hid = origin {
                // Display resolution/cancellation can synchronously deliver up,
                // a newer epoch or another accepted source. The earlier idle
                // observation is not admission authority after that reentry.
                guard isOpenHIDContact(origin), inputLease == nil,
                      gestureController.state == .idle, fence?.isRetired != true else { return }
                gestureController.prepareForNewPhysicalContact(contactID: event.contactID)
            }
        }
        guard fence?.isRetired != true else { return }
        gestureController.handle(event, acceptingDown: { [weak self] session in
            guard let self, fence?.isRetired != true else { return false }
            if case .hid = origin {
                guard self.isOpenHIDContact(origin), self.inputLease == nil else { return false }
            }
            self.inputLease = InputLease(origin: origin, session: session, fence: fence, mode: .pressed)
            if case .hid = origin {
                // A fresh accepted cycle follows that source's release barrier.
                self.resynchronizeNewSources = false
            }
            return true
        })
        // Reentrant up/cancel/new-down may have replaced or closed this session.
        renewPressedWatchdog(origin: origin)
    }

    private func isOpenHIDContact(_ origin: InputOrigin) -> Bool {
        guard case .hid(let identity) = origin,
              let contact = sourceContacts[identity.sourceID] else { return false }
        return contact.epoch == identity.epoch && contact.isPressed &&
            !contact.isClosed && !contact.isRejected && !contact.needsRelease
    }

    private func renewPressedWatchdog(origin: InputOrigin) {
        guard let lease = inputLease, lease.origin == origin, lease.mode == .pressed,
              gestureController.acceptsHeartbeat(for: lease.session) else { return }
        guard lease.fence?.isRetired != true else {
            if case .hid(let contact) = origin { handleSourceRemoval(contact.sourceID) }
            return
        }
        scheduleStuckGestureTimer(for: lease)
    }

    private func inputSessionEnded(_ session: GestureInputSession) {
        guard var lease = inputLease, lease.session == session, lease.mode == .pressed else { return }
        // Seal pressed liveness before inputDidEnd can reenter. Cleanup gets one
        // fixed bound; later heartbeats, ignored input and repeated up cannot renew it.
        lease.mode = .cleanup
        inputLease = lease
        scheduleStuckGestureTimer(for: lease)
    }

    private func inputSessionInvalidated(_ session: GestureInputSession) {
        guard inputLease?.session == session else { return }
        inputLease = nil
        cancelStuckGestureTimer()
    }

    func handleDeviceMatched() {
        refreshDisplayMapping(reason: "HID device match")
    }

    func handleDeviceRemoval() {
        cancelActiveGesture()
    }

    func handleSourceRemoval(_ sourceID: HIDSourceID) {
        sourceContacts.removeValue(forKey: sourceID)
        if let lease = inputLease, lease.mode == .pressed,
           case .hid(let contact) = lease.origin, contact.sourceID == sourceID {
            // A replacement's first held packet is not proof of a new finger
            // down. Only this exceptional owner-loss path requires up -> down.
            resynchronizeNewSources = true
            for source in Array(sourceContacts.keys) {
                sourceContacts[source]?.needsRelease = true
            }
        }
        if let lease = inputLease, case .hid(let contact) = lease.origin, contact.sourceID == sourceID {
            cancelActiveGesture()
        }
    }

    /// Called only after main-thread ingress has retired every registration.
    /// Preserve interrupted-hold recovery across a stop/start of this instance.
    func handleHIDStop() {
        if let lease = inputLease, lease.mode == .pressed, case .hid = lease.origin {
            resynchronizeNewSources = true
        }
        sourceContacts.removeAll()
        normalizedOrigins.removeAll()
        cancelActiveGesture()
    }

    /// Gesture teardown shared by stop, owner removal, and display loss.
    /// Called on the gesture queue in production; tests can exercise it without starting HID.
    func cancelActiveGesture() {
        inputLease = nil
        cancelStuckGestureTimer()
        // Invalidate ownership before either cleanup collaborator can reenter.
        let generation = gestureController.ownershipGeneration
        gestureController.invalidatePhysicalInput()
        focusRestorer.discardCapturedWindow()
        gestureController.forceCancel(ifGeneration: generation)
    }

    private func scheduleStuckGestureTimer(for lease: InputLease) {
        cancelStuckGestureTimer()
        let serial = stuckGestureTimerGeneration
        let timer = scheduler.schedule(afterMilliseconds: configuration.timing.stuckGestureTimeoutMs) { [weak self] in
            guard let self, self.stuckGestureTimerGeneration == serial,
                  let current = self.inputLease, current.origin == lease.origin,
                  current.session == lease.session, current.mode == lease.mode else { return }
            // Timeout wins permanently before any focus/input/cursor collaborator.
            self.inputLease = nil
            self.stuckGestureTimer = nil
            self.stuckGestureTimerGeneration &+= 1
            let controllerGeneration = self.gestureController.ownershipGeneration
            self.gestureController.invalidatePhysicalInput()
            DriverLoggers.log(.warning, category: .gesture, "Touch gesture timed out; forcing cleanup.")
            self.focusRestorer.discardCapturedWindow()
            self.gestureController.forceCancel(ifGeneration: controllerGeneration)
        }
        if stuckGestureTimerGeneration == serial,
           let current = inputLease, current.origin == lease.origin,
           current.session == lease.session, current.mode == lease.mode {
            stuckGestureTimer = timer
        } else {
            // Inline scheduling may expire, close, or replace this exact session.
            timer.cancel()
        }
    }

    private func cancelStuckGestureTimer() {
        stuckGestureTimerGeneration &+= 1
        stuckGestureTimer?.cancel()
        stuckGestureTimer = nil
    }

    /// Internal registration seam keeps tests on the exact production ingress.
    func registerDisplayReconfigurationCallback(operations: DisplayReconfigurationRegistration.Operations = .live) {
        precondition(Thread.isMainThread, "Display registration must use the main thread.")
        guard displayCallbackRegistration == nil else { return }
        let registration = DisplayReconfigurationRegistration(application: self, operations: operations)
        displayCallbackRegistration = registration
        registration.start()
    }

    private func unregisterDisplayReconfigurationCallback() {
        displayCallbackRegistration?.stop()
        displayCallbackRegistration = nil
    }

}

private final class CoordinateMapperStore {
    private let lock = NSLock()
    private var storedMapper: CoordinateMapper?
    private var revision: UInt64 = 0
    private var isReconfiguring = false

    var currentMapper: CoordinateMapper? {
        lock.lock()
        defer { lock.unlock() }
        return isReconfiguring ? nil : storedMapper
    }

    var settledRevision: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return isReconfiguring ? nil : revision
    }

    func recordReconfiguration(flags: CGDisplayChangeSummaryFlags) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if flags.contains(.beginConfigurationFlag) {
            revision &+= 1
            isReconfiguring = true
        }
        return revision
    }

    func isCurrent(revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.revision == revision
    }

    func update(_ mapper: CoordinateMapper?, revision: UInt64, completesReconfiguration: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.revision == revision else { return false }
        storedMapper = mapper
        if completesReconfiguration {
            isReconfiguring = false
        }
        return true
    }
}
