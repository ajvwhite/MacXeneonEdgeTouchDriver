import CoreGraphics
import Foundation

/// Handles normalized touch events and emits cursor/input side effects.
public final class GestureController {
    /// Current controller state.
    public private(set) var state: GestureState = .idle

    /// Called when all delayed cleanup has completed and the controller is idle.
    public var onBecameIdle: (() -> Void)?

    private let mapperProvider: () -> CoordinateMapper?
    private let timing: GestureTiming
    private let schedulingQueue: DispatchQueue?
    private let inputSink: SyntheticInputSink
    private let cursorController: CursorController
    private let focusRestorer: FocusRestorer
    private var pendingMouseDown: DispatchWorkItem?
    private var pendingMouseUp: DispatchWorkItem?
    private var pendingCursorReturn: DispatchWorkItem?
    private var lastCompletedTouchTimestamp: DispatchTime?

    /// Creates a single-touch gesture controller.
    public init(
        mapperProvider: @escaping () -> CoordinateMapper?,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorer: FocusRestorer = NoOpFocusRestorer(),
        timing: GestureTiming = .immediate,
        schedulingQueue: DispatchQueue? = nil
    ) {
        self.mapperProvider = mapperProvider
        self.inputSink = inputSink
        self.cursorController = cursorController
        self.focusRestorer = focusRestorer
        self.timing = timing
        self.schedulingQueue = schedulingQueue
    }

    /// Handles one normalized touch event.
    public func handle(_ event: TouchEvent) {
        guard let mapper = mapperProvider() else {
            DriverLoggers.log(.warning, category: .gesture, "Dropping touch event because no display mapper is available.")
            return
        }

        let point = mapper.map(rawX: event.rawX, rawY: event.rawY)

        switch (state, event.kind) {
        case (.idle, .down):
            guard !isDebounced(event.timestamp) else {
                DriverLoggers.log(.debug, category: .gesture, "Ignoring touch down inside tap debounce window.")
                return
            }

            focusRestorer.captureFocusedWindow()
            guard cursorController.borrow(warpingTo: point) else {
                focusRestorer.discardCapturedWindow()
                DriverLoggers.log(.warning, category: .gesture, "Dropping touch down because cursor borrow failed.")
                return
            }

            state = .singleTouch(
                SingleTouchContext(
                    contactID: event.contactID,
                    startPoint: point,
                    lastPoint: point,
                    lastRawX: event.rawX,
                    lastRawY: event.rawY,
                    isMouseDownPosted: false,
                    hasMoved: false
                )
            )
            scheduleMouseDown(contactID: event.contactID, at: point)

        case (.singleTouch(let context), .move):
            guard context.contactID == event.contactID else {
                DriverLoggers.log(.warning, category: .gesture, "Ignoring move for unexpected contact ID \(event.contactID).")
                return
            }

            ensureMouseDownPosted()
            guard case .singleTouch(var currentContext) = state else {
                return
            }

            cursorController.updatePosition(point)
            inputSink.postMouseDragged(to: point)
            currentContext.lastPoint = point
            currentContext.lastRawX = event.rawX
            currentContext.lastRawY = event.rawY
            currentContext.hasMoved = true
            state = .singleTouch(currentContext)

        case (.singleTouch(let context), .up):
            guard context.contactID == event.contactID else {
                DriverLoggers.log(.warning, category: .gesture, "Ignoring up for unexpected contact ID \(event.contactID).")
                return
            }

            ensureMouseDownPosted()
            guard case .singleTouch(var currentContext) = state else {
                return
            }

            currentContext.lastPoint = point
            currentContext.lastRawX = event.rawX
            currentContext.lastRawY = event.rawY
            state = .singleTouch(currentContext)
            lastCompletedTouchTimestamp = event.timestamp

            if currentContext.hasMoved {
                postMouseUpAndScheduleReturn(contactID: currentContext.contactID, at: point)
            } else {
                scheduleMouseUpThenReturn(contactID: currentContext.contactID, at: point)
            }

        case (.idle, .move), (.idle, .up):
            DriverLoggers.log(.debug, category: .gesture, "Ignoring touch event while idle.")

        case (.singleTouch, .down):
            DriverLoggers.log(.warning, category: .gesture, "Received touch down while already tracking a single touch.")
        }
    }

