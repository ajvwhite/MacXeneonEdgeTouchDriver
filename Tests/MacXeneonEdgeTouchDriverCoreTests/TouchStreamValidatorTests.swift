import MacXeneonEdgeTouchDriverCore
import XCTest

final class TouchStreamValidatorTests: XCTestCase {
    func testStableTapPassesWithoutDelayOrRejection() {
        let validator = TouchStreamValidator()
        let down = event(.down, x: 8_000, y: 4_000, milliseconds: 0)
        let up = event(.up, x: 8_000, y: 4_000, milliseconds: 100)

        XCTAssertEqual(validator.process(down), .init(events: [down]))
        XCTAssertEqual(validator.process(up), .init(events: [up]))
    }

    func testCoherentMotionIsBufferedDuringProbationThenReleasedInOrder() {
        let validator = TouchStreamValidator()
        let down = event(.down, x: 1_000, y: 1_000, milliseconds: 0)
        let firstMove = event(.move, x: 2_000, y: 1_100, milliseconds: 20)
        let secondMove = event(.move, x: 3_000, y: 1_200, milliseconds: 40)

        XCTAssertEqual(validator.process(down).events, [down])
        XCTAssertTrue(validator.process(firstMove).events.isEmpty)
        XCTAssertEqual(validator.process(secondMove), .init(events: [firstMove, secondMove]))
    }

    func testHighRateContinuousSwipeRemainsPlausible() {
        let validator = TouchStreamValidator()
        let down = event(.down, x: 1_000, y: 1_000, milliseconds: 0)
        XCTAssertEqual(validator.process(down).events, [down])

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

        XCTAssertEqual(released.count, 5)
        XCTAssertEqual(released.last?.rawX, 3_000)
    }

    func testCapturedStormJumpIsRejectedBeforeAnyMoveEscapes() {
        let validator = TouchStreamValidator()
        let down = event(.down, x: 10_410, y: 6_120, milliseconds: 0)
        let impossibleMove = event(.move, x: 11_264, y: 4_533, milliseconds: 8)

        XCTAssertEqual(validator.process(down).events, [down])
        XCTAssertEqual(
            validator.process(impossibleMove),
            .init(events: [], rejectedStream: true)
        )
    }

    func testStormSuppressionRequiresAQuietInterval() {
        let validator = TouchStreamValidator()
        _ = validator.process(event(.down, x: 10_410, y: 6_120, milliseconds: 0))
        _ = validator.process(event(.move, x: 11_264, y: 4_533, milliseconds: 8))

        XCTAssertTrue(validator.process(event(.up, x: 11_264, y: 4_533, milliseconds: 16)).events.isEmpty)
        XCTAssertTrue(validator.process(event(.down, x: 8_000, y: 4_000, milliseconds: 200)).events.isEmpty)

        let recoveredDown = event(.down, x: 8_000, y: 4_000, milliseconds: 500)
        XCTAssertEqual(validator.process(recoveredDown).events, [recoveredDown])
    }

    func testImpossibleJumpAfterAcceptedMotionRejectsActiveStream() {
        let validator = TouchStreamValidator()
        _ = validator.process(event(.down, x: 1_000, y: 1_000, milliseconds: 0))
        _ = validator.process(event(.move, x: 2_000, y: 1_100, milliseconds: 20))
        _ = validator.process(event(.move, x: 3_000, y: 1_200, milliseconds: 40))

        let rejection = validator.process(event(.move, x: 15_000, y: 9_000, milliseconds: 48))

        XCTAssertTrue(rejection.rejectedStream)
        XCTAssertTrue(rejection.events.isEmpty)
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
            timestamp: DispatchTime(uptimeNanoseconds: 1_000_000_000 + milliseconds * 1_000_000)
        )
    }
}
