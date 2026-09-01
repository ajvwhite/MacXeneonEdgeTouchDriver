import CoreGraphics
import Foundation

/// Lifecycle phase for a synthetic pixel-scroll gesture.
public enum SyntheticScrollPhase: Int64, Equatable {
    case began = 1
    case changed = 2
    case ended = 4
}

/// Receives synthetic input commands from the gesture controller.
public protocol SyntheticInputSink: AnyObject {
    /// Posts a left mouse-down event at a Quartz-coordinate point.
    func postMouseDown(at point: CGPoint, clickCount: Int)

    /// Posts a left mouse-up event at a Quartz-coordinate point.
    func postMouseUp(at point: CGPoint, clickCount: Int)

    /// Posts a left mouse-dragged event to a Quartz-coordinate point.
    func postMouseDragged(to point: CGPoint)

    /// Posts a pixel-precise scroll event targeted at the current cursor location.
    func postScroll(deltaX: CGFloat, deltaY: CGFloat, phase: SyntheticScrollPhase)
}
