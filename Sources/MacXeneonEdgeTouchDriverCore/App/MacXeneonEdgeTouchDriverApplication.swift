import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Production wiring for independent, persisted touchscreen-to-display sessions.
public final class MacXeneonEdgeTouchDriverApplication {
    private let configuration: DriverConfiguration
    private let displayResolver: DisplayResolver
    private let pairingStore: PairingStore
    private let pairingOverlay: PairingOverlayPresenting
    private let gestureQueue = DispatchQueue(label: "\(DriverLoggers.subsystem).gesture-queue")
    private let inputSink: SyntheticInputSink
    private let cursorController: CursorController
    private let focusRestorerProvider: () -> FocusRestorer

    private lazy var hidMonitor = HIDDeviceMonitor(
        eventQueue: gestureQueue,
        seizeDevice: true,
        touchReportHandler: { [weak self] device, timestamp, event in
            self?.handleHIDReport(device: device, timestamp: timestamp, event: event)
        },
        deviceRemovalHandler: { [weak self] device in self?.handleDeviceRemoval(device) },
        deviceMatchedHandler: { [weak self] device in self?.handleDeviceMatched(device) }
    )

    private var connectedDevices: Set<TouchDeviceIdentity> = []
    private var suppressedUntilUp: Set<TouchDeviceIdentity> = []
    private var sessions: [TouchDeviceIdentity: DeviceTouchSession] = [:]
    private var compatibleDisplays: [DisplaySnapshot] = []
    private var pairingTarget: DisplaySnapshot?
    private var pairingAdvanceWork: DispatchWorkItem?
    private var reconciliationWork: DispatchWorkItem?
    private var screenParametersObserver: NSObjectProtocol?
    private var overlayPresentationAttempt = 0
    private var activeGestureDevice: TouchDeviceIdentity?
    private var stuckGestureTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var didRegisterDisplayCallback = false
    private var isRunning = false

    public convenience init(configuration: DriverConfiguration = .defaults) {
        self.init(
            configuration: configuration,
            displayResolver: DisplayResolver(configuration: configuration.display),
            inputSink: CGEventInputSink(),
            cursorController: CGCursorController(),
            focusRestorerProvider: { AXFocusRestorer() },
            pairingStore: PairingStore(),
            pairingOverlay: PairingOverlayController()
        )
    }

    public init(
        configuration: DriverConfiguration,
        displayResolver: DisplayResolver,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorerProvider: @escaping () -> FocusRestorer = { NoOpFocusRestorer() },
        pairingStore: PairingStore = PairingStore(),
        pairingOverlay: PairingOverlayPresenting = PairingOverlayController()
    ) {
        self.configuration = configuration
        self.displayResolver = displayResolver
        self.inputSink = inputSink
        self.cursorController = cursorController
        self.focusRestorerProvider = focusRestorerProvider
        self.pairingStore = pairingStore
        self.pairingOverlay = pairingOverlay
    }

    deinit { stop() }

    public func run() -> Int32 {
        guard !isRunning else { return EXIT_SUCCESS }
        isRunning = true

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        DriverLoggers.log(.notice, category: .lifecycle, "Starting independent multi-display touch driver.")

        guard verifySyntheticEventPermission() else {
            stop()
            return EXIT_FAILURE
        }

        registerDisplayReconfigurationCallback()
        registerScreenParametersObserver()
        installSignalHandlers()

        do {
            try hidMonitor.start()
        } catch {
            DriverLoggers.log(.fault, category: .lifecycle, "Could not start HID monitor: \(error.localizedDescription)")
            stop()
            return EXIT_FAILURE
        }

        scheduleDisplayReconciliation(reason: "startup", delay: .milliseconds(500))

        CFRunLoopRun()
        return EXIT_SUCCESS
    }

    public func stop() {
        guard isRunning else { return }
        hidMonitor.stop()
        gestureQueue.sync {
            cancelStuckGestureTimer()
            pairingAdvanceWork?.cancel()
            reconciliationWork?.cancel()
            sessions.values.forEach {
                $0.cancelStormRecoveryTimer()
                $0.gesture.forceCancel()
            }
            sessions.removeAll()
            activeGestureDevice = nil
        }
        pairingOverlay.hide()
        unregisterDisplayReconfigurationCallback()
        unregisterScreenParametersObserver()
        signalSources.removeAll()
        isRunning = false
        DriverLoggers.log(.notice, category: .lifecycle, "Stopped multi-display touch driver.")
        CFRunLoopStop(CFRunLoopGetMain())
    }

