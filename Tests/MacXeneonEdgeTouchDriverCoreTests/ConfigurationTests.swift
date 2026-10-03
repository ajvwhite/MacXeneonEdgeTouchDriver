import Foundation
import MacXeneonEdgeTouchDriverCore
import XCTest

final class ConfigurationTests: XCTestCase {
    func testFocusAndCursorRestorationAreEnabledByDefault() {
        XCTAssertTrue(DriverConfiguration.defaults.focus.restorePreviousWindow)
        XCTAssertTrue(DriverConfiguration.defaults.cursor.returnToPreviousPosition)
    }

    func testFocusAndCursorRestorationCanBeConfiguredIndependently() throws {
        for (restoreFocus, returnCursor) in [(true, true), (true, false), (false, true), (false, false)] {
            let url = try writeConfig("""
            {
              "logLevel": "debug",
              "timing": { "tapDebounceMs": 75 },
              "focus": { "restorePreviousWindow": \(restoreFocus) },
              "cursor": { "returnToPreviousPosition": \(returnCursor) }
            }
            """)

            let result = DriverConfiguration.load(from: url)
            var expected = DriverConfiguration.defaults
            expected.logLevel = "debug"
            expected.timing.tapDebounceMs = 75
            expected.focus.restorePreviousWindow = restoreFocus
            expected.cursor.returnToPreviousPosition = returnCursor

            XCTAssertEqual(result.configuration, expected)
            XCTAssertTrue(result.warnings.isEmpty)
        }
    }

    func testMissingOrNullFocusOptionsKeepRestorationEnabled() throws {
        for contents in [
            #"{"logLevel":"debug"}"#,
            #"{"focus":{}}"#,
            #"{"focus":null}"#,
            #"{"focus":{"restorePreviousWindow":null}}"#
        ] {
            let result = DriverConfiguration.load(from: try writeConfig(contents))

            XCTAssertTrue(result.configuration.focus.restorePreviousWindow, contents)
            XCTAssertTrue(result.warnings.isEmpty, contents)
        }
    }

    func testMissingOrNullCursorOptionsKeepReturnEnabledAndPreserveDisabledFocus() throws {
        for contents in [
            #"{"logLevel":"debug","focus":{"restorePreviousWindow":false}}"#,
            #"{"logLevel":"debug","focus":{"restorePreviousWindow":false},"cursor":{}}"#,
            #"{"logLevel":"debug","focus":{"restorePreviousWindow":false},"cursor":null}"#,
            #"{"logLevel":"debug","focus":{"restorePreviousWindow":false},"cursor":{"returnToPreviousPosition":null}}"#
        ] {
            let result = DriverConfiguration.load(from: try writeConfig(contents))
            var expected = DriverConfiguration.defaults
            expected.logLevel = "debug"
            expected.focus.restorePreviousWindow = false

            XCTAssertEqual(result.configuration, expected, contents)
            XCTAssertTrue(result.warnings.isEmpty, contents)
        }
    }

    func testMalformedFocusOptionsUseDefaultsWithWarning() throws {
        for contents in [
            #"{"focus":{"restorePreviousWindow":"false"}}"#,
            #"{"focus":{"restorePreviousWindow":0}}"#,
            #"{"focus":false}"#
        ] {
            let result = DriverConfiguration.load(from: try writeConfig(contents))

            XCTAssertEqual(result.configuration, .defaults, contents)
            XCTAssertEqual(result.warnings.count, 1, contents)
        }
    }

    func testMalformedCursorOptionsUseWholeConfigurationDefaultsWithWarning() throws {
        for cursor in [
            #"{"returnToPreviousPosition":"false"}"#,
            #"{"returnToPreviousPosition":0}"#,
            #"{"returnToPreviousPosition":[]}"#,
            #"false"#,
            #""disabled""#,
            #"[]"#
        ] {
            let contents = """
            {
              "logLevel": "debug",
              "focus": { "restorePreviousWindow": false },
              "cursor": \(cursor)
            }
            """
            let result = DriverConfiguration.load(from: try writeConfig(contents))

            XCTAssertEqual(result.configuration, .defaults, contents)
            XCTAssertEqual(result.warnings.count, 1, contents)
        }
    }

    func testFocusAndCursorRestorationCombinationsSurviveCodableRoundTrip() throws {
        for (restoreFocus, returnCursor) in [(true, true), (true, false), (false, true), (false, false)] {
            var configuration = DriverConfiguration.defaults
            configuration.logLevel = "debug"
            configuration.timing.tapDebounceMs = 75
            configuration.focus.restorePreviousWindow = restoreFocus
            configuration.cursor.returnToPreviousPosition = returnCursor

            let encoded = try JSONEncoder().encode(configuration)
            let decoded = try JSONDecoder().decode(DriverConfiguration.self, from: encoded)

            XCTAssertEqual(decoded, configuration)
        }
    }

