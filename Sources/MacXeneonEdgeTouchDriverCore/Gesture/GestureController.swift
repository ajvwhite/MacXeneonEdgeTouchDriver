import CoreGraphics
import Foundation

/// Classifies one raw contact as a tap, direct scroll, or hold-and-drag gesture.
public final class GestureController {
    public private(set) var state: GestureState = .idle
    public var onBecameIdle: (() -> Void)?

    private let mapperProvider: () -> CoordinateMapper?
    private let timing: GestureTiming
    private let schedulingQueue: DispatchQueue?
    private let inputSink: SyntheticInputSink
    private let cursorController: CursorController
    private let focusRestorer: FocusRestorer
    private var pendingHold: DispatchWorkItem?
    private var pendingMouseUp: DispatchWorkItem?
    private var pendingCursorReturn: DispatchWorkItem?
    private var lastCompletedTouchTimestamp: DispatchTime?

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

    public func handle(_ event: TouchEvent) {
        guard let mapper = mapperProvider() else {
            DriverLoggers.log(.warning, category: .gesture, "Dropping touch event because no display mapper is available.")
            return
        }
        let point = mapper.map(rawX: event.rawX, rawY: event.rawY)

        switch (state, event.kind) {
        case (.idle, .down):
            beginContact(event, at: point)
        case (.singleTouch(let context), .move):
            guard context.contactID == event.contactID else { return }
            handleMove(event, at: point, context: context)
        case (.singleTouch(let context), .up):
            guard context.contactID == event.contactID else { return }
            finishContact(event, at: point, context: context)
        case (.idle, .move), (.idle, .up):
            DriverLoggers.log(.debug, category: .gesture, "Ignoring touch event while idle.")
        case (.singleTouch, .down):
            DriverLoggers.log(.warning, category: .gesture, "Received touch down while already tracking a contact.")
        }
    }

    public func handleIdleTimeout() {
        forceCancel()
    }

    public func forceCancel() {
        cancelPendingWork()

        switch state {
        case .idle:
            cursorController.forceShow()
            focusRestorer.discardCapturedWindow()
        case .singleTouch(let context):
            switch context.phase {
            case .scrolling:
                inputSink.postScroll(deltaX: 0, deltaY: 0, phase: .ended)
            case .dragging, .finishingTap:
                inputSink.postMouseUp(at: context.lastPoint)
            case .pending:
                break
            }
            cursorController.returnToOrigin()
            focusRestorer.restoreCapturedWindow()
            transitionToIdle()
        }
    }

    private func beginContact(_ event: TouchEvent, at point: CGPoint) {
        guard !isDebounced(event.timestamp) else { return }
        focusRestorer.captureFocusedWindow()
        guard cursorController.borrow(warpingTo: point) else {
            focusRestorer.discardCapturedWindow()
            return
        }

        state = .singleTouch(SingleTouchContext(
            contactID: event.contactID,
            startPoint: point,
            lastPoint: point,
            lastRawX: event.rawX,
            lastRawY: event.rawY,
            phase: .pending
        ))
        scheduleHoldToDrag(contactID: event.contactID)
    }

    private func handleMove(_ event: TouchEvent, at point: CGPoint, context: SingleTouchContext) {
        var updated = context
        let deltaX = point.x - context.lastPoint.x
        let deltaY = point.y - context.lastPoint.y
        updated.lastPoint = point
        updated.lastRawX = event.rawX
        updated.lastRawY = event.rawY

        switch context.phase {
        case .pending:
            let distance = hypot(point.x - context.startPoint.x, point.y - context.startPoint.y)
            guard distance >= timing.movementThresholdPoints else {
                state = .singleTouch(updated)
                return
            }
            pendingHold?.cancel()
            pendingHold = nil
            updated.phase = .scrolling
            state = .singleTouch(updated)
            inputSink.postScroll(
                deltaX: (point.x - context.startPoint.x) * timing.scrollSensitivity,
                deltaY: (point.y - context.startPoint.y) * timing.scrollSensitivity,
                phase: .began
            )
        case .scrolling:
            state = .singleTouch(updated)
            inputSink.postScroll(
                deltaX: deltaX * timing.scrollSensitivity,
                deltaY: deltaY * timing.scrollSensitivity,
                phase: .changed
            )
        case .dragging:
            state = .singleTouch(updated)
            cursorController.updatePosition(point)
            inputSink.postMouseDragged(to: point)
        case .finishingTap:
            break
        }
    }

