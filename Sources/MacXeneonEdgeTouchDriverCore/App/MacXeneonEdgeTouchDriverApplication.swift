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
    private let gestureQueue = DispatchQueue(label: "\(DriverLoggers.subsystem).gesture-queue")
    private let inputSink: SyntheticInputSink
    private let cursorController: CursorController
    private let focusRestorer: FocusRestorer

    private lazy var gestureController = GestureController(
        mapperProvider: { [mapperStore] in
            mapperStore.currentMapper
        },
        inputSink: inputSink,
        cursorController: cursorController,
        focusRestorer: focusRestorer,
        timing: GestureTiming(configuration: configuration.timing),
        schedulingQueue: gestureQueue
    )

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

    private var stuckGestureTimer: DispatchSourceTimer?
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
            focusRestorer: AXFocusRestorer()
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
            focusRestorer: focusRestorer,
            startupDependencies: .live,
            monitoringOverride: nil
        )
    }

    init(
        configuration: DriverConfiguration,
        displayResolver: DisplayResolver,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorer: FocusRestorer = NoOpFocusRestorer(),
        startupDependencies: DriverStartupDependencies,
        monitoringOverride: DriverMonitoringHooks?
    ) {
        self.startupDependencies = startupDependencies
        self.monitoringOverride = monitoringOverride
        self.configuration = configuration
        self.displayResolver = displayResolver
        self.inputSink = inputSink
        self.cursorController = cursorController
        self.focusRestorer = focusRestorer
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
        guard let startupCoordinator else { return }
        precondition(Thread.isMainThread, "Driver lifecycle must stop on the main thread.")
        startupCoordinator.stop()
    }

    private func startMonitoring() throws {
        gestureController.onBecameIdle = { [weak self] in
            self?.cancelStuckGestureTimer()
        }
        if let monitoringOverride {
            try monitoringOverride.start()
            return
        }
        refreshDisplayMapping(reason: "startup")
        registerDisplayReconfigurationCallback()
        try hidMonitor.start()
    }

    private func stopMonitoring() {
        if let monitoringOverride {
            monitoringOverride.stop()
        } else {
            hidMonitor.stop()
        }
        gestureQueue.sync {
            cancelStuckGestureTimer()
            gestureController.forceCancel()
        }
        if monitoringOverride == nil {
            unregisterDisplayReconfigurationCallback()
        }
    }

    fileprivate func handleDisplayReconfiguration() {
        gestureQueue.async { [weak self] in
            self?.refreshDisplayMapping(reason: "display reconfiguration")
        }
    }

    private func refreshDisplayMapping(reason: String) {
        displayResolver.refresh()
        mapperStore.currentMapper = displayResolver.currentMapper

        if let bounds = displayResolver.currentBounds {
            DriverLoggers.log(
                .notice,
                category: .display,
                "Resolved Xeneon Edge display after \(reason): x=\(bounds.origin.x), y=\(bounds.origin.y), width=\(bounds.width), height=\(bounds.height)."
            )
        } else {
            DriverLoggers.log(.error, category: .display, "Could not resolve Xeneon Edge display after \(reason). Touch events will be dropped.")
            gestureQueue.async { [weak self] in
                self?.cancelStuckGestureTimer()
                self?.gestureController.forceCancel()
            }
        }
    }

    func handleTouchEvent(_ event: TouchEvent) {
        if mapperStore.currentMapper == nil {
            refreshDisplayMapping(reason: "touch event without display mapper")
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

    private func handleDeviceRemoval() {
        cancelStuckGestureTimer()
        gestureController.forceCancel()
    }

    private func scheduleStuckGestureTimer() {
        cancelStuckGestureTimer()

        let timer = DispatchSource.makeTimerSource(queue: gestureQueue)
        timer.schedule(deadline: .now() + .milliseconds(configuration.timing.stuckGestureTimeoutMs))
        timer.setEventHandler { [weak self] in
            DriverLoggers.log(.warning, category: .gesture, "Touch gesture timed out without an up event; forcing cleanup.")
            self?.gestureController.handleIdleTimeout()
            self?.stuckGestureTimer = nil
        }
        timer.resume()
        stuckGestureTimer = timer
    }

    private func cancelStuckGestureTimer() {
        stuckGestureTimer?.setEventHandler {}
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

    var currentMapper: CoordinateMapper? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedMapper
        }
        set {
            lock.lock()
            storedMapper = newValue
            lock.unlock()
        }
    }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, context in
    guard let context else {
        return
    }

    let application = Unmanaged<MacXeneonEdgeTouchDriverApplication>.fromOpaque(context).takeUnretainedValue()
    application.handleDisplayReconfiguration()
}
