import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

// These tests exercise the existing synchronous lock/ownership contract. They do
// not make DriverFileLog or its injected closure graph universally Sendable.
// The fake independently locks every external and callback access, so a logger
// regression is an assertion failure, not an intentional race in the fixture.
final class DriverFileLogConcurrencyTests: XCTestCase {
    func testConcurrentWritesPreserveWholeUniqueLines() throws {
        let io = ConcurrentFileLogIO()
        let log = io.makeLog()
        defer { withExtendedLifetime(log) {} }
        try log.configure(fileLogPath: io.url.path, maxBytes: 1_000_000)

        try writeConcurrently(log, count: 64, prefix: "message-")

        let snapshot = io.snapshot()
        XCTAssertEqual(snapshot.writeAttempts, 64)
        XCTAssertEqual(Set(snapshot.lines(at: io.url)), Set((0..<64).map { io.line("message-\($0)") }))
        XCTAssertEqual(snapshot.openedURLs, [io.url])
        XCTAssertEqual(snapshot.closeCount, 0)
        assertValid(snapshot)
    }

    func testConcurrentFailuresRetryOncePerCooldownAndReportOncePerOutage() throws {
        let io = ConcurrentFileLogIO()
        let log = io.makeLog()
        defer { withExtendedLifetime(log) {} }
        try log.configure(fileLogPath: io.url.path, maxBytes: 1_000_000)
        io.setFailure(write: true)

        try writeConcurrently(log, count: 32, prefix: "failed-")
        var snapshot = io.snapshot()
        XCTAssertEqual(snapshot.writeAttempts, 1)
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertEqual(snapshot.failures, [.write])

        io.setFailure(write: false)
        io.setUptime(4.999)
        try writeConcurrently(log, count: 32, prefix: "cooldown-")
        snapshot = io.snapshot()
        XCTAssertEqual(snapshot.openedURLs.count, 1)
        XCTAssertEqual(snapshot.timestampReads, 1)

        io.setUptime(5)
        io.setFailure(open: true)
        try writeConcurrently(log, count: 32, prefix: "open still failing-")
        snapshot = io.snapshot()
        XCTAssertEqual(snapshot.openedURLs.count, 2)
        XCTAssertEqual(snapshot.writeAttempts, 1)
        XCTAssertEqual(snapshot.failures, [.write])

        io.setFailure(open: false)
        io.setUptime(10)
        try writeConcurrently(log, count: 32, prefix: "recovery-")
        snapshot = io.snapshot()
        XCTAssertEqual(snapshot.openedURLs.count, 3)
        XCTAssertEqual(snapshot.writeAttempts, 33)
        XCTAssertEqual(Set(snapshot.lines(at: io.url)), Set((0..<32).map { io.line("recovery-\($0)") }))
        XCTAssertEqual(snapshot.failures, [.write])

        io.setFailure(write: true)
        try writeConcurrently(log, count: 32, prefix: "new outage-")
        snapshot = io.snapshot()
        XCTAssertEqual(snapshot.writeAttempts, 34)
        XCTAssertEqual(snapshot.failures, [.write, .write])
        assertValid(snapshot, expectedFailures: [.write, .write])
    }

    func testConcurrentLargeWritesRotateClosedHandlesWithoutReplayingLines() throws {
        let io = ConcurrentFileLogIO()
        let log = io.makeLog()
        defer { withExtendedLifetime(log) {} }
        try log.configure(fileLogPath: io.url.path, maxBytes: 65_536)
        let payload = String(repeating: "x", count: 65_536)

        try writeConcurrently(log, count: 8, prefix: "large-", suffix: " \(payload)")

        let snapshot = io.snapshot()
        XCTAssertEqual(snapshot.writeAttempts, 8)
        XCTAssertEqual(snapshot.writtenLines.count, 8)
        XCTAssertEqual(Set(snapshot.writtenLines), Set((0..<8).map { io.line("large-\($0) \(payload)") }))
        XCTAssertEqual(snapshot.rotateCount, 8)
        XCTAssertEqual(snapshot.openedURLs.count, 9)
        XCTAssertEqual(snapshot.closeCount, 8)
        XCTAssertEqual(snapshot.openHandleCount, 1)
        XCTAssertEqual(snapshot.lines(at: io.url), [])
        assertValid(snapshot)
    }

