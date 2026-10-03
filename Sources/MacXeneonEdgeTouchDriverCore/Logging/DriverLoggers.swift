import Foundation
import os

/// Log categories emitted by the driver.
public enum DriverLogCategory: String {
    case lifecycle
    case hid
    case gesture
    case cursor
    case display
    case focus
}

/// Log severity levels emitted by the driver.
public enum DriverLogLevel: String {
    case debug = "DEBUG"
    case notice = "NOTICE"
    case warning = "WARNING"
    case error = "ERROR"
    case fault = "FAULT"

    /// Creates a log level from a user-facing configuration name.
    public init?(configurationName: String) {
        switch configurationName.lowercased() {
        case "debug":
            self = .debug
        case "info", "notice":
            self = .notice
        case "warning", "warn":
            self = .warning
        case "error":
            self = .error
        case "fault":
            self = .fault
        default:
            return nil
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .debug:
            return 0
        case .notice:
            return 1
        case .warning:
            return 2
        case .error:
            return 3
        case .fault:
            return 4
        }
    }
}

/// Shared `os.Logger` instances used by the driver.
public enum DriverLoggers {
    /// Unified logging subsystem and LaunchAgent label.
    public static let subsystem = "com.ajvwhite.MacXeneonEdgeTouchDriver"

    /// Lifecycle and process startup/shutdown events.
    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")

    /// HID discovery, parsing, and device hotplug events.
    public static let hid = Logger(subsystem: subsystem, category: "hid")

    /// Gesture state machine transitions.
    public static let gesture = Logger(subsystem: subsystem, category: "gesture")

    /// Cursor borrow, warp, hide, and restore operations.
    public static let cursor = Logger(subsystem: subsystem, category: "cursor")

    /// Display discovery and reconfiguration events.
    public static let display = Logger(subsystem: subsystem, category: "display")

    /// Focus capture and restoration events.
    public static let focus = Logger(subsystem: subsystem, category: "focus")

    /// Writes a message to Unified Logging and the configured diagnostics file.
    public static func log(_ level: DriverLogLevel, category: DriverLogCategory, _ message: String) {
        let logger = logger(for: category)

        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        case .fault:
            logger.fault("\(message, privacy: .public)")
        }

        DriverFileLog.shared.write(level: level, category: category, message: message)
    }

    private static func logger(for category: DriverLogCategory) -> Logger {
        switch category {
        case .lifecycle:
            return lifecycle
        case .hid:
            return hid
        case .gesture:
            return gesture
        case .cursor:
            return cursor
        case .display:
            return display
        case .focus:
            return focus
        }
    }
}

// Internal I/O seams keep failure and recovery tests independent of filesystem timing.
struct DriverFileLogHandle {
    var write: (Data) throws -> Void
    var offset: () throws -> UInt64
    var close: () throws -> Void
}

struct DriverFileLogOperations {
    var open: (URL, FileManager) throws -> DriverFileLogHandle
    var size: (URL, FileManager) -> UInt64?
    var rotate: (URL, FileManager) throws -> Void

    // Construct per logger; no shared storage of non-Sendable I/O closures.
    static var live: DriverFileLogOperations {
        DriverFileLogOperations(
            open: { url, fileManager in
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: url.path) {
                    fileManager.createFile(atPath: url.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: url)
                do {
                    try handle.seekToEnd()
                } catch {
                    try? handle.close()
                    throw error
                }
                return DriverFileLogHandle(
                    write: { try handle.write(contentsOf: $0) },
                    offset: { try handle.offset() },
                    close: { try handle.close() }
                )
            },
            size: { url, fileManager in
                guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                      let size = attributes[.size] as? NSNumber else {
                    return nil
                }
                return size.uint64Value
            },
            rotate: { url, fileManager in
                let rotatedURL = url.appendingPathExtension("1")
                if fileManager.fileExists(atPath: rotatedURL.path) {
                    try fileManager.removeItem(at: rotatedURL)
                }
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.moveItem(at: url, to: rotatedURL)
                }
            }
        )
    }
}

/// Mirrors driver log messages to a rotating diagnostics file.
public final class DriverFileLog {
    /// Shared diagnostics file writer.
    public static let shared = DriverFileLog()

