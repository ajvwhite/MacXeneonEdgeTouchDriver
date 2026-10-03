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
    private let scheduler: GestureScheduler
    private let inputSink: SyntheticInputSink
    private let cursorController: CursorController
    private let focusRestorer: FocusRestorer
    private var pendingMouseDown: GestureScheduledTask?
    private var pendingMouseUp: GestureScheduledTask?
    private var pendingCursorReturn: GestureScheduledTask?
    private var lastCompletedTouchTimestamp: DispatchTime?
    private var generation: UInt64 = 0
    private var phase: Phase?
    // A rejected down rejects that entire contact, even if cleanup finishes before its up.
    private var rejectedContactIDs: Set<Int> = []

    private enum Phase {
        case tracking
        case waitingForMouseUp
        case waitingForCursorReturn
        case finishing
    }

    /// Creates a single-touch gesture controller.
    public convenience init(
        mapperProvider: @escaping () -> CoordinateMapper?,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorer: FocusRestorer = NoOpFocusRestorer(),
        timing: GestureTiming = .immediate,
        schedulingQueue: DispatchQueue? = nil
    ) {
        self.init(
            mapperProvider: mapperProvider,
            inputSink: inputSink,
            cursorController: cursorController,
            focusRestorer: focusRestorer,
            timing: timing,
            scheduler: DispatchGestureScheduler(queue: schedulingQueue)
        )
    }

    init(
        mapperProvider: @escaping () -> CoordinateMapper?,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorer: FocusRestorer = NoOpFocusRestorer(),
        timing: GestureTiming = .immediate,
        scheduler: GestureScheduler
    ) {
        self.mapperProvider = mapperProvider
        self.inputSink = inputSink
        self.cursorController = cursorController
        self.focusRestorer = focusRestorer
        self.timing = timing
        self.scheduler = scheduler
    }

    /// Handles one normalized touch event.
    public func handle(_ event: TouchEvent) {
        // Consume contact boundaries even when the display mapper is unavailable.
        if rejectedContactIDs.contains(event.contactID) {
            if event.kind == .up {
                rejectedContactIDs.remove(event.contactID)
            }
            return
        }

        guard let mapper = mapperProvider() else {
            if case .singleTouch = state {
                cancelForMissingMapper()
            }
            if event.kind == .down {
                rejectedContactIDs.insert(event.contactID)
            }
            DriverLoggers.log(.warning, category: .gesture, "Dropping touch event because no display mapper is available.")
            return
        }

        let point = mapper.map(rawX: event.rawX, rawY: event.rawY)

        switch (state, event.kind) {
        case (.idle, .down):
            guard !isDebounced(event.timestamp) else {
                rejectedContactIDs.insert(event.contactID)
                DriverLoggers.log(.debug, category: .gesture, "Ignoring touch down inside tap debounce window.")
                return
            }

            focusRestorer.captureFocusedWindow()
            guard mapperProvider() != nil else {
                rejectedContactIDs.insert(event.contactID)
                focusRestorer.discardCapturedWindow()
                DriverLoggers.log(.warning, category: .gesture, "Dropping touch down because the display mapper was lost during focus capture.")
                return
            }
            guard cursorController.borrow(warpingTo: point) else {
                rejectedContactIDs.insert(event.contactID)
                focusRestorer.discardCapturedWindow()
                DriverLoggers.log(.warning, category: .gesture, "Dropping touch down because cursor borrow failed.")
                return
            }

            generation &+= 1
            phase = .tracking
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
            scheduleMouseDown(generation: generation, at: point)

        case (.singleTouch(let context), .move):
            guard phase == .tracking else { return }
            guard context.contactID == event.contactID else {
                DriverLoggers.log(.warning, category: .gesture, "Ignoring move for unexpected contact ID \(event.contactID).")
                return
            }

            ensureMouseDownPosted()
            guard case .singleTouch(var currentContext) = state else {
                return
            }
            guard mapperProvider() != nil else {
                cancelForMissingMapper()
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
            guard phase == .tracking else { return }
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
            phase = .waitingForMouseUp

            if currentContext.hasMoved {
                postMouseUpAndScheduleReturn(generation: generation, at: point)
            } else {
                scheduleMouseUpThenReturn(generation: generation, at: point)
            }

        case (.idle, .move), (.idle, .up):
            DriverLoggers.log(.debug, category: .gesture, "Ignoring touch event while idle.")

        case (.singleTouch(let context), .down):
            if phase == .tracking, context.contactID == event.contactID {
                // Hardware reuses ID 0. A second down without an up is ambiguous;
                // release the owned button before rejecting the malformed contact.
                forceCancel()
            }
            rejectedContactIDs.insert(event.contactID)
            DriverLoggers.log(.warning, category: .gesture, "Rejecting touch down while a gesture is active or cleaning up.")
        }
    }

    /// Handles a stuck gesture timeout by cleaning up any active mouse-down state.
    public func handleIdleTimeout() {
        forceCancel()
    }

    /// Forces the controller back to idle, posting cleanup events if needed.
    public func forceCancel() {
        guard phase != .finishing else { return }
        generation &+= 1
        cancelPendingWork()
        rejectedContactIDs.removeAll()

        switch state {
        case .idle:
            cursorController.forceShow()
            focusRestorer.discardCapturedWindow()

        case .singleTouch(var context):
            phase = .finishing
            if context.isMouseDownPosted {
                context.isMouseDownPosted = false
                state = .singleTouch(context)
                inputSink.postMouseUp(at: context.lastPoint)
            }
            cursorController.returnToOrigin()
            focusRestorer.restoreCapturedWindow()
            transitionToIdle()
        }
    }

    private func scheduleMouseDown(generation: UInt64, at point: CGPoint) {
        pendingMouseDown?.cancel()
        let task = schedule(after: timing.warpToClickDelayMs) { [weak self] in
            self?.postMouseDownIfNeeded(generation: generation, at: point)
        }
        // Zero-delay scheduling runs inline; it may have completed this phase already.
        if self.generation == generation, phase == .tracking,
           case .singleTouch(let context) = state, !context.isMouseDownPosted {
            pendingMouseDown = task
        } else {
            task.cancel()
        }
    }

    private func ensureMouseDownPosted() {
        pendingMouseDown?.cancel()
        pendingMouseDown = nil

        guard case .singleTouch(let context) = state else {
            return
        }

        postMouseDownIfNeeded(generation: generation, at: context.startPoint)
    }

    private func postMouseDownIfNeeded(generation: UInt64, at point: CGPoint) {
        guard self.generation == generation, phase == .tracking,
              case .singleTouch(var context) = state else {
            return
        }
        guard !context.isMouseDownPosted else {
            return
        }
        guard mapperProvider() != nil else {
            cancelForMissingMapper()
            return
        }

        context.isMouseDownPosted = true
        state = .singleTouch(context)
        pendingMouseDown = nil
        inputSink.postMouseDown(at: point)
    }

    private func cancelForMissingMapper() {
        // Geometry loss must not use focus-restoration fallbacks at stale coordinates.
        focusRestorer.discardCapturedWindow()
        forceCancel()
    }

    private func scheduleMouseUpThenReturn(generation: UInt64, at point: CGPoint) {
        pendingMouseUp?.cancel()
        let task = schedule(after: timing.downToUpDelayMs) { [weak self] in
            self?.postMouseUpAndScheduleReturn(generation: generation, at: point)
        }
        if self.generation == generation, phase == .waitingForMouseUp {
            pendingMouseUp = task
        } else {
            task.cancel()
        }
    }

    private func postMouseUpAndScheduleReturn(generation: UInt64, at point: CGPoint) {
        guard self.generation == generation, phase == .waitingForMouseUp,
              case .singleTouch(var context) = state, context.isMouseDownPosted else {
            return
        }
        guard mapperProvider() != nil else {
            cancelForMissingMapper()
            return
        }

        context.isMouseDownPosted = false
        state = .singleTouch(context)
        phase = .waitingForCursorReturn
        pendingMouseUp?.cancel()
        pendingMouseUp = nil
        inputSink.postMouseUp(at: point)
        guard self.generation == generation, phase == .waitingForCursorReturn else { return }
        pendingCursorReturn?.cancel()
        let task = schedule(after: timing.clickToWarpBackDelayMs) { [weak self] in
            self?.returnCursorAndIdle(generation: generation)
        }
        if self.generation == generation, phase == .waitingForCursorReturn {
            pendingCursorReturn = task
        } else {
            task.cancel()
        }
    }

    private func returnCursorAndIdle(generation: UInt64) {
        guard self.generation == generation, phase == .waitingForCursorReturn,
              case .singleTouch = state else {
            return
        }
        guard mapperProvider() != nil else {
            cancelForMissingMapper()
            return
        }

        phase = .finishing
        cursorController.returnToOrigin()
        focusRestorer.restoreCapturedWindow()
        pendingCursorReturn = nil
        transitionToIdle()
    }

    private func transitionToIdle() {
        generation &+= 1
        cancelPendingWork()
        phase = nil
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

    private func schedule(after milliseconds: Int, action: @escaping () -> Void) -> GestureScheduledTask {
        scheduler.schedule(afterMilliseconds: milliseconds, action: action)
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
