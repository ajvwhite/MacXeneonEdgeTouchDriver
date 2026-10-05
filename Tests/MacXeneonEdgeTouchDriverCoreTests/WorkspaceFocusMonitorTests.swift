import Foundation
import os
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class WorkspaceFocusMonitorTests: XCTestCase {
    func testSnapshotsReadFreshWorkspaceAndHintsOnlyAdvanceRevision() {
        onMain {
            let effects = WorkspaceOperationsFake()
            let monitor = WorkspaceFocusMonitor(operations: effects.operations)
            var observations: [FocusObservationEvent] = []
            monitor.start { observations.append($0) }
            let first = monitor.snapshot()
            effects.frontmost = effects.other
            effects.handlers[0](.focusChanged)
            let second = monitor.snapshot()
            XCTAssertEqual(effects.frontmostReadCount, 2)
            XCTAssertTrue(first.application!.isSameApplication(as: effects.original))
            XCTAssertTrue(second.application!.isSameApplication(as: effects.other))
            XCTAssertEqual(second.revision, first.revision + 1)
            XCTAssertEqual(observations.count, 1)
            monitor.stop()
        }
    }

    func testWakeCannotReactivateAnInactiveUserSession() {
        onMain {
            let effects = WorkspaceOperationsFake()
            let monitor = WorkspaceFocusMonitor(operations: effects.operations)
            monitor.start { _ in }
            XCTAssertTrue(monitor.snapshot().sessionActive)
            effects.handlers[0](.sessionActive(false))
            effects.handlers[0](.sleeping(true))
            effects.handlers[0](.sleeping(false))
            XCTAssertFalse(monitor.snapshot().sessionActive)
            effects.handlers[0](.sessionActive(true))
            XCTAssertTrue(monitor.snapshot().sessionActive)
            monitor.stop()
        }
    }

    func testUnknownOrInactiveInitialSessionPreventsEligibility() {
        onMain {
            let effects = WorkspaceOperationsFake()
            let monitor = WorkspaceFocusMonitor(operations: effects.operations)
            effects.sessionActive = nil
            XCTAssertFalse(monitor.snapshot().sessionActive)
            effects.sessionActive = false
            XCTAssertFalse(monitor.snapshot().sessionActive)
            effects.sessionActive = true
            XCTAssertTrue(monitor.snapshot().sessionActive)
        }
    }

    func testStopIsIdempotentAndOldRegistrationCannotAffectNewSession() {
        onMain {
            let effects = WorkspaceOperationsFake()
            let monitor = WorkspaceFocusMonitor(operations: effects.operations)
            var observations = 0
            monitor.start { _ in observations += 1 }
            monitor.start { _ in observations += 1 }
            XCTAssertEqual(effects.handlers.count, 1)
            let old = effects.handlers[0]
            monitor.stop()
            monitor.stop()
            XCTAssertEqual(effects.stopCount, 1)
            monitor.start { _ in observations += 1 }
            let before = monitor.snapshot().revision
            old(.lifecycleChanged)
            XCTAssertEqual(monitor.snapshot().revision, before)
            XCTAssertEqual(observations, 0)
            effects.handlers[1](.lifecycleChanged)
            XCTAssertEqual(observations, 1)
            monitor.stop()
        }
    }

    func testOffMainFinalReleaseRetainsRegistrationUntilMainRemovalAndIgnoresQueuedNotification() {
        let notified = expectation(description: "already queued notification delivered")
        let removed = expectation(description: "main-owned registration removed")
        let verified = expectation(description: "main removal and resource release verified")
        onMain {
            let effects = WorkspaceOperationsFake()
            effects.onStop = {
                XCTAssertTrue(Thread.isMainThread)
                removed.fulfill()
            }
            var monitor: WorkspaceFocusMonitor? = WorkspaceFocusMonitor(operations: effects.operations)
            let observations = OSAllocatedUnfairLock(initialState: 0)
            monitor?.start { _ in observations.withLock { $0 += 1 } }
            let weakMonitor = WorkspaceWeakReference(monitor)
            let resource = effects.resources[0]
            let queuedHandler = effects.handlers[0]
            let owner = WorkspaceReleaseOwner(monitor!)
            monitor = nil

            // Queue notification delivery ahead of removal, then keep main occupied
            // until the background owner has made the final release. The callback
            // must be harmless even though NotificationCenter has not removed it yet.
            DispatchQueue.main.async {
                queuedHandler(.focusChanged)
                notified.fulfill()
            }
            guard self.releaseOnBackground(owner) else {
                XCTFail("Background final release did not return; no dependent fixture access follows")
                return
            }
            XCTAssertNil(weakMonitor.value)
            XCTAssertEqual(effects.stopCount, 0)
            XCTAssertEqual(effects.resourceReleaseCount, 0)
            XCTAssertNotNil(resource.value, "The pending removal must retain its registration resources")
            DispatchQueue.main.async {
                XCTAssertEqual(observations.withLock { $0 }, 0)
                XCTAssertEqual(effects.stopCount, 1)
                XCTAssertEqual(effects.resourceReleaseCount, 1)
                XCTAssertNil(resource.value)
                verified.fulfill()
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [notified, removed, verified], timeout: 2), .completed)
    }

    func testExplicitStopThenOffMainFinalReleaseRemovesRegistrationOnlyOnce() {
        let verified = expectation(description: "stopped registration remained removed")
        onMain {
            let effects = WorkspaceOperationsFake()
            var monitor: WorkspaceFocusMonitor? = WorkspaceFocusMonitor(operations: effects.operations)
            let observations = OSAllocatedUnfairLock(initialState: 0)
            monitor?.start { _ in observations.withLock { $0 += 1 } }
            let queuedHandler = effects.handlers[0]
            let resource = effects.resources[0]
            monitor?.stop()
            monitor?.stop()
            XCTAssertEqual(effects.stopCount, 1)
            XCTAssertEqual(effects.resourceReleaseCount, 1)
            XCTAssertNil(resource.value)
            let weakMonitor = WorkspaceWeakReference(monitor)
            let owner = WorkspaceReleaseOwner(monitor!)
            monitor = nil
            guard self.releaseOnBackground(owner) else {
                XCTFail("Background final release did not return; no dependent fixture access follows")
                return
            }
            XCTAssertNil(weakMonitor.value)
            DispatchQueue.main.async {
                queuedHandler(.lifecycleChanged)
                XCTAssertEqual(observations.withLock { $0 }, 0)
                XCTAssertEqual(effects.stopCount, 1)
                XCTAssertEqual(effects.resourceReleaseCount, 1)
                verified.fulfill()
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [verified], timeout: 2), .completed)
    }

    private func releaseOnBackground(_ owner: WorkspaceReleaseOwner) -> Bool {
        precondition(Thread.isMainThread)
        let released = DispatchSemaphore(value: 0)
        DispatchQueue(label: "test.workspace.final-release").async {
            XCTAssertFalse(Thread.isMainThread)
            owner.release()
            released.signal()
        }
        // This deliberately prevents main removal from running until the final
        // release is known to have completed. Production teardown never waits.
        return released.wait(timeout: .now() + 2) == .success
    }

    private func onMain(_ action: () -> Void) {
        if Thread.isMainThread { action() }
        else { DispatchQueue.main.sync(execute: action) }
    }
}

