import Foundation

/// Captures and restores the focused window around a touch gesture.
public protocol FocusRestorer: AnyObject {
    /// Starts pre-input capture. Completion must be delivered on the caller's gesture queue.
    /// The caller may discard this preparation before completion; that must invalidate late results.
    func prepareFocusedWindow(completion: @escaping () -> Void)

    /// Captures the currently focused window, if one is available.
    func captureFocusedWindow()

    /// Marks receipt of the accepted HID touch-up, before delayed synthetic mouse-up.
    /// Observed focus changes now revoke restoration eligibility. Repeated cleanup
    /// calls must be idempotent. This must not wait for or begin an AX mutation.
    func inputDidEnd()

    /// Restores the captured focused window and clears the capture.
    func restoreCapturedWindow()

    /// Clears any captured focused window without restoring it.
    func discardCapturedWindow()

    /// Invalidates outstanding work without waiting for an Accessibility request to return.
    func shutdown()
}

public extension FocusRestorer {
    /// Synchronous implementations keep their existing ordering and timing.
    func prepareFocusedWindow(completion: @escaping () -> Void) {
        captureFocusedWindow()
        completion()
    }

    func shutdown() {
        discardCapturedWindow()
    }

    func inputDidEnd() {}
}

/// Focus restorer used when restoration is disabled or side effects are unwanted.
public final class NoOpFocusRestorer: FocusRestorer {
    public init() {}

    public func captureFocusedWindow() {}

    public func restoreCapturedWindow() {}

    public func discardCapturedWindow() {}
}