    func testMissingOrNullRestorationOptionsDecodeWithDefaultsFromCompleteConfiguration() throws {
        var configuration = DriverConfiguration.defaults
        configuration.logLevel = "debug"
        configuration.focus.restorePreviousWindow = false
        configuration.cursor.returnToPreviousPosition = false
        let encoded = try JSONEncoder().encode(configuration)
        let complete = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        for (section, field) in [("focus", "restorePreviousWindow"), ("cursor", "returnToPreviousPosition")] {
            let variants: [(String, Any?)] = [
                ("absent section", nil),
                ("null section", NSNull()),
                ("absent field", [String: Any]()),
                ("null field", [field: NSNull()])
            ]
            for (description, value) in variants {
                var object = complete
                object[section] = value
                let data = try JSONSerialization.data(withJSONObject: object)
                let decoded = try JSONDecoder().decode(DriverConfiguration.self, from: data)
                var expected = configuration
                if section == "focus" {
                    expected.focus.restorePreviousWindow = true
                } else {
                    expected.cursor.returnToPreviousPosition = true
                }

                XCTAssertEqual(decoded, expected, "\(section): \(description)")
            }
        }
    }

    func testLegacyCompleteConfigurationWithoutCursorPreservesDisabledFocus() throws {
        var configuration = DriverConfiguration.defaults
        configuration.logLevel = "debug"
        configuration.focus.restorePreviousWindow = false
        let encoded = try JSONEncoder().encode(configuration)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "cursor")

        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(DriverConfiguration.self, from: data)

        XCTAssertEqual(decoded, configuration)
    }

    func testLegacyCompleteConfigurationWithoutFocusOrCursorEnablesBoth() throws {
        let encoded = try JSONEncoder().encode(DriverConfiguration.defaults)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "focus")
        legacy.removeValue(forKey: "cursor")

        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(DriverConfiguration.self, from: data)

        XCTAssertEqual(decoded, .defaults)
    }

    func testMissingFileUsesDefaultsWithWarning() {
        let url = temporaryDirectory().appendingPathComponent("missing.json")

        let result = DriverConfiguration.load(from: url)

        XCTAssertEqual(result.configuration, .defaults)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testPartialConfigurationUsesDefaultsForMissingFields() throws {
        let url = try writeConfig("""
        {
          "logLevel": "debug",
          "timing": {
            "tapDebounceMs": 75
          },
          "display": {
            "expectedWidth": 2560
          }
        }
        """)

        let result = DriverConfiguration.load(from: url)

        XCTAssertEqual(result.configuration.logLevel, "debug")
        XCTAssertEqual(result.configuration.timing.tapDebounceMs, 75)
        XCTAssertEqual(result.configuration.timing.downToUpDelayMs, DriverConfiguration.defaults.timing.downToUpDelayMs)
        XCTAssertEqual(result.configuration.display.expectedWidth, 2_560)
        XCTAssertEqual(result.configuration.display.expectedHeight, DriverConfiguration.defaults.display.expectedHeight)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testMalformedConfigurationUsesDefaultsWithWarning() throws {
        let url = try writeConfig("{ bad json")

        let result = DriverConfiguration.load(from: url)

        XCTAssertEqual(result.configuration, .defaults)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testInvalidLogLevelDefaultsWithWarning() throws {
        let url = try writeConfig("""
        {
          "logLevel": "chatty"
        }
        """)

        let result = DriverConfiguration.load(from: url)

        XCTAssertEqual(result.configuration.logLevel, DriverConfiguration.defaults.logLevel)
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testOutOfRangeValuesAreClamped() throws {
        let url = try writeConfig("""
        {
          "timing": {
            "warpToClickDelayMs": -5,
            "stuckGestureTimeoutMs": 999999
          },
          "diagnostics": {
            "fileLogMaxBytes": 1
          }
        }
        """)

        let result = DriverConfiguration.load(from: url)

        XCTAssertEqual(result.configuration.timing.warpToClickDelayMs, 0)
        XCTAssertEqual(result.configuration.timing.stuckGestureTimeoutMs, 60_000)
        XCTAssertEqual(result.configuration.diagnostics.fileLogMaxBytes, 65_536)
        XCTAssertEqual(result.warnings.count, 3)
    }

    func testMultiTouchCannotBeEnabledForSingleTouchHardware() throws {
        let url = try writeConfig("""
        {
          "gesture": {
            "multiTouchEnabled": true
          }
        }
        """)

        let result = DriverConfiguration.load(from: url)

        XCTAssertFalse(result.configuration.gesture.multiTouchEnabled)
        XCTAssertEqual(result.warnings.count, 1)
    }

    private func writeConfig(_ contents: String) throws -> URL {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        try contents.data(using: .utf8)?.write(to: url)
        return url
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MacXeneonEdgeTouchDriverTests", isDirectory: true)
    }
}