    func testConcurrentConfigureAndWriteDoNotUseRetiredHandles() throws {
        let io = ConcurrentFileLogIO()
        let log = io.makeLog()
        defer { withExtendedLifetime(log) {} }
        try log.configure(fileLogPath: io.url.path, maxBytes: 1_000_000)

        let completed = DispatchGroup()
        for index in 0..<32 {
            completed.enter()
            DispatchQueue.global().async {
                defer { completed.leave() }
                if index.isMultiple(of: 2) {
                    log.write(level: .notice, category: .lifecycle, message: "write-\(index)")
                } else {
                    let url = io.url.deletingLastPathComponent().appendingPathComponent("destination-\(index).log")
                    do {
                        try log.configure(fileLogPath: url.path, maxBytes: 1_000_000)
                    } catch {
                        io.recordUnexpected(error)
                    }
                }
            }
        }
        try waitForCompletion(completed)

        let snapshot = io.snapshot()
        XCTAssertEqual(snapshot.writeAttempts, 16)
        XCTAssertEqual(snapshot.writtenLines.count, 16)
        XCTAssertEqual(Set(snapshot.writtenLines), Set(stride(from: 0, to: 32, by: 2).map { io.line("write-\($0)") }))
        XCTAssertEqual(snapshot.openedURLs.count, 17)
        XCTAssertEqual(snapshot.closeCount, 16)
        XCTAssertEqual(snapshot.openHandleCount, 1)
        assertValid(snapshot)
    }

    func testReconfigurationWaitsForAnAdmittedWriteBeforeRetiringItsHandle() throws {
        let io = ConcurrentFileLogIO()
        let log = io.makeLog()
        defer { withExtendedLifetime(log) {} }
        let gate = FileLogWriteGate()
        let configureStarted = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        let nextURL = io.url.deletingLastPathComponent().appendingPathComponent("next.log")
        try log.configure(fileLogPath: io.url.path, maxBytes: 1_000_000)
        io.blockNextWrite(with: gate)
        // Release on every exit, including an entry timeout before the worker ran.
        defer { gate.release.signal() }

        completed.enter()
        DispatchQueue.global().async {
            defer { completed.leave() }
            log.write(level: .notice, category: .lifecycle, message: "admitted")
        }
        try waitForSignal(gate.entered)

        completed.enter()
        DispatchQueue.global().async {
            defer { completed.leave() }
            configureStarted.signal()
            do {
                try log.configure(fileLogPath: nextURL.path, maxBytes: 1_000_000)
            } catch {
                io.recordUnexpected(error)
            }
        }
        try waitForSignal(configureStarted)
        gate.release.signal()
        try waitForCompletion(completed)
        log.write(level: .notice, category: .lifecycle, message: "new destination")

        let snapshot = io.snapshot()
        XCTAssertEqual(snapshot.lines(at: io.url), [io.line("admitted")])
        XCTAssertEqual(snapshot.lines(at: nextURL), [io.line("new destination")])
        let writeEnd = try XCTUnwrap(snapshot.events.firstIndex(of: "write.end:1"))
        let oldClose = try XCTUnwrap(snapshot.events.firstIndex(of: "close:1"))
        let newOpen = try XCTUnwrap(snapshot.events.firstIndex(of: "open:2"))
        XCTAssertLessThan(writeEnd, oldClose)
        XCTAssertLessThan(oldClose, newOpen)
        assertValid(snapshot)
    }