private final class WorkspaceOperationsFake {
    let original = AXFocusWorkspaceApplication(processIdentifier: 10, identity: "original" as NSString,
                                               isTerminated: false, isHidden: false)
    let other = AXFocusWorkspaceApplication(processIdentifier: 20, identity: "other" as NSString,
                                            isTerminated: false, isHidden: false)
    var frontmost: AXFocusWorkspaceApplication?
    var sessionActive: Bool? = true
    var handlers: [(WorkspaceFocusMonitor.Event) -> Void] = []
    var stopCount = 0
    var resourceReleaseCount = 0
    var resources: [WorkspaceWeakReference<WorkspaceRegistrationResource>] = []
    var onStop: (() -> Void)?
    var frontmostReadCount = 0
    init() { frontmost = original }

    var operations: WorkspaceFocusMonitor.Operations {
        WorkspaceFocusMonitor.Operations(
            frontmostApplication: { self.frontmostReadCount += 1; return self.frontmost },
            application: { $0 == self.original.processIdentifier ? self.original : self.other },
            sessionIsActive: { self.sessionActive },
            observe: { handler in
                self.handlers.append(handler)
                let resource = WorkspaceRegistrationResource {
                    XCTAssertTrue(Thread.isMainThread, "Registration resources must be released on main")
                    self.resourceReleaseCount += 1
                }
                self.resources.append(WorkspaceWeakReference(resource))
                return {
                    XCTAssertTrue(Thread.isMainThread, "Registration removal must execute on main")
                    withExtendedLifetime(resource) {
                        self.stopCount += 1
                        self.onStop?()
                    }
                }
            }
        )
    }
}

private final class WorkspaceWeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
}

private final class WorkspaceRegistrationResource {
    private let onRelease: () -> Void
    init(onRelease: @escaping () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}

/// Ownership transfers to the background queue before release. No other caller
/// reads or mutates storage after submission; the semaphore acknowledges release.
private final class WorkspaceReleaseOwner {
    private var monitor: WorkspaceFocusMonitor?
    init(_ monitor: WorkspaceFocusMonitor) { self.monitor = monitor }
    func release() { monitor = nil }
}
