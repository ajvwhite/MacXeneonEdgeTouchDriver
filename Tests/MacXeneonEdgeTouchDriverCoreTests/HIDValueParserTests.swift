@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class HIDValueParserTests: XCTestCase {
    func testParsesDownMoveAndUpReports() {
        let parser = HIDValueParser()

        let down = parser.parseReport(reportID: 7, bytes: report(isDown: true, x: 5_224, y: 5_500))
        let repeated = parser.parseReport(reportID: 7, bytes: report(isDown: true, x: 5_224, y: 5_500))
        let move = parser.parseReport(reportID: 7, bytes: report(isDown: true, x: 6_000, y: 5_700))
        let up = parser.parseReport(reportID: 7, bytes: report(isDown: false, x: 6_000, y: 5_700))

        XCTAssertEqual(down?.kind, .down)
        XCTAssertEqual(down?.rawX, 5_224)
        XCTAssertEqual(down?.rawY, 5_500)
        XCTAssertNil(repeated)
        XCTAssertEqual(move?.kind, .move)
        XCTAssertEqual(move?.rawX, 6_000)
        XCTAssertEqual(move?.rawY, 5_700)
        XCTAssertEqual(up?.kind, .up)
    }

    func testIgnoresNonTouchReports() {
        let parser = HIDValueParser()

        XCTAssertNil(parser.parseReport(reportID: 99, bytes: report(isDown: true, x: 1, y: 1)))
        XCTAssertNil(parser.parseReport(reportID: 7, bytes: [0x07, 0x01]))
    }

    func testResetForgetsActiveTouch() {
        let parser = HIDValueParser()

        _ = parser.parseReport(reportID: 7, bytes: report(isDown: true, x: 10, y: 20))
        parser.reset()
        let event = parser.parseReport(reportID: 7, bytes: report(isDown: true, x: 10, y: 20))

        XCTAssertEqual(event?.kind, .down)
    }

    func testObservationRetainsStationaryPressAndReceiptTimestamp() {
        let parser = HIDValueParser()
        let sourceID = HIDSourceID(rawValue: 123)
        let down = parser.parseObservation(sourceID: sourceID, reportID: 7,
                                           bytes: report(isDown: true, x: 10, y: 20),
                                           timestamp: DispatchTime(uptimeNanoseconds: 100))
        let heartbeatTimestamp = DispatchTime(uptimeNanoseconds: 200)
        let heartbeat = parser.parseObservation(sourceID: sourceID, reportID: 7,
                                                bytes: report(isDown: true, x: 10, y: 20),
                                                timestamp: heartbeatTimestamp)
        XCTAssertEqual(down?.event?.kind, .down)
        XCTAssertEqual(heartbeat?.sourceID, sourceID)
        XCTAssertEqual(heartbeat?.contactEpoch, 1)
        XCTAssertEqual(heartbeat?.isPressed, true)
        XCTAssertEqual(heartbeat?.timestamp, heartbeatTimestamp)
        XCTAssertNil(heartbeat?.event)
    }

    func testContactEpochAdvancesOnlyForNewPressedCycleAndSurvivesReset() {
        let parser = HIDValueParser()
        let sourceID = HIDSourceID(rawValue: 123)
        func parse(_ isDown: Bool, x: Int = 10) -> HIDTouchObservation? {
            parser.parseObservation(sourceID: sourceID, reportID: 7,
                                    bytes: report(isDown: isDown, x: x, y: 20))
        }
        XCTAssertEqual(parse(false)?.contactEpoch, 0)
        XCTAssertEqual(parse(false)?.contactEpoch, 0)
        XCTAssertEqual(parse(true)?.contactEpoch, 1)
        XCTAssertEqual(parse(true, x: 11)?.contactEpoch, 1)
        XCTAssertEqual(parse(false)?.contactEpoch, 1)
        XCTAssertEqual(parse(false)?.contactEpoch, 1)
        XCTAssertEqual(parse(true)?.contactEpoch, 2)
        parser.reset()
        let fresh = parse(true)
        XCTAssertEqual(fresh?.event?.kind, .down)
        XCTAssertEqual(fresh?.contactEpoch, 3)
    }

    func testInvalidObservationDoesNotMutateEpochOrNormalization() {
        let parser = HIDValueParser()
        let sourceID = HIDSourceID(rawValue: 123)
        XCTAssertNil(parser.parseObservation(sourceID: sourceID, reportID: 99,
                                              bytes: report(isDown: true, x: 10, y: 20)))
        XCTAssertNil(parser.parseObservation(sourceID: sourceID, reportID: 7, bytes: [7, 1]))
        let down = parser.parseObservation(sourceID: sourceID, reportID: 7,
                                           bytes: report(isDown: true, x: 10, y: 20))
        XCTAssertEqual(down?.contactEpoch, 1)
        XCTAssertEqual(down?.event?.kind, .down)
        XCTAssertNil(parser.parseObservation(sourceID: sourceID, reportID: 99,
                                              bytes: report(isDown: false, x: 50, y: 60)))
        XCTAssertNil(parser.parseObservation(sourceID: sourceID, reportID: 7, bytes: [7, 0]))
        let repeated = parser.parseObservation(sourceID: sourceID, reportID: 7,
                                               bytes: report(isDown: true, x: 10, y: 20))
        XCTAssertEqual(repeated?.contactEpoch, 1)
        XCTAssertEqual(repeated?.isPressed, true)
        XCTAssertNil(repeated?.event)
    }

    func testPublicParserAndObservationPathShareOneNormalizationState() {
        let parser = HIDValueParser()
        let sourceID = HIDSourceID(rawValue: 123)
        let bytes = report(isDown: true, x: 10, y: 20)
        XCTAssertEqual(parser.parseReport(reportID: 7, bytes: bytes)?.kind, .down)
        let heartbeat = parser.parseObservation(sourceID: sourceID, reportID: 7, bytes: bytes)
        XCTAssertEqual(heartbeat?.contactEpoch, 1)
        XCTAssertNil(heartbeat?.event)
        XCTAssertEqual(parser.parseReport(reportID: 7, bytes: report(isDown: false, x: 10, y: 20))?.kind, .up)
        let fresh = parser.parseObservation(sourceID: sourceID, reportID: 7, bytes: bytes)
        XCTAssertEqual(fresh?.contactEpoch, 2)
        XCTAssertEqual(fresh?.event?.kind, .down)
    }

    private func report(isDown: Bool, x: Int, y: Int) -> [UInt8] {
        [
            0x07,
            isDown ? 0x01 : 0x00,
            UInt8(x & 0xFF),
            UInt8((x >> 8) & 0xFF),
            UInt8(y & 0xFF),
            UInt8((y >> 8) & 0xFF),
            0x00
        ]
    }
}
