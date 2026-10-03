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
    private let returnCursorToPreviousPosition: Bool
    private var pendingMouseDown: GestureScheduledTask?
    private var pendingMouseUp: GestureScheduledTask?
    private var pendingCursorReturn: GestureScheduledTask?
    private var lastCompletedTouchTimestamp: DispatchTime?
    private var preparation: Preparation?
    private var preparationDeadline: GestureScheduledTask?
    private var preparationGeneration: UInt64 = 0
    private var rejectedPreparationContacts: Set<Int> = []

    /// An input deadline, not a promise that an in-flight AX call can be cancelled.
    static let focusPreparationTimeoutMs = 30

    private struct Preparation {
        let generation: UInt64
        let contactID: Int
        let point: CGPoint
        let deadline: DispatchTime
    }

    /// Creates a single-touch gesture controller.
    public convenience init(
        mapperProvider: @escaping () -> CoordinateMapper?,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorer: FocusRestorer = NoOpFocusRestorer(),
        returnCursorToPreviousPosition: Bool = true,
        timing: GestureTiming = .immediate,
        schedulingQueue: DispatchQueue? = nil
    ) {
        self.init(
            mapperProvider: mapperProvider,
            inputSink: inputSink,
            cursorController: cursorController,
            focusRestorer: focusRestorer,
            returnCursorToPreviousPosition: returnCursorToPreviousPosition,
            timing: timing,
            scheduler: DispatchGestureScheduler(queue: schedulingQueue)
        )
    }

    init(
        mapperProvider: @escaping () -> CoordinateMapper?,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorer: FocusRestorer = NoOpFocusRestorer(),
        returnCursorToPreviousPosition: Bool = true,
        timing: GestureTiming = .immediate,
        scheduler: GestureScheduler
    ) {
        self.mapperProvider = mapperProvider
        self.inputSink = inputSink
        self.cursorController = cursorController
        self.focusRestorer = focusRestorer
        self.returnCursorToPreviousPosition = returnCursorToPreviousPosition
        self.timing = timing
        self.scheduler = scheduler
    }

    /// Handles one normalized touch event.
    public func handle(_ event: TouchEvent) {
        if rejectedPreparationContacts.contains(event.contactID) {
            if event.kind == .up { rejectedPreparationContacts.remove(event.contactID) }
            return
        }

        if let preparation {
            guard event.contactID == preparation.contactID else {
                if event.kind == .down { rejectedPreparationContacts.insert(event.contactID) }
                return
            }
            if event.kind == .down {
                // A second down with the reused hardware ID makes the pending contact ambiguous.
                forceCancel()
                rejectedPreparationContacts.insert(event.contactID)
                return
            }
            // Preserve every move/up, without buffering or coalescing a drag path.
            finishPreparation(generation: preparation.generation, captureReady: false)
            if rejectedPreparationContacts.contains(event.contactID) {
                if event.kind == .up { rejectedPreparationContacts.remove(event.contactID) }
                return
            }
        }

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
            beginPreparation(contactID: event.contactID, at: point)

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
        rejectedPreparationContacts.removeAll()
        if preparation != nil {
            cancelPreparation()
            focusRestorer.discardCapturedWindow()
            transitionToIdle()
            return
        }
        cancelPendingWork()

        switch state {
        case .idle:
            cursorController.forceShow()
            focusRestorer.discardCapturedWindow()

        case .singleTouch(let context):
            if context.isMouseDownPosted {
                focusRestorer.inputDidEnd()
                inputSink.postMouseUp(at: context.lastPoint)
            }
            cursorController.releaseBorrow(returnToPreviousPosition: returnCursorToPreviousPosition)
            focusRestorer.restoreCapturedWindow()
            transitionToIdle()
        }
    }

    private func beginPreparation(contactID: Int, at point: CGPoint) {
        preparationGeneration &+= 1
        let generation = preparationGeneration
        preparation = Preparation(
            generation: generation,
            contactID: contactID,
            point: point,
            deadline: DispatchTime(uptimeNanoseconds:
                scheduler.now.uptimeNanoseconds + UInt64(Self.focusPreparationTimeoutMs) * 1_000_000)
        )

        // Offer inline/no-op capture before installing a timer: the queue-less scheduler
        // intentionally executes even delayed tasks synchronously.
        focusRestorer.prepareFocusedWindow { [weak self] in
            self?.finishPreparation(generation: generation, captureReady: true)
        }
        guard let preparation, preparation.generation == generation else { return }
        let deadline = preparation.deadline.uptimeNanoseconds
        let remaining = deadline - min(deadline, scheduler.now.uptimeNanoseconds)
        let milliseconds = Int((remaining + 999_999) / 1_000_000)
        let task = schedule(after: milliseconds) { [weak self] in
            self?.finishPreparation(generation: generation, captureReady: false)
        }
        if self.preparation?.generation == generation {
            preparationDeadline = task
        } else {
            task.cancel()
        }
    }

    private func finishPreparation(generation: UInt64, captureReady: Bool) {
        guard let preparation, preparation.generation == generation else { return }
        let captureIsTimely = captureReady && scheduler.now.uptimeNanoseconds < preparation.deadline.uptimeNanoseconds
        cancelPreparation()
        if !captureIsTimely {
            focusRestorer.discardCapturedWindow()
        }
        guard mapperProvider() != nil,
              cursorController.borrow(warpingTo: preparation.point) else {
            rejectedPreparationContacts.insert(preparation.contactID)
            focusRestorer.discardCapturedWindow()
            transitionToIdle()
            return
        }
        scheduleMouseDown(contactID: preparation.contactID, at: preparation.point)
    }

    private func cancelPreparation() {
        preparationGeneration &+= 1
        preparation = nil
        preparationDeadline?.cancel()
        preparationDeadline = nil
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

        focusRestorer.inputDidEnd()
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

        cursorController.releaseBorrow(returnToPreviousPosition: returnCursorToPreviousPosition)
        focusRestorer.restoreCapturedWindow()
        pendingCursorReturn = nil
        transitionToIdle()
    }

    private func transitionToIdle() {
        cancelPreparation()
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
