import Foundation
import MacXeneonEdgeTouchDriverCore
import XCTest

final class DriverFileLogTests: XCTestCase {
    func testWritesDriverLogLineToConfiguredFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MacXeneonEdgeTouchDriverFileLogTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("driver.log", isDirectory: false)

        try DriverFileLog.shared.configure(fileLogPath: logURL.path, maxBytes: 65_536)
        DriverLoggers.log(.notice, category: .lifecycle, "test diagnostics message")
        try DriverFileLog.shared.configure(fileLogPath: nil, maxBytes: 65_536)

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("NOTICE [lifecycle] test diagnostics message"))
    }
}