    func handleDisplayReconfiguration(
        displayID: CGDirectDisplayID,
        flags: CGDisplayChangeSummaryFlags
    ) {
        gestureQueue.async { [weak self] in
            guard let self else { return }
            self.cancelPairingPresentation()

            if flags.contains(.beginConfigurationFlag) {
                return
            }

            let changesMembership = flags.contains(.addFlag) ||
                flags.contains(.removeFlag) ||
                flags.contains(.enabledFlag) ||
                flags.contains(.disabledFlag)
            if changesMembership {
                do {
                    try self.pairingStore.invalidateBootSessionPairing(forDisplayID: displayID)
                } catch {
                    DriverLoggers.log(
                        .error,
                        category: .display,
                        "Could not invalidate pairing after display membership changed: \(error.localizedDescription)"
                    )
                }
            }

            self.scheduleDisplayReconciliation(
                reason: "display reconfiguration for ID \(displayID), flags \(flags.rawValue)"
            )
        }
    }

    func handleDeviceMatched(_ device: TouchDeviceIdentity) {
        connectedDevices.insert(device)
        ensureSession(for: device)
        scheduleDisplayReconciliation(reason: "HID device match at \(device.hexadecimalLocationID)")
    }

    func handleDeviceRemoval(_ device: TouchDeviceIdentity) {
        connectedDevices.remove(device)
        suppressedUntilUp.remove(device)
        sessions[device]?.cancelStormRecoveryTimer()
        if activeGestureDevice == device {
            sessions[device]?.gesture.forceCancel()
            activeGestureDevice = nil
            cancelStuckGestureTimer()
        }
        sessions.removeValue(forKey: device)
        do {
            try pairingStore.invalidateBootSessionPairing(for: device)
        } catch {
            DriverLoggers.log(
                .error,
                category: .display,
                "Could not invalidate pairing after controller removal: \(error.localizedDescription)"
            )
        }
        scheduleDisplayReconciliation(reason: "HID device removal at \(device.hexadecimalLocationID)")
    }

    func handleHIDReport(
        device: TouchDeviceIdentity,
        timestamp: DispatchTime,
        event: TouchEvent?
    ) {
        if let event {
            handleTouchEvent(DeviceTouchEvent(device: device, touch: event))
            return
        }
        if !connectedDevices.contains(device) {
            connectedDevices.insert(device)
            ensureSession(for: device)
        }
        sessions[device]?.validator.recordRawReport(at: timestamp)
    }

    func handleTouchEvent(_ event: DeviceTouchEvent) {
        if !connectedDevices.contains(event.device) {
            connectedDevices.insert(event.device)
            ensureSession(for: event.device)
        }
        guard let session = sessions[event.device] else { return }

        let validation = session.validator.process(event.touch)
        if let trigger = validation.stormStarted {
            suppressedUntilUp.remove(event.device)
            DriverLoggers.log(
                .warning,
                category: .gesture,
                "Touch storm detected on \(event.device.hexadecimalLocationID): \(trigger.rawValue). Entering confidence-tracking mode."
            )
            startStormRecoveryTimer(for: event.device)
        }

        if validation.cancelActiveGesture || validation.rejectedStream {
            session.gesture.forceCancel()
            if activeGestureDevice == event.device { activeGestureDevice = nil }
            cancelStuckGestureTimer()
        }

        for touch in validation.events {
            routeValidatedTouchEvent(DeviceTouchEvent(device: event.device, touch: touch))
        }
    }

    private func routeValidatedTouchEvent(_ event: DeviceTouchEvent) {
        if suppressedUntilUp.contains(event.device) {
            if event.touch.kind == .up {
                suppressedUntilUp.remove(event.device)
            }
            return
        }

        if pairingTarget != nil {
            handlePairingTouch(event)
            return
        }

        if sessions[event.device]?.mapperStore.currentMapper == nil {
            refreshDisplayMappings(reason: "touch without an active paired display")
            if pairingTarget != nil {
                handlePairingTouch(event)
                return
            }
        }

        guard let session = sessions[event.device], session.mapperStore.currentMapper != nil else { return }

        if let activeGestureDevice, activeGestureDevice != event.device {
            DriverLoggers.log(.debug, category: .gesture, "Ignoring simultaneous contact from \(event.device.hexadecimalLocationID).")
            return
        }
        if event.touch.kind == .down {
            activeGestureDevice = event.device
        }

        session.gesture.handle(event.touch)
        if case .idle = session.gesture.state {
            if activeGestureDevice == event.device { activeGestureDevice = nil }
            cancelStuckGestureTimer()
        } else {
            scheduleStuckGestureTimer(for: event.device)
        }
    }

