import Foundation

/// Optional scrolling keeps the existing direct-drag behavior as the default.
public struct GestureOptions: Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case direct, scroll }
    public var mode: Mode
    public var holdDurationMs: Int
    public var movementThresholdPx: Double
    public var scrollSensitivity: Double
    public var doubleClickEnabled: Bool

    public init(mode: Mode = .direct, holdDurationMs: Int = 300,
                movementThresholdPx: Double = 6, scrollSensitivity: Double = 1,
                doubleClickEnabled: Bool = true) {
        self.mode = mode
        self.holdDurationMs = min(2000, max(100, holdDurationMs))
        self.movementThresholdPx = movementThresholdPx.isFinite ? min(100, max(1, movementThresholdPx)) : 6
        self.scrollSensitivity = scrollSensitivity.isFinite ? min(10, max(0.1, scrollSensitivity)) : 1
        self.doubleClickEnabled = doubleClickEnabled
    }

    init(configuration: DriverConfiguration.Gesture) {
        self.init(mode: configuration.mode, holdDurationMs: configuration.holdDurationMs,
                  movementThresholdPx: Double(configuration.movementThresholdPx),
                  scrollSensitivity: configuration.scrollSensitivity,
                  doubleClickEnabled: configuration.doubleClickEnabled)
    }
}
