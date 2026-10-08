import Foundation

/// Runtime configuration loaded from the user's Application Support directory.
public struct DriverConfiguration: Codable, Equatable, Sendable {
    /// Logging verbosity name.
    public var logLevel: String

    /// Timing values used for synthetic input sequencing and recovery.
    public var timing: Timing

    /// Display matching options.
    public var display: Display

    /// Window focus behavior after a touch gesture.
    public var focus: Focus

    /// Cursor position behavior after a touch gesture.
    public var cursor: Cursor

    /// Gesture feature options.
    public var gesture: Gesture

    /// Optional file logging configuration.
    public var diagnostics: Diagnostics

    /// Default configuration for this hardware.
    public static let defaults = DriverConfiguration(
        logLevel: "info",
        timing: Timing(
            warpToClickDelayMs: 10,
            downToUpDelayMs: 20,
            clickToWarpBackDelayMs: 10,
            tapDebounceMs: 50,
            stuckGestureTimeoutMs: 2_000
        ),
        display: Display(
            vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber,
            serialNumber: nil,
            expectedWidth: CapturedXeneonDisplay.expectedWidth,
            expectedHeight: CapturedXeneonDisplay.expectedHeight
        ),
        focus: Focus(restorePreviousWindow: true),
        cursor: Cursor(returnToPreviousPosition: true),
        gesture: Gesture(
            multiTouchEnabled: XeneonEdgeDevice.supportsMultiTouch,
            pinchHysteresisPx: 5,
            minPinchForMagnify: 10,
            pinchModifies: .contentZoom
        ),
        diagnostics: Diagnostics(
            fileLogPath: defaultLogURL().path,
            fileLogMaxBytes: 5_242_880
        )
    )

    /// Loads configuration from a JSON file, returning defaults and warnings for recoverable issues.
    public static func load(
        from url: URL = defaultConfigURL(),
        fileManager: FileManager = .default
    ) -> ConfigurationLoadResult {
        guard fileManager.fileExists(atPath: url.path) else {
            return ConfigurationLoadResult(
                configuration: .defaults,
                warnings: ["Configuration file not found; using defaults."]
            )
        }

        do {
            let data = try Data(contentsOf: url)
            let partial = try JSONDecoder().decode(PartialConfiguration.self, from: data)
            return apply(partial)
        } catch {
            return ConfigurationLoadResult(
                configuration: .defaults,
                warnings: ["Configuration could not be parsed; using defaults. \(error.localizedDescription)"]
            )
        }
    }

