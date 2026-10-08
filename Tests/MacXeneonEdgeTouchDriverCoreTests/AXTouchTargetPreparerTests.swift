import CoreGraphics
import Foundation
import XCTest
@testable import MacXeneonEdgeTouchDriverCore

final class AXTouchTargetPreparerTests: XCTestCase {
    func testPassivePanelDoesNotActivateItsApplicationButStillChecksTarget() {
        let f = ActivationFixture(); f.backend.requiresActivation = false
        f.prepare(); f.worker.run(); f.main.run(); f.worker.run(); f.main.run(); f.callback.run()
        XCTAssertEqual(f.application.activations, 0)
        XCTAssertFalse(f.application.isActive)
        XCTAssertEqual(f.backend.focusCount, 1)
        XCTAssertEqual(f.results, [true])
    }

    func testPassivePanelLossBeforeCallbackRejectsClick() {
        let f = ActivationFixture(); f.backend.requiresActivation = false
        f.prepare(); f.worker.run(); f.main.run(); f.worker.run()
        f.application.isHidden = true
        f.main.run(); f.callback.run()
        XCTAssertEqual(f.results, [false])
        XCTAssertEqual(f.application.activations, 0)
    }

    func testActivationRequestWaitsForObservedActiveStateBeforeWindowMutation() {
        let f = ActivationFixture()
        f.prepare(); f.worker.run(); f.main.run()
        XCTAssertEqual(f.application.activations, 1)
        XCTAssertEqual(f.backend.focusCount, 0)
        XCTAssertTrue(f.results.isEmpty)
        f.application.isActive = true
        f.retry.run(); f.worker.run(); f.main.run(); f.callback.run()
        XCTAssertEqual(f.backend.focusCount, 1)
        XCTAssertEqual(f.results, [true])
    }

    func testUnconfirmedActivationExpiresWithoutWindowMutation() {
        let f = ActivationFixture()
        f.prepare(); f.worker.run(); f.main.run()
        f.now = 80_000_000
        f.retry.run(); f.callback.run()
        XCTAssertEqual(f.backend.focusCount, 0)
        XCTAssertEqual(f.results, [false])
    }

    func testActivationAtDeadlineCannotBeAcceptedLate() {
        let f = ActivationFixture()
        f.prepare(); f.worker.run(); f.main.run()
        f.now = 80_000_000; f.application.isActive = true
        f.retry.run(); f.callback.run()
        XCTAssertEqual(f.backend.focusCount, 0)
        XCTAssertEqual(f.results, [false])
    }

    func testCancelBeforeResolutionPreventsAllAXAndApplicationWork() {
        let f = ActivationFixture()
        f.prepare(); f.preparer.cancel(); f.worker.run(); f.callback.run()
        XCTAssertEqual(f.backend.resolveCount, 0)
        XCTAssertEqual(f.application.activations, 0)
        XCTAssertTrue(f.results.isEmpty)
    }

    func testCancelDuringActivationWaitPreventsQueuedWindowMutation() {
        let f = ActivationFixture()
        f.prepare(); f.worker.run(); f.main.run()
        f.preparer.cancel(); f.application.isActive = true
        f.retry.run(); f.callback.run()
        XCTAssertEqual(f.backend.focusCount, 0)
        XCTAssertTrue(f.results.isEmpty)
        f.prepare(); f.worker.run(); f.main.run(); f.worker.run(); f.main.run(); f.callback.run()
        XCTAssertEqual(f.results, [true])
    }

    func testCancellationBeforeCallbackRevokesCompletedActivation() {
        let f = ActivationFixture(); f.application.isActive = true
        f.prepare(); f.worker.run(); f.main.run(); f.worker.run(); f.main.run()
        f.preparer.cancel(); f.callback.run()
        XCTAssertTrue(f.results.isEmpty)
    }

    func testApplicationLossAfterWindowConfirmationRejectsContact() {
        let f = ActivationFixture(); f.application.isActive = true
        f.prepare(); f.worker.run(); f.main.run(); f.worker.run()
        f.application.isHidden = true
        f.main.run(); f.callback.run()
        XCTAssertEqual(f.results, [false])
    }

    func testPhysicalChoiceDuringEarlierFocusCaptureRejectsTargetActivation() {
        let f = ActivationFixture()
        f.preparer.beginContact()
        f.inputUnchanged = false
        f.prepare(); f.worker.run(); f.callback.run()
        XCTAssertEqual(f.backend.resolveCount, 0)
        XCTAssertEqual(f.application.activations, 0)
        XCTAssertEqual(f.results, [false])
    }

    func testPhysicalChoiceBeforeGestureCallbackRevokesReadyTarget() {
        let f = ActivationFixture(); f.application.isActive = true
        f.prepare(); f.worker.run(); f.main.run(); f.worker.run(); f.main.run()
        f.inputUnchanged = false
        f.callback.run()
        XCTAssertEqual(f.results, [false])
    }

    func testBusyPreparationCannotBuildUnboundedAXQueue() {
        let f = ActivationFixture()
        f.prepare()
        for _ in 0..<100 { f.prepare() }
        XCTAssertEqual(f.worker.tasks.count, 1)
        XCTAssertEqual(f.results, Array(repeating: false, count: 100))
        f.worker.run(); f.callback.run()
        XCTAssertEqual(f.backend.resolveCount, 0)
    }
}

private final class ActivationQueue {
    var tasks: [() -> Void] = []
    func enqueue(_ task: @escaping () -> Void) { tasks.append(task) }
    func run() { XCTAssertFalse(tasks.isEmpty); if !tasks.isEmpty { tasks.removeFirst()() } }
}

private final class ActivationFixture {
    let worker = ActivationQueue(), main = ActivationQueue(), callback = ActivationQueue(), retry = ActivationQueue()
    let application = ActivationApplication()
    let backend = ActivationBackend()
    var now: UInt64 = 0
    var results: [Bool] = []
    var inputUnchanged = true
    lazy var preparer = AXTouchTargetPreparer(backend: backend,
        onWorker: worker.enqueue, onMain: main.enqueue, onCallback: callback.enqueue,
        retryOnMain: retry.enqueue, now: { self.now }, application: { _ in self.application },
        captureInputPermit: { { self.inputUnchanged } })
    func prepare() { preparer.prepare(at: CGPoint(x: 10, y: 10)) { self.results.append($0) } }
}

private final class ActivationApplication: TouchTargetApplication {
    var isActive = false, isTerminated = false, isHidden = false
    var activations = 0
    func activate() -> Bool { activations += 1; return true }
}

private final class ActivationBackend: AXTouchTargetResolving {
    var resolveCount = 0, focusCount = 0
    var requiresActivation = true
    func resolve(at point: CGPoint, permit: () -> Bool) -> AXTouchTargetBackend.Target? {
        resolveCount += 1
        let element = AXFocusElement(rawValue: "window" as NSString)
        return AXTouchTargetBackend.Target(application: element, window: element, pid: 33, requiresActivation: requiresActivation)
    }
    func focusWindow(_ target: AXTouchTargetBackend.Target, at point: CGPoint, permit: () -> Bool) -> Bool {
        focusCount += 1; return true
    }
}
