import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class DriverFileLogRecoveryTests: XCTestCase {
    func testFailedWriteWaitsForCooldownAndWritesOnlyTheRecoveryMessage() throws {
        let fixture = FileLogRecoveryFixture()
        let log = fixture.makeLog()
        try log.configure(fileLogPath: fixture.url.path, maxBytes: 65_536)
        fixture.io.writeFailure = .beforeWrite

        log.write(level: .notice, category: .lifecycle, message: "failed")
        XCTAssertEqual(fixture.io.openedURLs, [fixture.url])
        XCTAssertEqual(fixture.io.closeCount, 1)
        XCTAssertEqual(fixture.failures, [.write])

        fixture.io.writeFailure = nil
        fixture.uptime = 4.999
        for _ in 0..<100 {
            log.write(level: .notice, category: .lifecycle, message: "cooldown")
        }
        XCTAssertEqual(fixture.io.openedURLs.count, 1)
        XCTAssertEqual(fixture.io.writeCount, 1)
        XCTAssertEqual(fixture.timestampReads, 1)

        fixture.uptime = 5
        log.write(level: .notice, category: .lifecycle, message: "recovered")
        XCTAssertEqual(fixture.io.openedURLs, [fixture.url, fixture.url])
        XCTAssertEqual(fixture.io.writeCount, 2)
        XCTAssertEqual(fixture.io.text(at: fixture.url), fixture.line("recovered"))
        XCTAssertEqual(fixture.failures, [.write])
    }

    func testWriteWithSideEffectsIsNeverReplayedAfterAnError() throws {
        let fixture = FileLogRecoveryFixture()
        let log = fixture.makeLog()
        try log.configure(fileLogPath: fixture.url.path, maxBytes: 65_536)
        fixture.io.writeFailure = .afterWrite
        log.write(level: .notice, category: .lifecycle, message: "possibly committed")

        fixture.io.writeFailure = nil
        fixture.uptime = 5
        log.write(level: .notice, category: .lifecycle, message: "next")

        XCTAssertEqual(fixture.io.text(at: fixture.url), fixture.line("possibly committed") + fixture.line("next"))
        XCTAssertEqual(fixture.io.writeCount, 2)
    }

    func testSustainedOpenFailureRetriesOncePerCooldownAndReportsOnce() throws {
        let fixture = FileLogRecoveryFixture()
        let log = fixture.makeLog()
        try log.configure(fileLogPath: fixture.url.path, maxBytes: 65_536)
        fixture.io.writeFailure = .beforeWrite
        log.write(level: .notice, category: .lifecycle, message: "failed")
        fixture.io.writeFailure = nil
        fixture.io.failOpen = true

        for deadline in [5.0, 10.0, 15.0] {
            fixture.uptime = deadline
            for _ in 0..<100 {
                log.write(level: .notice, category: .lifecycle, message: "unavailable")
            }
        }
        XCTAssertEqual(fixture.io.openedURLs.count, 4)
        XCTAssertEqual(fixture.io.writeCount, 1)
        XCTAssertEqual(fixture.failures, [.write])

        fixture.io.failOpen = false
        fixture.uptime = 19.999
        log.write(level: .notice, category: .lifecycle, message: "too early")
        XCTAssertEqual(fixture.io.openedURLs.count, 4)
        fixture.uptime = 20
        log.write(level: .notice, category: .lifecycle, message: "repaired")
        XCTAssertEqual(fixture.io.openedURLs.count, 5)
        XCTAssertEqual(fixture.io.text(at: fixture.url), fixture.line("repaired"))
    }

    func testReopeningWithoutASuccessfulWriteDoesNotResetFailureReporting() throws {
        let fixture = FileLogRecoveryFixture()
        let log = fixture.makeLog()
        try log.configure(fileLogPath: fixture.url.path, maxBytes: 65_536)
        fixture.io.writeFailure = .beforeWrite
        for time in [0.0, 5.0, 10.0] {
            fixture.uptime = time
            log.write(level: .notice, category: .lifecycle, message: "still failing")
        }
        XCTAssertEqual(fixture.io.openedURLs.count, 3)
        XCTAssertEqual(fixture.io.writeCount, 3)
        XCTAssertEqual(fixture.failures, [.write])

        fixture.io.writeFailure = nil
        fixture.uptime = 15
        log.write(level: .notice, category: .lifecycle, message: "recovered")
        fixture.io.writeFailure = .beforeWrite
        log.write(level: .notice, category: .lifecycle, message: "new outage")
        XCTAssertEqual(fixture.failures, [.write, .write])
        XCTAssertEqual(fixture.io.text(at: fixture.url), fixture.line("recovered"))
    }

    func testFailedRotationIsRetriedBeforeAppendingAndDoesNotDuplicateTheWrittenLine() throws {
        let fixture = FileLogRecoveryFixture()
        let log = fixture.makeLog()
        try log.configure(fileLogPath: fixture.url.path, maxBytes: 65_536)
        fixture.io.failRotate = true
        let largeMessage = String(repeating: "x", count: 65_536)
        log.write(level: .notice, category: .lifecycle, message: largeMessage)
        XCTAssertEqual(fixture.io.closeCount, 1)
        XCTAssertEqual(fixture.failures, [.rotate])
        XCTAssertEqual(fixture.io.text(at: fixture.url), fixture.line(largeMessage))

        fixture.uptime = 5
        for _ in 0..<100 {
            log.write(level: .notice, category: .lifecycle, message: "rotation blocked")
        }
        XCTAssertEqual(fixture.io.rotateCount, 2)
        XCTAssertEqual(fixture.io.openedURLs.count, 1)
        XCTAssertEqual(fixture.io.writeCount, 1)
        XCTAssertEqual(fixture.failures, [.rotate])

        fixture.io.failRotate = false
        fixture.uptime = 10
        log.write(level: .notice, category: .lifecycle, message: "after rotation")
        XCTAssertEqual(fixture.io.rotateCount, 3)
        XCTAssertEqual(fixture.io.text(at: fixture.url.appendingPathExtension("1")), fixture.line(largeMessage))
        XCTAssertEqual(fixture.io.text(at: fixture.url), fixture.line("after rotation"))
        XCTAssertEqual(fixture.io.writeCount, 2)
    }

    func testFailedReopenAfterRotationPreservesTheBackupOnRecovery() throws {
        let fixture = FileLogRecoveryFixture()
        let log = fixture.makeLog()
        try log.configure(fileLogPath: fixture.url.path, maxBytes: 65_536)
        fixture.io.failOpen = true
        let largeMessage = String(repeating: "y", count: 65_536)
        log.write(level: .notice, category: .lifecycle, message: largeMessage)
        XCTAssertNil(fixture.io.files[fixture.url])
        XCTAssertEqual(fixture.io.rotateCount, 1)
        XCTAssertEqual(fixture.failures, [.open])

        fixture.io.failOpen = false
        fixture.uptime = 5
        log.write(level: .notice, category: .lifecycle, message: "new file")
        XCTAssertEqual(fixture.io.rotateCount, 1)
        XCTAssertEqual(fixture.io.text(at: fixture.url.appendingPathExtension("1")), fixture.line(largeMessage))
        XCTAssertEqual(fixture.io.text(at: fixture.url), fixture.line("new file"))
        XCTAssertEqual(fixture.io.writeCount, 2)
    }

    func testCloseFailureDuringRotationDoesNotKeepUsingTheDetachedHandle() throws {
        let fixture = FileLogRecoveryFixture()
        let log = fixture.makeLog()
        try log.configure(fileLogPath: fixture.url.path, maxBytes: 65_536)
        fixture.io.failClose = true
        let largeMessage = String(repeating: "c", count: 65_536)
        log.write(level: .notice, category: .lifecycle, message: largeMessage)
        XCTAssertEqual(fixture.failures, [.close])
        XCTAssertEqual(fixture.io.closeCount, 1)
        XCTAssertEqual(fixture.io.rotateCount, 0)

        fixture.io.failClose = false
        fixture.uptime = 5
        log.write(level: .notice, category: .lifecycle, message: "after close failure")
        XCTAssertEqual(fixture.io.openedURLs.count, 2)
        XCTAssertEqual(fixture.io.closeCount, 1)
        XCTAssertEqual(fixture.io.rotateCount, 1)
        XCTAssertEqual(fixture.io.text(at: fixture.url.appendingPathExtension("1")), fixture.line(largeMessage))
        XCTAssertEqual(fixture.io.text(at: fixture.url), fixture.line("after close failure"))
    }

    func testOffsetFailureDoesNotReplayTheAlreadyWrittenMessage() throws {
        let fixture = FileLogRecoveryFixture()
        let log = fixture.makeLog()
        try log.configure(fileLogPath: fixture.url.path, maxBytes: 65_536)
        fixture.io.failOffset = true
        log.write(level: .notice, category: .lifecycle, message: "written before offset failure")
        fixture.io.failOffset = false
        fixture.uptime = 5
        log.write(level: .notice, category: .lifecycle, message: "next")
        XCTAssertEqual(fixture.failures, [.offset])
        XCTAssertEqual(fixture.io.text(at: fixture.url), fixture.line("written before offset failure") + fixture.line("next"))
    }

    func testReconfigurationDuringCooldownWritesOnlyToTheNewDestination() throws {
        let fixture = FileLogRecoveryFixture()
        let log = fixture.makeLog()
        try log.configure(fileLogPath: fixture.url.path, maxBytes: 65_536)
        fixture.io.writeFailure = .afterWrite
        log.write(level: .notice, category: .lifecycle, message: "old destination")
        fixture.io.writeFailure = nil
        let newURL = fixture.url.deletingLastPathComponent().appendingPathComponent("new.log")

        try log.configure(fileLogPath: newURL.path, maxBytes: 65_536, minimumLevel: .warning)
        log.write(level: .notice, category: .lifecycle, message: "filtered")
        log.write(level: .warning, category: .lifecycle, message: "new immediately")
        fixture.uptime = 100
        log.write(level: .warning, category: .lifecycle, message: "new later")

        XCTAssertEqual(fixture.io.openedURLs, [fixture.url, newURL])
        XCTAssertEqual(fixture.io.text(at: fixture.url), fixture.line("old destination"))
        XCTAssertEqual(fixture.io.text(at: newURL), fixture.line("new immediately", level: "WARNING") + fixture.line("new later", level: "WARNING"))
        XCTAssertEqual(fixture.io.writeCount, 3)
    }

    func testDisablingWithNilOrEmptyPathCancelsPendingRecovery() throws {
        let disabledPaths: [String?] = [nil, ""]
        for disabledPath in disabledPaths {
            let fixture = FileLogRecoveryFixture()
            let log = fixture.makeLog()
            try log.configure(fileLogPath: fixture.url.path, maxBytes: 65_536)
            fixture.io.writeFailure = .beforeWrite
            log.write(level: .notice, category: .lifecycle, message: "failed")
            try log.configure(fileLogPath: disabledPath, maxBytes: 65_536)
            fixture.io.writeFailure = nil
            fixture.uptime = 100
            log.write(level: .fault, category: .lifecycle, message: "disabled")
            XCTAssertEqual(fixture.io.openedURLs, [fixture.url])
            XCTAssertEqual(fixture.io.writeCount, 1)
        }
    }

    func testFailedReconfigurationCannotReopenTheOldOrRejectedDestination() throws {
        let fixture = FileLogRecoveryFixture()
        let log = fixture.makeLog()
        try log.configure(fileLogPath: fixture.url.path, maxBytes: 65_536)
        fixture.io.writeFailure = .beforeWrite
        log.write(level: .notice, category: .lifecycle, message: "failed")
        let newURL = fixture.url.deletingLastPathComponent().appendingPathComponent("rejected.log")
        fixture.io.failOpen = true
        XCTAssertThrowsError(try log.configure(fileLogPath: newURL.path, maxBytes: 65_536))
        fixture.io.failOpen = false
        fixture.io.writeFailure = nil
        fixture.uptime = 100
        log.write(level: .notice, category: .lifecycle, message: "must stay disabled")
        XCTAssertEqual(fixture.io.openedURLs, [fixture.url, newURL])
        XCTAssertEqual(fixture.io.writeCount, 1)

        try log.configure(fileLogPath: newURL.path, maxBytes: 65_536)
        log.write(level: .notice, category: .lifecycle, message: "explicitly enabled")
        XCTAssertEqual(fixture.io.text(at: newURL), fixture.line("explicitly enabled"))
    }

    func testCloseFailureDuringReconfigurationCannotLeaveAStaleWriter() throws {
        let fixture = FileLogRecoveryFixture()
        let log = fixture.makeLog()
        try log.configure(fileLogPath: fixture.url.path, maxBytes: 65_536)
        fixture.io.failClose = true
        XCTAssertThrowsError(try log.configure(fileLogPath: nil, maxBytes: 65_536))
        fixture.io.failClose = false
        fixture.uptime = 100
        log.write(level: .notice, category: .lifecycle, message: "stale")
        XCTAssertEqual(fixture.io.openedURLs, [fixture.url])
        XCTAssertEqual(fixture.io.closeCount, 1)
        XCTAssertEqual(fixture.io.writeCount, 0)
    }

    func testFilteringAndWallClockChangesDoNotTriggerAnEarlyRetry() throws {
        let fixture = FileLogRecoveryFixture()
        let log = fixture.makeLog()
        try log.configure(fileLogPath: fixture.url.path, maxBytes: 65_536)
        fixture.io.writeFailure = .beforeWrite
        log.write(level: .notice, category: .lifecycle, message: "failed")
        fixture.io.writeFailure = nil
        fixture.date = Date(timeIntervalSince1970: 1_000_000)
        fixture.uptime = 4
        log.write(level: .notice, category: .lifecycle, message: "wall clock jumped")
        fixture.uptime = 5
        log.write(level: .debug, category: .lifecycle, message: "filtered")
        XCTAssertEqual(fixture.io.openedURLs.count, 1)
        XCTAssertEqual(fixture.timestampReads, 1)

        fixture.date = Date(timeIntervalSince1970: 0)
        log.write(level: .notice, category: .lifecycle, message: "eligible")
        XCTAssertEqual(fixture.io.openedURLs.count, 2)
        XCTAssertEqual(fixture.io.text(at: fixture.url), fixture.line("eligible"))
    }

    func testNormalWritesPreserveAppendRotationLimitAndTildeExpansion() throws {
        let fixture = FileLogRecoveryFixture()
        let log = fixture.makeLog()
        let path = "~/file-log-recovery-tests/driver.log"
        let expandedURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        fixture.io.files[expandedURL] = Data("existing\n".utf8)
        try log.configure(fileLogPath: path, maxBytes: 1)
        log.write(level: .notice, category: .lifecycle, message: "appended")
        XCTAssertEqual(fixture.io.openedURLs, [expandedURL])
        XCTAssertEqual(fixture.io.text(at: expandedURL), "existing\n" + fixture.line("appended"))
        XCTAssertEqual(fixture.io.rotateCount, 0)

        let largeMessage = String(repeating: "z", count: 65_536)
        log.write(level: .notice, category: .lifecycle, message: largeMessage)
        XCTAssertEqual(fixture.io.rotateCount, 1)
        XCTAssertEqual(fixture.io.text(at: expandedURL.appendingPathExtension("1")), "existing\n" + fixture.line("appended") + fixture.line(largeMessage))
        XCTAssertEqual(fixture.io.text(at: expandedURL), "")
        XCTAssertTrue(fixture.failures.isEmpty)
    }
}