    /// Default config file location.
    public static func defaultConfigURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MacXeneonEdgeTouchDriver", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    /// Default diagnostics log file location.
    public static func defaultLogURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MacXeneonEdgeTouchDriver", isDirectory: true)
            .appendingPathComponent("driver.log", isDirectory: false)
    }

    private static func apply(_ partial: PartialConfiguration) -> ConfigurationLoadResult {
        var configuration = DriverConfiguration.defaults
        var warnings: [String] = []

        if let logLevel = partial.logLevel {
            if DriverLogLevel(configurationName: logLevel) != nil {
                configuration.logLevel = logLevel
            } else {
                warnings.append("logLevel was not recognized and defaulted to \(configuration.logLevel).")
            }
        }

        if let timing = partial.timing {
            if let value = timing.warpToClickDelayMs {
                configuration.timing.warpToClickDelayMs = clamp(value, to: 0...1_000, name: "timing.warpToClickDelayMs", warnings: &warnings)
            }
            if let value = timing.downToUpDelayMs {
                configuration.timing.downToUpDelayMs = clamp(value, to: 0...1_000, name: "timing.downToUpDelayMs", warnings: &warnings)
            }
            if let value = timing.clickToWarpBackDelayMs {
                configuration.timing.clickToWarpBackDelayMs = clamp(value, to: 0...1_000, name: "timing.clickToWarpBackDelayMs", warnings: &warnings)
            }
            if let value = timing.tapDebounceMs {
                configuration.timing.tapDebounceMs = clamp(value, to: 0...2_000, name: "timing.tapDebounceMs", warnings: &warnings)
            }
            if let value = timing.stuckGestureTimeoutMs {
                configuration.timing.stuckGestureTimeoutMs = clamp(value, to: 100...60_000, name: "timing.stuckGestureTimeoutMs", warnings: &warnings)
            }
        }

        if let display = partial.display {
            if let value = display.vendorNumber {
                configuration.display.vendorNumber = value
            }
            if let value = display.modelNumber {
                configuration.display.modelNumber = value
            }
            if let value = display.serialNumber {
                configuration.display.serialNumber = value
            }
            if let value = display.expectedWidth {
                configuration.display.expectedWidth = clamp(value, to: 1...100_000, name: "display.expectedWidth", warnings: &warnings)
            }
            if let value = display.expectedHeight {
                configuration.display.expectedHeight = clamp(value, to: 1...100_000, name: "display.expectedHeight", warnings: &warnings)
            }
        }

        if let restorePreviousWindow = partial.focus?.restorePreviousWindow {
            configuration.focus.restorePreviousWindow = restorePreviousWindow
        }

        if let returnToPreviousPosition = partial.cursor?.returnToPreviousPosition {
            configuration.cursor.returnToPreviousPosition = returnToPreviousPosition
        }

        if let gesture = partial.gesture {
            if let mode = gesture.mode {
                if let value = GestureOptions.Mode(rawValue: mode) { configuration.gesture.mode = value }
                else { warnings.append("Unsupported gesture.mode '\(mode)'; keeping direct mode. Two-finger scrolling is unavailable on the observed hardware. Choose 'scroll' explicitly for single-finger scrolling.") }
            }
            if let value = gesture.holdDurationMs {
                configuration.gesture.holdDurationMs = clamp(value, to: 100...2000, name: "gesture.holdDurationMs", warnings: &warnings)
            }
            if let value = gesture.movementThresholdPx {
                configuration.gesture.movementThresholdPx = clamp(value, to: 1...100, name: "gesture.movementThresholdPx", warnings: &warnings)
            }
            if let value = gesture.scrollSensitivity {
                configuration.gesture.scrollSensitivity = min(10, max(0.1, value))
                if configuration.gesture.scrollSensitivity != value { warnings.append("gesture.scrollSensitivity must be between 0.1 and 10; using the nearest limit.") }
            }
            if let value = gesture.doubleClickEnabled { configuration.gesture.doubleClickEnabled = value }
            if let value = gesture.multiTouchEnabled {
                configuration.gesture.multiTouchEnabled = value && XeneonEdgeDevice.supportsMultiTouch
                if value && !XeneonEdgeDevice.supportsMultiTouch {
                    warnings.append("gesture.multiTouchEnabled requested but this hardware reported single-touch only; forcing false.")
                }
            }
            if let value = gesture.pinchHysteresisPx {
                configuration.gesture.pinchHysteresisPx = clamp(value, to: 0...1_000, name: "gesture.pinchHysteresisPx", warnings: &warnings)
            }
            if let value = gesture.minPinchForMagnify {
                configuration.gesture.minPinchForMagnify = clamp(value, to: 0...1_000, name: "gesture.minPinchForMagnify", warnings: &warnings)
            }
            if let value = gesture.pinchModifies {
                configuration.gesture.pinchModifies = value
            }
        }

        if let diagnostics = partial.diagnostics {
            if let value = diagnostics.performanceMetricsEnabled { configuration.diagnostics.performanceMetricsEnabled = value }
            if let value = diagnostics.fileLogPath {
                configuration.diagnostics.fileLogPath = value
            }
            if let value = diagnostics.fileLogMaxBytes {
                configuration.diagnostics.fileLogMaxBytes = clamp(value, to: 65_536...104_857_600, name: "diagnostics.fileLogMaxBytes", warnings: &warnings)
            }
        }

        return ConfigurationLoadResult(configuration: configuration, warnings: warnings)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>, name: String, warnings: inout [String]) -> Int {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        if clamped != value {
            warnings.append("\(name) was out of range and was clamped to \(clamped).")
        }
        return clamped
    }
}

