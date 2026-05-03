import Foundation
import MacXeneonEdgeTouchDriverCore
import XCTest

final class DriverFileLogTests: XCTestCase {
    func testWritesDriverLogLineToConfiguredFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MacXeneonEdgeTouchDriverFileLogTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("driver.log", isDirectory: false)
        let fileLog = DriverFileLog()

        try fileLog.configure(fileLogPath: logURL.path, maxBytes: 65_536)
        fileLog.write(level: .notice, category: .lifecycle, message: "test diagnostics message")
        try fileLog.configure(fileLogPath: nil, maxBytes: 65_536)

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("NOTICE [lifecycle] test diagnostics message"))
    }

    func testConfiguredMinimumLevelFiltersLowerPriorityMessages() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MacXeneonEdgeTouchDriverFileLogTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("driver.log", isDirectory: false)
        let fileLog = DriverFileLog()

        try fileLog.configure(fileLogPath: logURL.path, maxBytes: 65_536, minimumLevel: .warning)
        fileLog.write(level: .debug, category: .lifecycle, message: "debug diagnostics message")
        fileLog.write(level: .warning, category: .lifecycle, message: "warning diagnostics message")
        try fileLog.configure(fileLogPath: nil, maxBytes: 65_536)

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("debug diagnostics message"))
        XCTAssertTrue(contents.contains("WARNING [lifecycle] warning diagnostics message"))
    }
}