    private func ensureSession(for device: TouchDeviceIdentity) {
        guard sessions[device] == nil else { return }
        let mapperStore = CoordinateMapperStore()
        let gesture = GestureController(
            mapperProvider: { [mapperStore] in mapperStore.currentMapper },
            inputSink: inputSink,
            cursorController: cursorController,
            focusRestorer: focusRestorerProvider(),
            timing: GestureTiming(configuration: configuration.timing, gesture: configuration.gesture),
            doubleClickIntervalProvider: { NSEvent.doubleClickInterval },
            schedulingQueue: gestureQueue
        )
        gesture.onBecameIdle = { [weak self] in
            guard let self else { return }
            if self.activeGestureDevice == device { self.activeGestureDevice = nil }
            self.cancelStuckGestureTimer()
        }
        sessions[device] = DeviceTouchSession(
            mapperStore: mapperStore,
            gesture: gesture,
            validator: TouchStreamValidator()
        )
    }

    func refreshDisplayMappings(reason: String) {
        let activeDisplays = displayResolver.activeDisplays()
        do {
            let removedCount = try pairingStore.reconcileRuntimeDescriptors(
                connectedDevices: connectedDevices,
                displays: activeDisplays
            )
            if removedCount > 0 {
                DriverLoggers.log(
                    .notice,
                    category: .display,
                    "Removed \(removedCount) stale runtime pairing(s) after \(reason)."
                )
            }
        } catch {
            DriverLoggers.log(
                .error,
                category: .display,
                "Could not persist runtime pairing reconciliation: \(error.localizedDescription)"
            )
        }
        compatibleDisplays = displayResolver.matchingDisplays(from: activeDisplays)
        let resolvedDisplays = Dictionary(uniqueKeysWithValues: connectedDevices.compactMap { device in
            pairingStore.resolveDisplay(
                for: device,
                connectedDevices: connectedDevices,
                displays: compatibleDisplays
            ).map { (device, $0) }
        })

        for device in connectedDevices {
            ensureSession(for: device)
            let display = resolvedDisplays[device]
            let mapper = display.map { CoordinateMapper(displayBounds: $0.bounds) }
            if mapper == nil, sessions[device]?.mapperStore.currentMapper != nil {
                sessions[device]?.gesture.forceCancel()
                sessions[device]?.validator.reset()
                sessions[device]?.cancelStormRecoveryTimer()
                if activeGestureDevice == device { activeGestureDevice = nil }
            }
            sessions[device]?.mapperStore.currentMapper = mapper
        }

        DriverLoggers.log(
            .notice,
            category: .display,
            "Display refresh after \(reason): \(compatibleDisplays.count) compatible display(s), \(connectedDevices.count) controller(s), \(resolvedDisplays.count) active pairing(s)."
        )
        beginPairingIfNeeded(resolvedDisplays: resolvedDisplays)
    }

    private func beginPairingIfNeeded(resolvedDisplays: [TouchDeviceIdentity: DisplaySnapshot]? = nil) {
        let resolved = resolvedDisplays ?? Dictionary(uniqueKeysWithValues: connectedDevices.compactMap { device in
            pairingStore.resolveDisplay(
                for: device,
                connectedDevices: connectedDevices,
                displays: compatibleDisplays
            ).map { (device, $0) }
        })
        let unresolved = connectedDevices
            .filter { resolved[$0] == nil }
            .sorted { $0.locationID < $1.locationID }

        let usedDisplayIDs = Set(resolved.values.map(\.displayID))
        let candidates = compatibleDisplays.filter { !usedDisplayIDs.contains($0.displayID) }

        guard !unresolved.isEmpty, let target = candidates.first else {
            pairingTarget = nil
            overlayPresentationAttempt = 0
            pairingOverlay.hide()
            return
        }

        let total = min(connectedDevices.count, compatibleDisplays.count)
        let step = min(resolved.count + 1, total)
        guard pairingOverlay.show(on: target, step: step, total: total) else {
            pairingTarget = nil
            schedulePairingOverlayRetry()
            return
        }

        overlayPresentationAttempt = 0
        pairingTarget = target
        DriverLoggers.log(.notice, category: .display, "Waiting for a raw touch on display ID \(target.displayID).")
    }

