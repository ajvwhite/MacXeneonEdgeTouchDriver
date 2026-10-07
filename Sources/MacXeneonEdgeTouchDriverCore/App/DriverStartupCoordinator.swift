import Darwin
import Foundation
import IOKit

protocol StartupRunLoop {
    func run()
    func stop()
}

struct MainStartupRunLoop: StartupRunLoop {
    func run() {
        // Keep the loop alive even before HID has registered any sources.
        var context = CFRunLoopSourceContext()
        let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)!
        let loop = CFRunLoopGetMain()
        CFRunLoopAddSource(loop, keepAlive, .defaultMode)
        defer { CFRunLoopSourceInvalidate(keepAlive) }
        CFRunLoopRun()
    }
    func stop() { CFRunLoopStop(CFRunLoopGetMain()) }
}

struct DriverStartupDependencies {
    let permissions: SyntheticPermissionProviding
    let requestWorker: PermissionRequestWorking
    let polling: PermissionPollScheduling
    let signals: StartupSignalHandling
    let runLoop: StartupRunLoop
    var freshPermissionWorker: PermissionRequestWorking? = nil
    var refreshPermissionProcess: (() throws -> Void)? = nil

    static var live: DriverStartupDependencies {
        DriverStartupDependencies(
            permissions: SystemSyntheticPermissionProvider(),
            requestWorker: DispatchPermissionRequestWorker(),
            polling: DispatchPermissionPollScheduler(),
            signals: DispatchStartupSignals(),
            runLoop: MainStartupRunLoop(),
            freshPermissionWorker: DispatchPermissionRequestWorker(label: "permission-check"),
            refreshPermissionProcess: { try PermissionProcessRefresh.live.perform() }
        )
    }
}

/// One startup attempt, owned by the main lifecycle queue. All callbacks except
/// request work return to that queue. Terminal states cannot restart hardware.
final class DriverStartupCoordinator {
    enum State: Equatable {
        case idle, installingSignals, waitingForPermission, startingHardware, running, stopped, failed
    }

    private let dependencies: DriverStartupDependencies
    private let startHardware: () throws -> Void
    private let stopHardware: () -> Void
    private let releaseFailedHardware: () -> Void
    private let log: (DriverLogLevel, String) -> Void
    private var requestCancellation = StartupCancellation()
    private var poll: PermissionPollTask?
    private var generation: UInt64 = 0
    private var didAttemptHardware = false
    private var isStartingHardware = false
    private var waitingForHIDGrant = false
    private var lastSnapshot: SyntheticPermissionSnapshot?
    private var freshSnapshot: SyntheticPermissionSnapshot?
    private var freshCheckPending = false
    private var freshCheckID: UInt64 = 0
    private var requiresFreshHIDGrant = false
    private(set) var state: State = .idle
    private(set) var exitStatus: Int32 = EXIT_SUCCESS

    init(
        dependencies: DriverStartupDependencies,
        startHardware: @escaping () throws -> Void,
        stopHardware: @escaping () -> Void,
        releaseFailedHardware: (() -> Void)? = nil,
        log: @escaping (DriverLogLevel, String) -> Void = { DriverLoggers.log($0, category: .lifecycle, $1) }
    ) {
        self.dependencies = dependencies
        self.startHardware = startHardware
        self.stopHardware = stopHardware
        self.releaseFailedHardware = releaseFailedHardware ?? stopHardware
        self.log = log
    }

    func run() -> Int32 {
        precondition(Thread.isMainThread, "Driver lifecycle must run on the main thread.")
        guard state == .idle else { return exitStatus }
        start()
        if state == .waitingForPermission || state == .running {
            dependencies.runLoop.run()
            stop()
        }
        return exitStatus
    }

    func start() {
        precondition(Thread.isMainThread, "Driver lifecycle must run on the main thread.")
        guard state == .idle else { return }
        state = .installingSignals
        do {
            try dependencies.signals.install { [weak self] signal in
                guard let self, self.state != .stopped, self.state != .failed else { return }
                self.log(.notice, "Received signal \(signal); stopping driver.")
                self.stop()
            }
        } catch {
            fail("Could not install startup signals: \(error.localizedDescription)")
            return
        }
        guard state == .installingSignals else { return }
        state = .waitingForPermission
        checkReadiness()
        guard state == .waitingForPermission else { return }

        ensurePermissionPoll()
        guard state == .waitingForPermission, !waitingForHIDGrant,
              lastSnapshot?.hasRequiredSyntheticAccess != true else { return }
        let currentGeneration = generation
        let permissions = dependencies.permissions
        let cancellation = requestCancellation
        dependencies.requestWorker.submit({
            guard !cancellation.isCancelled else { return }
            permissions.requestInitialAccess(cancellation: cancellation)
        }, completion: { [weak self] in
            self?.checkReadiness(generation: currentGeneration)
        })
    }

    private func ensurePermissionPoll() {
        guard state == .waitingForPermission, poll == nil else { return }
        let currentGeneration = generation
        let task = dependencies.polling.schedule(everySeconds: 2, leewayMilliseconds: 500) { [weak self] in
            self?.checkReadiness(generation: currentGeneration)
        }
        guard state == .waitingForPermission, generation == currentGeneration else { task.cancel(); return }
        poll = task
    }

    func stop() {
        precondition(Thread.isMainThread, "Driver lifecycle must stop on the main thread.")
        guard state != .stopped, state != .failed else { return }
        finish(as: .stopped)
    }