private final class FileLogRecoveryFixture {
    let url = URL(fileURLWithPath: "/file-log-recovery-tests/driver.log")
    let io = FakeFileLogIO()
    var uptime: TimeInterval = 0
    var date = Date(timeIntervalSince1970: 0)
    var timestampReads = 0
    var failures: [FakeFileLogIO.Failure] = []

    func makeLog() -> DriverFileLog {
        DriverFileLog(
            dateProvider: { self.timestampReads += 1; return self.date },
            timeZoneProvider: { TimeZone(secondsFromGMT: 0)! },
            uptimeProvider: { self.uptime },
            operations: io.operations,
            reportFailure: { error in
                guard let failure = error as? FakeFileLogIO.Failure else {
                    XCTFail("Unexpected file log error: \(error)")
                    return
                }
                self.failures.append(failure)
            }
        )
    }

    func line(_ message: String, level: String = "NOTICE") -> String {
        "1970-01-01T00:00:00.000Z \(level) [lifecycle] \(message)\n"
    }
}

private final class FakeFileLogIO {
    enum Failure: Error, Equatable { case open, write, offset, rotate, close, closedHandle }
    enum WriteFailure: Equatable { case beforeWrite, afterWrite }
    var files: [URL: Data] = [:]
    var openedURLs: [URL] = []
    var writeCount = 0
    var closeCount = 0
    var rotateCount = 0
    var failOpen = false
    var failOffset = false
    var failRotate = false
    var failClose = false
    var writeFailure: WriteFailure?
    private var closedHandles: Set<Int> = []

