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
    private var didRegisterDisplayCallback = false
    private let startupDependencies: DriverStartupDependencies
    private let monitoringOverride: DriverMonitoringHooks?
    private var startupCoordinator: DriverStartupCoordinator?

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
        stop()
    }

    /// Starts one driver lifecycle on the main thread, waiting for permission if needed.
    public func run() -> Int32 {
        precondition(Thread.isMainThread, "Driver lifecycle must run on the main thread.")
        if startupCoordinator == nil {
            DriverLoggers.log(.notice, category: .lifecycle, "Starting Mac Xeneon Edge Touch Driver in single-touch mode.")
            startupCoordinator = DriverStartupCoordinator(
                dependencies: startupDependencies,
                startHardware: { [weak self] in try self?.startMonitoring() },
                stopHardware: { [weak self] in self?.stopMonitoring() }
            )
        }
        return startupCoordinator!.run()
    }

    /// Stops the lifecycle on the main thread. Waiting callbacks are invalidated before teardown.
    public func stop() {
        guard let startupCoordinator else {
            focusRestorer.shutdown()
            return
        }
        precondition(Thread.isMainThread, "Driver lifecycle must stop on the main thread.")
        startupCoordinator.stop()
        // Waiting has no hardware teardown; invalidate any remaining focus work too.
        focusRestorer.shutdown()
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
        focusRestorer.shutdown()
        if let monitoringOverride {
            monitoringOverride.stop()
        } else {
            hidMonitor.stop()
        }
        gestureQueue.sync {
            cancelActiveGesture()
        }
        if monitoringOverride == nil {
            unregisterDisplayReconfigurationCallback()
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

    private func registerDisplayReconfigurationCallback() {
        guard !didRegisterDisplayCallback else {
            return
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)

        if result == .success {
            didRegisterDisplayCallback = true
        } else {
            DriverLoggers.log(.error, category: .display, "CGDisplayRegisterReconfigurationCallback failed with \(result.rawValue).")
        }
    }

    private func unregisterDisplayReconfigurationCallback() {
        guard didRegisterDisplayCallback else {
            return
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, context)

        if result != .success {
            DriverLoggers.log(.error, category: .display, "CGDisplayRemoveReconfigurationCallback failed with \(result.rawValue).")
        }
        didRegisterDisplayCallback = false
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

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, context in
    guard let context else {
        return
    }

    let application = Unmanaged<MacXeneonEdgeTouchDriverApplication>.fromOpaque(context).takeUnretainedValue()
    application.enqueueDisplayReconfiguration(flags: flags)
}
