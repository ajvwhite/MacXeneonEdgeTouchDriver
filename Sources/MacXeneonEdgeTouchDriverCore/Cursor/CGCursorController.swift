import CoreGraphics
import Foundation

/// Borrows the system cursor while a touch gesture is active.
public final class CGCursorController: CursorController {
    private let displayIDProvider: () -> CGDirectDisplayID
    private let operations: Operations
    private var savedCursorPosition: CGPoint?
    private var isCursorHidden = false
    private var isCursorAssociated = true

    /// Creates a CoreGraphics cursor controller.
    public convenience init(displayIDProvider: @escaping () -> CGDirectDisplayID = CGMainDisplayID) {
        self.init(displayIDProvider: displayIDProvider, operations: .live)
    }

    init(displayIDProvider: @escaping () -> CGDirectDisplayID, operations: Operations) {
        self.displayIDProvider = displayIDProvider
        self.operations = operations
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
        releaseBorrow(returnToPreviousPosition: true)
    }

    public func releaseBorrow(returnToPreviousPosition: Bool) {
        setCursorAssociation(true)
        if returnToPreviousPosition, let savedCursorPosition {
            _ = warp(to: savedCursorPosition)
        }
        self.savedCursorPosition = nil
        showCursor()
    }

    public func forceShow() {
        releaseBorrow(returnToPreviousPosition: false)
    }

    private func currentCursorPosition() -> CGPoint? {
        operations.currentPosition()
    }

    private func warp(to point: CGPoint) -> Bool {
        let result = operations.warp(point)
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

        let result = operations.hide(displayIDProvider())
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

        let result = operations.show(displayIDProvider())
        if result == .success {
            isCursorHidden = false
        } else {
            DriverLoggers.log(.error, category: .cursor, "CGDisplayShowCursor failed with \(result.rawValue).")
        }
    }

    private func setCursorAssociation(_ shouldAssociate: Bool) {
        guard isCursorAssociated != shouldAssociate else {
            return
        }

        let result = operations.associate(shouldAssociate)

        if result == .success {
            isCursorAssociated = shouldAssociate
        } else {
            DriverLoggers.log(.error, category: .cursor, "CGAssociateMouseAndMouseCursorPosition failed with \(result.rawValue).")
        }
    }

    /// CoreGraphics calls are injectable so ownership and recovery can be tested without moving a cursor.
    struct Operations {
        var currentPosition: () -> CGPoint?
        var warp: (CGPoint) -> CGError
        var hide: (CGDirectDisplayID) -> CGError
        var show: (CGDirectDisplayID) -> CGError
        var associate: (Bool) -> CGError

        static let live = Operations(
            currentPosition: { CGEvent(source: nil)?.location },
            warp: { CGWarpMouseCursorPosition($0) },
            hide: { CGDisplayHideCursor($0) },
            show: { CGDisplayShowCursor($0) },
            associate: { CGAssociateMouseAndMouseCursorPosition($0 ? boolean_t(1) : boolean_t(0)) }
        )
    }
}
