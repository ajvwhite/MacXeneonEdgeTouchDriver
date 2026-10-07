import Darwin
import Foundation
import IOKit
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class DriverStartupCoordinatorTests: XCTestCase {
    func testAlreadyReadyWithCGAccessStartsAfterSignalsWithoutRequesting() {
        assertAlreadyReady(SyntheticPermissionSnapshot(postEventAccess: true, accessibilityTrusted: false))
    }

    func testAlreadyReadyWithAXTrustPreservesCompatibility() {
        assertAlreadyReady(SyntheticPermissionSnapshot(postEventAccess: false, accessibilityTrusted: true))
    }

    func testLongWaitRequestsOnceAndDoesNotLogEveryPollOrStartHardware() {
        let harness = StartupTestHarness()
        harness.coordinator.start()
        harness.worker.runRequest()
        harness.worker.completeRequest()
        let initialLogs = harness.logs

        harness.polling.advance(bySeconds: 20_000)
        harness.coordinator.start()

        XCTAssertEqual(harness.coordinator.state, .waitingForPermission)
        XCTAssertEqual(harness.worker.submissionCount, 1)
        XCTAssertEqual(harness.permissions.requestCount, 1)
        XCTAssertEqual(harness.permissions.snapshotCount, 10_002)
        XCTAssertEqual(harness.hardwareStartCount, 0)
        XCTAssertEqual(harness.hardwareStopCount, 0)
        XCTAssertEqual(harness.logs, initialLogs)
        XCTAssertEqual(initialLogs.count, 2)
        XCTAssertEqual(harness.polling.tasks.count, 1)
        XCTAssertEqual(harness.polling.tasks.first?.everySeconds, 2)
        XCTAssertEqual(harness.polling.tasks.first?.leewayMilliseconds, 500)
        XCTAssertEqual(harness.events.prefix(3), ["signals.install", "permission.snapshot", "poll.schedule"])
        XCTAssertLessThan(harness.events.firstIndex(of: "signals.install")!, harness.events.firstIndex(of: "permission.request")!)
    }

    func testGrantWhileWaitingStartsOnceAndCancelsPolling() {
        let harness = StartupTestHarness()
        harness.coordinator.start()
        harness.worker.runRequest()
        harness.worker.completeRequest()
        harness.permissions.currentSnapshot = .cgReady

        harness.polling.advance(bySeconds: 2)
        let readsAtStartup = harness.permissions.snapshotCount
        harness.polling.tasks[0].deliverEvenIfCancelled()
        harness.worker.completeRequest()
        harness.coordinator.start()

        XCTAssertEqual(harness.coordinator.state, .running)
        XCTAssertEqual(harness.hardwareStartCount, 1)
        XCTAssertEqual(harness.permissions.snapshotCount, readsAtStartup)
        XCTAssertTrue(harness.polling.tasks[0].isCancelled)
        XCTAssertEqual(harness.logs.filter { $0.hasPrefix("Synthetic permission state:") }.count, 2)
        XCTAssertEqual(harness.logs.filter { $0.hasPrefix("Waiting for synthetic") }.count, 1)
        XCTAssertEqual(harness.logs.filter { $0.contains("monitoring started") }.count, 1)
    }

    func testRequestCompletionChecksFreshReadinessWithoutTrustingRequestResult() {
        let harness = StartupTestHarness()
        harness.coordinator.start()
        harness.worker.runRequest()
        harness.worker.completeRequest()
        XCTAssertEqual(harness.coordinator.state, .waitingForPermission)
        XCTAssertEqual(harness.hardwareStartCount, 0)

        harness.permissions.currentSnapshot = .axReady
        harness.worker.completeRequest()

        XCTAssertEqual(harness.coordinator.state, .running)
        XCTAssertEqual(harness.hardwareStartCount, 1)
        XCTAssertEqual(harness.permissions.requestCount, 1)
    }

    func testStopWhileWaitingCancelsBeforeCleanupAndRemainsSuccessful() {
        let harness = StartupTestHarness()
        harness.coordinator.start()
        harness.worker.runRequest()
        harness.signals.onCancel = {
            XCTAssertEqual(harness.coordinator.state, .stopped)
            XCTAssertTrue(harness.permissions.requestCancellations[0].isCancelled)
            XCTAssertTrue(harness.polling.tasks[0].isCancelled)
        }

        harness.coordinator.stop()
        harness.coordinator.stop()

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.coordinator.exitStatus, EXIT_SUCCESS)
        XCTAssertEqual(harness.hardwareStartCount, 0)
        XCTAssertEqual(harness.hardwareStopCount, 0)
        XCTAssertEqual(harness.signals.cancelCount, 1)
        XCTAssertEqual(harness.runLoop.stopCount, 1)
    }

    func testRunReturnsSuccessForSIGTERMWhileWaiting() {
        let harness = StartupTestHarness()
        harness.runLoop.onRun = {
            XCTAssertEqual(harness.coordinator.state, .waitingForPermission)
            harness.signals.send(SIGTERM)
        }

        XCTAssertEqual(harness.coordinator.run(), EXIT_SUCCESS)

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.runLoop.runCount, 1)
        XCTAssertEqual(harness.runLoop.stopCount, 1)
        XCTAssertEqual(harness.signals.cancelCount, 1)
        XCTAssertEqual(harness.hardwareStartCount, 0)
        XCTAssertTrue(harness.logs.contains { $0.contains("Received signal \(SIGTERM)") })
    }

    func testRunLoopReturningWhileWaitingIsAnIntentionalSuccessfulStop() {
        let harness = StartupTestHarness()

        XCTAssertEqual(harness.coordinator.run(), EXIT_SUCCESS)

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.runLoop.runCount, 1)
        XCTAssertEqual(harness.hardwareStartCount, 0)
        XCTAssertTrue(harness.polling.tasks[0].isCancelled)
    }

    func testBlockedRequestCompletionAfterStopCannotStartHardware() {
        let harness = StartupTestHarness()
        harness.coordinator.start()
        // Start request work but hold its completion, as if the OS request were blocked.
        harness.worker.runRequest()
        harness.polling.advance(bySeconds: 200)
        harness.coordinator.stop()
        harness.permissions.currentSnapshot = .cgReady
        let readsAtStop = harness.permissions.snapshotCount

        harness.worker.completeRequest()

        XCTAssertTrue(harness.permissions.requestCancellations[0].isCancelled)
        XCTAssertEqual(harness.permissions.snapshotCount, readsAtStop)
        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.coordinator.exitStatus, EXIT_SUCCESS)
        XCTAssertEqual(harness.hardwareStartCount, 0)
    }

    func testQueuedRequestCancelledBeforeExecutionNeverCallsProvider() {
        let harness = StartupTestHarness()
        harness.coordinator.start()
        harness.coordinator.stop()
        let readsAtStop = harness.permissions.snapshotCount

        harness.worker.runRequest()
        harness.worker.completeRequest()

        XCTAssertEqual(harness.worker.submissionCount, 1)
        XCTAssertEqual(harness.permissions.requestCount, 0)
        XCTAssertEqual(harness.permissions.snapshotCount, readsAtStop)
        XCTAssertEqual(harness.hardwareStartCount, 0)
    }

    func testCancelledTimerDeliveredLateCannotReadPermissionsOrStartHardware() {
        let harness = StartupTestHarness()
        harness.coordinator.start()
        harness.polling.tasks[0].onCancel = { harness.polling.tasks[0].deliverEvenIfCancelled() }
        harness.coordinator.stop()
        let readsAtStop = harness.permissions.snapshotCount
        harness.permissions.currentSnapshot = .cgReady

        for _ in 0..<10 { harness.polling.tasks[0].deliverEvenIfCancelled() }
        harness.signals.send(SIGTERM)
        harness.coordinator.start()

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.permissions.snapshotCount, readsAtStop)
        XCTAssertEqual(harness.hardwareStartCount, 0)
        XCTAssertEqual(harness.signals.cancelCount, 1)
    }

    func testSynchronousPollGrantBeforeScheduleReturnsCancelsReturnedTask() {
        let harness = StartupTestHarness()
        harness.polling.onSchedule = { task in
            harness.permissions.currentSnapshot = .cgReady
            task.deliverEvenIfCancelled()
        }

        harness.coordinator.start()

        XCTAssertEqual(harness.coordinator.state, .running)
        XCTAssertEqual(harness.hardwareStartCount, 1)
        XCTAssertTrue(harness.polling.tasks[0].isCancelled)
        XCTAssertEqual(harness.worker.submissionCount, 0)
        XCTAssertEqual(harness.permissions.requestCount, 0)
    }

    func testSynchronousStopBeforeScheduleReturnsCancelsReturnedTask() {
        let harness = StartupTestHarness()
        harness.polling.onSchedule = { task in
            harness.coordinator.stop()
            harness.permissions.currentSnapshot = .cgReady
            task.deliverEvenIfCancelled()
        }

        harness.coordinator.start()

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertTrue(harness.polling.tasks[0].isCancelled)
        XCTAssertEqual(harness.worker.submissionCount, 0)
        XCTAssertEqual(harness.hardwareStartCount, 0)
    }

    func testStopDuringPollingCancellationPreventsHardwareStart() {
        let harness = StartupTestHarness()
        harness.coordinator.start()
        harness.polling.tasks[0].onCancel = { harness.coordinator.stop() }
        harness.permissions.currentSnapshot = .cgReady
        harness.polling.advance(bySeconds: 2)
        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.hardwareStartCount, 0)
        XCTAssertEqual(harness.hardwareStopCount, 0)
        XCTAssertEqual(harness.coordinator.exitStatus, EXIT_SUCCESS)
    }

    func testStopDuringSnapshotDiscardsReadyResult() {
        let harness = StartupTestHarness()
        harness.coordinator.start()
        harness.permissions.onSnapshot = {
            harness.permissions.currentSnapshot = .cgReady
            harness.coordinator.stop()
        }

        harness.polling.advance(bySeconds: 2)

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.hardwareStartCount, 0)
        XCTAssertEqual(harness.coordinator.exitStatus, EXIT_SUCCESS)
    }

    func testSignalDuringSignalInstallationStopsBeforeAnyPermissionWork() {
        let harness = StartupTestHarness()
        harness.signals.onInstall = { harness.signals.send(SIGTERM) }

        harness.coordinator.start()

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.permissions.snapshotCount, 0)
        XCTAssertEqual(harness.polling.tasks.count, 0)
        XCTAssertEqual(harness.worker.submissionCount, 0)
        XCTAssertEqual(harness.hardwareStartCount, 0)
        XCTAssertEqual(harness.signals.cancelCount, 1)
    }

    func testPartialSignalSetupFailureCleansUpAndReturnsFailureWithoutPermissionWork() {
        let harness = StartupTestHarness()
        harness.signals.installError = StartupTestError.signalSetup

        XCTAssertEqual(harness.coordinator.run(), EXIT_FAILURE)

        XCTAssertEqual(harness.coordinator.state, .failed)
        XCTAssertEqual(harness.signals.installCount, 1)
        XCTAssertEqual(harness.signals.cancelCount, 1)
        XCTAssertEqual(harness.runLoop.runCount, 0)
        XCTAssertEqual(harness.permissions.snapshotCount, 0)
        XCTAssertEqual(harness.worker.submissionCount, 0)
        XCTAssertEqual(harness.hardwareStartCount, 0)
        XCTAssertTrue(harness.logs.contains { $0.contains("Could not install startup signals") })
    }

    func testSignalDuringHardwareStartupPreventsRunningStateAndStopsOnce() {
        let harness = StartupTestHarness(snapshot: .cgReady)
        var isOpen = false
        harness.onStartHardware = {
            harness.signals.send(SIGTERM)
            // Acquisition can finish after a nested stop callback returns.
            isOpen = true
        }
        harness.onStopHardware = { isOpen = false }

        harness.coordinator.start()
        XCTAssertFalse(isOpen, "Cleanup must wait for the in-flight startup to return.")
        harness.coordinator.stop()

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.coordinator.exitStatus, EXIT_SUCCESS)
        XCTAssertEqual(harness.hardwareStartCount, 1)
        XCTAssertEqual(harness.hardwareStopCount, 1)
        XCTAssertFalse(harness.logs.contains { $0.contains("monitoring started") })
    }

    func testSignalDuringThrowingHardwareStartupCleansUpAfterUnwindingAndRemainsSuccessful() {
        let harness = StartupTestHarness(snapshot: .cgReady)
        var isOpen = false
        harness.onStartHardware = {
            harness.signals.send(SIGTERM)
            isOpen = true
        }
        harness.hardwareError = HIDDeviceMonitorError.openFailed(kIOReturnNotPermitted)
        harness.onStopHardware = { isOpen = false }

        harness.coordinator.start()
        XCTAssertFalse(isOpen, "A later startup error must still release resources acquired after stop.")
        harness.coordinator.stop()

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.coordinator.exitStatus, EXIT_SUCCESS)
        XCTAssertEqual(harness.hardwareStartCount, 1)
        XCTAssertEqual(harness.hardwareStopCount, 1)
        XCTAssertEqual(harness.signals.cancelCount, 1)
        XCTAssertFalse(harness.logs.contains { $0.contains("monitoring started") })
        XCTAssertFalse(harness.logs.contains { $0.contains("startup failed") })
    }

    func testReadyWhileRequestIsPendingCancelsRequestAndStartsOnlyOnce() {
        let harness = StartupTestHarness()
        harness.coordinator.start()
        harness.permissions.currentSnapshot = .cgReady
        harness.polling.advance(bySeconds: 2)

        harness.worker.runRequest()
        harness.worker.completeRequest()

        XCTAssertEqual(harness.coordinator.state, .running)
        XCTAssertEqual(harness.hardwareStartCount, 1)
        XCTAssertEqual(harness.permissions.requestCount, 0)
    }

    func testHIDExclusiveAccessFailureDoesNotBecomePermissionWaitOrRetry() {
        assertHardwareFailure(result: kIOReturnExclusiveAccess)
    }

    func testHIDDenialWaitsInSameProcessAndRetriesOnlyAfterPositiveGrant() {
        let harness = StartupTestHarness(snapshot: .cgReady)
        harness.hardwareError = HIDDeviceMonitorError.openFailed(kIOReturnNotPermitted)
        harness.coordinator.start()
        XCTAssertEqual(harness.coordinator.state, .waitingForPermission)
        XCTAssertEqual(harness.hardwareStartCount, 1)
        XCTAssertEqual(harness.hardwareStopCount, 1)
        harness.polling.advance(bySeconds: 20)
        XCTAssertEqual(harness.hardwareStartCount, 1, "Unknown HID access must not retry or restart")
        harness.permissions.currentSnapshot = SyntheticPermissionSnapshot(postEventAccess: true,
            accessibilityTrusted: false, hidInputAccess: .denied)
        harness.polling.advance(bySeconds: 20)
        XCTAssertEqual(harness.hardwareStartCount, 1)
        harness.hardwareError = nil
        harness.permissions.currentSnapshot = SyntheticPermissionSnapshot(postEventAccess: true,
            accessibilityTrusted: false, hidInputAccess: .granted)
        harness.polling.advance(bySeconds: 2)
        XCTAssertEqual(harness.coordinator.state, .running)
        XCTAssertEqual(harness.hardwareStartCount, 2)
        XCTAssertEqual(harness.permissions.requestCount, 0)
        XCTAssertEqual(harness.worker.submissionCount, 0)
        harness.coordinator.stop()
        XCTAssertEqual(harness.hardwareStopCount, 2)
    }

    func testKnownHIDDenialDoesNotAttemptHardwareOrRequestSyntheticAccess() {
        let harness = StartupTestHarness(snapshot: SyntheticPermissionSnapshot(postEventAccess: true,
            accessibilityTrusted: false, hidInputAccess: .denied))
        harness.coordinator.start()
        XCTAssertEqual(harness.coordinator.state, .waitingForPermission)
        XCTAssertEqual(harness.hardwareStartCount, 0)
        XCTAssertEqual(harness.worker.submissionCount, 0)
        harness.signals.send(SIGTERM)
        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.coordinator.exitStatus, EXIT_SUCCESS)
    }

    func testRunReturnsFailureWhenGrantLaterRevealsHardwareError() {
        let harness = StartupTestHarness()
        let error = HIDDeviceMonitorError.openFailed(kIOReturnExclusiveAccess)
        harness.hardwareError = error
        harness.runLoop.onRun = {
            harness.permissions.currentSnapshot = .cgReady
            harness.polling.advance(bySeconds: 2)
        }

        XCTAssertEqual(harness.coordinator.run(), EXIT_FAILURE)
        harness.worker.runRequest()
        harness.worker.completeRequest()
        harness.polling.tasks[0].deliverEvenIfCancelled()

        XCTAssertEqual(harness.coordinator.state, .failed)
        XCTAssertEqual(harness.hardwareStartCount, 1)
        XCTAssertEqual(harness.hardwareStopCount, 1)
        XCTAssertEqual(harness.signals.cancelCount, 1)
        XCTAssertEqual(harness.runLoop.runCount, 1)
        XCTAssertEqual(harness.permissions.requestCount, 0)
        XCTAssertTrue(harness.logs.contains { $0.contains(error.localizedDescription) })
    }

    func testReadyRunStopsHardwareOnceWhenRunLoopReturns() {
        let harness = StartupTestHarness(snapshot: .cgReady)

        XCTAssertEqual(harness.coordinator.run(), EXIT_SUCCESS)
        harness.coordinator.stop()

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.hardwareStartCount, 1)
        XCTAssertEqual(harness.hardwareStopCount, 1)
        XCTAssertEqual(harness.signals.cancelCount, 1)
    }

    func testRepeatedAndNestedRunDoNotStartAnotherRunLoopOrRequest() {
        let harness = StartupTestHarness()
        harness.runLoop.onRun = {
            XCTAssertEqual(harness.coordinator.run(), EXIT_SUCCESS)
            harness.coordinator.start()
            XCTAssertEqual(harness.coordinator.state, .waitingForPermission)
            harness.signals.send(SIGTERM)
        }

        XCTAssertEqual(harness.coordinator.run(), EXIT_SUCCESS)
        XCTAssertEqual(harness.coordinator.run(), EXIT_SUCCESS)
        harness.coordinator.start()

        XCTAssertEqual(harness.coordinator.state, .stopped)
        XCTAssertEqual(harness.runLoop.runCount, 1)
        XCTAssertEqual(harness.signals.installCount, 1)
        XCTAssertEqual(harness.worker.submissionCount, 1)
        XCTAssertEqual(harness.hardwareStartCount, 0)
    }

    private func assertAlreadyReady(_ snapshot: SyntheticPermissionSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        let harness = StartupTestHarness(snapshot: snapshot)
        harness.coordinator.start()

        XCTAssertEqual(harness.coordinator.state, .running, file: file, line: line)
        XCTAssertEqual(harness.hardwareStartCount, 1, file: file, line: line)
        XCTAssertEqual(harness.permissions.snapshotCount, 1, file: file, line: line)
        XCTAssertEqual(harness.permissions.requestCount, 0, file: file, line: line)
        XCTAssertEqual(harness.worker.submissionCount, 0, file: file, line: line)
        XCTAssertTrue(harness.polling.tasks.isEmpty, file: file, line: line)
        XCTAssertEqual(harness.events, ["signals.install", "permission.snapshot", "hardware.start"], file: file, line: line)
        harness.coordinator.stop()
    }

    private func assertHardwareFailure(result: IOReturn, file: StaticString = #filePath, line: UInt = #line) {
        let harness = StartupTestHarness(snapshot: .cgReady)
        let error = HIDDeviceMonitorError.openFailed(result)
        harness.hardwareError = error

        XCTAssertEqual(harness.coordinator.run(), EXIT_FAILURE, file: file, line: line)
        harness.coordinator.start()
        harness.coordinator.stop()

        XCTAssertEqual(harness.coordinator.state, .failed, file: file, line: line)
        XCTAssertEqual(harness.coordinator.exitStatus, EXIT_FAILURE, file: file, line: line)
        XCTAssertEqual(harness.hardwareStartCount, 1, file: file, line: line)
        XCTAssertEqual(harness.hardwareStopCount, 1, file: file, line: line)
        XCTAssertEqual(harness.worker.submissionCount, 0, file: file, line: line)
        XCTAssertEqual(harness.permissions.requestCount, 0, file: file, line: line)
        XCTAssertTrue(harness.polling.tasks.isEmpty, file: file, line: line)
        XCTAssertEqual(harness.runLoop.runCount, 0, file: file, line: line)
        XCTAssertTrue(harness.logs.contains { $0.contains(error.localizedDescription) }, file: file, line: line)
        XCTAssertFalse(harness.logs.contains { $0.hasPrefix("Waiting for synthetic") }, file: file, line: line)
    }
}

