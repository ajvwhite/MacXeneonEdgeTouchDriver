import Foundation

/// Captures and restores the focused window around a touch gesture.
public protocol FocusRestorer: AnyObject {
    /// Captures the currently focused window, if one is available.
    func captureFocusedWindow()

    /// Restores the captured focused window and clears the capture.
    func restoreCapturedWindow()

    /// Clears any captured focused window without restoring it.
    func discardCapturedWindow()
}

/// Focus restorer used when restoration is disabled or side effects are unwanted.
public final class NoOpFocusRestorer: FocusRestorer {
    public init() {}

    public func captureFocusedWindow() {}

    public func restoreCapturedWindow() {}

    public func discardCapturedWindow() {}
}