public extension DriverConfiguration {
    /// Decodes complete configurations written before the focus and cursor options were added.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            logLevel: try values.decode(String.self, forKey: .logLevel),
            timing: try values.decode(Timing.self, forKey: .timing),
            display: try values.decode(Display.self, forKey: .display),
            focus: try values.decodeIfPresent(Focus.self, forKey: .focus) ?? Focus(restorePreviousWindow: true),
            cursor: try values.decodeIfPresent(Cursor.self, forKey: .cursor) ?? Cursor(returnToPreviousPosition: true),
            gesture: try values.decode(Gesture.self, forKey: .gesture),
            diagnostics: try values.decode(Diagnostics.self, forKey: .diagnostics)
        )
    }

    /// Timing values in milliseconds.
    struct Timing: Codable, Equatable, Sendable {
        public var warpToClickDelayMs: Int
        public var downToUpDelayMs: Int
        public var clickToWarpBackDelayMs: Int
        public var tapDebounceMs: Int
        public var stuckGestureTimeoutMs: Int
    }

    /// Display matching configuration.
    struct Display: Codable, Equatable, Sendable {
        public var vendorNumber: UInt32?
        public var modelNumber: UInt32?
        public var serialNumber: UInt32?
        public var expectedWidth: Int
        public var expectedHeight: Int
    }

    /// Window focus configuration.
    struct Focus: Codable, Equatable, Sendable {
        public var restorePreviousWindow: Bool
    }

    /// Cursor position configuration. Cleanup always restores visibility and mouse association.
    struct Cursor: Codable, Equatable, Sendable {
        public var returnToPreviousPosition: Bool
    }

    /// Gesture configuration.
    struct Gesture: Codable, Equatable, Sendable {
        public var mode: GestureOptions.Mode = .direct
        public var holdDurationMs: Int = 300
        public var movementThresholdPx: Int = 6
        public var scrollSensitivity: Double = 1
        public var doubleClickEnabled: Bool = true
        public var multiTouchEnabled: Bool
        public var pinchHysteresisPx: Int
        public var minPinchForMagnify: Int
        public var pinchModifies: PinchMode
    }

    /// Diagnostic file logging configuration.
    struct Diagnostics: Codable, Equatable, Sendable {
        public var performanceMetricsEnabled: Bool = false
        public var fileLogPath: String?
        public var fileLogMaxBytes: Int
    }

    /// Pinch behavior mode. This remains disabled for the current single-touch hardware.
    enum PinchMode: String, Codable, Equatable, Sendable {
        case contentZoom
        case windowSize
    }
}

public extension DriverConfiguration.Focus {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(restorePreviousWindow: try values.decodeIfPresent(Bool.self, forKey: .restorePreviousWindow) ?? true)
    }
}

public extension DriverConfiguration.Cursor {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(returnToPreviousPosition: try values.decodeIfPresent(Bool.self, forKey: .returnToPreviousPosition) ?? true)
    }
}

/// Result of loading the configuration file.
public struct ConfigurationLoadResult: Equatable, Sendable {
    /// The effective configuration.
    public let configuration: DriverConfiguration

    /// Recoverable issues encountered during loading.
    public let warnings: [String]
}

private struct PartialConfiguration: Decodable {
    var logLevel: String?
    var timing: PartialTiming?
    var display: PartialDisplay?
    var focus: PartialFocus?
    var cursor: PartialCursor?
    var gesture: PartialGesture?
    var diagnostics: PartialDiagnostics?
}

private struct PartialTiming: Decodable {
    var warpToClickDelayMs: Int?
    var downToUpDelayMs: Int?
    var clickToWarpBackDelayMs: Int?
    var tapDebounceMs: Int?
    var stuckGestureTimeoutMs: Int?
}

private struct PartialDisplay: Decodable {
    var vendorNumber: UInt32?
    var modelNumber: UInt32?
    var serialNumber: UInt32?
    var expectedWidth: Int?
    var expectedHeight: Int?
}

private struct PartialFocus: Decodable {
    var restorePreviousWindow: Bool?
}

private struct PartialCursor: Decodable {
    var returnToPreviousPosition: Bool?
}

private struct PartialGesture: Decodable {
    var mode: String?
    var holdDurationMs: Int?
    var movementThresholdPx: Int?
    var scrollSensitivity: Double?
    var doubleClickEnabled: Bool?
    var multiTouchEnabled: Bool?
    var pinchHysteresisPx: Int?
    var minPinchForMagnify: Int?
    var pinchModifies: DriverConfiguration.PinchMode?
}

private struct PartialDiagnostics: Decodable {
    var performanceMetricsEnabled: Bool?
    var fileLogPath: String?
    var fileLogMaxBytes: Int?
}
