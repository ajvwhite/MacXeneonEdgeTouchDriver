import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class ExactGestureSchedulerTests: XCTestCase {
    func testNanosecondReplayPreservesSuppliedDispatchTimesWithoutMillisecondRounding() {
        let scheduler = TestGestureScheduler()
        // These authoritative offsets deliberately include sub-millisecond
        // jitter. DispatchTime, not this fixture, applies native tick precision.
        let offsets: [UInt64] = [5_928_750, 13_928_749, 13_929_750]
        for offset in offsets {
            let suppliedTime = DispatchTime(uptimeNanoseconds: offset)
            scheduler.advance(toNanoseconds: suppliedTime.uptimeNanoseconds)
            XCTAssertEqual(scheduler.now, suppliedTime)
        }
        let beforeIncrement = scheduler.now.uptimeNanoseconds
        scheduler.advance(byNanoseconds: 1_000)
        XCTAssertEqual(scheduler.now, DispatchTime(uptimeNanoseconds: beforeIncrement + 1_000))
    }

    func testReportBeforeEqualDeadlineStillRunsEarlierTimersFirst() {
        let scheduler = TestGestureScheduler(executeCancelledActions: true)
        var calls: [String] = []
        scheduler.schedule(afterMilliseconds: 9) { calls.append("earlier timer") }
        let old = scheduler.schedule(afterMilliseconds: 10) { calls.append("canceled timer") }
        let deadline = DispatchTime(uptimeNanoseconds: 10_000_000)
        scheduler.advance(toNanoseconds: deadline.uptimeNanoseconds, beforeDueActions: {
            XCTAssertEqual(scheduler.now, deadline)
            calls.append("report")
            old.cancel()
        })
        XCTAssertEqual(calls, ["earlier timer", "report", "canceled timer"])
        XCTAssertEqual(scheduler.scheduledTaskCount, 2)
    }

    func testBeforeDueActionsProjectsNonrepresentableTargetOnceWithoutBackwardsDrain() {
        let scheduler = TestGestureScheduler(executeCancelledActions: true)
        let rawTarget: UInt64 = 99_999_999
        let suppliedTime = DispatchTime(uptimeNanoseconds: rawTarget)
        var reportTime: DispatchTime?
        scheduler.advance(toNanoseconds: rawTarget, beforeDueActions: {
            reportTime = scheduler.now
        })
        XCTAssertEqual(reportTime, suppliedTime)
        XCTAssertEqual(scheduler.now, suppliedTime)
    }

    func testOrdinaryAdvanceAllowsTimerBeforeEqualDeadlineReport() {
        let scheduler = TestGestureScheduler(executeCancelledActions: true)
        var calls: [String] = []
        scheduler.schedule(afterMilliseconds: 10) { calls.append("timer") }
        scheduler.advance(toNanoseconds: 10_000_000)
        calls.append("report")
        XCTAssertEqual(calls, ["timer", "report"])
    }
}
