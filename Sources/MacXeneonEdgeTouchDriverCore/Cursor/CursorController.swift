import CoreGraphics
import Foundation

/// Manages cursor borrow, warp, and return operations.
public protocol CursorController: AnyObject {
    /// Saves the current cursor position, hides the cursor, and warps to `point`.
    ///
    /// - Returns: `true` if the cursor was borrowed and warped successfully.
    func borrow(warpingTo point: CGPoint) -> Bool

    /// Warps the borrowed cursor to a new gesture point.
    func updatePosition(_ point: CGPoint)

    /// Restores the cursor to its saved pre-touch position and shows it.
    func returnToOrigin()

    /// Shows the cursor for recovery paths.
    func forceShow()
}