    private let lock = NSLock()
    private let dateFormatter = DateFormatter()
    private let dateProvider: () -> Date
    private let timeZoneProvider: () -> TimeZone
    private let uptimeProvider: () -> TimeInterval
    private let operations: DriverFileLogOperations
    private let reportFailure: (Error) -> Void
    private static let retryInterval: TimeInterval = 5
    private var fileURL: URL?
    private var maxBytes: Int = 0
    private var fileHandle: DriverFileLogHandle?
    private var fileManager: FileManager = .default
    private var minimumLevel: DriverLogLevel = .notice
    private var retryAfter: TimeInterval?
    private var failureReported = false

    public convenience init() {
        self.init(
            dateProvider: Date.init,
            timeZoneProvider: { .autoupdatingCurrent }
        )
    }

    init(
        dateProvider: @escaping () -> Date,
        timeZoneProvider: @escaping () -> TimeZone,
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        operations: DriverFileLogOperations = .live,
        reportFailure: @escaping (Error) -> Void = { error in
            // Do not call DriverLoggers.log: it would re-enter this sink under its lock.
            DriverLoggers.lifecycle.error("Diagnostics file logging interrupted: \(error.localizedDescription, privacy: .public). Will retry on eligible messages after a 5-second cooldown; interrupted messages are not replayed.")
        }
    ) {
        self.dateProvider = dateProvider
        self.timeZoneProvider = timeZoneProvider
        self.uptimeProvider = uptimeProvider
        self.operations = operations
        self.reportFailure = reportFailure
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Opens the diagnostics log file. Pass `nil` or an empty path to disable file logging.
    public func configure(
        fileLogPath: String?,
        maxBytes: Int,
        minimumLevel: DriverLogLevel = .notice,
        fileManager: FileManager = .default
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        // Retire the old destination before any throwing work, including close.
        // An unsuccessful explicit configuration stays disabled, with no stale retry.
        fileURL = nil
        self.maxBytes = 0
        retryAfter = nil
        failureReported = false
        self.minimumLevel = minimumLevel
        self.fileManager = fileManager
        try closeLocked()

        guard let fileLogPath, !fileLogPath.isEmpty else {
            return
        }

        let expandedPath = NSString(string: fileLogPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath, isDirectory: false)
        let limit = max(65_536, maxBytes)
        let handle = try openLocked(fileURL: url, maxBytes: limit)
        fileURL = url
        self.maxBytes = limit
        fileHandle = handle
    }

    /// Writes one diagnostics log line if file logging is configured.
    /// After an I/O failure, eligible messages retry at most once per five seconds.
    /// Failed and cooldown messages are not replayed, since a failed write may be partial.
    public func write(level: DriverLogLevel, category: DriverLogCategory, message: String) {
        lock.lock()
        defer { lock.unlock() }

        guard level.priority >= minimumLevel.priority else {
            return
        }

        guard let fileURL else {
            return
        }

        if fileHandle == nil {
            guard let retryAfter, uptimeProvider() >= retryAfter else {
                return
            }
            do {
                fileHandle = try openLocked(fileURL: fileURL, maxBytes: maxBytes)
            } catch {
                suspendLocked(after: error)
                return
            }
        }
        guard let fileHandle else { return }

        dateFormatter.timeZone = timeZoneProvider()
        let timestamp = dateFormatter.string(from: dateProvider())
        let line = "\(timestamp) \(level.rawValue) [\(category.rawValue)] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        do {
            try fileHandle.write(data)
            try rotateAfterWriteIfNeededLocked(fileURL: fileURL)
            // Opening alone is not recovery: a write or rotation may still fail.
            retryAfter = nil
            failureReported = false
        } catch {
            suspendLocked(after: error)
        }
    }

    private func rotateAfterWriteIfNeededLocked(fileURL: URL) throws {
        guard maxBytes > 0 else {
            return
        }

        let offset = try fileHandle?.offset() ?? 0
        guard offset >= UInt64(maxBytes) else {
            return
        }

        try closeLocked()
        try operations.rotate(fileURL, fileManager)
        fileHandle = try operations.open(fileURL, fileManager)
    }

    private func openLocked(fileURL: URL, maxBytes: Int) throws -> DriverFileLogHandle {
        if let size = operations.size(fileURL, fileManager), size >= UInt64(maxBytes) {
            try operations.rotate(fileURL, fileManager)
        }
        return try operations.open(fileURL, fileManager)
    }

    private func closeLocked() throws {
        let handle = fileHandle
        fileHandle = nil
        try handle?.close()
    }

    private func suspendLocked(after error: Error) {
        try? closeLocked()
        retryAfter = uptimeProvider() + Self.retryInterval
        if !failureReported {
            failureReported = true
            reportFailure(error)
        }
    }
}
