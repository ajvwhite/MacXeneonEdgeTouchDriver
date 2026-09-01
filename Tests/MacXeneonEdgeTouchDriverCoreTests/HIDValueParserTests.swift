import MacXeneonEdgeTouchDriverCore
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
        XCTAssertEqual(repeated?.kind, .move)
        XCTAssertEqual(repeated?.rawX, 5_224)
        XCTAssertEqual(repeated?.rawY, 5_500)
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
