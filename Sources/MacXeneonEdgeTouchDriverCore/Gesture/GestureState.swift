import CoreGraphics
import Foundation

/// State for the single-touch gesture controller.
public enum GestureState: Equatable {
    case idle
    case singleTouch(SingleTouchContext)
}

/// Context kept while one contact is active.
public struct SingleTouchContext: Equatable {
    public enum Phase: Equatable {
        case pending
        case scrolling
        case dragging
        case finishingTap
    }

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

    /// Current interpretation of the contact.
    public var phase: Phase

    /// Click count used if this contact has emitted a mouse-down event.
    public var clickCount: Int
}
