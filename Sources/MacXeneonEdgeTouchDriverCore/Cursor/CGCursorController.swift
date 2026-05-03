import CoreGraphics
import Foundation

/// Borrows the system cursor while a touch gesture is active.
public final class CGCursorController: CursorController {
    private let displayIDProvider: () -> CGDirectDisplayID
    private var savedCursorPosition: CGPoint?
    private var isCursorHidden = false
    private var isCursorAssociated = true

    /// Creates a CoreGraphics cursor controller.
    public init(displayIDProvider: @escaping () -> CGDirectDisplayID = CGMainDisplayID) {
        self.displayIDProvider = displayIDProvider
    }

    public func borrow(warpingTo point: CGPoint) -> Bool {
        let isNewBorrow = savedCursorPosition == nil

        if savedCursorPosition == nil {
            guard let currentPosition = currentCursorPosition() else {
                DriverLoggers.log(.error, category: .cursor, "Could not read current cursor position; refusing to borrow cursor.")
                return false
            }

            savedCursorPosition = currentPosition
            hideCursor()
            setCursorAssociation(false)
        }

        guard warp(to: point) else {
            if isNewBorrow {
                setCursorAssociation(true)
                savedCursorPosition = nil
                showCursor()
            }
            return false
        }

        return true
    }

    public func updatePosition(_ point: CGPoint) {
        guard savedCursorPosition != nil else {
            DriverLoggers.log(.debug, category: .cursor, "Ignoring cursor update because no touch gesture has borrowed the cursor.")
            return
        }

        _ = warp(to: point)
    }

    public func returnToOrigin() {
        guard let savedCursorPosition else {
            forceShow()
            return
        }

        setCursorAssociation(true)
        _ = warp(to: savedCursorPosition)
        self.savedCursorPosition = nil
        showCursor()
    }

    public func forceShow() {
        setCursorAssociation(true)
        savedCursorPosition = nil
        showCursor()
    }

    private func currentCursorPosition() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    private func warp(to point: CGPoint) -> Bool {
        let result = CGWarpMouseCursorPosition(point)
        if result != .success {
            DriverLoggers.log(.error, category: .cursor, "CGWarpMouseCursorPosition failed with \(result.rawValue).")
            return false
        }
        return true
    }

    private func hideCursor() {
        guard !isCursorHidden else {
            return
        }

        let result = CGDisplayHideCursor(displayIDProvider())
        if result == .success {
            isCursorHidden = true
        } else {
            DriverLoggers.log(.error, category: .cursor, "CGDisplayHideCursor failed with \(result.rawValue).")
        }
    }

    private func showCursor() {
        guard isCursorHidden else {
            return
        }

        let result = CGDisplayShowCursor(displayIDProvider())
        if result == .success {
            isCursorHidden = false
        } else {
            DriverLoggers.log(.error, category: .cursor, "CGDisplayShowCursor failed with \(result.rawValue).")
        }
    }

    private func setCursorAssociation(_ shouldAssociate: Bool) {
        let associationValue = shouldAssociate ? boolean_t(1) : boolean_t(0)
        let result = CGAssociateMouseAndMouseCursorPosition(associationValue)

        if result == .success {
            isCursorAssociated = shouldAssociate
        } else {
            DriverLoggers.log(.error, category: .cursor, "CGAssociateMouseAndMouseCursorPosition failed with \(result.rawValue).")
        }
    }
}
