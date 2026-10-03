import Foundation
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
    var frontmostReadCount = 0
    init() { frontmost = original }

    var operations: WorkspaceFocusMonitor.Operations {
        WorkspaceFocusMonitor.Operations(
            frontmostApplication: { self.frontmostReadCount += 1; return self.frontmost },
            application: { $0 == self.original.processIdentifier ? self.original : self.other },
            sessionIsActive: { self.sessionActive },
            observe: { handler in
                self.handlers.append(handler)
                return { self.stopCount += 1 }
            }
        )
    }
}