extension SyntheticPermissionSnapshot {
    static var notReady: Self { Self(postEventAccess: false, accessibilityTrusted: false) }
    static var cgReady: Self { Self(postEventAccess: true, accessibilityTrusted: false) }
    static var axReady: Self { Self(postEventAccess: false, accessibilityTrusted: true) }
}

final class StartupTestHarness {
    let permissions: FakeSyntheticPermissionProvider
    let worker = FakePermissionRequestWorker()
    let freshWorker = FakePermissionRequestWorker()
    var useFreshWorker = false
    let polling = FakePermissionPollScheduler()
    let signals = FakeStartupSignals()
    let runLoop = FakeStartupRunLoop()
    var events: [String] = []
    var logs: [String] = []
    var hardwareStartCount = 0
    var hardwareStopCount = 0
    var hardwareError: Error?
    var onStartHardware: (() -> Void)?
    var onStopHardware: (() -> Void)?

    var dependencies: DriverStartupDependencies {
        DriverStartupDependencies(permissions: permissions, requestWorker: worker, polling: polling, signals: signals, runLoop: runLoop,
            freshPermissionWorker: useFreshWorker ? freshWorker : nil)
    }

    lazy var coordinator = DriverStartupCoordinator(
        dependencies: dependencies,
        startHardware: { [unowned self] in
            events.append("hardware.start")
            hardwareStartCount += 1
            onStartHardware?()
            if let hardwareError { throw hardwareError }
        },
        stopHardware: { [unowned self] in
            events.append("hardware.stop")
            hardwareStopCount += 1
            onStopHardware?()
        },
        log: { [unowned self] _, message in logs.append(message) }
    )

