import CoreGraphics
import Foundation

/// Maps raw HID coordinates into Quartz display coordinates.
public struct CoordinateMapper: Equatable {
    /// Minimum raw X coordinate emitted by the touchscreen.
    public let rawMinX: Int

    /// Maximum raw X coordinate emitted by the touchscreen.
    public let rawMaxX: Int

    /// Minimum raw Y coordinate emitted by the touchscreen.
    public let rawMinY: Int

    /// Maximum raw Y coordinate emitted by the touchscreen.
    public let rawMaxY: Int

    /// Target display bounds in Quartz coordinates.
    public let displayBounds: CGRect

    /// Creates a mapper for a raw coordinate range and target display bounds.
    public init(
        rawMinX: Int = XeneonEdgeDevice.rawXRange.lowerBound,
        rawMaxX: Int = XeneonEdgeDevice.rawXRange.upperBound,
        rawMinY: Int = XeneonEdgeDevice.rawYRange.lowerBound,
        rawMaxY: Int = XeneonEdgeDevice.rawYRange.upperBound,
        displayBounds: CGRect
    ) {
        precondition(rawMaxX > rawMinX, "rawMaxX must be greater than rawMinX")
        precondition(rawMaxY > rawMinY, "rawMaxY must be greater than rawMinY")

        self.rawMinX = rawMinX
        self.rawMaxX = rawMaxX
        self.rawMinY = rawMinY
        self.rawMaxY = rawMaxY
        self.displayBounds = displayBounds
    }

    /// Maps a raw touchscreen coordinate to the target display.
    public func map(rawX: Int, rawY: Int) -> CGPoint {
        let clampedX = clamp(rawX, lowerBound: rawMinX, upperBound: rawMaxX)
        let clampedY = clamp(rawY, lowerBound: rawMinY, upperBound: rawMaxY)

        let normalizedX = CGFloat(clampedX - rawMinX) / CGFloat(rawMaxX - rawMinX)
        let normalizedY = CGFloat(clampedY - rawMinY) / CGFloat(rawMaxY - rawMinY)

        return CGPoint(
            x: displayBounds.origin.x + normalizedX * displayBounds.width,
            y: displayBounds.origin.y + normalizedY * displayBounds.height
        )
    }

    private func clamp(_ value: Int, lowerBound: Int, upperBound: Int) -> Int {
        min(max(value, lowerBound), upperBound)
    }
}