    /// Handles a stuck gesture timeout by cleaning up any active mouse-down state.
    public func handleIdleTimeout() {
        forceCancel()
    }

    /// Forces the controller back to idle, posting cleanup events if needed.
    public func forceCancel() {
        cancelPendingWork()

        switch state {
        case .idle:
            cursorController.forceShow()
            focusRestorer.discardCapturedWindow()

        case .singleTouch(let context):
            if context.isMouseDownPosted {
                inputSink.postMouseUp(at: context.lastPoint)
            }
            cursorController.returnToOrigin()
            focusRestorer.restoreCapturedWindow()
            transitionToIdle()
        }
    }

    private func scheduleMouseDown(contactID: Int, at point: CGPoint) {
        pendingMouseDown = schedule(after: timing.warpToClickDelayMs) { [weak self] in
            self?.postMouseDownIfNeeded(contactID: contactID, at: point)
        }
    }

    private func ensureMouseDownPosted() {
        pendingMouseDown?.cancel()
        pendingMouseDown = nil

        guard case .singleTouch(let context) = state else {
            return
        }

        postMouseDownIfNeeded(contactID: context.contactID, at: context.startPoint)
    }

    private func postMouseDownIfNeeded(contactID: Int, at point: CGPoint) {
        guard case .singleTouch(var context) = state, context.contactID == contactID else {
            return
        }
        guard !context.isMouseDownPosted else {
            return
        }

        inputSink.postMouseDown(at: point)
        context.isMouseDownPosted = true
        state = .singleTouch(context)
        pendingMouseDown = nil
    }

    private func scheduleMouseUpThenReturn(contactID: Int, at point: CGPoint) {
        pendingMouseUp = schedule(after: timing.downToUpDelayMs) { [weak self] in
            self?.postMouseUpAndScheduleReturn(contactID: contactID, at: point)
        }
    }

    private func postMouseUpAndScheduleReturn(contactID: Int, at point: CGPoint) {
        guard case .singleTouch(let context) = state, context.contactID == contactID else {
            return
        }

        inputSink.postMouseUp(at: point)
        pendingMouseUp = nil
        pendingCursorReturn = schedule(after: timing.clickToWarpBackDelayMs) { [weak self] in
            self?.returnCursorAndIdle(contactID: contactID)
        }
    }

    private func returnCursorAndIdle(contactID: Int) {
        guard case .singleTouch(let context) = state, context.contactID == contactID else {
            return
        }

        cursorController.returnToOrigin()
        focusRestorer.restoreCapturedWindow()
        pendingCursorReturn = nil
        transitionToIdle()
    }

    private func transitionToIdle() {
        state = .idle
        onBecameIdle?()
    }

    private func cancelPendingWork() {
        pendingMouseDown?.cancel()
        pendingMouseUp?.cancel()
        pendingCursorReturn?.cancel()
        pendingMouseDown = nil
        pendingMouseUp = nil
        pendingCursorReturn = nil
    }

    private func schedule(after milliseconds: Int, action: @escaping () -> Void) -> DispatchWorkItem {
        let workItem = DispatchWorkItem(block: action)

        guard milliseconds > 0, let schedulingQueue else {
            workItem.perform()
            return workItem
        }

        schedulingQueue.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: workItem)
        return workItem
    }

    private func isDebounced(_ timestamp: DispatchTime) -> Bool {
        guard timing.tapDebounceMs > 0, let lastCompletedTouchTimestamp else {
            return false
        }

        let debounceNanoseconds = UInt64(timing.tapDebounceMs) * 1_000_000
        return timestamp.uptimeNanoseconds >= lastCompletedTouchTimestamp.uptimeNanoseconds &&
            timestamp.uptimeNanoseconds - lastCompletedTouchTimestamp.uptimeNanoseconds < debounceNanoseconds
    }
}
