import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation

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
    private var signalSources: [DispatchSourceSignal] = []
    private var currentDisplaySnapshot: DisplaySnapshot?
    private var didRegisterDisplayCallback = false
    private var isRunning = false

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
            scheduler: nil
        )
    }

    /// Supplies deterministic scheduling for isolated gesture and watchdog tests.
    init(
        configuration: DriverConfiguration,
        displayResolver: DisplayResolver,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorer: FocusRestorer = NoOpFocusRestorer(),
        scheduler: GestureScheduler?,
        gestureQueue: DispatchQueue? = nil
    ) {
        let gestureQueue = gestureQueue ?? DispatchQueue(label: "\(DriverLoggers.subsystem).gesture-queue")
        self.gestureQueue = gestureQueue
        self.scheduler = scheduler ?? DispatchGestureScheduler(queue: gestureQueue)
        self.configuration = configuration
        self.displayResolver = displayResolver
        self.inputSink = inputSink
        self.cursorController = cursorController
        self.focusRestorer = focusRestorer
    }

    deinit {
        stop()
    }

    /// Starts the driver and runs the main CFRunLoop until stopped.
    public func run() -> Int32 {
        guard !isRunning else {
            return EXIT_SUCCESS
        }

        isRunning = true
        DriverLoggers.log(.notice, category: .lifecycle, "Starting Mac Xeneon Edge Touch Driver in single-touch mode.")
        guard verifySyntheticEventPermission() else {
            stop()
            return EXIT_FAILURE
        }

        registerDisplayReconfigurationCallback()
        gestureQueue.sync {
            refreshDisplayMapping(reason: "startup")
        }
        installSignalHandlers()

        do {
            try hidMonitor.start()
        } catch {
            DriverLoggers.log(.fault, category: .lifecycle, "Could not start HID monitor: \(error.localizedDescription)")
            stop()
            return EXIT_FAILURE
        }

        CFRunLoopRun()
        return EXIT_SUCCESS
    }

    /// Stops monitoring and restores cursor/input state.
    public func stop() {
        guard isRunning else {
            return
        }

        hidMonitor.stop()
        gestureQueue.sync {
            cancelActiveGesture()
        }
        unregisterDisplayReconfigurationCallback()
        signalSources.removeAll()
        isRunning = false

        DriverLoggers.log(.notice, category: .lifecycle, "Stopped Mac Xeneon Edge Touch Driver.")
        CFRunLoopStop(CFRunLoopGetMain())
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
            focusRestorer.discardCapturedWindow()
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

    private func installSignalHandlers() {
        signalSources = [SIGINT, SIGTERM].map { signalNumber in
            ignoreDefaultSignalAction(signalNumber)

            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                DriverLoggers.log(.notice, category: .lifecycle, "Received signal \(signalNumber); stopping driver.")
                self?.stop()
            }
            source.resume()
            return source
        }
    }

    private func verifySyntheticEventPermission() -> Bool {
        if CGPreflightPostEventAccess() {
            DriverLoggers.log(.notice, category: .lifecycle, "CoreGraphics post-event permission is granted.")
            return true
        }

        logPermissionIdentity()
        DriverLoggers.log(.error, category: .lifecycle, "CoreGraphics post-event permission is not granted; requesting permission if macOS will show a prompt.")

        if CGRequestPostEventAccess() {
            DriverLoggers.log(.notice, category: .lifecycle, "CoreGraphics post-event permission was granted after request.")
            return true
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let isAXTrusted = AXIsProcessTrustedWithOptions(options)
        if isAXTrusted || CGPreflightPostEventAccess() {
            DriverLoggers.log(.notice, category: .lifecycle, "Accessibility trust is granted after prompt.")
            return true
        }

        DriverLoggers.log(
            .fault,
            category: .lifecycle,
            "Synthetic mouse event permission is not granted. Grant Accessibility to the executable or to the launcher app named in the previous log line, then restart the driver."
        )
        return false
    }

    private func logPermissionIdentity() {
        let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "Unknown executable"
        let launcherPath = NSRunningApplication(processIdentifier: getppid())?.bundleURL?.path ?? "Unknown launcher"

        DriverLoggers.log(.error, category: .lifecycle, "Permission identity: executable=\(executablePath), launcher=\(launcherPath).")
    }

    private func ignoreDefaultSignalAction(_ signalNumber: Int32) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_IGN
        action.sa_flags = 0
        sigemptyset(&action.sa_mask)

        if sigaction(signalNumber, &action, nil) != 0 {
            DriverLoggers.log(.error, category: .lifecycle, "sigaction failed for signal \(signalNumber).")
        }
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
