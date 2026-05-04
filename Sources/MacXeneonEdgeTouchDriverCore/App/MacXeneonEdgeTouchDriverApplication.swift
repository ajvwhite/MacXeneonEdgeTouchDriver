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
    private let gestureQueue = DispatchQueue(label: "\(DriverLoggers.subsystem).gesture-queue")
    private let inputSink: SyntheticInputSink
    private let cursorController: CursorController

    private lazy var gestureController = GestureController(
        mapperProvider: { [mapperStore] in
            mapperStore.currentMapper
        },
        inputSink: inputSink,
        cursorController: cursorController,
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
    private var signalSources: [DispatchSourceSignal] = []
    private var didRegisterDisplayCallback = false
    private var isRunning = false

    /// Creates a production application with CoreGraphics side effects.
    public convenience init(configuration: DriverConfiguration = .defaults) {
        self.init(
            configuration: configuration,
            displayResolver: DisplayResolver(configuration: configuration.display),
            inputSink: CGEventInputSink(),
            cursorController: CGCursorController()
        )
    }

    /// Creates an application with injectable side-effect dependencies.
    public init(
        configuration: DriverConfiguration,
        displayResolver: DisplayResolver,
        inputSink: SyntheticInputSink,
        cursorController: CursorController
    ) {
        self.configuration = configuration
        self.displayResolver = displayResolver
        self.inputSink = inputSink
        self.cursorController = cursorController
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
        gestureController.onBecameIdle = { [weak self] in
            self?.cancelStuckGestureTimer()
        }

        guard verifySyntheticEventPermission() else {
            stop()
            return EXIT_FAILURE
        }

        refreshDisplayMapping(reason: "startup")
        registerDisplayReconfigurationCallback()
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
            cancelStuckGestureTimer()
            gestureController.forceCancel()
        }
        unregisterDisplayReconfigurationCallback()
        signalSources.removeAll()
        isRunning = false

        DriverLoggers.log(.notice, category: .lifecycle, "Stopped Mac Xeneon Edge Touch Driver.")
        CFRunLoopStop(CFRunLoopGetMain())
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
