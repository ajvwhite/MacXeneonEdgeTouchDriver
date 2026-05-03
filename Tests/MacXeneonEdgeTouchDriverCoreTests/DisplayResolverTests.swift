import CoreGraphics
import MacXeneonEdgeTouchDriverCore
import XCTest

final class DisplayResolverTests: XCTestCase {
    func testMatchesCapturedVendorModelAndResolution() {
        let resolver = DisplayResolver()
        let displays = [
            DisplaySnapshot(
                displayID: 1,
                vendorNumber: 1,
                modelNumber: 2,
                serialNumber: 3,
                bounds: .zero,
                pixelsWide: 1_728,
                pixelsHigh: 1_117
            ),
            DisplaySnapshot(
                displayID: 2,
                vendorNumber: CapturedXeneonDisplay.vendorNumber,
                modelNumber: CapturedXeneonDisplay.modelNumber,
                serialNumber: CapturedXeneonDisplay.observedSerialNumber,
                bounds: CGRect(x: 5_088, y: 1_890, width: 2_560, height: 720),
                pixelsWide: 2_560,
                pixelsHigh: 720
            )
        ]

        let match = resolver.resolve(from: displays)

        XCTAssertEqual(match?.displayID, 2)
    }

    func testResolutionDisambiguatesVendorModelMatches() {
        let resolver = DisplayResolver()
        let wrongSize = DisplaySnapshot(
            displayID: 10,
            vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber,
            serialNumber: 111,
            bounds: .zero,
            pixelsWide: 3_840,
            pixelsHigh: 2_160
        )
        let rightSize = DisplaySnapshot(
            displayID: 11,
            vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber,
            serialNumber: 222,
            bounds: .zero,
            pixelsWide: 2_560,
            pixelsHigh: 720
        )

        let match = resolver.resolve(from: [wrongSize, rightSize])

        XCTAssertEqual(match?.displayID, 11)
    }
}
