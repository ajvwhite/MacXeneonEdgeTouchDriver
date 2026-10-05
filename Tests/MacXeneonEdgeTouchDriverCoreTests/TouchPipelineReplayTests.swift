import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class TouchPipelineReplayTests: XCTestCase {
    func testHealthyTapRunsProductionFilterAndBalancesButtons() throws {
        let records = [sample(0, true), sample(8, true), sample(16, false)]
        let report = try TouchPipelineReplay.run(records)
        XCTAssertEqual(report.mouseDownPosts, 1)
        XCTAssertEqual(report.mouseUpPosts, 1)
        XCTAssertEqual(report.dragPosts, 0)
        XCTAssertTrue(report.finalInputBalanced)
        XCTAssertEqual(report.metrics.timings["hidToMouseDownPost"]?.count, 1)
        XCTAssertEqual(report.metrics.timings["hidUpToMouseUpPost"]?.p50Milliseconds, 20)
        XCTAssertTrue(report.measurement.contains("simulated"))
        XCTAssertNil(report.metrics.timings["focusRestoration"], "Fake focus cannot establish AX latency")
    }

    func testRemovedHeldSourceReleasesWithoutGhostReplacementClick() throws {
        let records = [sample(0, true), sample(8, true),
            HIDReportTraceRecord(kind: .removal, sourceID: 1, timestampNanoseconds: 24_000_000),
            sample(32, true, source: 2), sample(40, true, source: 2)]
        let report = try TouchPipelineReplay.run(records)
        XCTAssertEqual(report.mouseDownPosts, 1)
        XCTAssertEqual(report.mouseUpPosts, 1)
        XCTAssertTrue(report.finalInputBalanced)
    }

    func testUnorderedOrInvalidTraceFailsBeforeReplay() {
        XCTAssertThrowsError(try TouchPipelineReplay.run([sample(8, true), sample(0, false)]))
        var malformed = sample(0, true); malformed.schemaVersion = 2
        XCTAssertThrowsError(try TouchPipelineReplay.run([malformed]))
        malformed = sample(0, true); malformed.bytes = Array(repeating: 0, count: 257)
        XCTAssertThrowsError(try TouchPipelineReplay.run([malformed]))
    }

    func testOptionalScrollReplayNeverPostsMousePress() throws {
        var configuration = DriverConfiguration.defaults
        configuration.gesture.mode = .scroll
        let records = [sample(0, true), sample(8, true), sample(24, true, x: 5200), sample(40, false, x: 5200)]
        let report = try TouchPipelineReplay.run(records, configuration: configuration)
        XCTAssertEqual(report.mouseDownPosts, 0)
        XCTAssertEqual(report.mouseUpPosts, 0)
        XCTAssertEqual(report.scrollPosts, 1)
        XCTAssertTrue(report.finalInputBalanced)
    }

    func testQueuedDragReplacesIntermediateMovesAndPreservesRelease() throws {
        var records = [sample(0, true), sample(8, true), sample(24, true, x: 5100),
                       sample(32, true, x: 5200), sample(40, true, x: 5300), sample(48, false, x: 5300)]
        for index in records.indices { records[index].deliveryTimestampNanoseconds = 100_000_000 }
        let report = try TouchPipelineReplay.run(records)
        XCTAssertEqual(report.mouseDownPosts, 1)
        XCTAssertEqual(report.mouseUpPosts, 1)
        XCTAssertEqual(report.dragPosts, 2)
        XCTAssertEqual(report.metrics.counters["coalescedMoves"], 1)
        XCTAssertTrue(report.finalInputBalanced)
        XCTAssertEqual(report.metrics.timings["rawReportQueueDelay"]?.count, 6)
    }

    func testStaleQueuedPressCannotBecomeGhostClick() throws {
        var records = [sample(0, true), sample(8, true), sample(16, false)]
        for index in records.indices { records[index].deliveryTimestampNanoseconds = 200_000_000 }
        let report = try TouchPipelineReplay.run(records)
        XCTAssertEqual(report.mouseDownPosts, 0)
        XCTAssertEqual(report.mouseUpPosts, 0)
        XCTAssertTrue(report.finalInputBalanced)
    }

    private func sample(_ ms: UInt64, _ pressed: Bool, source: UInt64 = 1, x: UInt16 = 5000) -> HIDReportTraceRecord {
        HIDReportTraceRecord(sourceID: source, timestampNanoseconds: ms * 1_000_000,
            bytes: [7, pressed ? 1 : 0, UInt8(x & 255), UInt8(x >> 8), 184, 11, 0])
    }
}