    init(snapshot: SyntheticPermissionSnapshot = .notReady) {
        permissions = FakeSyntheticPermissionProvider(snapshot: snapshot)
        permissions.record = { [weak self] in self?.events.append($0) }
        polling.record = { [weak self] in self?.events.append($0) }
        signals.record = { [weak self] in self?.events.append($0) }
    }
}

final class FakeSyntheticPermissionProvider: SyntheticPermissionProviding {
    var supportsFreshSnapshots = false
    var currentFreshSnapshot: SyntheticPermissionSnapshot?
    var onFreshSnapshot: ((StartupCancellation) -> Void)?
    private(set) var freshSnapshotCount = 0
    var currentSnapshot: SyntheticPermissionSnapshot
    var onSnapshot: (() -> Void)?
    var onRequest: ((StartupCancellation) -> Void)?
    var record: ((String) -> Void)?
    private(set) var snapshotCount = 0
    private(set) var requestCount = 0
    private(set) var requestCancellations: [StartupCancellation] = []

    init(snapshot: SyntheticPermissionSnapshot = .notReady) { currentSnapshot = snapshot }

    func snapshot() -> SyntheticPermissionSnapshot {
        snapshotCount += 1
        record?("permission.snapshot")
        onSnapshot?()
        return currentSnapshot
    }