    private func handlePairingTouch(_ event: DeviceTouchEvent) {
        guard event.touch.kind == .down, let target = pairingTarget else { return }

        let existingDisplayIsActive = pairingStore.resolveDisplay(
            for: event.device,
            connectedDevices: connectedDevices,
            displays: compatibleDisplays
        ) != nil
        guard !existingDisplayIsActive else {
            DriverLoggers.log(.debug, category: .display, "Ignoring pairing touch from an already resolved controller.")
            return
        }

        do {
            try pairingStore.assign(
                device: event.device,
                to: target,
                connectedDevices: connectedDevices,
                displays: compatibleDisplays
            )
            suppressedUntilUp.insert(event.device)
            pairingTarget = nil
            pairingOverlay.showConfirmation(on: target)
            DriverLoggers.log(.notice, category: .display, "Paired controller \(event.device.hexadecimalLocationID) to display ID \(target.displayID).")
            refreshSessionMapper(for: event.device, display: target)

            pairingAdvanceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.beginPairingIfNeeded() }
            pairingAdvanceWork = work
            gestureQueue.asyncAfter(deadline: .now() + .milliseconds(650), execute: work)
        } catch {
            DriverLoggers.log(.fault, category: .display, "Could not persist touch pairing: \(error.localizedDescription)")
        }
    }

    private func refreshSessionMapper(for device: TouchDeviceIdentity, display: DisplaySnapshot) {
        ensureSession(for: device)
        sessions[device]?.mapperStore.currentMapper = CoordinateMapper(displayBounds: display.bounds)
    }

    private func scheduleStuckGestureTimer(for device: TouchDeviceIdentity) {
        cancelStuckGestureTimer()
        let timer = DispatchSource.makeTimerSource(queue: gestureQueue)
        timer.schedule(deadline: .now() + .milliseconds(configuration.timing.stuckGestureTimeoutMs))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DriverLoggers.log(.warning, category: .gesture, "Touch gesture timed out; forcing cleanup.")
            self.sessions[device]?.gesture.handleIdleTimeout()
            self.stuckGestureTimer = nil
        }
        timer.resume()
        stuckGestureTimer = timer
    }

    private func cancelStuckGestureTimer() {
        stuckGestureTimer?.setEventHandler {}
        stuckGestureTimer?.cancel()
        stuckGestureTimer = nil
    }

    private func startStormRecoveryTimer(for device: TouchDeviceIdentity) {
        guard let session = sessions[device], session.stormRecoveryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: gestureQueue)
        timer.schedule(
            deadline: .now() + .seconds(1),
            repeating: .seconds(1),
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            self?.handleStormRecoveryTick(for: device, at: .now())
        }
        session.stormRecoveryTimer = timer
        session.stormSummaryTickCount = 0
        timer.resume()
    }

    func handleStormRecoveryTick(for device: TouchDeviceIdentity, at timestamp: DispatchTime) {
        guard let session = sessions[device], session.validator.isStormActive else {
            sessions[device]?.cancelStormRecoveryTimer()
            return
        }

        if let recovery = session.validator.recoverIfQuiet(at: timestamp) {
            session.cancelStormRecoveryTimer()
            if recovery.cancelActiveGesture {
                session.gesture.forceCancel()
                if activeGestureDevice == device { activeGestureDevice = nil }
                cancelStuckGestureTimer()
            }
            let duration = Double(
                recovery.snapshot.lastReportAtNanoseconds - recovery.snapshot.startedAtNanoseconds
            ) / 1_000_000_000
            DriverLoggers.log(
                .notice,
                category: .gesture,
                String(
                    format: "Touch storm ended on %@ after %.2fs: reports=%d, accepted=%d, dropped=%d, recoveredContacts=%d. Returning to normal mode.",
                    device.hexadecimalLocationID,
                    duration,
                    recovery.snapshot.totalReports,
                    recovery.snapshot.acceptedSamples,
                    recovery.snapshot.droppedSamples,
                    recovery.snapshot.recoveredContacts
                )
            )
            return
        }

        session.stormSummaryTickCount += 1
        guard session.stormSummaryTickCount.isMultiple(of: 5),
              let snapshot = session.validator.stormSnapshot() else { return }
        let duration = Double(timestamp.uptimeNanoseconds - snapshot.startedAtNanoseconds) / 1_000_000_000
        DriverLoggers.log(
            .notice,
            category: .gesture,
            String(
                format: "Touch storm active on %@ for %.2fs: reports=%d, accepted=%d, dropped=%d, recoveredContacts=%d, tracking=%@.",
                device.hexadecimalLocationID,
                duration,
                snapshot.totalReports,
                snapshot.acceptedSamples,
                snapshot.droppedSamples,
                snapshot.recoveredContacts,
                snapshot.hasAcquiredTrack ? "yes" : "no"
            )
        )
    }

    func hasStormRecoveryTimer(for device: TouchDeviceIdentity) -> Bool {
        sessions[device]?.stormRecoveryTimer != nil
    }

    private func registerDisplayReconfigurationCallback() {
        guard !didRegisterDisplayCallback else { return }
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)
        didRegisterDisplayCallback = result == .success
        if result != .success {
            DriverLoggers.log(.error, category: .display, "CGDisplayRegisterReconfigurationCallback failed with \(result.rawValue).")
        }
    }

    private func unregisterDisplayReconfigurationCallback() {
        guard didRegisterDisplayCallback else { return }
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        _ = CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, context)
        didRegisterDisplayCallback = false
    }

    private func registerScreenParametersObserver() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.gestureQueue.async { [weak self] in
                guard let self else { return }
                self.cancelPairingPresentation()
                self.scheduleDisplayReconciliation(reason: "AppKit screen parameters changed")
            }
        }
    }

    private func unregisterScreenParametersObserver() {
        guard let screenParametersObserver else { return }
        NotificationCenter.default.removeObserver(screenParametersObserver)
        self.screenParametersObserver = nil
    }

    private func scheduleDisplayReconciliation(
        reason: String,
        delay: DispatchTimeInterval = .milliseconds(250)
    ) {
        gestureQueue.async { [weak self] in
            guard let self else { return }
            self.overlayPresentationAttempt = 0
            self.reconciliationWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.refreshDisplayMappings(reason: reason)
            }
            self.reconciliationWork = work
            self.gestureQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func schedulePairingOverlayRetry() {
        guard overlayPresentationAttempt < 20 else {
            DriverLoggers.log(.error, category: .display, "Pairing overlay remained unavailable after bounded retries; waiting for the next display or HID event.")
            return
        }
        overlayPresentationAttempt += 1
        reconciliationWork?.cancel()
        let attempt = overlayPresentationAttempt
        let work = DispatchWorkItem { [weak self] in
            self?.refreshDisplayMappings(reason: "pairing overlay readiness retry \(attempt)")
        }
        reconciliationWork = work
        gestureQueue.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
    }

    private func cancelPairingPresentation() {
        pairingTarget = nil
        pairingAdvanceWork?.cancel()
        pairingAdvanceWork = nil
        pairingOverlay.hide()
    }

    private func installSignalHandlers() {
        signalSources = [SIGINT, SIGTERM].map { signalNumber in
            ignoreDefaultSignalAction(signalNumber)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            return source
        }
    }

    private func verifySyntheticEventPermission() -> Bool {
        if CGPreflightPostEventAccess() { return true }
        logPermissionIdentity()
        if CGRequestPostEventAccess() { return true }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if trusted || CGPreflightPostEventAccess() { return true }
        DriverLoggers.log(.fault, category: .lifecycle, "Synthetic mouse event permission is not granted. Grant Accessibility and restart the driver.")
        return false
    }

    private func logPermissionIdentity() {
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "Unknown executable"
        let launcher = NSRunningApplication(processIdentifier: getppid())?.bundleURL?.path ?? "Unknown launcher"
        DriverLoggers.log(.error, category: .lifecycle, "Permission identity: executable=\(executable), launcher=\(launcher).")
    }

    private func ignoreDefaultSignalAction(_ signalNumber: Int32) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_IGN
        action.sa_flags = 0
        sigemptyset(&action.sa_mask)
        _ = sigaction(signalNumber, &action, nil)
    }
}

