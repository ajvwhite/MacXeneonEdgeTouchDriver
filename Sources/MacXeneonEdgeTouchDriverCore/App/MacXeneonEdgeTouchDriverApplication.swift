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
        }
    )

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
            cancelActiveGesture()
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

    func handleTouchEvent(_ event: TouchEvent) {
        if event.kind == .down {
            refreshDisplayMapping(reason: "touch down")
        }

        gestureController.handle(event)

        switch gestureController.state {
        case .idle:
            cancelStuckGestureTimer()

        case .singleTouch:
            scheduleStuckGestureTimer()
        }
    }

    func handleDeviceMatched() {
        refreshDisplayMapping(reason: "HID device match")
    }

    func handleDeviceRemoval() {
        cancelActiveGesture()
    }

    /// Gesture teardown shared by stop, device removal, and display loss.
    /// Called on the gesture queue in production; tests can exercise it without starting HID.
    func cancelActiveGesture() {
        focusRestorer.discardCapturedWindow()
        cancelStuckGestureTimer()
        gestureController.forceCancel()
    }

    private func scheduleStuckGestureTimer() {
        cancelStuckGestureTimer()

        let generation = stuckGestureTimerGeneration
        let timer = scheduler.schedule(afterMilliseconds: configuration.timing.stuckGestureTimeoutMs) { [weak self] in
            guard let self, self.stuckGestureTimerGeneration == generation else {
                return
            }
            self.stuckGestureTimer = nil
            self.stuckGestureTimerGeneration &+= 1
            DriverLoggers.log(.warning, category: .gesture, "Touch gesture timed out without an up event; forcing cleanup.")
            self.focusRestorer.discardCapturedWindow()
            self.gestureController.handleIdleTimeout()
        }
        if stuckGestureTimerGeneration == generation {
            stuckGestureTimer = timer
        } else {
            // A scheduler may execute a zero-delay timeout before returning its task.
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
