import Foundation

/// Captures and restores the focused window around a touch gesture.
public protocol FocusRestorer: AnyObject {
    /// Starts pre-input capture. Completion must be delivered on the caller's gesture queue.
    /// The caller may discard this preparation before completion; that must invalidate late results.
    func prepareFocusedWindow(completion: @escaping () -> Void)

    /// Brackets the driver's verified target activation before synthetic input.
    func beginTargetActivation() -> Bool
    func confirmTargetActivation(completion: @escaping (Bool) -> Void)

    /// Starts the verified target's synthetic click delivery. Its app/window
    /// notifications may arrive after raw HID lift; physical input still revokes.
    func syntheticInputWillBegin(targetProcessIdentifier: Int32?, permitsWindowlessDestination: Bool)

    /// Captures the currently focused window, if one is available.
    func captureFocusedWindow()

    /// Marks receipt of the accepted HID touch-up, before delayed synthetic mouse-up.
    /// App/window changes revoke a pending restoration. The live AX coordinator
    /// separately guards later physical mouse/keyboard input, so a touch-generated
    /// control focus change does not discard the captured typing destination.
    /// Repeated cleanup calls must be idempotent; this never waits for AX.
    func inputDidEnd()

    /// Restores the captured focused window and clears the capture.
    func restoreCapturedWindow()

    /// Clears any captured focused window without restoring it.
    func discardCapturedWindow()

    /// Invalidates outstanding work without waiting for an Accessibility request to return.
    /// A completion already admitted on the gesture queue may still finish. The
    /// owner must stop new input producers, then cancel/drain that same serial queue
    /// if it requires a final boundary for gesture-side effects; shutdown is not that drain.
    func shutdown()
}

public extension FocusRestorer {
    func beginTargetActivation() -> Bool { true }
    func confirmTargetActivation(completion: @escaping (Bool) -> Void) { completion(true) }

    /// Synchronous implementations keep their existing ordering and timing.
    func prepareFocusedWindow(completion: @escaping () -> Void) {
        captureFocusedWindow()
        completion()
    }

    func shutdown() {
        discardCapturedWindow()
    }

    func inputDidEnd() {}
    func syntheticInputWillBegin(targetProcessIdentifier: Int32?, permitsWindowlessDestination: Bool = false) {}
}

/// Focus restorer used when restoration is disabled or side effects are unwanted.
public final class NoOpFocusRestorer: FocusRestorer {
    public init() {}

    public func captureFocusedWindow() {}

    public func restoreCapturedWindow() {}

    public func discardCapturedWindow() {}
}
