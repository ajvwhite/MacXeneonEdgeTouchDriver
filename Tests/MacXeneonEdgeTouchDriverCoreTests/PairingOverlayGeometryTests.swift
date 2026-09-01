import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class PairingOverlayGeometryTests: XCTestCase {
    func testConvertsDisplayBelowPrimaryIntoAppKitCoordinates() {
        let frame = PairingOverlayGeometry.appKitFrame(
            for: CGRect(x: 3_840, y: 1_440, width: 1_280, height: 480),
            primaryCoreGraphicsFrame: CGRect(x: 0, y: 0, width: 5_120, height: 1_440),
            primaryAppKitFrame: CGRect(x: 0, y: 0, width: 5_120, height: 1_440)
        )

        XCTAssertEqual(frame, CGRect(x: 3_840, y: -480, width: 1_280, height: 480))
    }

    func testConvertsDisplayAbovePrimaryIntoAppKitCoordinates() {
        let frame = PairingOverlayGeometry.appKitFrame(
            for: CGRect(x: 500, y: -480, width: 1_280, height: 480),
            primaryCoreGraphicsFrame: CGRect(x: 0, y: 0, width: 5_120, height: 1_440),
            primaryAppKitFrame: CGRect(x: 0, y: 0, width: 5_120, height: 1_440)
        )

        XCTAssertEqual(frame, CGRect(x: 500, y: 1_440, width: 1_280, height: 480))
    }

    func testFrameComparisonAllowsRoundingButRejectsWrongScreenOrigin() {
        let expected = CGRect(x: 3_840, y: -480, width: 1_280, height: 480)

        XCTAssertTrue(PairingOverlayGeometry.framesMatch(
            CGRect(x: 3_840.5, y: -479.5, width: 1_280, height: 480),
            expected
        ))
        XCTAssertFalse(PairingOverlayGeometry.framesMatch(
            CGRect(x: 0, y: 0, width: 1_280, height: 480),
            expected
        ))
    }
}
