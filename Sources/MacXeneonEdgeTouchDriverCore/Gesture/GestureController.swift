import CoreGraphics
import Foundation

/// Identifies the controller generation that accepted a physical input contact.
/// It is distinct from the hardware's reused contact ID and the cleanup lease.
struct GestureInputSession: Equatable, Sendable {
    let generation: UInt64
    let contactID: Int
}

/// Handles normalized touch events and emits cursor/input side effects.
public final class GestureController {
    /// Current controller state.
    public private(set) var state: GestureState = .idle

    /// Called when all delayed cleanup has completed and the controller is idle.
    public var onBecameIdle: (() -> Void)?

    // These queue-confined hooks only change application liveness ownership.
    // Closing occurs before focus/cursor/input collaborators can reenter.
    var onInputSessionEnded: ((GestureInputSession) -> Void)?
    var onInputSessionInvalidated: ((GestureInputSession) -> Void)?
    private var inputSession: GestureInputSession?
    private var physicalInputIsOpen = false

    func acceptsHeartbeat(for session: GestureInputSession) -> Bool {
        inputSession == session && physicalInputIsOpen && !cancellationRequested &&
            (phase == .preparing || phase == .tracking)
    }

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

    /// An input deadline, not a promise that an in-flight AX call can be cancelled.
    static let focusPreparationTimeoutMs = 30

    private struct Preparation {
        let generation: UInt64
        let contactID: Int
        let point: CGPoint
        let deadline: DispatchTime
    }

    private var generation: UInt64 = 0
    private var phase: Phase?
    private var inputOperationInFlight = false
    private var cancellationRequested = false
    private var activeContactEndedDuringInput = false
    private var contactDownVersions: [Int: UInt64] = [:]
    private var deferredInputEnd: (generation: UInt64, event: TouchEvent)?
    // Unlike a lifecycle cancellation, failed input quarantines until its physical up.
    private var failedInputContactIDs: Set<Int> = []
    // A rejected down rejects that entire contact, even if cleanup finishes before its up.
    private var rejectedContactIDs: Set<Int> = []

    private enum Phase {
        case preparing
        case tracking
        case waitingForMouseUp
        case waitingForCursorReturn
        case finishing
        // A reporting sink violated its reserved-release contract. Keep ownership
        // without a cleanup warp, reject new input, and do not schedule retries.
        case releaseBlocked
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

    /// Production admission owns endpoint/epoch quarantine. Clear the older
    /// ID-only compatibility quarantine only for a new, independently admitted
    /// physical contact while no global input/cleanup lease remains.
    func prepareForNewPhysicalContact(contactID: Int) {
        guard state == .idle, !inputOperationInFlight else { return }
        failedInputContactIDs.remove(contactID)
        rejectedContactIDs.remove(contactID)
    }

    /// Handles one normalized touch event.
    public func handle(_ event: TouchEvent) {
        handle(event, acceptingDown: nil)
    }

