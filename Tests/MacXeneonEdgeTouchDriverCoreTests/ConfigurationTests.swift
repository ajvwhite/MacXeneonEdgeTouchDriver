import Foundation
import MacXeneonEdgeTouchDriverCore
import XCTest

final class ConfigurationTests: XCTestCase {
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

    func testDirectTouchGestureSettingsLoad() throws {
        let url = try writeConfig("""
        {
          "gesture": {
            "holdToDragMs": 450,
            "movementThresholdPoints": 12,
            "scrollSensitivity": 1.5,
            "doubleClickDistancePoints": 16
          }
        }
        """)

        let result = DriverConfiguration.load(from: url)

        XCTAssertEqual(result.configuration.gesture.holdToDragMs, 450)
        XCTAssertEqual(result.configuration.gesture.movementThresholdPoints, 12)
        XCTAssertEqual(result.configuration.gesture.scrollSensitivity, 1.5)
        XCTAssertEqual(result.configuration.gesture.doubleClickDistancePoints, 16)
        XCTAssertTrue(result.warnings.isEmpty)
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
