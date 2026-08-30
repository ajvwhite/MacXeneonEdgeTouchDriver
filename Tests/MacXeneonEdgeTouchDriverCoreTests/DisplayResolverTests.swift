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
                bounds: CGRect(x: 5_088, y: 1_890, width: 1_280, height: 480),
                pixelsWide: CapturedXeneonDisplay.expectedWidth,
                pixelsHigh: CapturedXeneonDisplay.expectedHeight
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
            pixelsWide: CapturedXeneonDisplay.expectedWidth,
            pixelsHigh: CapturedXeneonDisplay.expectedHeight
        )

        let match = resolver.resolve(from: [wrongSize, rightSize])

        XCTAssertEqual(match?.displayID, 11)
    }

    func testReturnsIdenticalDisplaysInStableVisualOrder() {
        let resolver = DisplayResolver()
        let right = matchingDisplay(id: 4, runtimeIdentifier: "RIGHT", x: 3_840)
        let left = matchingDisplay(id: 5, runtimeIdentifier: "LEFT", x: 0)

        XCTAssertEqual(resolver.matchingDisplays(from: [right, left]).map(\.runtimeIdentifier), ["LEFT", "RIGHT"])
    }

    private func matchingDisplay(id: CGDirectDisplayID, runtimeIdentifier: String, x: CGFloat) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: id,
            runtimeIdentifier: runtimeIdentifier,
            vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber,
            serialNumber: 0,
            bounds: CGRect(x: x, y: 1_440, width: 1_280, height: 480),
            pixelsWide: CapturedXeneonDisplay.expectedWidth,
            pixelsHigh: CapturedXeneonDisplay.expectedHeight
        )
    }
}
