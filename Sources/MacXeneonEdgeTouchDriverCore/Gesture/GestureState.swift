import CoreGraphics
import Foundation

/// State for the single-touch gesture controller.
public enum GestureState: Equatable {
    case idle
    case singleTouch(SingleTouchContext)
}

/// Context kept while one contact is active.
public struct SingleTouchContext: Equatable {
    /// Contact identifier. Current hardware always uses `0`.
    public let contactID: Int

    /// Initial mapped Quartz-coordinate point for the gesture.
    public let startPoint: CGPoint

    /// Last mapped Quartz-coordinate point.
    public var lastPoint: CGPoint

    /// Last raw X coordinate.
    public var lastRawX: Int

    /// Last raw Y coordinate.
    public var lastRawY: Int

    /// Whether the synthetic mouse-down event has been posted.
    public var isMouseDownPosted: Bool

    /// Whether at least one drag event has been posted for this gesture.
    public var hasMoved: Bool
}
