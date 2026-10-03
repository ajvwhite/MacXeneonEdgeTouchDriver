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

    /// Whether this gesture owns a down post invocation without a matching up invocation.
    /// This is release ownership, not proof that the operating system delivered input.
    public var isMouseDownPosted: Bool

    /// Whether a drag post was invoked for this gesture; not a delivery acknowledgement.
    public var hasMoved: Bool
}
