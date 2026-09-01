import MacXeneonEdgeTouchDriverCore
import XCTest

final class TouchStreamValidatorTests: XCTestCase {
    func testStableTapIsHeldUntilReleaseThenEmittedAsACompleteContact() {
        let validator = TouchStreamValidator()
        let down = event(.down, x: 8_000, y: 4_000, milliseconds: 0)
        let up = event(.up, x: 8_000, y: 4_000, milliseconds: 100)

        XCTAssertEqual(validator.process(down), .init())
        XCTAssertEqual(validator.process(up), .init(events: [down, up]))
    }

    func testStationarySamplesConfirmAHeldContactWithoutReachingGesturesAsMoves() {
        let validator = TouchStreamValidator()
        let down = event(.down, x: 8_000, y: 4_000, milliseconds: 0)

        XCTAssertTrue(validator.process(down).events.isEmpty)
        XCTAssertTrue(validator.process(event(.move, x: 8_000, y: 4_000, milliseconds: 20)).events.isEmpty)
        XCTAssertEqual(
            validator.process(event(.move, x: 8_000, y: 4_000, milliseconds: 40)).events,
            [down]
        )
        XCTAssertTrue(validator.process(event(.move, x: 8_000, y: 4_000, milliseconds: 48)).events.isEmpty)
    }

    func testCoherentMotionIsBufferedDuringProbationThenReleasedInOrder() {
        let validator = TouchStreamValidator()
        let down = event(.down, x: 1_000, y: 1_000, milliseconds: 0)
        let firstMove = event(.move, x: 2_000, y: 1_100, milliseconds: 20)
        let secondMove = event(.move, x: 3_000, y: 1_200, milliseconds: 40)

        XCTAssertTrue(validator.process(down).events.isEmpty)
        XCTAssertTrue(validator.process(firstMove).events.isEmpty)
        XCTAssertEqual(validator.process(secondMove), .init(events: [down, firstMove, secondMove]))
    }

    func testHighRateContinuousSwipeRemainsPlausible() {
        let validator = TouchStreamValidator()
        let down = event(.down, x: 1_000, y: 1_000, milliseconds: 0)
        XCTAssertTrue(validator.process(down).events.isEmpty)

        var released: [TouchEvent] = []
        for index in 1...5 {
            let move = event(
                .move,
                x: 1_000 + index * 400,
                y: 1_000 + index * 40,
                milliseconds: UInt64(index * 8)
            )
            let result = validator.process(move)
            XCTAssertFalse(result.rejectedStream)
            released.append(contentsOf: result.events)
        }

        XCTAssertEqual(released.count, 6)
        XCTAssertEqual(released.first?.kind, .down)
        XCTAssertEqual(released.last?.rawX, 3_000)
    }

    func testCapturedStormJumpStartsStormBeforeAnyContactEscapes() {
        let validator = TouchStreamValidator()
        let down = event(.down, x: 10_410, y: 6_120, milliseconds: 0)
        let impossibleMove = event(.move, x: 11_264, y: 4_533, milliseconds: 8)

        XCTAssertTrue(validator.process(down).events.isEmpty)
        XCTAssertEqual(
            validator.process(impossibleMove),
            .init(
                rejectedStream: true,
                stormStarted: .severeCoordinateJump
            )
        )
        XCTAssertTrue(validator.isStormActive)
    }

    func testRawReportActivityPreventsStormRecoveryUntilOneSecondOfSilence() {
        let validator = stormingValidator()
        validator.recordRawReport(at: time(milliseconds: 500))

        XCTAssertNil(validator.recoverIfQuiet(at: time(milliseconds: 1_400)))
        let recovery = validator.recoverIfQuiet(at: time(milliseconds: 1_500))

        XCTAssertNotNil(recovery)
        XCTAssertFalse(validator.isStormActive)
        XCTAssertEqual(recovery?.snapshot.totalReports, 2)
    }

    func testFirstPressedSampleAfterRecoveryCanReestablishParserState() {
        let validator = stormingValidator()
        XCTAssertNotNil(validator.recoverIfQuiet(at: time(milliseconds: 1_100)))

        let parserStillPressed = event(.move, x: 8_000, y: 4_000, milliseconds: 1_200)
        let release = event(.up, x: 8_000, y: 4_000, milliseconds: 1_300)

        XCTAssertTrue(validator.process(parserStillPressed).events.isEmpty)
        XCTAssertEqual(validator.process(release).events.map(\.kind), [.down, .up])
    }