    /// Acceptance is reported before the first reentrant collaborator, never
    /// inferred from whichever same-ID gesture happens to exist after handle.
    func handle(_ event: TouchEvent, acceptingDown: ((GestureInputSession) -> Bool)?) {
        if event.kind == .down { contactDownVersions[event.contactID, default: 0] &+= 1 }
        let downVersionAtReceipt = contactDownVersions[event.contactID, default: 0]
        // Side effects may synchronously reenter the controller. Do not admit a
        // newer contact while an older post invocation has not returned.
        if inputOperationInFlight {
            handleDuringInputOperation(event)
            return
        }
        // Consume both forms of quarantine at the same physical boundary, even
        // when geometry is unavailable. One up must not require a second up.
        if failedInputContactIDs.contains(event.contactID) || rejectedContactIDs.contains(event.contactID) {
            if event.kind == .up {
                failedInputContactIDs.remove(event.contactID)
                rejectedContactIDs.remove(event.contactID)
            }
            return
        }

        // Freeze focus restoration eligibility at the accepted HID release, before synthetic cleanup.
        if event.kind == .up, phase == .preparing || phase == .tracking,
           case .singleTouch(let context) = state, context.contactID == event.contactID {
            let acceptedGeneration = generation
            closePhysicalInput()
            guard generation == acceptedGeneration else { return }
            focusRestorer.inputDidEnd()
            guard generation == acceptedGeneration else { return }
        }

        if let preparation {
            guard event.contactID == preparation.contactID else {
                if event.kind == .down { rejectedContactIDs.insert(event.contactID) }
                return
            }
            if event.kind == .down {
                // A second down with the reused hardware ID makes the pending contact ambiguous.
                forceCancel()
                rejectedContactIDs.insert(event.contactID)
                return
            }
            // Preserve every move/up, without buffering or coalescing a drag path.
            let preparingGestureGeneration = generation
            finishPreparation(generation: preparation.generation, captureReady: false)
            if rejectedContactIDs.contains(event.contactID) || failedInputContactIDs.contains(event.contactID) {
                if event.kind == .up {
                    if contactDownVersions[event.contactID, default: 0] == downVersionAtReceipt {
                        rejectedContactIDs.remove(event.contactID)
                        failedInputContactIDs.remove(event.contactID)
                    }
                }
                return
            }
            // A failed/flushed preparation may synchronously reach idle and start
            // another contact. Never route this older move/up into that generation.
            guard generation == preparingGestureGeneration else { return }
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

            generation &+= 1
            phase = .preparing
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
            let acceptedSession = GestureInputSession(generation: generation, contactID: event.contactID)
            inputSession = acceptedSession
            physicalInputIsOpen = true
            if acceptingDown?(acceptedSession) == false {
                transitionToIdle()
                return
            }
            guard inputSession == acceptedSession, phase == .preparing else { return }
            beginPreparation(contactID: event.contactID, at: point)

        case (.singleTouch(let context), .move):
            guard phase == .tracking else { return }
            guard context.contactID == event.contactID else {
                DriverLoggers.log(.warning, category: .gesture, "Ignoring move for unexpected contact ID \(event.contactID).")
                return
            }

            guard ensureMouseDownPosted(), phase == .tracking,
                  case .singleTouch(var currentContext) = state else { return }
            let activeGeneration = generation

            guard mapperProvider() != nil else {
                cancelForMissingMapper()
                return
            }

            cursorController.updatePosition(point)
            guard generation == activeGeneration, phase == .tracking else { return }
            guard mapperProvider() != nil else {
                cancelForMissingMapper()
                return
            }
            // Accept after cursor update and geometry revalidation, before the
            // fallible drag. A failed drag still releases at this accepted point.
            currentContext.lastPoint = point
            currentContext.lastRawX = event.rawX
            currentContext.lastRawY = event.rawY
            state = .singleTouch(currentContext)
            let result = performInput {
                if let reporting = inputSink as? ReportingSyntheticInputSink {
                    return reporting.tryPostMouseDragged(to: point)
                }
                inputSink.postMouseDragged(to: point)
                return .postInvoked
            }
            if result == .postInvoked, case .singleTouch(var updated) = state {
                updated.hasMoved = true
                state = .singleTouch(updated)
            }
            finishDeferredInput()

        case (.singleTouch(let context), .up):
            guard phase == .tracking else { return }
            guard context.contactID == event.contactID else {
                DriverLoggers.log(.warning, category: .gesture, "Ignoring up for unexpected contact ID \(event.contactID).")
                return
            }

            guard ensureMouseDownPosted(), phase == .tracking,
                  case .singleTouch(var currentContext) = state else {
                // This up closes the failed original contact, but cannot close a
                // newer same-ID down observed while its down call was in flight.
                if contactDownVersions[event.contactID, default: 0] == downVersionAtReceipt {
                    failedInputContactIDs.remove(event.contactID)
                }
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

    /// Allows application cleanup to verify that its own collaborator did not
    /// synchronously replace the generation it intended to cancel.
    var ownershipGeneration: UInt64 { generation }

    func forceCancel(ifGeneration expected: UInt64) {
        guard generation == expected else { return }
        forceCancel()
    }

    /// Forces the controller back to idle, posting cleanup events if needed.
    public func forceCancel() {
        invalidateInputSession()
        guard phase != .finishing, phase != .releaseBlocked else { return }
        if inputOperationInFlight {
            cancellationRequested = true
            return
        }
        generation &+= 1
        let cancelledGeneration = generation
        cancelPendingWork()
        rejectedContactIDs.removeAll()
        if preparation != nil {
            cancelPreparation()
            focusRestorer.discardCapturedWindow()
            guard generation == cancelledGeneration else { return }
            transitionToIdle()
            return
        }

        switch state {
        case .idle:
            cursorController.forceShow()
            guard generation == cancelledGeneration else { return }
            focusRestorer.discardCapturedWindow()

        case .singleTouch(let context):
            phase = .finishing
            if context.isMouseDownPosted {
                focusRestorer.inputDidEnd()
                guard releaseOwnedMouseDown(at: context.lastPoint) else { return }
            }
            cursorController.releaseBorrow(returnToPreviousPosition: returnCursorToPreviousPosition)
            restoreFocusAfterCursorReturn()
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
        let acceptedGeneration = self.generation
        // Keep the preparation transition leased across discard and borrow.
        // A reentrant up after preparation is cleared must still be deferred,
        // not lost in the gap before tracking begins.
        inputOperationInFlight = true
        activeContactEndedDuringInput = false
        cancelPreparation()
        if !captureIsTimely {
            focusRestorer.discardCapturedWindow()
        }
        guard self.generation == acceptedGeneration, phase == .preparing else {
            inputOperationInFlight = false
            return
        }
        if cancellationRequested {
            inputOperationInFlight = false
            // Cancellation won before any borrow. There is no cursor or button
            // ownership to release. Keep the lease closed through focus cleanup.
            rejectedContactIDs.removeAll()
            phase = .finishing
            focusRestorer.discardCapturedWindow()
            transitionToIdle()
            return
        }
        guard mapperProvider() != nil else {
            inputOperationInFlight = false
            invalidateInputSession()
            rejectedContactIDs.insert(preparation.contactID)
            focusRestorer.discardCapturedWindow()
            guard self.generation == acceptedGeneration else { return }
            transitionToIdle()
            return
        }
        // Borrow can synchronously reenter too. Retain the global lease until
        // its result is known, just as for a synthetic post invocation.
        let borrowed = cursorController.borrow(warpingTo: preparation.point)
        inputOperationInFlight = false
        // A borrow collaborator may cancel or replace this gesture. Its old
        // return value cannot move a newer generation into tracking.
        guard self.generation == acceptedGeneration, phase == .preparing else { return }
        guard borrowed else {
            invalidateInputSession()
            if !activeContactEndedDuringInput { rejectedContactIDs.insert(preparation.contactID) }
            phase = .finishing
            focusRestorer.discardCapturedWindow()
            transitionToIdle()
            return
        }
        phase = .tracking
        if cancellationRequested {
            finishDeferredInput()
            return
        }
        scheduleMouseDown(generation: self.generation, at: preparation.point)
        finishDeferredInput()
    }

    private func cancelPreparation() {
        preparationGeneration &+= 1
        preparation = nil
        preparationDeadline?.cancel()
        preparationDeadline = nil
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

    private func ensureMouseDownPosted() -> Bool {
        pendingMouseDown?.cancel()
        pendingMouseDown = nil

        guard case .singleTouch(let context) = state else { return false }
        let activeGeneration = generation
        postMouseDownIfNeeded(generation: activeGeneration, at: context.startPoint)
        guard generation == activeGeneration, phase == .tracking,
              case .singleTouch(let current) = state else { return false }
        return current.isMouseDownPosted
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

        pendingMouseDown = nil
        let result = performInput {
            if let reporting = inputSink as? ReportingSyntheticInputSink {
                return reporting.tryPostMouseDown(at: point)
            }
            inputSink.postMouseDown(at: point)
            return .postInvoked
        }
        guard result == .postInvoked else {
            abortFailedMouseDown(contactID: context.contactID)
            return
        }
        context.isMouseDownPosted = true
        state = .singleTouch(context)
        finishDeferredInput()
    }

    private func performInput(_ operation: () -> SyntheticInputResult) -> SyntheticInputResult {
        precondition(!inputOperationInFlight)
        inputOperationInFlight = true
        activeContactEndedDuringInput = false
        defer { inputOperationInFlight = false }
        return operation()
    }

    private func handleDuringInputOperation(_ event: TouchEvent) {
        if case .singleTouch(let context) = state, context.contactID == event.contactID {
            if event.kind == .up { activeContactEndedDuringInput = true }
            if event.kind == .down {
                activeContactEndedDuringInput = false
            }
        }
        if event.kind == .up {
            // A rejected contact can complete while a collaborator is on-stack.
            // Consume that boundary now instead of quarantining its next reuse.
            let wasFailed = failedInputContactIDs.remove(event.contactID) != nil
            let wasRejected = rejectedContactIDs.remove(event.contactID) != nil
            if wasFailed || wasRejected { return }
            if phase == .preparing || phase == .tracking, case .singleTouch(let context) = state,
               context.contactID == event.contactID, deferredInputEnd == nil {
                // One terminal event is enough; never buffer an unbounded path.
                deferredInputEnd = (generation, event)
                closePhysicalInput()
                focusRestorer.inputDidEnd()
            }
        } else if event.kind == .down {
            failedInputContactIDs.insert(event.contactID)
            if phase == .preparing || phase == .tracking, case .singleTouch(let context) = state,
               context.contactID == event.contactID {
                // The reused active ID is ambiguous, just like an ordinary second
                // down. Cancel only after the in-flight result establishes ownership.
                cancellationRequested = true
            }
        }
    }

    private func finishDeferredInput() {
        let ended = deferredInputEnd
        deferredInputEnd = nil
        if cancellationRequested {
            cancellationRequested = false
            if let ended, ended.generation == generation,
               case .singleTouch(var context) = state,
               context.contactID == ended.event.contactID,
               let mapper = mapperProvider() {
                context.lastPoint = mapper.map(rawX: ended.event.rawX, rawY: ended.event.rawY)
                context.lastRawX = ended.event.rawX
                context.lastRawY = ended.event.rawY
                state = .singleTouch(context)
            }
            forceCancel()
        } else if let ended, ended.generation == generation {
            handle(ended.event)
        }
    }

    private func abortFailedMouseDown(contactID: Int) {
        invalidateInputSession()
        // No poster was invoked, so no release is owed. Block reentry until cursor
        // cleanup finishes, discard focus eligibility, and quarantine the contact.
        phase = .finishing
        cancellationRequested = false
        failedInputContactIDs.insert(contactID)
        // The active boundary may have been consumed as an ambiguous/rejected
        // up, so it need not appear in deferredInputEnd. A later active-ID down
        // resets this marker and remains quarantined until its own up.
        if activeContactEndedDuringInput { failedInputContactIDs.remove(contactID) }
        deferredInputEnd = nil
        cancelPendingWork()
        focusRestorer.discardCapturedWindow()
        cursorController.releaseBorrow(returnToPreviousPosition: returnCursorToPreviousPosition)
        transitionToIdle()
    }

    @discardableResult
    private func releaseOwnedMouseDown(at point: CGPoint) -> Bool {
        guard case .singleTouch(var context) = state, context.isMouseDownPosted else { return true }
        let result = performInput {
            if let reporting = inputSink as? ReportingSyntheticInputSink {
                return reporting.tryPostMouseUp(at: point)
            }
            inputSink.postMouseUp(at: point)
            return .postInvoked
        }
        guard result == .postInvoked else {
            // Production CGEventInputSink cannot reach this after an accepted down.
            // Never hide a contract violation behind idle, a cursor warp, or retries.
            // Release visibility/association without moving the cursor; ownership
            // remains unresolved, and repeated lifecycle cleanup is a no-op.
            invalidateInputSession()
            phase = .releaseBlocked
            cancellationRequested = false
            cancelPendingWork()
            focusRestorer.discardCapturedWindow()
            cursorController.releaseBorrow(returnToPreviousPosition: false)
            DriverLoggers.log(.fault, category: .gesture, "Synthetic mouse release was not invoked; retaining unresolved release ownership without a cursor warp.")
            return false
        }
        context.isMouseDownPosted = false
        state = .singleTouch(context)
        return true
    }

    private func cancelForMissingMapper() {
        let cancelledGeneration = generation
        invalidateInputSession()
        // Geometry loss must not use focus-restoration fallbacks at stale coordinates.
        focusRestorer.discardCapturedWindow()
        forceCancel(ifGeneration: cancelledGeneration)
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
              case .singleTouch(let context) = state, context.isMouseDownPosted else {
            return
        }
        guard mapperProvider() != nil else {
            cancelForMissingMapper()
            return
        }

        pendingMouseUp?.cancel()
        pendingMouseUp = nil
        focusRestorer.inputDidEnd()
        guard self.generation == generation, phase == .waitingForMouseUp else { return }
        guard releaseOwnedMouseDown(at: point) else { return }
        phase = .waitingForCursorReturn
        finishDeferredInput()
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
        cursorController.releaseBorrow(returnToPreviousPosition: returnCursorToPreviousPosition)
        restoreFocusAfterCursorReturn()
        pendingCursorReturn = nil
        transitionToIdle()
    }

    private func restoreFocusAfterCursorReturn() {
        // Cursor cleanup may deliver a display notification. Recheck before starting
        // focus work; the cursor operation that already ran cannot be retracted.
        guard mapperProvider() != nil else {
            focusRestorer.discardCapturedWindow()
            return
        }
        focusRestorer.restoreCapturedWindow()
    }

    private func closePhysicalInput() {
        guard physicalInputIsOpen, let session = inputSession else { return }
        physicalInputIsOpen = false
        onInputSessionEnded?(session)
    }

    /// Application teardown seals liveness before its own focus collaborators.
    func invalidatePhysicalInput() {
        invalidateInputSession()
    }

    private func invalidateInputSession() {
        guard let session = inputSession else { return }
        inputSession = nil
        physicalInputIsOpen = false
        onInputSessionInvalidated?(session)
    }

    private func transitionToIdle() {
        invalidateInputSession()
        cancelPreparation()
        generation &+= 1
        cancelPendingWork()
        phase = nil
        cancellationRequested = false
        activeContactEndedDuringInput = false
        deferredInputEnd = nil
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