    func freshSnapshot(cancellation: StartupCancellation) -> SyntheticPermissionSnapshot? {
        freshSnapshotCount += 1
        onFreshSnapshot?(cancellation)
        return currentFreshSnapshot
    }

    func requestInitialAccess(cancellation: StartupCancellation) {
        requestCount += 1
        requestCancellations.append(cancellation)
        record?("permission.request")
        onRequest?(cancellation)
    }
}

/// Request execution and completion are separate so a test can model a blocked OS call.
final class FakePermissionRequestWorker: PermissionRequestWorking {
    private var requests: [() -> Void] = []
    private var completions: [() -> Void] = []
    var submissionCount: Int { requests.count }

    func submit(_ request: @escaping () -> Void, completion: @escaping () -> Void) {
        requests.append(request)
        completions.append(completion)
    }

    func runRequest(at index: Int = 0) { requests[index]() }
    func completeRequest(at index: Int = 0) { completions[index]() }
}

/// A virtual clock; no dispatch timers, sleeping, or wall-clock time are involved.
final class FakePermissionPollScheduler: PermissionPollScheduling {
    final class Task: PermissionPollTask {
        let everySeconds: Int
        let leewayMilliseconds: Int
        var nextFire: Int
        private let action: () -> Void
        private(set) var isCancelled = false
        var onCancel: (() -> Void)?

