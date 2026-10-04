import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class ExperimentalStartupGateTests: XCTestCase {
    func testAbsentGateStartsLegacyExactlyOnceWithoutReadingOrReporting() {
        var reads = 0
        var reports = 0
        var starts = 0
        let result = ExperimentalStartupGate.run(
            arguments: [],
            readConfiguration: { _ in reads += 1; return Data() },
            reportRejection: { _ in reports += 1 },
            startLegacy: { starts += 1; return 23 }
        )
        XCTAssertEqual(result, 23)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(reports, 0)
        XCTAssertEqual(starts, 1)
    }

    func testUnrelatedArgumentsRetainLegacyIgnoredArgumentBehavior() {
        for arguments in [["--old-ignored-option"], ["value"], ["--config", "old.json"]] {
            let result = evaluate(arguments, contents: "")
            XCTAssertEqual(result.exit, 17, "\(arguments)")
            XCTAssertEqual(result.starts, 1)
            XCTAssertEqual(result.reads, [])
            XCTAssertEqual(result.diagnostics, [])
        }
    }

    func testAbsentGatePreservesLegacyDependencyConstructionOrder() {
        // The production composition root passes its entire old construction
        // sequence as the startup closure. This spy verifies gate ordering.
        var effects: [String] = []
        let exit = ExperimentalStartupGate.run(
            arguments: [],
            readConfiguration: { _ in effects.append("read"); return Data() },
            reportRejection: { _ in effects.append("reject") },
            startLegacy: {
                effects += ["legacy-config", "legacy-logging", "input", "focus", "application", "run"]
                return 0
            }
        )
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(effects, ["legacy-config", "legacy-logging", "input", "focus", "application", "run"])
    }

    func testMissingRepeatedUnknownAndEqualsSyntaxRejectWithoutReading() {
        let variants = [
            ["--experimental-config"],
            ["--experimental-config", ""],
            ["--experimental-config", "   \n"],
            ["--experimental-config", "--other"],
            ["--experimental-config", "a", "--experimental-config", "b"],
            ["--experimental-config", "a", "extra"],
            ["prefix", "--experimental-config", "a"],
            ["--experimental-config=a"],
            ["--experimental-routing-config", "a"],
            ["--experimental-confg", "a"]
        ]
        for arguments in variants {
            let result = evaluate(arguments, contents: validRequest)
            assertRejected(result)
            XCTAssertEqual(result.reads, [], "\(arguments)")
        }
    }

    func testExplicitPathIsPassedUnchangedAndReadOnlyOnce() {
        let result = evaluate(["--experimental-config", "relative path/config.json"], contents: validRequest)
        assertRejected(result)
        XCTAssertEqual(result.reads, ["relative path/config.json"])
        XCTAssertTrue(result.diagnostics[0].contains("live dispatch is unavailable"))
    }

    func testUnreadableExplicitFileNeverFallsBackToLegacy() {
        var starts = 0
        var diagnostics: [String] = []
        enum Failure: Error { case unreadable }
        let result = ExperimentalStartupGate.run(
            arguments: ["--experimental-config", "missing.json"],
            readConfiguration: { _ in throw Failure.unreadable },
            reportRejection: { diagnostics.append($0) },
            startLegacy: { starts += 1; return 0 }
        )
        XCTAssertEqual(result, 78)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].contains("could not be read"))
    }

    func testEmptyOversizedAndWhitespaceFilesRejectBeforeStartup() {
        for contents in ["", "   \n", String(repeating: " ", count: 65_537)] {
            assertRejected(evaluate(contents: contents))
        }
    }

    func testSizeBoundaryStillRequiresValidRequestAndReadiness() {
        let padding = String(repeating: " ", count: 65_536 - validRequest.utf8.count)
        let result = evaluate(contents: validRequest + padding)
        assertRejected(result)
        XCTAssertTrue(result.diagnostics[0].contains("live dispatch is unavailable"))
    }

    func testMalformedAndNonObjectRootsReject() {
        for contents in ["{bad", "[]", "null", "true", "1", "\"request\""] {
            assertInvalid(contents)
        }
    }

    func testMissingNullWrongTypeAndUnknownSchemaVersionsReject() {
        let variants = [
            #"{"features":["spatialDoubleClick"]}"#,
            #"{"schemaVersion":null,"features":["spatialDoubleClick"]}"#,
            #"{"schemaVersion":true,"features":["spatialDoubleClick"]}"#,
            #"{"schemaVersion":"1","features":["spatialDoubleClick"]}"#,
            #"{"schemaVersion":0,"features":["spatialDoubleClick"]}"#,
            #"{"schemaVersion":2,"features":["spatialDoubleClick"]}"#,
            #"{"schemaVersion":-1,"features":["spatialDoubleClick"]}"#,
            #"{"schemaVersion":1.5,"features":["spatialDoubleClick"]}"#,
            #"{"schemaVersion":999999999999999999999,"features":["spatialDoubleClick"]}"#
        ]
        variants.forEach { assertInvalid($0) }
    }

    func testMissingEmptyNullWrongTypeAndUnknownFeaturesReject() {
        let variants = [
            #"{"schemaVersion":1}"#,
            #"{"schemaVersion":1,"features":[]}"#,
            #"{"schemaVersion":1,"features":null}"#,
            #"{"schemaVersion":1,"features":"spatialDoubleClick"}"#,
            #"{"schemaVersion":1,"features":[null]}"#,
            #"{"schemaVersion":1,"features":[true]}"#,
            #"{"schemaVersion":1,"features":[1]}"#,
            #"{"schemaVersion":1,"features":["appAllowlist"]}"#,
            #"{"schemaVersion":1,"features":["spatialdoubleclick"]}"#,
            #"{"schemaVersion":1,"features":["spatialDoubleClick","unknown"]}"#
        ]
        variants.forEach { assertInvalid($0) }
    }

    func testUnknownKeysCannotSupplyEvidenceOrTuning() {
        for extra in [#""verified":true"#, #""enabled":false"#, #""routing":{}"#,
                      #""maxIntervalMilliseconds":500"#, #""readiness":"ready""#] {
            assertInvalid(#"{"schemaVersion":1,"features":["spatialDoubleClick"],"# + extra + "}")
        }
    }

    func testDuplicateObjectKeysRejectEvenWhenValuesAgree() {
        for contents in [
            #"{"schemaVersion":1,"schemaVersion":1,"features":["spatialDoubleClick"]}"#,
            #"{"schemaVersion":2,"schemaVersion":1,"features":["spatialDoubleClick"]}"#,
            #"{"schemaVersion":1,"features":[],"features":["spatialDoubleClick"]}"#,
            #"{"schemaVersion":1,"features":["spatialDoubleClick"],"features":[]}"#,
            #"{"schemaVersion":1,"schema\u0056ersion":1,"features":["spatialDoubleClick"]}"#
        ] {
            assertInvalid(contents)
        }
    }

    func testDuplicateFeatureRequestsReject() {
        assertInvalid(#"{"schemaVersion":1,"features":["spatialDoubleClick","spatialDoubleClick"]}"#)
    }

    func testNestedUnknownPayloadsRejectWithoutTreatingStringsAsObjectKeys() {
        for contents in [
            #"{"schemaVersion":1,"features":["spatialDoubleClick"],"extra":{"a":1,"a":2}}"#,
            #"{"schemaVersion":1,"features":["spatialDoubleClick"],"extra":[{"a":[true,false,null]}]}"#,
            #"{"schemaVersion":1,"features":["{\"schemaVersion\":1}"]}"#
        ] {
            assertInvalid(contents)
        }
    }

    func testExcessiveJSONNestingRejects() {
        let nested = String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)
        assertInvalid(#"{"schemaVersion":1,"features":["spatialDoubleClick"],"extra":"# + nested + "}")
    }

    func testEscapedFeatureAndKeySpellingDecodeButRemainUnavailable() throws {
        let contents = #"{"schema\u0056ersion":1,"features":["spatial\u0044oubleClick"]}"#
        let configuration = try ExperimentalConfiguration.decode(Data(contents.utf8))
        XCTAssertEqual(configuration.schemaVersion, 1)
        XCTAssertEqual(configuration.features, [.spatialDoubleClick])
        let result = evaluate(contents: contents)
        assertRejected(result)
        XCTAssertTrue(result.diagnostics[0].contains("live dispatch is unavailable"))
    }

    func testAllRecognizedFeaturesRemainIndividuallyUnavailable() {
        for feature in ["spatialDoubleClick", "twoFingerScroll", "explicitRouting"] {
            let result = evaluate(contents: "{\"schemaVersion\":1,\"features\":[\"\(feature)\"]}")
            assertRejected(result)
            XCTAssertTrue(result.diagnostics[0].contains(feature))
            XCTAssertTrue(result.diagnostics[0].contains("Pure models are for deterministic tests only"))
        }
    }

    func testCombinedRequestListsEveryReadinessBlockerWithoutStartup() {
        let result = evaluate(contents: #"{"schemaVersion":1,"features":["explicitRouting","spatialDoubleClick","twoFingerScroll"]}"#)
        assertRejected(result)
        XCTAssertTrue(result.diagnostics[0].contains("attributed exclusive endpoint"))
        XCTAssertTrue(result.diagnostics[0].contains("verified source lifecycle"))
        XCTAssertTrue(result.diagnostics[0].contains("single-touch"))
    }

    func testRejectedGateCannotConstructAnyApplicationOrInputDependency() {
        var effects: [String] = []
        let result = ExperimentalStartupGate.run(
            arguments: ["--experimental-config", "explicit.json"],
            readConfiguration: { _ in effects.append("read"); return Data(self.validRequest.utf8) },
            reportRejection: { _ in effects.append("reject") },
            startLegacy: {
                effects += ["config", "logger", "source", "input", "AX", "application", "permission", "HID"]
                return 0
            }
        )
        XCTAssertEqual(result, 78)
        XCTAssertEqual(effects, ["read", "reject"])
    }

    private var validRequest: String {
        #"{"schemaVersion":1,"features":["spatialDoubleClick"]}"#
    }

    private struct Result {
        let exit: Int32
        let starts: Int
        let reads: [String]
        let diagnostics: [String]
    }

    private func evaluate(_ arguments: [String] = ["--experimental-config", "trial.json"], contents: String) -> Result {
        var starts = 0
        var reads: [String] = []
        var diagnostics: [String] = []
        let exit = ExperimentalStartupGate.run(
            arguments: arguments,
            readConfiguration: { reads.append($0); return Data(contents.utf8) },
            reportRejection: { diagnostics.append($0) },
            startLegacy: { starts += 1; return 17 }
        )
        return Result(exit: exit, starts: starts, reads: reads, diagnostics: diagnostics)
    }

    private func assertRejected(_ result: Result, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.exit, 78, file: file, line: line)
        XCTAssertEqual(result.starts, 0, file: file, line: line)
        XCTAssertEqual(result.diagnostics.count, 1, file: file, line: line)
    }

    private func assertInvalid(_ contents: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ExperimentalConfiguration.decode(Data(contents.utf8)), file: file, line: line)
        let result = evaluate(contents: contents)
        assertRejected(result, file: file, line: line)
        XCTAssertTrue(result.diagnostics[0].contains("invalid versioned request"), contents, file: file, line: line)
    }
}
