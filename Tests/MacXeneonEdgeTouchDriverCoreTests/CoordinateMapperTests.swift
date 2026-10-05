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

        XCTAssertEqual(mapper.map(rawX: 16_383, rawY: 9_599), CGPoint(x: CGFloat(2_570).nextDown, y: CGFloat(740).nextDown))
    }

    func testMapsNegativeOriginDisplay() {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: -1_280, y: 1_890, width: 2_560, height: 720))

        XCTAssertEqual(mapper.map(rawX: 0, rawY: 0), CGPoint(x: -1_280, y: 1_890))
        XCTAssertEqual(mapper.map(rawX: 16_383, rawY: 9_599), CGPoint(x: CGFloat(1_280).nextDown, y: CGFloat(2_610).nextDown))
    }

    func testClampsRawCoordinates() {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 2_560, height: 720))

        XCTAssertEqual(mapper.map(rawX: -500, rawY: -500), CGPoint(x: 0, y: 0))
        XCTAssertEqual(mapper.map(rawX: 99_999, rawY: 99_999), CGPoint(x: CGFloat(2_560).nextDown, y: CGFloat(720).nextDown))
    }

    func testMapsApproximateMidpoint() {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 2_560, height: 720))
        let point = mapper.map(rawX: 8_191, rawY: 4_799)

        XCTAssertEqual(point.x, 1_279.9218702318256, accuracy: 0.001)
        XCTAssertEqual(point.y, 359.962496093342, accuracy: 0.001)
    }

    func testCornersEdgeMidpointsAndOutOfRangeValuesStayInsideTarget() {
        for bounds in targetBounds {
            for ranges in rawRanges {
                let mapper = makeMapper(bounds: bounds, ranges: ranges)
                let xs = samples(in: ranges.x)
                let ys = samples(in: ranges.y)
                let right = CGRect(x: bounds.maxX, y: bounds.minY, width: bounds.width, height: bounds.height)
                let bottom = CGRect(x: bounds.minX, y: bounds.maxY, width: bounds.width, height: bounds.height)

                for rawX in xs {
                    for rawY in ys {
                        let point = mapper.map(rawX: rawX, rawY: rawY)
                        let context = "bounds=\(bounds), raw=(\(rawX), \(rawY))"
                        XCTAssertTrue(bounds.contains(point), context)
                        XCTAssertFalse(right.contains(point), context)
                        XCTAssertFalse(bottom.contains(point), context)
                        XCTAssertGreaterThanOrEqual(point.x, bounds.minX, context)
                        XCTAssertLessThan(point.x, bounds.maxX, context)
                        XCTAssertGreaterThanOrEqual(point.y, bounds.minY, context)
                        XCTAssertLessThan(point.y, bounds.maxY, context)
                    }
                }

                XCTAssertEqual(mapper.map(rawX: ranges.x.lowerBound, rawY: ranges.y.lowerBound), bounds.origin)
                XCTAssertEqual(
                    mapper.map(rawX: ranges.x.upperBound, rawY: ranges.y.upperBound),
                    CGPoint(x: bounds.maxX.nextDown, y: bounds.maxY.nextDown)
                )
            }
        }
    }

    func testEveryRawAxisValueIsMonotoneAndPreservesContainedAffineResultsExactly() {
        for bounds in targetBounds {
            for ranges in rawRanges {
                let mapper = makeMapper(bounds: bounds, ranges: ranges)
                var previousX = -CGFloat.infinity
                for rawX in ranges.x {
                    let point = mapper.map(rawX: rawX, rawY: ranges.y.lowerBound)
                    let affineX = bounds.origin.x + CGFloat(rawX - ranges.x.lowerBound) /
                        CGFloat(ranges.x.upperBound - ranges.x.lowerBound) * bounds.width
                    XCTAssertTrue(bounds.contains(point))
                    XCTAssertGreaterThanOrEqual(point.x, previousX)
                    if affineX >= bounds.minX && affineX < bounds.maxX {
                        XCTAssertEqual(Double(point.x).bitPattern, Double(affineX).bitPattern)
                    }
                    previousX = point.x
                }

                var previousY = -CGFloat.infinity
                for rawY in ranges.y {
                    let point = mapper.map(rawX: ranges.x.lowerBound, rawY: rawY)
                    let affineY = bounds.origin.y + CGFloat(rawY - ranges.y.lowerBound) /
                        CGFloat(ranges.y.upperBound - ranges.y.lowerBound) * bounds.height
                    XCTAssertTrue(bounds.contains(point))
                    XCTAssertGreaterThanOrEqual(point.y, previousY)
                    if affineY >= bounds.minY && affineY < bounds.maxY {
                        XCTAssertEqual(Double(point.y).bitPattern, Double(affineY).bitPattern)
                    }
                    previousY = point.y
                }
            }
        }
    }

    func testZeroEndingEdgesUseNegativeSubnormalAfterGlobalAddition() {
        let bounds = CGRect(x: -2_560, y: -720, width: 2_560, height: 720)
        let point = CoordinateMapper(displayBounds: bounds).map(rawX: 16_383, rawY: 9_599)

        XCTAssertEqual(point.x, -CGFloat.leastNonzeroMagnitude)
        XCTAssertEqual(point.y, -CGFloat.leastNonzeroMagnitude)
        XCTAssertTrue(bounds.contains(point))
        XCTAssertFalse(CGRect(x: 0, y: -720, width: 2_560, height: 720).contains(point))
        XCTAssertFalse(CGRect(x: -2_560, y: 0, width: 2_560, height: 720).contains(point))
    }

    func testClampHandlesInteriorRawValuesThatRoundToExcludedMaximum() {
        let origin = CGFloat(4_503_599_627_370_496)
        let bounds = CGRect(x: origin, y: origin, width: 1, height: 1)
        let mapper = CoordinateMapper(displayBounds: bounds)

        for offset in 0...2 {
            let rawX = 16_383 - offset
            let rawY = 9_599 - offset
            XCTAssertEqual(bounds.origin.x + CGFloat(rawX) / 16_383 * bounds.width, bounds.maxX)
            XCTAssertEqual(bounds.origin.y + CGFloat(rawY) / 9_599 * bounds.height, bounds.maxY)
            let point = mapper.map(rawX: rawX, rawY: rawY)
            XCTAssertEqual(point, bounds.origin)
            XCTAssertTrue(bounds.contains(point))
        }
    }

    private var targetBounds: [CGRect] {
        [
            CGRect(x: 10, y: 20, width: 2_560, height: 720),
            CGRect(x: -1_280, y: -360, width: 2_560, height: 720),
            CGRect(x: -5_120, y: -1_440, width: 2_560, height: 720),
            CGRect(x: -2_560, y: 0, width: 2_560, height: 720),
            CGRect(x: 0, y: -720, width: 2_560, height: 720),
            CGRect(x: -2_560, y: -720, width: 2_560, height: 720),
            CGRect(x: -300.25, y: 12.125, width: 1_280.5, height: 360.25),
            CGRect(x: 100, y: -2_560, width: 720, height: 2_560),
            CGRect(x: 2_560, y: 100, width: 1_280, height: 360),
            CGRect(x: -0.0, y: -0.0, width: 2_560, height: 720),
        ]
    }

    private var rawRanges: [(x: ClosedRange<Int>, y: ClosedRange<Int>)] {
        [(0...16_383, 0...9_599), (-500...500, 100...900), (10...11, -2...0)]
    }

    private func samples(in range: ClosedRange<Int>) -> [Int] {
        [Int.min, range.lowerBound - 1, range.lowerBound, range.lowerBound + 1,
         range.lowerBound + (range.upperBound - range.lowerBound) / 2,
         range.upperBound - 2, range.upperBound - 1, range.upperBound, range.upperBound + 1, Int.max]
    }

    private func makeMapper(
        bounds: CGRect,
        ranges: (x: ClosedRange<Int>, y: ClosedRange<Int>)
    ) -> CoordinateMapper {
        CoordinateMapper(
            rawMinX: ranges.x.lowerBound, rawMaxX: ranges.x.upperBound,
            rawMinY: ranges.y.lowerBound, rawMaxY: ranges.y.upperBound,
            displayBounds: bounds
        )
    }
}