        init(everySeconds: Int, leewayMilliseconds: Int, now: Int, action: @escaping () -> Void) {
            self.everySeconds = everySeconds
            self.leewayMilliseconds = leewayMilliseconds
            nextFire = now + everySeconds
            self.action = action
        }

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            onCancel?()
        }

        func deliverEvenIfCancelled() { action() }
    }

    private(set) var tasks: [Task] = []
    private(set) var nowSeconds = 0
    var onSchedule: ((Task) -> Void)?
    var record: ((String) -> Void)?

    func schedule(everySeconds: Int, leewayMilliseconds: Int, _ action: @escaping () -> Void) -> PermissionPollTask {
        precondition(everySeconds > 0)
        let task = Task(everySeconds: everySeconds, leewayMilliseconds: leewayMilliseconds, now: nowSeconds, action: action)
        tasks.append(task)
        record?("poll.schedule")
        onSchedule?(task)
        return task
    }

    func advance(bySeconds seconds: Int) {
        precondition(seconds >= 0)
        let target = nowSeconds + seconds
        while let task = tasks.filter({ !$0.isCancelled && $0.nextFire <= target }).min(by: { $0.nextFire < $1.nextFire }) {
            nowSeconds = task.nextFire
            task.nextFire += task.everySeconds
            task.deliverEvenIfCancelled()
        }
        nowSeconds = target
    }
}

final class FakeStartupSignals: StartupSignalHandling {
    var installError: Error?
    var onInstall: (() -> Void)?
    var onCancel: (() -> Void)?
    var record: ((String) -> Void)?
    private var handler: ((Int32) -> Void)?
    private(set) var installCount = 0
    private(set) var cancelCount = 0

    func install(_ onSignal: @escaping (Int32) -> Void) throws {
        installCount += 1
        handler = onSignal
        record?("signals.install")
        onInstall?()
        if let installError { throw installError }
    }

    func cancel() {
        cancelCount += 1
        record?("signals.cancel")
        onCancel?()
    }

    // Keep the saved handler to model a delivery queued before cancellation.
    func send(_ signal: Int32) { handler?(signal) }
}

final class FakeStartupRunLoop: StartupRunLoop {
    var onRun: (() -> Void)?
    private(set) var runCount = 0
    private(set) var stopCount = 0

    func run() {
        runCount += 1
        onRun?()
    }

    func stop() { stopCount += 1 }
}

private enum StartupTestError: Error {
    case signalSetup
}