    private func finishContact(_ event: TouchEvent, at point: CGPoint, context: SingleTouchContext) {
        pendingHold?.cancel()
        pendingHold = nil
        lastCompletedTouchTimestamp = event.timestamp

        var updated = context
        updated.lastPoint = point
        updated.lastRawX = event.rawX
        updated.lastRawY = event.rawY

        switch context.phase {
        case .pending:
            updated.phase = .finishingTap
            updated.lastPoint = context.startPoint
            state = .singleTouch(updated)
            inputSink.postMouseDown(at: context.startPoint)
            scheduleMouseUpThenReturn(contactID: context.contactID, at: context.startPoint)
        case .scrolling:
            state = .singleTouch(updated)
            inputSink.postScroll(deltaX: 0, deltaY: 0, phase: .ended)
            scheduleCursorReturn(contactID: context.contactID)
        case .dragging:
            state = .singleTouch(updated)
            inputSink.postMouseUp(at: point)
            scheduleCursorReturn(contactID: context.contactID)
        case .finishingTap:
            break
        }
    }

    private func scheduleHoldToDrag(contactID: Int) {
        pendingHold = schedule(after: timing.holdToDragMs) { [weak self] in
            guard let self,
                  case .singleTouch(var context) = self.state,
                  context.contactID == contactID,
                  context.phase == .pending else { return }
            context.phase = .dragging
            self.state = .singleTouch(context)
            self.inputSink.postMouseDown(at: context.startPoint)
            self.pendingHold = nil
        }
    }

    private func scheduleMouseUpThenReturn(contactID: Int, at point: CGPoint) {
        pendingMouseUp = schedule(after: timing.downToUpDelayMs) { [weak self] in
            guard let self,
                  case .singleTouch(let context) = self.state,
                  context.contactID == contactID,
                  context.phase == .finishingTap else { return }
            self.inputSink.postMouseUp(at: point)
            self.pendingMouseUp = nil
            self.scheduleCursorReturn(contactID: contactID)
        }
    }

    private func scheduleCursorReturn(contactID: Int) {
        pendingCursorReturn = schedule(after: timing.clickToWarpBackDelayMs) { [weak self] in
            guard let self,
                  case .singleTouch(let context) = self.state,
                  context.contactID == contactID else { return }
            self.cursorController.returnToOrigin()
            self.focusRestorer.restoreCapturedWindow()
            self.pendingCursorReturn = nil
            self.transitionToIdle()
        }
    }

    private func transitionToIdle() {
        state = .idle
        onBecameIdle?()
    }

    private func cancelPendingWork() {
        pendingHold?.cancel()
        pendingMouseUp?.cancel()
        pendingCursorReturn?.cancel()
        pendingHold = nil
        pendingMouseUp = nil
        pendingCursorReturn = nil
    }

    @discardableResult
    private func schedule(after milliseconds: Int, action: @escaping () -> Void) -> DispatchWorkItem {
        let workItem = DispatchWorkItem(block: action)
        guard milliseconds > 0 else {
            workItem.perform()
            return workItem
        }
        (schedulingQueue ?? .main).asyncAfter(
            deadline: .now() + .milliseconds(milliseconds),
            execute: workItem
        )
        return workItem
    }

    private func isDebounced(_ timestamp: DispatchTime) -> Bool {
        guard timing.tapDebounceMs > 0, let lastCompletedTouchTimestamp else { return false }
        let debounceNanoseconds = UInt64(timing.tapDebounceMs) * 1_000_000
        return timestamp.uptimeNanoseconds >= lastCompletedTouchTimestamp.uptimeNanoseconds &&
            timestamp.uptimeNanoseconds - lastCompletedTouchTimestamp.uptimeNanoseconds < debounceNanoseconds
    }
}