    func testOffMainFinalReleaseClosesOnceAfterTheAdmittedWriteFinishes() throws {
        let io = ConcurrentFileLogIO()
        let gate = FileLogWriteGate()
        let closed = DispatchSemaphore(value: 0)
        var log: DriverFileLog? = io.makeLog()
        try log?.configure(fileLogPath: io.url.path, maxBytes: 1_000_000)
        io.blockNextWrite(with: gate)
        io.notifyClose(with: closed)
        defer { gate.release.signal() }

        // The capture owns the logger while this test releases its reference.
        // No unsafe/unretained reference, mutable captured log variable, or
        // callback back-reference extends or races the logger's lifetime.
        DispatchQueue.global().async { [writer = try XCTUnwrap(log)] in
            writer.write(level: .notice, category: .lifecycle, message: "last owner")
        }
        try waitForSignal(gate.entered)
        log = nil
        XCTAssertEqual(io.snapshot().closeCount, 0)
        gate.release.signal()
        try waitForSignal(closed)

        let snapshot = io.snapshot()
        XCTAssertEqual(snapshot.lines(at: io.url), [io.line("last owner")])
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertEqual(snapshot.closeWasMainThread, [false])
        XCTAssertEqual(snapshot.openHandleCount, 0)
        let writeEnd = try XCTUnwrap(snapshot.events.firstIndex(of: "write.end:1"))
        let close = try XCTUnwrap(snapshot.events.firstIndex(of: "close:1"))
        XCTAssertLessThan(writeEnd, close)
        assertValid(snapshot)
    }

    private func assertValid(
        _ snapshot: ConcurrentFileLogIO.Snapshot,
        expectedFailures: [ConcurrentFileLogIO.Failure] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(snapshot.failures, expectedFailures, file: file, line: line)
        XCTAssertEqual(snapshot.invalidHandleUses, 0, file: file, line: line)
        XCTAssertEqual(snapshot.maxConcurrentCallbacks, 1, file: file, line: line)
        XCTAssertTrue(snapshot.unexpectedErrors.isEmpty, "\(snapshot.unexpectedErrors)", file: file, line: line)
    }

    private func writeConcurrently(_ log: DriverFileLog, count: Int, prefix: String, suffix: String = "") throws {
        let completed = DispatchGroup()
        for index in 0..<count {
            completed.enter()
            DispatchQueue.global().async {
                defer { completed.leave() }
                log.write(level: .notice, category: .lifecycle, message: "\(prefix)\(index)\(suffix)")
            }
        }
        // An unsuccessful drain throws, skipping every dependent test phase.
        // Queued jobs retain their logger and independently synchronized fake.
        try waitForCompletion(completed)
    }

    private func waitForSignal(_ semaphore: DispatchSemaphore) throws {
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw ConcurrentFileLogIO.Failure.waitTimedOut
        }
    }

    private func waitForCompletion(_ group: DispatchGroup) throws {
        guard group.wait(timeout: .now() + 5) == .success else {
            throw ConcurrentFileLogIO.Failure.waitTimedOut
        }
    }
}

private struct FileLogWriteGate: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func block() throws {
        entered.signal()
        guard release.wait(timeout: .now() + 5) == .success else {
            throw ConcurrentFileLogIO.Failure.waitTimedOut
        }
    }
}

private final class ConcurrentFileLogIO {
    enum Failure: Error, Equatable, Sendable { case open, write, closedHandle, waitTimedOut }

    struct Snapshot: Sendable {
        var files: [URL: Data] = [:]
        var openedURLs: [URL] = []
        var writtenLines: [String] = []
        var writeAttempts = 0
        var closeCount = 0
        var closeWasMainThread: [Bool] = []
        var rotateCount = 0
        var timestampReads = 0
        var failures: [Failure] = []
        var unexpectedErrors: [String] = []
        var invalidHandleUses = 0
        var openHandleCount = 0
        var maxConcurrentCallbacks = 0
        var events: [String] = []

        func lines(at url: URL) -> [String] {
            String(decoding: files[url, default: Data()], as: UTF8.self)
                .split(separator: "\n").map { String($0) + "\n" }
        }
    }

    let url = URL(fileURLWithPath: "/file-log-concurrency-tests/driver.log")
    private let lock = NSLock()
    private var state = Snapshot()
    private var uptime: TimeInterval = 0
    private var failOpen = false
    private var failWrite = false
    private var nextHandle = 0
    private var handles: [Int: URL] = [:]
    private var activeCallbacks = 0
    private var nextWriteGate: FileLogWriteGate?
    private var closeSignal: DispatchSemaphore?

