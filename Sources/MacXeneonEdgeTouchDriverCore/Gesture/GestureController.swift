import CoreGraphics
import Foundation

/// Classifies one raw contact as a tap, direct scroll, or hold-and-drag gesture.
public final class GestureController {
    private struct EligibleTap {
        let point: CGPoint
        let timestamp: DispatchTime
    }

    public private(set) var state: GestureState = .idle
    public var onBecameIdle: (() -> Void)?

    private let mapperProvider: () -> CoordinateMapper?
    private let timing: GestureTiming
    private let schedulingQueue: DispatchQueue?
    private let inputSink: SyntheticInputSink
    private let cursorController: CursorController
    private let focusRestorer: FocusRestorer
    private let doubleClickIntervalProvider: () -> TimeInterval
    private var pendingHold: DispatchWorkItem?
    private var pendingMouseUp: DispatchWorkItem?
    private var pendingCursorReturn: DispatchWorkItem?
    private var pendingFocusRestore: DispatchWorkItem?
    private var lastCompletedTouchTimestamp: DispatchTime?
    private var eligibleFirstTap: EligibleTap?
    private var hasCapturedFocus = false

    public init(
        mapperProvider: @escaping () -> CoordinateMapper?,
        inputSink: SyntheticInputSink,
        cursorController: CursorController,
        focusRestorer: FocusRestorer = NoOpFocusRestorer(),
        timing: GestureTiming = .immediate,
        doubleClickIntervalProvider: @escaping () -> TimeInterval = { 0.5 },
        schedulingQueue: DispatchQueue? = nil
    ) {
        self.mapperProvider = mapperProvider
        self.inputSink = inputSink
        self.cursorController = cursorController
        self.focusRestorer = focusRestorer
        self.timing = timing
        self.doubleClickIntervalProvider = doubleClickIntervalProvider
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
            let continuesTapSequence = isSecondTapCandidate(at: point, timestamp: event.timestamp)
            if eligibleFirstTap != nil, !continuesTapSequence {
                finalizeTapSequenceFocus()
            }
            beginContact(event, at: point, continuesTapSequence: continuesTapSequence)
        case (.singleTouch(let context), .move):
            guard context.contactID == event.contactID else { return }
            handleMove(event, at: point, context: context)
        case (.singleTouch(let context), .up):
            guard context.contactID == event.contactID else { return }
            finishContact(event, at: point, context: context)
        case (.idle, .move), (.idle, .up):
            DriverLoggers.log(.debug, category: .gesture, "Ignoring touch event while idle.")
        case (.singleTouch(let context), .down):
            guard context.phase == .finishingTap,
                  isSecondTapCandidate(at: point, timestamp: event.timestamp) else {
                DriverLoggers.log(.warning, category: .gesture, "Received touch down while already tracking a contact.")
                return
            }
            completeFinishingTapImmediately(context)
            beginContact(event, at: point, continuesTapSequence: true)
        }
    }

    public func handleIdleTimeout() {
        forceCancel()
    }

    public func forceCancel() {
        cancelPendingWork()
        resetDoubleClickSequence()

        switch state {
        case .idle:
            cursorController.forceShow()
            finalizeCapturedFocus()
        case .singleTouch(let context):
            switch context.phase {
            case .scrolling:
                inputSink.postScroll(deltaX: 0, deltaY: 0, phase: .ended)
            case .dragging, .finishingTap:
                inputSink.postMouseUp(at: context.lastPoint, clickCount: context.clickCount)
            case .pending:
                break
            }
            cursorController.returnToOrigin()
            finalizeCapturedFocus()
            transitionToIdle()
        }
    }

    private func beginContact(
        _ event: TouchEvent,
        at point: CGPoint,
        continuesTapSequence: Bool
    ) {
        guard continuesTapSequence || !isDebounced(event.timestamp) else { return }

        if continuesTapSequence {
            pendingFocusRestore?.cancel()
            pendingFocusRestore = nil
        } else {
            focusRestorer.captureFocusedWindow()
            hasCapturedFocus = true
        }

        state = .singleTouch(SingleTouchContext(
            contactID: event.contactID,
            startPoint: point,
            lastPoint: point,
            lastRawX: event.rawX,
            lastRawY: event.rawY,
            phase: .pending,
            clickCount: 1
        ))
        scheduleHoldToDrag(contactID: event.contactID)
    }

    private func completeFinishingTapImmediately(_ context: SingleTouchContext) {
        pendingMouseUp?.cancel()
        pendingCursorReturn?.cancel()

        if pendingMouseUp != nil {
            inputSink.postMouseUp(at: context.lastPoint, clickCount: context.clickCount)
        }
        pendingMouseUp = nil
        pendingCursorReturn = nil
        cursorController.returnToOrigin()
        transitionToIdle()
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
            resetDoubleClickSequence()
            guard borrowCursor(at: context.startPoint) else { return }
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
            guard borrowCursor(at: context.startPoint) else { return }
            let clickCount = clickCountForTap(at: context.startPoint, timestamp: event.timestamp)
            updated.phase = .finishingTap
            updated.lastPoint = context.startPoint
            updated.clickCount = clickCount
            state = .singleTouch(updated)
            inputSink.postMouseDown(at: context.startPoint, clickCount: clickCount)
            scheduleMouseUpThenReturn(
                contactID: context.contactID,
                at: context.startPoint,
                clickCount: clickCount
            )
        case .scrolling:
            resetDoubleClickSequence()
            state = .singleTouch(updated)
            inputSink.postScroll(deltaX: 0, deltaY: 0, phase: .ended)
            scheduleCursorReturn(contactID: context.contactID, completedTapClickCount: nil)
        case .dragging:
            resetDoubleClickSequence()
            state = .singleTouch(updated)
            inputSink.postMouseUp(at: point, clickCount: 1)
            scheduleCursorReturn(contactID: context.contactID, completedTapClickCount: nil)
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
            self.pendingHold = nil
            guard self.borrowCursor(at: context.startPoint) else { return }
            context.phase = .dragging
            context.clickCount = 1
            self.state = .singleTouch(context)
            self.resetDoubleClickSequence()
            self.inputSink.postMouseDown(at: context.startPoint, clickCount: 1)
        }
    }

    private func scheduleMouseUpThenReturn(contactID: Int, at point: CGPoint, clickCount: Int) {
        pendingMouseUp = schedule(after: timing.downToUpDelayMs) { [weak self] in
            guard let self,
                  case .singleTouch(let context) = self.state,
                  context.contactID == contactID,
                  context.phase == .finishingTap else { return }
            self.inputSink.postMouseUp(at: point, clickCount: clickCount)
            self.pendingMouseUp = nil
            self.scheduleCursorReturn(
                contactID: contactID,
                completedTapClickCount: clickCount
            )
        }
    }

    private func scheduleCursorReturn(
        contactID: Int,
        completedTapClickCount: Int?
    ) {
        pendingCursorReturn = schedule(after: timing.clickToWarpBackDelayMs) { [weak self] in
            guard let self,
                  case .singleTouch(let context) = self.state,
                  context.contactID == contactID else { return }
            self.cursorController.returnToOrigin()
            self.pendingCursorReturn = nil
            self.transitionToIdle()

            if let completedTapClickCount {
                if completedTapClickCount == 2 {
                    self.finalizeTapSequenceFocus()
                } else {
                    self.scheduleTapSequenceFocusRestore()
                }
            } else {
                self.finalizeTapSequenceFocus()
            }
        }
    }

    private func transitionToIdle() {
        state = .idle
        onBecameIdle?()
    }

    private func borrowCursor(at point: CGPoint) -> Bool {
        guard cursorController.borrow(warpingTo: point) else {
            if eligibleFirstTap != nil {
                finalizeTapSequenceFocus()
            } else {
                focusRestorer.discardCapturedWindow()
                hasCapturedFocus = false
            }
            transitionToIdle()
            return false
        }
        return true
    }

    private func cancelPendingWork() {
        pendingHold?.cancel()
        pendingMouseUp?.cancel()
        pendingCursorReturn?.cancel()
        pendingFocusRestore?.cancel()
        pendingHold = nil
        pendingMouseUp = nil
        pendingCursorReturn = nil
        pendingFocusRestore = nil
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

    private func clickCountForTap(at point: CGPoint, timestamp: DispatchTime) -> Int {
        guard let firstTap = eligibleFirstTap else {
            eligibleFirstTap = EligibleTap(point: point, timestamp: timestamp)
            return 1
        }

        let interval = max(0, doubleClickIntervalProvider())
        let maximumNanoseconds = UInt64(interval * 1_000_000_000)
        let timestampIsOrdered = timestamp.uptimeNanoseconds >= firstTap.timestamp.uptimeNanoseconds
        let elapsed = timestampIsOrdered
            ? timestamp.uptimeNanoseconds - firstTap.timestamp.uptimeNanoseconds
            : UInt64.max
        let distance = hypot(point.x - firstTap.point.x, point.y - firstTap.point.y)

        if elapsed <= maximumNanoseconds, distance <= timing.doubleClickDistancePoints {
            eligibleFirstTap = nil
            DriverLoggers.log(.notice, category: .gesture, "Recognized touchscreen double-click.")
            return 2
        }

        eligibleFirstTap = EligibleTap(point: point, timestamp: timestamp)
        return 1
    }

    private func resetDoubleClickSequence() {
        eligibleFirstTap = nil
        pendingFocusRestore?.cancel()
        pendingFocusRestore = nil
    }

    private func isSecondTapCandidate(at point: CGPoint, timestamp: DispatchTime) -> Bool {
        guard let firstTap = eligibleFirstTap else { return false }

        let interval = max(0, doubleClickIntervalProvider())
        let maximumNanoseconds = UInt64(interval * 1_000_000_000)
        guard timestamp.uptimeNanoseconds >= firstTap.timestamp.uptimeNanoseconds else {
            return false
        }
        let elapsed = timestamp.uptimeNanoseconds - firstTap.timestamp.uptimeNanoseconds
        let distance = hypot(point.x - firstTap.point.x, point.y - firstTap.point.y)
        return elapsed <= maximumNanoseconds && distance <= timing.doubleClickDistancePoints
    }

    private func scheduleTapSequenceFocusRestore() {
        pendingFocusRestore?.cancel()
        let delayMilliseconds = Int(ceil(max(0, doubleClickIntervalProvider()) * 1_000))
        pendingFocusRestore = schedule(after: delayMilliseconds) { [weak self] in
            guard let self, self.eligibleFirstTap != nil else { return }
            self.pendingFocusRestore = nil
            self.finalizeTapSequenceFocus()
        }
    }

    private func finalizeTapSequenceFocus() {
        resetDoubleClickSequence()
        finalizeCapturedFocus()
    }

    private func finalizeCapturedFocus() {
        guard hasCapturedFocus else { return }
        hasCapturedFocus = false
        focusRestorer.restoreCapturedWindow()
    }
}
