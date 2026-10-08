import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class TouchStreamFilterTests: XCTestCase {
    func testShortTapConfirmedByRelease() {
        var filter = TouchStreamFilter()
        XCTAssertTrue(filter.process(report(0, true)).observations.isEmpty)
        let result = filter.process(report(3, false))
        XCTAssertEqual(result.observations.compactMap(\.event).map(\.kind), [.down, .up])
        XCTAssertEqual(result.observations.map(\.contactEpoch), [1, 1])
    }

    func testStationaryHoldPreservesHeartbeatsWithoutMoves() {
        var filter = TouchStreamFilter()
        _ = filter.process(report(0, true))
        XCTAssertEqual(filter.process(report(8, true)).observations.compactMap(\.event).map(\.kind), [.down])
        for t in stride(from: 16, through: 3000, by: 8) {
            let result = filter.process(report(t, true))
            XCTAssertEqual(result.observations.count, 1)
            XCTAssertNil(result.observations[0].event)
            XCTAssertFalse(result.cancelContact)
        }
        XCTAssertEqual(filter.process(report(3008, false)).observations.first?.event?.kind, .up)
    }

    func testImpossibleJumpCancelsAndEntersStorm() {
        var filter = TouchStreamFilter()
        _ = filter.process(report(0, true)); _ = filter.process(report(8, true))
        let result = filter.process(report(9, true, x: 16_000, y: 9000))
        XCTAssertTrue(result.cancelContact)
        XCTAssertTrue(result.enteredStorm)
        XCTAssertTrue(result.observations.isEmpty)
    }

    func testNoiseOnlyAlternatingCornersCannotAcquireTouch() {
        var filter = stormFilter()
        for t in stride(from: 10, through: 100, by: 8) {
            // Two competing stable clusters must not be mistaken for one finger.
            let x = (t / 8) % 2 == 0 ? 16_000 : 100
            let result = filter.process(report(t, true, x: x, y: 9000 - x / 2))
            XCTAssertTrue(result.observations.isEmpty)
        }
    }

    func testRecoverTouchAmidFarOutliers() {
        var filter = stormFilter()
        var results: [HIDTouchObservation] = []
        for (index, t) in [20, 28, 36, 44].enumerated() {
            results += filter.process(report(t, true, x: 5000, y: 3000)).observations
            let noise = [(16_000, 9000), (100, 9000), (16_000, 100), (100, 100)][index]
            results += filter.process(report(t + 1, true, x: noise.0, y: noise.1)).observations
        }
        XCTAssertEqual(results.compactMap(\.event).filter { $0.kind == .down }.count, 1)
        XCTAssertEqual(results.first?.rawX, 5000)
        XCTAssertTrue(filter.isStorming)
    }

    func testOutlierReleaseCannotEndTrackOrRenewConfidence() {
        var filter = acquiredStormFilter()
        let outlier = filter.process(report(50, false, x: 16_000, y: 9000))
        XCTAssertTrue(outlier.observations.isEmpty)
        XCTAssertFalse(outlier.cancelContact)
        XCTAssertFalse(filter.advance(to: 163_999_999).cancelContact)
        XCTAssertTrue(filter.advance(to: 164_000_000).cancelContact)
        XCTAssertFalse(filter.advance(to: 165_000_000).cancelContact)
    }

    func testNoReportTimerCancelsExpiredTrackBeforeQuietRecovery() {
        var filter = acquiredStormFilter()
        XCTAssertEqual(filter.nextDeadline, 164_000_000)
        XCTAssertTrue(filter.advance(to: 164_000_000).cancelContact)
        XCTAssertTrue(filter.isStorming)
        XCTAssertTrue(filter.advance(to: 1_044_000_000).recoveredFromStorm)
        XCTAssertFalse(filter.isStorming)
    }

    func testReportAtConfidenceDeadlineCannotContinueOldDrag() {
        var filter = acquiredStormFilter()
        let result = filter.process(report(164, true, x: 5001, y: 3000))
        XCTAssertTrue(result.cancelContact)
        XCTAssertTrue(result.observations.isEmpty)
    }

    func testPlausibleReleaseUsesLastAcceptedPosition() {
        var filter = acquiredStormFilter()
        let result = filter.process(report(50, false, x: 5005, y: 3003))
        XCTAssertEqual(result.observations.first?.event?.kind, .up)
        XCTAssertEqual(result.observations.first?.rawX, 5000)
        XCTAssertFalse(result.cancelContact)
    }

    func testStaleForeignAndInvalidReportsDoNotRenewTrack() {
        var filter = acquiredStormFilter()
        XCTAssertTrue(filter.process(report(44, true)).observations.isEmpty)
        XCTAssertTrue(filter.process(report(45, true, source: 2)).observations.isEmpty)
        XCTAssertTrue(filter.process(report(46, true, x: 20_000)).observations.isEmpty)
        XCTAssertEqual(filter.nextDeadline, 164_000_000)
    }

    func testNewTrackUsesNewValidatedEpoch() {
        var filter = acquiredStormFilter()
        let epoch = filter.process(report(50, false, x: 5000, y: 3000)).observations[0].contactEpoch
        var next: [HIDTouchObservation] = []
        for t in [60, 68, 76, 84] { next += filter.process(report(t, true, x: 6000, y: 3000)).observations }
        XCTAssertEqual(next.first?.contactEpoch, epoch + 1)
        XCTAssertEqual(next.first?.event?.kind, .down)
    }

    func testSeededNoiseOnlyStreamCannotProduceRecoveredClicks() {
        for seed: UInt64 in [0xA9F021D3, 1, 0xFFFFFFFF, 0xDEADBEEF] {
            var filter = stormFilter()
            var random = seed
            var downs = 0
            for index in 0..<10000 {
                random = random &* 6364136223846793005 &+ 1442695040888963407
                let x = Int((random >> 24) % 16384)
                random = random &* 6364136223846793005 &+ 1442695040888963407
                let y = Int((random >> 24) % 9600)
                let result = filter.process(report(10 + index * 8, index % 3 != 0, x: x, y: y))
                let acceptedDowns = result.observations.compactMap(\.event).filter { $0.kind == .down }.count
                downs += acceptedDowns
            }
            XCTAssertEqual(downs, 0, "Uniform noise has no deliberate contact to recover; seed \(seed)")
        }
    }

    func testCoherentMovingFingerCanAcquireAndThenTurn() {
        var filter = stormFilter()
        var events: [TouchEvent] = []
        for (index, t) in [20, 28, 36, 44].enumerated() {
            events += filter.process(report(t, true, x: 5000 + index * 80, y: 3000)).observations.compactMap(\.event)
        }
        XCTAssertEqual(events.filter { $0.kind == .down }.count, 1)
        XCTAssertEqual(filter.process(report(52, true, x: 5240, y: 3080)).observations.first?.event?.kind, .move)
        XCTAssertEqual(filter.process(report(60, true, x: 5160, y: 3080)).observations.first?.event?.kind, .move)
    }

    private func stormFilter() -> TouchStreamFilter {
        var filter = TouchStreamFilter()
        _ = filter.process(report(0, true)); _ = filter.process(report(1, true, x: 16_000, y: 9000))
        return filter
    }
    private func acquiredStormFilter() -> TouchStreamFilter {
        var filter = stormFilter()
        for t in [20, 28, 36, 44] { _ = filter.process(report(t, true, x: 5000, y: 3000)) }
        return filter
    }
    private func report(_ ms: Int, _ pressed: Bool, x: Int = 5000, y: Int = 3000,
                        source: UInt = 1) -> HIDTouchObservation {
        HIDTouchObservation(sourceID: HIDSourceID(rawValue: source), contactEpoch: 1,
            isPressed: pressed, timestamp: DispatchTime(uptimeNanoseconds: UInt64(ms) * 1_000_000),
            event: nil, rawX: x, rawY: y)
    }
}