    var operations: DriverFileLogOperations {
        DriverFileLogOperations(
            open: { url, _ in
                self.openedURLs.append(url)
                if self.failOpen { throw Failure.open }
                let identifier = self.openedURLs.count
                if self.files[url] == nil { self.files[url] = Data() }
                return DriverFileLogHandle(
                    write: { data in
                        self.writeCount += 1
                        if self.closedHandles.contains(identifier) { throw Failure.closedHandle }
                        if self.writeFailure == .beforeWrite { throw Failure.write }
                        self.files[url, default: Data()].append(data)
                        if self.writeFailure == .afterWrite { throw Failure.write }
                    },
                    offset: {
                        if self.closedHandles.contains(identifier) { throw Failure.closedHandle }
                        if self.failOffset { throw Failure.offset }
                        return UInt64(self.files[url]?.count ?? 0)
                    },
                    close: {
                        self.closeCount += 1
                        self.closedHandles.insert(identifier)
                        if self.failClose { throw Failure.close }
                    }
                )
            },
            size: { url, _ in self.files[url].map { UInt64($0.count) } },
            rotate: { url, _ in
                self.rotateCount += 1
                if self.failRotate { throw Failure.rotate }
                self.files[url.appendingPathExtension("1")] = self.files.removeValue(forKey: url)
            }
        )
    }

    func text(at url: URL) -> String {
        String(decoding: files[url, default: Data()], as: UTF8.self)
    }
}
