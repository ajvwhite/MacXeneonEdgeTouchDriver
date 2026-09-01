import Foundation

/// Timing values used to sequence cursor warps and synthetic mouse events.
public struct GestureTiming: Equatable {
    /// Delay between cursor warp and mouse-down.
    public let warpToClickDelayMs: Int

    /// Minimum delay between mouse-down and mouse-up for tap gestures.
    public let downToUpDelayMs: Int

    /// Delay between mouse-up and cursor return.
    public let clickToWarpBackDelayMs: Int

    /// Minimum interval before accepting a new tap after the previous touch ended.
    public let tapDebounceMs: Int

    /// Time a stationary contact must be held before movement becomes a drag.
    public let holdToDragMs: Int

    /// Movement required to classify a contact as scrolling.
    public let movementThresholdPoints: CGFloat

    /// Multiplier applied to pixel-scroll deltas.
    public let scrollSensitivity: CGFloat

    /// Maximum mapped distance between two taps that may form a double-click.
    public let doubleClickDistancePoints: CGFloat

    /// Creates gesture timing values in milliseconds.
    public init(
        warpToClickDelayMs: Int,
        downToUpDelayMs: Int,
        clickToWarpBackDelayMs: Int,
        tapDebounceMs: Int,
        holdToDragMs: Int = 300,
        movementThresholdPoints: CGFloat = 8,
        scrollSensitivity: CGFloat = 1,
        doubleClickDistancePoints: CGFloat = 12
    ) {
        self.warpToClickDelayMs = max(0, warpToClickDelayMs)
        self.downToUpDelayMs = max(0, downToUpDelayMs)
        self.clickToWarpBackDelayMs = max(0, clickToWarpBackDelayMs)
        self.tapDebounceMs = max(0, tapDebounceMs)
        self.holdToDragMs = max(0, holdToDragMs)
        self.movementThresholdPoints = max(1, movementThresholdPoints)
        self.scrollSensitivity = max(0.1, scrollSensitivity)
        self.doubleClickDistancePoints = max(1, doubleClickDistancePoints)
    }

    /// Creates gesture timing from loaded driver configuration.
    public init(configuration: DriverConfiguration.Timing, gesture: DriverConfiguration.Gesture = DriverConfiguration.defaults.gesture) {
        self.init(
            warpToClickDelayMs: configuration.warpToClickDelayMs,
            downToUpDelayMs: configuration.downToUpDelayMs,
            clickToWarpBackDelayMs: configuration.clickToWarpBackDelayMs,
            tapDebounceMs: configuration.tapDebounceMs,
            holdToDragMs: gesture.holdToDragMs,
            movementThresholdPoints: CGFloat(gesture.movementThresholdPoints),
            scrollSensitivity: CGFloat(gesture.scrollSensitivity),
            doubleClickDistancePoints: CGFloat(gesture.doubleClickDistancePoints)
        )
    }

    /// Immediate timing for deterministic unit tests.
    public static let immediate = GestureTiming(
        warpToClickDelayMs: 0,
        downToUpDelayMs: 0,
        clickToWarpBackDelayMs: 0,
        tapDebounceMs: 0,
        holdToDragMs: 300,
        movementThresholdPoints: 8,
        scrollSensitivity: 1,
        doubleClickDistancePoints: 12
    )
}
