import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class GestureSchedulerTests: XCTestCase {
    func testAbsentQueueRunsPositiveDelaySynchronously() {
        let scheduler = DispatchGestureScheduler(queue: nil)
        var didRun = false

        scheduler.schedule(afterMilliseconds: 100) { didRun = true }

        XCTAssertTrue(didRun)
    }

    func testZeroDelayRunsSynchronouslyWithQueue() {
        let scheduler = DispatchGestureScheduler(queue: DispatchQueue(label: "test.gesture-scheduler"))
        var didRun = false

        scheduler.schedule(afterMilliseconds: 0) { didRun = true }

        XCTAssertTrue(didRun)
    }

    func testVirtualTimeRunsDeadlinesInOrderIncludingNewlyScheduledWork() {
        let scheduler = TestGestureScheduler()
        var calls: [String] = []
        scheduler.schedule(afterMilliseconds: 20) { calls.append("later") }
        scheduler.schedule(afterMilliseconds: 10) {
            calls.append("first")
            XCTAssertEqual(scheduler.now.uptimeNanoseconds, 10_000_000)
            scheduler.schedule(afterMilliseconds: 5) { calls.append("nested") }
        }
        scheduler.schedule(afterMilliseconds: 10) { calls.append("second") }

        scheduler.advance(toMilliseconds: 9)
        XCTAssertTrue(calls.isEmpty)
        scheduler.advance(toMilliseconds: 20)

        XCTAssertEqual(calls, ["first", "second", "nested", "later"])
        XCTAssertEqual(scheduler.now.uptimeNanoseconds, 20_000_000)
    }

    func testVirtualTimeCancellationPreventsDelivery() {
        let scheduler = TestGestureScheduler()
        var didRun = false
        let task = scheduler.schedule(afterMilliseconds: 10) { didRun = true }

        task.cancel()
        task.cancel()
        scheduler.advance(byMilliseconds: 20)

        XCTAssertFalse(didRun)
    }

    func testVirtualTimeCanDeliverCancelledWorkToExerciseStaleCallbacks() {
        let scheduler = TestGestureScheduler(executeCancelledActions: true)
        var didRun = false
        let task = scheduler.schedule(afterMilliseconds: 10) { didRun = true }

        task.cancel()
        scheduler.advance(toMilliseconds: 10)

        XCTAssertTrue(didRun)
    }
}
