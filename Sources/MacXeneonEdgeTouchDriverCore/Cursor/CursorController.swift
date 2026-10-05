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

    /// Releases the borrow, reassociates the mouse, and balances the cursor hide.
    /// When `false`, leaves the cursor at its current position without a cleanup warp.
    func releaseBorrow(returnToPreviousPosition: Bool)

    /// Reassociates the mouse, clears the borrow, and balances the cursor hide without warping.
    func forceShow()
}

public extension CursorController {
    /// Preserves compatibility with cursor controllers implementing the original cleanup methods.
    func releaseBorrow(returnToPreviousPosition: Bool) {
        if returnToPreviousPosition {
            returnToOrigin()
        } else {
            forceShow()
        }
    }
}
