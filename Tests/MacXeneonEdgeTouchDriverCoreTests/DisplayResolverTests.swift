import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
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
            bounds: CGRect(x: 0, y: 0, width: 3_840, height: 2_160),
            pixelsWide: 3_840,
            pixelsHigh: 2_160
        )
        let rightSize = DisplaySnapshot(
            displayID: 11,
            vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber,
            serialNumber: 222,
            bounds: CGRect(x: 100, y: 200, width: 2_560, height: 720),
            pixelsWide: 2_560,
            pixelsHigh: 720
        )

        let match = resolver.resolve(from: [wrongSize, rightSize])

        XCTAssertEqual(match?.displayID, 11)
    }

    func testUnconfiguredSerialPreservesOrdinarySingleDisplaySelection() {
        let resolver = DisplayResolver()
        let display = xeneonDisplay(serialNumber: 123, pixelsWide: 1_280, pixelsHigh: 360)

        XCTAssertEqual(resolver.resolve(from: [display]), display)
    }

    func testSizePreferenceIsIndependentOfEnumerationOrder() {
        let resolver = DisplayResolver()
        let wrongSize = xeneonDisplay(displayID: 1, pixelsWide: 3_840, pixelsHigh: 2_160)
        let rightSize = xeneonDisplay(displayID: 2)

        for displays in [[wrongSize, rightSize], [rightSize, wrongSize]] {
            XCTAssertEqual(resolver.resolve(from: displays), rightSize)
        }
    }

    func testConfiguredSerialDoesNotMatchAnAbsentDisplay() {
        var configuration = DriverConfiguration.defaults.display
        configuration.serialNumber = 456
        let resolver = DisplayResolver(configuration: configuration)

        XCTAssertNil(resolver.resolve(from: []))
    }

    func testConfiguredSerialRejectsOtherSameModelDisplaysInEitherOrder() {
        var configuration = DriverConfiguration.defaults.display
        configuration.serialNumber = 456
        let resolver = DisplayResolver(configuration: configuration)
        let first = xeneonDisplay(displayID: 1, serialNumber: 123)
        let second = xeneonDisplay(displayID: 2, serialNumber: 789)

        for displays in [[first, second], [second, first]] {
            XCTAssertNil(resolver.resolve(from: displays))
        }
    }

    func testConfiguredSerialMatchesTheCorrectDisplayInEitherOrder() {
        var configuration = DriverConfiguration.defaults.display
        configuration.serialNumber = 456
        let resolver = DisplayResolver(configuration: configuration)
        let wrongSerial = xeneonDisplay(displayID: 1, serialNumber: 123)
        let correctSerial = xeneonDisplay(displayID: 2, serialNumber: 456)

        for displays in [[wrongSerial, correctSerial], [correctSerial, wrongSerial]] {
            XCTAssertEqual(resolver.resolve(from: displays), correctSerial)
        }
    }

    func testConfiguredSerialTakesPrecedenceOverSizePreferenceInEitherOrder() {
        var configuration = DriverConfiguration.defaults.display
        configuration.serialNumber = 456
        let resolver = DisplayResolver(configuration: configuration)
        let wrongSerial = xeneonDisplay(displayID: 1, serialNumber: 123)
        let correctSerial = xeneonDisplay(
            displayID: 2,
            serialNumber: 456,
            pixelsWide: 1_280,
            pixelsHigh: 360
        )

        for displays in [[wrongSerial, correctSerial], [correctSerial, wrongSerial]] {
            XCTAssertEqual(resolver.resolve(from: displays), correctSerial)
        }
    }

    func testRejectsInvalidBounds() {
        let resolver = DisplayResolver()
        let invalidBounds: [CGRect] = [
            .zero,
            .null,
            .infinite,
            CGRect(x: CGFloat.nan, y: 0, width: 2_560, height: 720),
            CGRect(x: 0, y: CGFloat.nan, width: 2_560, height: 720),
            CGRect(x: CGFloat.infinity, y: 0, width: 2_560, height: 720),
            CGRect(x: 0, y: -CGFloat.infinity, width: 2_560, height: 720),
            CGRect(x: 0, y: 0, width: 0, height: 720),
            CGRect(x: 0, y: 0, width: 2_560, height: 0),
            CGRect(x: 0, y: 0, width: -2_560, height: 720),
            CGRect(x: 0, y: 0, width: 2_560, height: -720),
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: 720),
            CGRect(x: 0, y: 0, width: 2_560, height: CGFloat.nan),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 720),
            CGRect(x: 0, y: 0, width: 2_560, height: CGFloat.infinity),
            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 720),
            CGRect(x: 0, y: CGFloat.greatestFiniteMagnitude, width: 2_560, height: CGFloat.greatestFiniteMagnitude)
        ]

        for bounds in invalidBounds {
            XCTAssertNil(resolver.resolve(from: [xeneonDisplay(bounds: bounds)]), "Accepted invalid bounds: \(bounds)")
        }
    }

    func testInvalidPreferredSizeDisplayDoesNotHideAValidMatch() {
        let resolver = DisplayResolver()
        let invalid = xeneonDisplay(displayID: 1, bounds: .zero)
        let valid = xeneonDisplay(displayID: 2, pixelsWide: 1_280, pixelsHigh: 360)

        for displays in [[invalid, valid], [valid, invalid]] {
            XCTAssertEqual(resolver.resolve(from: displays), valid)
        }
    }

    func testAcceptsFiniteNegativeDisplayOrigin() {
        let resolver = DisplayResolver()
        let display = xeneonDisplay(bounds: CGRect(x: -2_560, y: -720, width: 2_560, height: 720))

        XCTAssertEqual(resolver.resolve(from: [display]), display)
    }

    func testRejectsPositiveDimensionsWhoseGlobalEdgesCollapse() {
        let origin = CGFloat(4_503_599_627_370_496)
        let collapsedBounds = [
            CGRect(x: origin, y: 0, width: 0.25, height: 720),
            CGRect(x: 0, y: origin, width: 2_560, height: 0.25),
            CGRect(x: -origin, y: 0, width: 0.125, height: 720),
            CGRect(x: 0, y: -origin, width: 2_560, height: 0.125),
        ]

        for bounds in collapsedBounds {
            let valid = xeneonDisplay(displayID: 2)
            let invalid = xeneonDisplay(bounds: bounds)
            let resolver = DisplayResolver(activeDisplayProvider: { [invalid] })
            XCTAssertGreaterThan(bounds.width, 0)
            XCTAssertGreaterThan(bounds.height, 0)
            XCTAssertTrue(bounds.minX == bounds.maxX || bounds.minY == bounds.maxY)
            XCTAssertNil(resolver.resolve(from: [invalid]))
            XCTAssertEqual(resolver.resolve(from: [invalid, valid]), valid)
            resolver.update(with: valid)
            var changes: [CGRect?] = []
            resolver.onDisplayChanged = { changes.append($0) }

            resolver.update(with: invalid)
            resolver.refresh()

            XCTAssertNil(resolver.currentSnapshot)
            XCTAssertNil(resolver.currentBounds)
            XCTAssertNil(resolver.currentMapper)
            XCTAssertEqual(changes, [nil])
        }
    }

    func testAcceptsBoundsWithExactlyOneRepresentableCoordinateOnEachAxis() {
        let origin = CGFloat(4_503_599_627_370_496)
        for bounds in [
            CGRect(x: origin, y: origin, width: 1, height: 1),
            CGRect(x: -CGFloat.leastNonzeroMagnitude, y: -CGFloat.leastNonzeroMagnitude,
                   width: CGFloat.leastNonzeroMagnitude, height: CGFloat.leastNonzeroMagnitude),
        ] {
            let display = xeneonDisplay(bounds: bounds)
            let resolver = DisplayResolver(activeDisplayProvider: { [display] })
            resolver.refresh()

            XCTAssertEqual(resolver.currentSnapshot, display)
            XCTAssertEqual(resolver.currentMapper?.map(rawX: 16_383, rawY: 9_599), bounds.origin)
        }
    }

    func testRefreshReadsProviderOnceAndCommitsThatSnapshot() {
        let first = xeneonDisplay(displayID: 1)
        let second = xeneonDisplay(displayID: 2, bounds: CGRect(x: 900, y: 200, width: 2_560, height: 720))
        var providerReads = 0
        let resolver = DisplayResolver(activeDisplayProvider: {
            providerReads += 1
            return [providerReads == 1 ? first : second]
        })

        resolver.refresh()

        XCTAssertEqual(providerReads, 1)
        XCTAssertEqual(resolver.currentSnapshot, first)
        XCTAssertEqual(resolver.currentBounds, first.bounds)
        XCTAssertEqual(resolver.currentMapper?.displayBounds, first.bounds)
    }

    func testResolveThenUpdateDoesNotReadProviderAgain() {
        let display = xeneonDisplay()
        var providerReads = 0
        let resolver = DisplayResolver(activeDisplayProvider: {
            providerReads += 1
            return providerReads == 1 ? [display] : []
        })

        let snapshot = resolver.resolve()
        XCTAssertNil(resolver.currentSnapshot)
        resolver.update(with: snapshot)

        XCTAssertEqual(providerReads, 1)
        XCTAssertEqual(resolver.currentSnapshot, display)
        XCTAssertEqual(resolver.currentMapper?.displayBounds, display.bounds)
    }

    func testUnchangedMappingDoesNotRepeatCallback() {
        let display = xeneonDisplay()
        let resolver = DisplayResolver(activeDisplayProvider: { [display] })
        var changes: [CGRect?] = []
        resolver.onDisplayChanged = { changes.append($0) }

        resolver.refresh()
        resolver.refresh()

        XCTAssertEqual(changes, [display.bounds])
    }

    func testIdentityChangeNotifiesEvenWithUnchangedBounds() {
        let first = xeneonDisplay(displayID: 1)
        let second = xeneonDisplay(displayID: 2)
        let resolver = DisplayResolver(activeDisplayProvider: { [] })
        var changes: [CGRect?] = []
        resolver.onDisplayChanged = { changes.append($0) }

        resolver.update(with: first)
        resolver.update(with: second)

        XCTAssertEqual(changes, [first.bounds, second.bounds])
        XCTAssertEqual(resolver.currentSnapshot, second)
    }

    func testBoundsChangeNotifiesWithUnchangedIdentity() {
        let first = xeneonDisplay()
        let moved = xeneonDisplay(bounds: CGRect(x: 900, y: 200, width: 2_560, height: 720))
        let resolver = DisplayResolver(activeDisplayProvider: { [] })
        var changes: [CGRect?] = []
        resolver.onDisplayChanged = { changes.append($0) }

        resolver.update(with: first)
        resolver.update(with: moved)

        XCTAssertEqual(changes, [first.bounds, moved.bounds])
        XCTAssertEqual(resolver.currentMapper?.displayBounds, moved.bounds)
    }

    func testMetadataChangeCommitsExactSnapshotWithoutRepeatingMappingCallback() {
        let first = xeneonDisplay(serialNumber: 123)
        let updated = xeneonDisplay(serialNumber: 456, pixelsWide: 1_280, pixelsHigh: 360)
        let resolver = DisplayResolver(activeDisplayProvider: { [] })
        var changes: [CGRect?] = []
        resolver.onDisplayChanged = { changes.append($0) }

        resolver.update(with: first)
        resolver.update(with: updated)

        XCTAssertEqual(changes, [first.bounds])
        XCTAssertEqual(resolver.currentSnapshot, updated)
    }

    func testRefreshClearsStaleMappingAndNotifiesOnceWhenDisplayIsLost() {
        let display = xeneonDisplay()
        var displays = [display]
        let resolver = DisplayResolver(activeDisplayProvider: { displays })
        var changes: [CGRect?] = []
        resolver.onDisplayChanged = { changes.append($0) }

        resolver.refresh()
        displays = []
        resolver.refresh()
        resolver.refresh()

        XCTAssertNil(resolver.currentSnapshot)
        XCTAssertNil(resolver.currentBounds)
        XCTAssertNil(resolver.currentMapper)
        XCTAssertEqual(changes, [display.bounds, nil])
    }

    func testRefreshRecoversWithTheCurrentSnapshotAfterTransientLoss() {
        let first = xeneonDisplay()
        let recovered = xeneonDisplay(bounds: CGRect(x: -2_560, y: 0, width: 2_560, height: 720))
        var displays = [first]
        let resolver = DisplayResolver(activeDisplayProvider: { displays })
        var changes: [CGRect?] = []
        resolver.onDisplayChanged = { changes.append($0) }

        resolver.refresh()
        displays = []
        resolver.refresh()
        displays = [recovered]
        resolver.refresh()

        XCTAssertEqual(resolver.currentSnapshot, recovered)
        XCTAssertEqual(resolver.currentMapper?.displayBounds, recovered.bounds)
        XCTAssertEqual(changes, [first.bounds, nil, recovered.bounds])
    }

    func testCommittingInvalidSnapshotClearsThePreviousMappingWithoutAProviderRead() {
        var providerReads = 0
        let resolver = DisplayResolver(activeDisplayProvider: {
            providerReads += 1
            return []
        })
        resolver.update(with: xeneonDisplay())

        resolver.update(with: xeneonDisplay(bounds: .zero))

        XCTAssertEqual(providerReads, 0)
        XCTAssertNil(resolver.currentSnapshot)
        XCTAssertNil(resolver.currentBounds)
        XCTAssertNil(resolver.currentMapper)
    }

    private func xeneonDisplay(
        displayID: CGDirectDisplayID = 1,
        serialNumber: UInt32 = CapturedXeneonDisplay.observedSerialNumber,
        bounds: CGRect = CGRect(x: 100, y: 200, width: 2_560, height: 720),
        pixelsWide: Int = 2_560,
        pixelsHigh: Int = 720
    ) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: displayID,
            vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber,
            serialNumber: serialNumber,
            bounds: bounds,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh
        )
    }
}