private final class DeviceTouchSession {
    let mapperStore: CoordinateMapperStore
    let gesture: GestureController
    let validator: TouchStreamValidator
    var stormRecoveryTimer: DispatchSourceTimer?
    var stormSummaryTickCount = 0

    init(mapperStore: CoordinateMapperStore, gesture: GestureController, validator: TouchStreamValidator) {
        self.mapperStore = mapperStore
        self.gesture = gesture
        self.validator = validator
    }

    deinit {
        cancelStormRecoveryTimer()
    }

    func cancelStormRecoveryTimer() {
        stormRecoveryTimer?.setEventHandler {}
        stormRecoveryTimer?.cancel()
        stormRecoveryTimer = nil
        stormSummaryTickCount = 0
    }
}

private final class CoordinateMapperStore {
    private let lock = NSLock()
    private var storedMapper: CoordinateMapper?

    var currentMapper: CoordinateMapper? {
        get { lock.lock(); defer { lock.unlock() }; return storedMapper }
        set { lock.lock(); storedMapper = newValue; lock.unlock() }
    }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, context in
    guard let context else { return }
    let app = Unmanaged<MacXeneonEdgeTouchDriverApplication>.fromOpaque(context).takeUnretainedValue()
    app.handleDisplayReconfiguration(displayID: displayID, flags: flags)
}
