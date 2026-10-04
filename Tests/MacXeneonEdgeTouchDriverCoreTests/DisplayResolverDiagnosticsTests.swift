import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class DisplayResolverDiagnosticsTests: XCTestCase {
    func testEnabledAndDisabledDiagnosticsUseTheSameSingleProviderRead() {
        for loggingEnabled in [false, true] {
            for usesRefresh in [false, true] {
                let first = display(displayID: 1)
                let next = display(displayID: 2, bounds: CGRect(x: 900, y: 200, width: 2_560, height: 720))
                var reads = 0
                let recorder = Recorder()
                let resolver = DisplayResolver(activeDisplayProvider: {
                    reads += 1
                    return [reads == 1 ? first : next]
                }, diagnosticLog: loggingEnabled ? recorder.record : nil)
                var changes: [CGRect?] = []
                resolver.onDisplayChanged = { changes.append($0) }

                if usesRefresh {
                    resolver.refresh()
                } else {
                    let selected = resolver.resolve()
                    XCTAssertNil(resolver.currentSnapshot)
                    resolver.update(with: selected)
                }

                XCTAssertEqual(reads, 1)
                XCTAssertEqual(resolver.currentSnapshot, first)
                XCTAssertEqual(resolver.currentMapper?.displayBounds, first.bounds)
                XCTAssertEqual(changes, [first.bounds])
                XCTAssertEqual(recorder.entries.count, loggingEnabled ? 1 : 0)
                if loggingEnabled {
                    let message = recorder.entries[0].message
                    XCTAssertTrue(message.contains("selectedID=1"))
                    XCTAssertTrue(message.contains("id=1 "))
                    XCTAssertFalse(message.contains("id=2 "))
                    XCTAssertFalse(message.contains("900"))
                }

                resolver.refresh()
                XCTAssertEqual(reads, 2)
                XCTAssertEqual(resolver.currentSnapshot, next)
                XCTAssertEqual(recorder.entries.count, loggingEnabled ? 2 : 0)
                if loggingEnabled {
                    XCTAssertTrue(recorder.entries[1].message.contains("selectedID=2"))
                    XCTAssertTrue(recorder.entries[1].message.contains("bounds=(900.0,200.0,2560.0,720.0)"))
                }
            }
        }
    }

    func testSuppliedSnapshotsNeverReadTheProviderOrCommitMapping() {
        var reads = 0
        let recorder = Recorder()
        let resolver = DisplayResolver(activeDisplayProvider: {
            reads += 1
            return []
        }, diagnosticLog: recorder.record)
        let selected = display()

        XCTAssertEqual(resolver.resolve(from: [selected]), selected)
        XCTAssertEqual(reads, 0)
        XCTAssertNil(resolver.currentSnapshot)
        XCTAssertEqual(recorder.entries.count, 1)
    }

    func testEnabledAndDisabledDiagnosticsPreserveSelectionAcrossFailureAndRecovery() {
        var configuration = DriverConfiguration.defaults.display
        configuration.serialNumber = 456
        let selected = display(displayID: 1, serialNumber: 456)
        let duplicateSerial = display(displayID: 2, serialNumber: 456)
        let invalid = display(displayID: 3, serialNumber: 456, bounds: .zero)
        let wrongSerial = display(displayID: 4, serialNumber: 123)
        let fallback = display(displayID: 5, serialNumber: 456, pixelsWide: 1_280, pixelsHigh: 360)
        let cases: [([DisplaySnapshot], DisplaySnapshot?)] = [
            ([], nil), ([wrongSerial], nil), ([invalid], nil),
            ([selected, duplicateSerial], nil), ([invalid, wrongSerial, fallback], fallback),
            ([selected, fallback, wrongSerial], selected), ([selected], selected)
        ]
        for loggingEnabled in [false, true] {
            let recorder = Recorder()
            var candidates: [DisplaySnapshot] = []
            var reads = 0
            let resolver = DisplayResolver(configuration: configuration, activeDisplayProvider: {
                reads += 1
                return candidates
            }, diagnosticLog: loggingEnabled ? recorder.record : nil)
            var changes: [CGRect?] = []
            resolver.onDisplayChanged = { changes.append($0) }
            for (index, testCase) in cases.enumerated() {
                candidates = testCase.0
                resolver.refresh()
                XCTAssertEqual(reads, index + 1)
                XCTAssertEqual(resolver.currentSnapshot, testCase.1)
            }
            XCTAssertEqual(changes, [fallback.bounds, selected.bounds])
            XCTAssertEqual(recorder.entries.count, loggingEnabled ? cases.count : 0)
        }
    }

    func testSelectedDiagnosticIncludesCandidateGeometryPixelsAndMetadata() {
        let selected = display(displayID: 7, serialNumber: 456,
            bounds: CGRect(x: -2_560, y: 90.5, width: 1_280, height: 360))
        let losing = display(displayID: 8, serialNumber: 789, pixelsWide: 3_840, pixelsHigh: 2_160)
        let recorder = Recorder()
        let resolver = DisplayResolver(activeDisplayProvider: { [losing, selected] }, diagnosticLog: recorder.record)

        XCTAssertEqual(resolver.resolve(), selected)

        let message = recorder.entries[0].message
        XCTAssertTrue(message.contains("selectedID=7 preference=expected-pixels"))
        XCTAssertTrue(message.contains("id=7 vendor=\(CapturedXeneonDisplay.vendorNumber) model=\(CapturedXeneonDisplay.modelNumber) serial=456"))
        XCTAssertTrue(message.contains("bounds=(-2560.0,90.5,1280.0,360.0) pixels=2560x720 validBounds=true"))
        XCTAssertTrue(message.contains("id=8 "))
        XCTAssertTrue(message.contains("pixels=3840x2160"))
    }

    func testSingleFallbackCandidateReportsFallbackSelection() {
        let selected = display(pixelsWide: 1_280, pixelsHigh: 360)
        let recorder = Recorder()
        let resolver = DisplayResolver(activeDisplayProvider: { [selected] }, diagnosticLog: recorder.record)

        XCTAssertEqual(resolver.resolve(), selected)
        XCTAssertTrue(recorder.entries[0].message.contains("selectedID=1 preference=fallback"))
    }

    func testNoMatchReasonsDistinguishEmptyIdentityBoundsAndSerialFailures() {
        var configuration = DriverConfiguration.defaults.display
        configuration.serialNumber = 456
        let wrongIdentity = display(vendorNumber: 0)
        let invalidBounds = display(serialNumber: 456, bounds: .zero)
        let wrongSerial = display(serialNumber: 123)
        let cases: [(String, [DisplaySnapshot])] = [
            ("no-active-displays", []),
            ("no-vendor-model-match", [wrongIdentity]),
            ("no-valid-bounds", [invalidBounds]),
            ("no-valid-configured-serial-match", [wrongSerial]),
            ("no-valid-configured-serial-match", [invalidBounds, wrongSerial])
        ]
        for (reason, candidates) in cases {
            let recorder = Recorder()
            let resolver = DisplayResolver(configuration: configuration,
                activeDisplayProvider: { candidates }, diagnosticLog: recorder.record)
            XCTAssertNil(resolver.resolve())
            XCTAssertEqual(recorder.entries.count, 1)
            XCTAssertTrue(recorder.entries[0].message.contains("no-match reason=\(reason)"))
            XCTAssertTrue(recorder.entries[0].message.contains("serial=456 pixels=2560x720; candidates=["))
            XCTAssertFalse(recorder.entries[0].message.contains("selectedID="))
        }
    }

    func testDuplicateSerialAmbiguityReportsAllBestIDsAndPreference() {
        var configuration = DriverConfiguration.defaults.display
        configuration.serialNumber = 456
        for exactSize in [false, true] {
            let first = display(displayID: 1, serialNumber: 456, pixelsWide: exactSize ? 2_560 : 1_280)
            let second = display(displayID: 2, serialNumber: 456, pixelsWide: exactSize ? 2_560 : 3_840)
            let recorder = Recorder()
            let resolver = DisplayResolver(configuration: configuration,
                activeDisplayProvider: { [] }, diagnosticLog: recorder.record)

            XCTAssertNil(resolver.resolve(from: [second, first]))
            XCTAssertNil(resolver.resolve(from: [first, second]))

            XCTAssertEqual(recorder.entries.count, 1)
            let preference = exactSize ? "expected-pixels" : "fallback"
            XCTAssertTrue(recorder.entries[0].message.contains("ambiguous preference=\(preference) bestIDs=[1,2]"))
        }
    }

    func testExactDuplicateRecordsStayAmbiguousAndAreNotDeduplicatedAway() {
        let same = display()
        let recorder = Recorder()
        let resolver = DisplayResolver(activeDisplayProvider: { [] }, diagnosticLog: recorder.record)

        XCTAssertEqual(resolver.resolve(from: [same]), same)
        XCTAssertNil(resolver.resolve(from: [same, same]))
        XCTAssertNil(resolver.resolve(from: [same, same]))
        XCTAssertEqual(resolver.resolve(from: [same]), same)

        XCTAssertEqual(recorder.entries.count, 3)
        XCTAssertTrue(recorder.entries[1].message.contains("ambiguous preference=expected-pixels bestIDs=[1,1]"))
        XCTAssertEqual(recorder.entries[0].message, recorder.entries[2].message)
    }

    func testReorderedCandidatesWithDuplicateIDsRemainEquivalent() {
        let selected = display(displayID: 1)
        let losing = display(displayID: 2, pixelsWide: 1_280, pixelsHigh: 360)
        let duplicateID = display(displayID: 2, bounds: .zero)
        let invalid = display(displayID: 3, bounds: CGRect(x: CGFloat.nan, y: 0, width: 2_560, height: 720))
        let recorder = Recorder()
        let resolver = DisplayResolver(activeDisplayProvider: { [] }, diagnosticLog: recorder.record)

        for candidates in [[selected, losing, duplicateID, invalid], [invalid, duplicateID, losing, selected],
                           [duplicateID, selected, invalid, losing], [losing, invalid, selected, duplicateID]] {
            XCTAssertEqual(resolver.resolve(from: candidates), selected)
        }

        XCTAssertEqual(recorder.entries.count, 1)
    }

    func testOriginIdentityLosingGeometryPixelsAndRecoveryProduceUpdates() {
        let first = display(displayID: 1)
        let moved = display(displayID: 1, bounds: CGRect(x: -2_560, y: 200, width: 2_560, height: 720))
        let replaced = display(displayID: 2, bounds: moved.bounds)
        let losing = display(displayID: 3, pixelsWide: 1_280, pixelsHigh: 360)
        let movedLosing = display(displayID: 3, bounds: CGRect(x: 800, y: 900, width: 1_280, height: 360),
            pixelsWide: 1_280, pixelsHigh: 360)
        let resizedLosing = display(displayID: 3, bounds: movedLosing.bounds, pixelsWide: 3_840, pixelsHigh: 2_160)
        var candidates = [first, losing]
        let recorder = Recorder()
        let resolver = DisplayResolver(activeDisplayProvider: { candidates }, diagnosticLog: recorder.record)
        var changes: [CGRect?] = []
        resolver.onDisplayChanged = { changes.append($0) }

        let steps: [[DisplaySnapshot]] = [[first, losing], [moved, losing], [replaced, losing],
            [replaced, movedLosing], [replaced, resizedLosing], [], [first, losing]]
        for step in steps {
            candidates = step
            resolver.refresh()
            candidates.reverse()
            resolver.refresh()
        }

        XCTAssertEqual(recorder.entries.count, steps.count)
        XCTAssertEqual(changes, [first.bounds, moved.bounds, replaced.bounds, nil, first.bounds])
        XCTAssertEqual(resolver.currentSnapshot, first)
        XCTAssertTrue(recorder.entries[3].message.contains("bounds=(800.0,900.0,1280.0,360.0)"))
        XCTAssertTrue(recorder.entries[4].message.contains("pixels=3840x2160"))
        XCTAssertTrue(recorder.entries[5].message.contains("no-active-displays"))
        XCTAssertEqual(recorder.entries.first?.message, recorder.entries.last?.message)
    }

    func testAmbiguityAndRecoveryLogOnceWithoutChangingCallbacks() {
        let first = display(displayID: 1)
        let second = display(displayID: 2)
        var candidates = [first]
        let recorder = Recorder()
        let resolver = DisplayResolver(activeDisplayProvider: { candidates }, diagnosticLog: recorder.record)
        var changes: [CGRect?] = []
        resolver.onDisplayChanged = { changes.append($0) }
        resolver.refresh()
        candidates = [first, second]
        resolver.refresh()
        candidates.reverse()
        resolver.refresh()
        candidates = [second]
        resolver.refresh()
        resolver.refresh()

        XCTAssertEqual(recorder.entries.count, 3)
        XCTAssertEqual(changes, [first.bounds, nil, second.bounds])
        XCTAssertEqual(resolver.currentSnapshot, second)
    }

    func testNonfiniteBoundsAreSafeToFormatAndUnchangedInvalidCandidatesStayQuiet() {
        let cases: [(CGRect, String?)] = [
            (CGRect(x: CGFloat.nan, y: 0, width: 2_560, height: 720), "nan"),
            (CGRect(x: CGFloat.infinity, y: 0, width: 2_560, height: 720), "inf"),
            (CGRect(x: 0, y: -CGFloat.infinity, width: 2_560, height: 720), "-inf"),
            (CGRect(x: 0, y: 0, width: CGFloat.nan, height: 720), "nan"),
            (.null, nil), (.infinite, nil),
            (CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0,
                width: CGFloat.greatestFiniteMagnitude, height: 720), nil)
        ]
        for (bounds, expectedText) in cases {
            let candidate = display(bounds: bounds)
            let recorder = Recorder()
            let resolver = DisplayResolver(activeDisplayProvider: { [candidate] }, diagnosticLog: recorder.record)
            for _ in 0..<10 { XCTAssertNil(resolver.resolve()) }
            XCTAssertEqual(recorder.entries.count, 1)
            XCTAssertTrue(recorder.entries[0].message.contains("no-match reason=no-valid-bounds"))
            XCTAssertTrue(recorder.entries[0].message.contains("validBounds=false"))
            if let expectedText { XCTAssertTrue(recorder.entries[0].message.contains(expectedText)) }
        }
    }

    func testSignedZeroAndDifferentNaNPayloadsDoNotCauseDuplicateDiagnostics() {
        let recorder = Recorder()
        let resolver = DisplayResolver(activeDisplayProvider: { [] }, diagnosticLog: recorder.record)
        for origin in [CGFloat.zero, -CGFloat.zero] {
            _ = resolver.resolve(from: [display(bounds: CGRect(x: origin, y: 0, width: 2_560, height: 720))])
        }
        XCTAssertEqual(recorder.entries.count, 1)
        for nan in [Double.nan, Double(bitPattern: 0x7ff8_0000_0000_0001), -Double.nan] {
            XCTAssertNil(resolver.resolve(from: [display(bounds: CGRect(x: CGFloat(nan), y: 0, width: 2_560, height: 720))]))
        }
        XCTAssertEqual(recorder.entries.count, 2)
    }

    func testFiniteSubpixelChangesAreNotRoundedOutOfTheDiagnosticKey() {
        let recorder = Recorder()
        let resolver = DisplayResolver(activeDisplayProvider: { [] }, diagnosticLog: recorder.record)
        for origin in [CGFloat(100), CGFloat(100).nextUp] {
            XCTAssertNotNil(resolver.resolve(from: [display(bounds: CGRect(x: origin, y: 200, width: 2_560, height: 720))]))
        }
        XCTAssertEqual(recorder.entries.count, 2)
        XCTAssertNotEqual(recorder.entries[0].message, recorder.entries[1].message)
    }

    func testUnchangedTouchStyleResolvesEmitOnlyOneDebugDisplayMessage() {
        let candidate = display()
        let recorder = Recorder()
        var reads = 0
        let resolver = DisplayResolver(activeDisplayProvider: {
            reads += 1
            return [candidate]
        }, diagnosticLog: recorder.record)
        var changes: [CGRect?] = []
        resolver.onDisplayChanged = { changes.append($0) }

        for _ in 0..<100 {
            let selected = resolver.resolve()
            resolver.update(with: selected)
        }

        XCTAssertEqual(reads, 100)
        XCTAssertEqual(recorder.entries.count, 1)
        XCTAssertEqual(recorder.entries[0].level, .debug)
        XCTAssertEqual(recorder.entries[0].category, .display)
        XCTAssertEqual(changes, [candidate.bounds])
    }

    private final class Recorder {
        struct Entry {
            let level: DriverLogLevel
            let category: DriverLogCategory
            let message: String
        }
        var entries: [Entry] = []
        func record(_ level: DriverLogLevel, _ category: DriverLogCategory, _ message: String) {
            entries.append(Entry(level: level, category: category, message: message))
        }
    }

    private func display(
        displayID: CGDirectDisplayID = 1,
        vendorNumber: UInt32 = CapturedXeneonDisplay.vendorNumber,
        serialNumber: UInt32 = 123,
        bounds: CGRect = CGRect(x: 100, y: 200, width: 2_560, height: 720),
        pixelsWide: Int = 2_560,
        pixelsHigh: Int = 720
    ) -> DisplaySnapshot {
        DisplaySnapshot(displayID: displayID, vendorNumber: vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber, serialNumber: serialNumber,
            bounds: bounds, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
    }
}
