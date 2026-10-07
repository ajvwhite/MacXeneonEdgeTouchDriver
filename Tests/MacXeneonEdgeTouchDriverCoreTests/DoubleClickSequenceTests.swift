import CoreGraphics
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class DoubleClickSequenceTests: XCTestCase {
    private let target = TouchTargetIdentity(pid: 10, application: "app" as CFString, window: "window" as CFString)
    private let mapper = CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 2560, height: 720))

    func testFingerLandingVariationPairsOnlyOnTheSameHitElement() {
        let button = TouchTargetIdentity(pid: 10, application: "app" as CFString,
                                        window: "window" as CFString, hitElement: "button" as CFString)
        for scenario in ["same", "neighbour", "unknown", "too far"] {
            var sequence = DoubleClickSequence()
            XCTAssertEqual(sequence.begin(at: CGPoint(x: 519, y: 237), timestamp: 0,
                target: button, mapper: mapper, interval: 500_000_000, inputPermit: { true }), 1)
            sequence.completed(at: CGPoint(x: 519, y: 237), timestamp: 20_000_000,
                interval: 500_000_000, dragged: false, posted: true)
            let identity = scenario == "unknown" ? target : scenario == "neighbour" ?
                TouchTargetIdentity(pid: 10, application: "app" as CFString,
                    window: "window" as CFString, hitElement: "next button" as CFString) : button
            let point = scenario == "too far" ? CGPoint(x: 544, y: 237) : CGPoint(x: 526, y: 246)
            XCTAssertEqual(sequence.mayContinue(at: point, timestamp: 134_000_000,
                mapper: mapper, interval: 500_000_000), scenario != "too far")
            XCTAssertEqual(sequence.begin(at: point, timestamp: 134_000_000, target: identity,
                mapper: mapper, interval: 500_000_000, inputPermit: { true }), scenario == "same" ? 2 : 1, scenario)
        }
    }

    func testNearbyCompletedTapsPairAndThirdStartsNewSequence() {
        var sequence = DoubleClickSequence()
        XCTAssertEqual(begin(&sequence, at: 0), 1)
        finish(&sequence, at: 20)
        XCTAssertEqual(begin(&sequence, at: 100), 2)
        finish(&sequence, at: 120)
        XCTAssertEqual(begin(&sequence, at: 200), 1)
    }

    func testDistanceDeadlineAndUnknownTargetKeepClicksSeparate() {
        for scenario in ["distance", "deadline", "unknown", "window", "geometry", "clock"] {
            var sequence = DoubleClickSequence()
            _ = begin(&sequence, at: 100); finish(&sequence, at: 120)
            let point = scenario == "distance" ? CGPoint(x: 5, y: 0) : .zero
            let timestamp: UInt64 = scenario == "deadline" ? 600 : scenario == "clock" ? 99 : 200
            let identity = scenario == "unknown" ? nil : scenario == "window" ?
                TouchTargetIdentity(pid: 10, application: "app" as CFString, window: "other" as CFString) : target
            let geometry = scenario == "geometry" ? CoordinateMapper(displayBounds: CGRect(x: 1, y: 0, width: 2560, height: 720)) : mapper
            XCTAssertEqual(sequence.begin(at: point, timestamp: timestamp * 1_000_000,
                target: identity, mapper: geometry, interval: 500_000_000, inputPermit: { true }), 1, scenario)
        }
    }

    func testDragFailedPostingLongHoldAndCancellationBreakPair() {
        for scenario in ["drag", "failed", "hold", "cancel"] {
            var sequence = DoubleClickSequence()
            _ = begin(&sequence, at: 0)
            sequence.completed(at: .zero, timestamp: scenario == "hold" ? 600_000_000 : 20_000_000,
                interval: 500_000_000, dragged: scenario == "drag", posted: scenario != "failed")
            if scenario == "cancel" { sequence.reset() }
            XCTAssertEqual(begin(&sequence, at: 100), 1, scenario)
        }
    }

    func testInterveningPhysicalInputBreaksPair() {
        var sequence = DoubleClickSequence()
        var permitted = true
        _ = sequence.begin(at: .zero, timestamp: 0, target: target, mapper: mapper,
                           interval: 500_000_000, inputPermit: { permitted })
        finish(&sequence, at: 20)
        permitted = false
        XCTAssertEqual(begin(&sequence, at: 100), 1)
    }

    private func begin(_ sequence: inout DoubleClickSequence, at ms: UInt64) -> Int {
        sequence.begin(at: .zero, timestamp: ms * 1_000_000, target: target,
                       mapper: mapper, interval: 500_000_000, inputPermit: { true })
    }
    private func finish(_ sequence: inout DoubleClickSequence, at ms: UInt64) {
        sequence.completed(at: .zero, timestamp: ms * 1_000_000, interval: 500_000_000,
                           dragged: false, posted: true)
    }
}
