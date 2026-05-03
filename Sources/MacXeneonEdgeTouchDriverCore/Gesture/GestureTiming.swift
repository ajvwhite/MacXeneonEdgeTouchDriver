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

    /// Creates gesture timing values in milliseconds.
    public init(
        warpToClickDelayMs: Int,
        downToUpDelayMs: Int,
        clickToWarpBackDelayMs: Int,
        tapDebounceMs: Int
    ) {
        self.warpToClickDelayMs = max(0, warpToClickDelayMs)
        self.downToUpDelayMs = max(0, downToUpDelayMs)
        self.clickToWarpBackDelayMs = max(0, clickToWarpBackDelayMs)
        self.tapDebounceMs = max(0, tapDebounceMs)
    }

    /// Creates gesture timing from loaded driver configuration.
    public init(configuration: DriverConfiguration.Timing) {
        self.init(
            warpToClickDelayMs: configuration.warpToClickDelayMs,
            downToUpDelayMs: configuration.downToUpDelayMs,
            clickToWarpBackDelayMs: configuration.clickToWarpBackDelayMs,
            tapDebounceMs: configuration.tapDebounceMs
        )
    }

    /// Immediate timing for deterministic unit tests.
    public static let immediate = GestureTiming(
        warpToClickDelayMs: 0,
        downToUpDelayMs: 0,
        clickToWarpBackDelayMs: 0,
        tapDebounceMs: 0
    )
}