    private func checkReadiness(generation expectedGeneration: UInt64? = nil, allowFreshCheck: Bool = true) {
        guard state == .waitingForPermission,
              expectedGeneration == nil || expectedGeneration == generation else { return }
        let snapshot = freshSnapshot ?? dependencies.permissions.snapshot()
        // A dependency may deliver stop while a check is in progress.
        guard state == .waitingForPermission else { return }
        let snapshotChanged = snapshot != lastSnapshot
        if snapshotChanged {
            lastSnapshot = snapshot
            log(.notice, "Synthetic permission state: CG post-event access=\(snapshot.postEventAccess), AX trusted=\(snapshot.accessibilityTrusted), HID listen access=\(snapshot.hidInputAccess.rawValue).")
        }
        guard snapshot.isReady, !waitingForHIDGrant || snapshot.hidInputAccess == .granted,
              !requiresFreshHIDGrant else {
            if snapshot.hasRequiredSyntheticAccess {
                if snapshotChanged || expectedGeneration == nil {
                    log(.notice, "Waiting for HID Input Monitoring access. Grant access to the executable or launcher; startup will continue automatically.")
                }
            } else if snapshotChanged || expectedGeneration == nil {
                log(.notice, "Waiting for synthetic event permission. Enable Device Control and Data Access (Accessibility on earlier macOS) for the executable or launcher; startup will continue automatically.")
            }
            if allowFreshCheck { requestFreshSnapshot() }
            return
        }

        let needsProcessRefresh = freshSnapshot != nil && dependencies.refreshPermissionProcess != nil
            && (waitingForHIDGrant || dependencies.permissions.snapshot().hidInputAccess != .granted)
        guard state == .waitingForPermission else { return }
        if needsProcessRefresh, let refresh = dependencies.refreshPermissionProcess {
            // A fresh check can see approval while this process or its device
            // objects retain denial. Replace the process image before acquiring
            // HID; the replacement carries a one-refresh limit across exec.
            state = .startingHardware
            invalidateWaiting()
            dependencies.signals.cancel()
            do {
                log(.notice, "Refreshing driver startup after Input Monitoring approval.")
                try refresh()
                // A real exec never returns. Test replacements return here.
                finish(as: .stopped)
            } catch {
                log(.fault, "Could not refresh permission state: \(error.localizedDescription). Restart the driver after checking its permissions.")
                // Exit normally so launchd cannot turn a failed refresh into
                // an automatic relaunch loop. Monitoring has not started.
                exitStatus = EXIT_SUCCESS
                finish(as: .failed)
            }
            return
        }

        state = .startingHardware
        invalidateWaiting()
        guard state == .startingHardware else { return }
        didAttemptHardware = true
        isStartingHardware = true
        let result = Result { try startHardware() }
        isStartingHardware = false
        guard state == .startingHardware else {
            // A nested stop must wait for acquisition to unwind before releasing it.
            stopAttemptedHardware()
            return
        }
        switch result {
        case .success:
            state = .running
            log(.notice, "Permission readiness accepted; driver monitoring started.")
        case .failure(let error):
            if case HIDDeviceMonitorError.openFailed(kIOReturnNotPermitted) = error {
                // Release any partial acquisition before waiting in this process.
                // A current HID permission grant is required before another open attempt;
                // unknown/denied state never loops through permission prompts.
                stopAttemptedHardware(finalStop: false)
                guard state == .startingHardware else { return }
                waitingForHIDGrant = true
                requestCancellation = StartupCancellation()
                freshSnapshot = nil
                requiresFreshHIDGrant = dependencies.permissions.supportsFreshSnapshots
                    && dependencies.freshPermissionWorker != nil
                state = .waitingForPermission
                log(.notice, "HID access denied; waiting for Input Monitoring permission without restarting: \(error.localizedDescription)")
                ensurePermissionPoll()
            } else {
                fail("Could not start driver monitoring: \(error.localizedDescription)")
            }
        }
    }

    private func requestFreshSnapshot() {
        guard state == .waitingForPermission, !freshCheckPending,
              dependencies.permissions.supportsFreshSnapshots,
              let worker = dependencies.freshPermissionWorker else { return }
        freshCheckPending = true
        freshCheckID &+= 1
        let currentID = freshCheckID
        let currentGeneration = generation
        let permissions = dependencies.permissions
        let cancellation = requestCancellation
        let result = PermissionSnapshotBox()
        worker.submit({
            guard !cancellation.isCancelled else { return }
            result.store(permissions.freshSnapshot(cancellation: cancellation))
        }, completion: { [weak self] in
            guard let self, self.state == .waitingForPermission,
                  self.generation == currentGeneration, self.freshCheckPending,
                  self.freshCheckID == currentID else { return }
            self.freshCheckPending = false
            if let snapshot = result.read() {
                self.freshSnapshot = snapshot
                self.requiresFreshHIDGrant = false
            }
            // A denied result waits for the next timer tick; completion never
            // starts an immediate chain of new checks.
            self.checkReadiness(generation: currentGeneration, allowFreshCheck: false)
        })
    }

    private func stopAttemptedHardware(finalStop: Bool = true) {
        guard didAttemptHardware else { return }
        didAttemptHardware = false
        if finalStop { stopHardware() } else { releaseFailedHardware() }
    }

    private func fail(_ message: String) {
        guard state != .stopped, state != .failed else { return }
        exitStatus = EXIT_FAILURE
        log(.fault, message)
        finish(as: .failed)
    }

    private func invalidateWaiting() {
        generation &+= 1
        freshCheckPending = false
        requestCancellation.cancel()
        poll?.cancel()
        poll = nil
    }

    private func finish(as terminalState: State) {
        state = terminalState
        invalidateWaiting()
        if !isStartingHardware {
            stopAttemptedHardware()
        }
        dependencies.signals.cancel()
        log(terminalState == .failed ? .fault : .notice, terminalState == .failed ? "Driver startup failed." : "Stopped Mac Xeneon Edge Touch Driver.")
        dependencies.runLoop.stop()
    }
}