    func makeLog() -> DriverFileLog {
        DriverFileLog(
            dateProvider: {
                self.callback {
                    self.withLock { self.state.timestampReads += 1 }
                    return Date(timeIntervalSince1970: 0)
                }
            },
            timeZoneProvider: { TimeZone(secondsFromGMT: 0)! },
            uptimeProvider: { self.callback { self.withLock { self.uptime } } },
            operations: DriverFileLogOperations(
                open: { url, _ in try self.open(url) },
                size: { url, _ in self.callback { self.withLock { self.state.files[url].map { UInt64($0.count) } } } },
                rotate: { url, _ in self.rotate(url) }
            ),
            reportFailure: { error in
                self.callback {
                    self.withLock {
                        if let failure = error as? Failure {
                            self.state.failures.append(failure)
                        } else {
                            self.state.unexpectedErrors.append(String(describing: error))
                        }
                    }
                }
            }
        )
    }

    func snapshot() -> Snapshot { withLock { state } }
    func setUptime(_ value: TimeInterval) { withLock { uptime = value } }
    func setFailure(open: Bool? = nil, write: Bool? = nil) {
        withLock {
            if let open { failOpen = open }
            if let write { failWrite = write }
        }
    }
    func blockNextWrite(with gate: FileLogWriteGate) { withLock { nextWriteGate = gate } }
    func notifyClose(with signal: DispatchSemaphore) { withLock { closeSignal = signal } }
    func recordUnexpected(_ error: Error) { withLock { state.unexpectedErrors.append(String(describing: error)) } }
    func line(_ message: String) -> String { "1970-01-01T00:00:00.000Z NOTICE [lifecycle] \(message)\n" }

    private func open(_ url: URL) throws -> DriverFileLogHandle {
        try callback {
            let identifier = try withLock {
                state.openedURLs.append(url)
                if failOpen { throw Failure.open }
                nextHandle += 1
                handles[nextHandle] = url
                state.openHandleCount = handles.count
                state.events.append("open:\(nextHandle)")
                if state.files[url] == nil { state.files[url] = Data() }
                return nextHandle
            }
            return DriverFileLogHandle(
                write: { data in try self.write(data, handle: identifier) },
                offset: { try self.offset(handle: identifier) },
                close: { try self.close(handle: identifier) }
            )
        }
    }

    private func write(_ data: Data, handle: Int) throws {
        try callback {
            let gate = withLock { () -> FileLogWriteGate? in
                state.writeAttempts += 1
                state.events.append("write.begin:\(handle)")
                let gate = nextWriteGate
                nextWriteGate = nil
                return gate
            }
            try gate?.block()
            try withLock {
                let url = try requireHandleLocked(handle)
                if failWrite { throw Failure.write }
                state.files[url, default: Data()].append(data)
                state.writtenLines.append(String(decoding: data, as: UTF8.self))
                state.events.append("write.end:\(handle)")
            }
        }
    }

    private func offset(handle: Int) throws -> UInt64 {
        try callback {
            try withLock {
                let url = try requireHandleLocked(handle)
                return UInt64(state.files[url]?.count ?? 0)
            }
        }
    }

    private func close(handle: Int) throws {
        // Signal after leaving callback accounting so a final-release snapshot
        // observes a fully completed close, not a half-finished fake callback.
        let signal: DispatchSemaphore? = try callback {
            try withLock {
                _ = try requireHandleLocked(handle)
                handles.removeValue(forKey: handle)
                state.openHandleCount = handles.count
                state.closeCount += 1
                state.closeWasMainThread.append(Thread.isMainThread)
                state.events.append("close:\(handle)")
                return closeSignal
            }
        }
        signal?.signal()
    }

    private func rotate(_ url: URL) {
        callback {
            withLock {
                state.rotateCount += 1
                if handles.values.contains(url) { state.invalidHandleUses += 1 }
                state.files[url.appendingPathExtension("1")] = state.files.removeValue(forKey: url)
            }
        }
    }

    // All callers hold the fake lock. No handle or state reference escapes.
    private func requireHandleLocked(_ handle: Int) throws -> URL {
        guard let url = handles[handle] else {
            state.invalidHandleUses += 1
            throw Failure.closedHandle
        }
        return url
    }

    private func callback<T>(_ body: () throws -> T) rethrows -> T {
        withLock {
            activeCallbacks += 1
            state.maxConcurrentCallbacks = max(state.maxConcurrentCallbacks, activeCallbacks)
        }
        defer { withLock { activeCallbacks -= 1 } }
        return try body()
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
