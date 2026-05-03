import CoreGraphics
import MacXeneonEdgeTouchDriverCore
import XCTest

final class CoordinateMapperTests: XCTestCase {
    func testMapsOrigin() {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 10, y: 20, width: 2_560, height: 720))

        XCTAssertEqual(mapper.map(rawX: 0, rawY: 0), CGPoint(x: 10, y: 20))
    }

    func testMapsMaximum() {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 10, y: 20, width: 2_560, height: 720))

        XCTAssertEqual(mapper.map(rawX: 16_383, rawY: 9_599), CGPoint(x: 2_570, y: 740))
    }

    func testMapsNegativeOriginDisplay() {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: -1_280, y: 1_890, width: 2_560, height: 720))

        XCTAssertEqual(mapper.map(rawX: 0, rawY: 0), CGPoint(x: -1_280, y: 1_890))
        XCTAssertEqual(mapper.map(rawX: 16_383, rawY: 9_599), CGPoint(x: 1_280, y: 2_610))
    }

    func testClampsRawCoordinates() {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 2_560, height: 720))

        XCTAssertEqual(mapper.map(rawX: -500, rawY: -500), CGPoint(x: 0, y: 0))
        XCTAssertEqual(mapper.map(rawX: 99_999, rawY: 99_999), CGPoint(x: 2_560, y: 720))
    }

    func testMapsApproximateMidpoint() {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 2_560, height: 720))
        let point = mapper.map(rawX: 8_191, rawY: 4_799)

        XCTAssertEqual(point.x, 1_279.9218702318256, accuracy: 0.001)
        XCTAssertEqual(point.y, 359.962496093342, accuracy: 0.001)
    }
}
