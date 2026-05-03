import Foundation
import os

/// Log categories emitted by the driver.
public enum DriverLogCategory: String {
    case lifecycle
    case hid
    case gesture
    case cursor
    case display
}

/// Log severity levels emitted by the driver.
public enum DriverLogLevel: String {
    case debug = "DEBUG"
    case notice = "NOTICE"
    case warning = "WARNING"
    case error = "ERROR"
    case fault = "FAULT"
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
        }
    }
}

/// Mirrors driver log messages to a rotating diagnostics file.
public final class DriverFileLog {
    /// Shared diagnostics file writer.
    public static let shared = DriverFileLog()

    private let lock = NSLock()
    private let dateFormatter = ISO8601DateFormatter()
    private var fileURL: URL?
    private var maxBytes: Int = 0
    private var fileHandle: FileHandle?

    private init() {
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Opens the diagnostics log file. Pass `nil` or an empty path to disable file logging.
    public func configure(fileLogPath: String?, maxBytes: Int, fileManager: FileManager = .default) throws {
        lock.lock()
        defer { lock.unlock() }

        try fileHandle?.close()
        fileHandle = nil

        guard let fileLogPath, !fileLogPath.isEmpty else {
            fileURL = nil
            self.maxBytes = 0
            return
        }

        let expandedPath = NSString(string: fileLogPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath, isDirectory: false)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        fileURL = url
        self.maxBytes = max(65_536, maxBytes)
        try rotateIfNeededLocked(fileManager: fileManager)

        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        fileHandle = handle
    }

    /// Writes one diagnostics log line if file logging is configured.
    public func write(level: DriverLogLevel, category: DriverLogCategory, message: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let fileURL, let fileHandle else {
            return
        }

        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) \(level.rawValue) [\(category.rawValue)] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        do {
            try fileHandle.write(contentsOf: data)
            try rotateAfterWriteIfNeededLocked(fileURL: fileURL)
        } catch {
            try? fileHandle.close()
            self.fileHandle = nil
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

        try fileHandle?.close()
        fileHandle = nil
        try rotateLocked(fileURL: fileURL, fileManager: .default)

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        fileHandle = handle
    }

    private func rotateIfNeededLocked(fileManager: FileManager) throws {
        guard let fileURL, maxBytes > 0 else {
            return
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= maxBytes else {
            return
        }

        try rotateLocked(fileURL: fileURL, fileManager: fileManager)
    }

    private func rotateLocked(fileURL: URL, fileManager: FileManager) throws {
        let rotatedURL = fileURL.appendingPathExtension("1")

        if fileManager.fileExists(atPath: rotatedURL.path) {
            try fileManager.removeItem(at: rotatedURL)
        }

        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.moveItem(at: fileURL, to: rotatedURL)
        }
    }
}
