import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class DriverPerformanceMetricsTests: XCTestCase {
    func testPercentilesAndTotalCountsUseBoundedRecentWindow() {
        let metrics = DriverPerformanceMetrics(capacity: 4)
        for value: UInt64 in 1...6 { metrics.record("latency", from: 0, to: value * 1_000_000) }
        let distribution = metrics.snapshot().timings["latency"]!
        XCTAssertEqual(distribution.count, 6)
        XCTAssertEqual(distribution.retainedSamples, 4)
        XCTAssertEqual(distribution.p50Milliseconds, 4)
        XCTAssertEqual(distribution.p95Milliseconds, 6)
        XCTAssertEqual(distribution.p99Milliseconds, 6)
    }

    func testClockReversalDoesNotBecomeHugeLatency() {
        let metrics = DriverPerformanceMetrics()
        metrics.record("latency", from: 10, to: 9)
        XCTAssertTrue(metrics.snapshot().timings.isEmpty)
    }

    func testConcurrentProducersKeepCountsAndSnapshotsConsistent() {
        let metrics = DriverPerformanceMetrics(capacity: 8)
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            metrics.record("latency", from: 0, to: UInt64(index))
            metrics.increment("reports")
            _ = metrics.snapshot()
        }
        XCTAssertEqual(metrics.snapshot().timings["latency"]?.count, 1000)
        XCTAssertEqual(metrics.snapshot().timings["latency"]?.retainedSamples, 8)
        XCTAssertEqual(metrics.snapshot().counters["reports"], 1000)
    }
}