    func testImpossibleJumpAfterAcceptedMotionCancelsActiveGestureAndStartsStorm() {
        let validator = TouchStreamValidator()
        _ = validator.process(event(.down, x: 1_000, y: 1_000, milliseconds: 0))
        _ = validator.process(event(.move, x: 2_000, y: 1_100, milliseconds: 20))
        _ = validator.process(event(.move, x: 3_000, y: 1_200, milliseconds: 40))

        let rejection = validator.process(event(.move, x: 15_000, y: 9_000, milliseconds: 48))

        XCTAssertTrue(rejection.rejectedStream)
        XCTAssertTrue(rejection.cancelActiveGesture)
        XCTAssertEqual(rejection.stormStarted, .severeCoordinateJump)
        XCTAssertTrue(rejection.events.isEmpty)
    }

    func testStormModeExtractsAStableTapFromInterleavedOutliers() {
        let validator = stormingValidator()
        let reports = [
            event(.down, x: 8_000, y: 4_000, milliseconds: 20),
            event(.move, x: 200, y: 9_000, milliseconds: 28),
            event(.move, x: 8_010, y: 4_005, milliseconds: 36),
            event(.move, x: 15_000, y: 300, milliseconds: 44),
            event(.move, x: 8_020, y: 4_010, milliseconds: 52),
            event(.move, x: 8_030, y: 4_015, milliseconds: 68)
        ]

        var output: [TouchEvent] = []
        for report in reports {
            output.append(contentsOf: validator.process(report).events)
        }

        XCTAssertEqual(output.first?.kind, .down)
        XCTAssertEqual(output.first?.rawX, 8_000)
        XCTAssertEqual(output.last?.rawX, 8_030)

        let release = validator.process(event(.up, x: 8_032, y: 4_015, milliseconds: 84))
        XCTAssertEqual(release.events.map(\.kind), [.up])
        XCTAssertEqual(validator.stormSnapshot()?.recoveredContacts, 1)
    }

    func testStormModeTracksCoherentMovementAndDropsDistantSamples() {
        let validator = stormingValidator()
        let reports = [
            event(.down, x: 2_000, y: 2_000, milliseconds: 20),
            event(.move, x: 2_300, y: 2_020, milliseconds: 28),
            event(.move, x: 15_000, y: 9_000, milliseconds: 32),
            event(.move, x: 2_600, y: 2_040, milliseconds: 36),
            event(.move, x: 2_900, y: 2_060, milliseconds: 44),
            event(.move, x: 14_500, y: 400, milliseconds: 48),
            event(.move, x: 3_200, y: 2_080, milliseconds: 52)
        ]

        var output: [TouchEvent] = []
        for report in reports {
            output.append(contentsOf: validator.process(report).events)
        }

        XCTAssertEqual(output.first?.kind, .down)
        XCTAssertEqual(output.last?.rawX, 3_200)
        XCTAssertFalse(output.contains { $0.rawX > 10_000 })
        XCTAssertGreaterThanOrEqual(validator.stormSnapshot()?.droppedSamples ?? 0, 1)
    }

    func testRandomStormDataDoesNotAcquireATrack() {
        let validator = stormingValidator()
        let points = [
            (100, 100), (15_000, 9_000), (300, 8_500), (14_000, 200),
            (7_000, 9_200), (16_000, 4_000), (1_000, 7_000), (12_000, 1_000)
        ]

        var output: [TouchEvent] = []
        for (index, point) in points.enumerated() {
            output.append(contentsOf: validator.process(event(
                index == 0 ? .down : .move,
                x: point.0,
                y: point.1,
                milliseconds: UInt64(20 + index * 8)
            )).events)
        }

        XCTAssertTrue(output.isEmpty)
        XCTAssertEqual(validator.stormSnapshot()?.hasAcquiredTrack, false)
    }

    private func stormingValidator() -> TouchStreamValidator {
        let validator = TouchStreamValidator()
        _ = validator.process(event(.down, x: 10_410, y: 6_120, milliseconds: 0))
        _ = validator.process(event(.move, x: 11_264, y: 4_533, milliseconds: 8))
        XCTAssertTrue(validator.isStormActive)
        return validator
    }

    private func event(
        _ kind: TouchEvent.Kind,
        x: Int,
        y: Int,
        milliseconds: UInt64
    ) -> TouchEvent {
        TouchEvent(
            kind: kind,
            contactID: 0,
            rawX: x,
            rawY: y,
            timestamp: time(milliseconds: milliseconds)
        )
    }

    private func time(milliseconds: UInt64) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: 1_000_000_000 + milliseconds * 1_000_000)
    }
}
