import CoreGraphics
import Foundation

/// Receives synthetic input commands from the gesture controller.
public protocol SyntheticInputSink: AnyObject {
    /// Posts a left mouse-down event at a Quartz-coordinate point.
    func postMouseDown(at point: CGPoint)

    /// Posts a left mouse-up event at a Quartz-coordinate point.
    func postMouseUp(at point: CGPoint)

    /// Posts a left mouse-dragged event to a Quartz-coordinate point.
    func postMouseDragged(to point: CGPoint)
}
