import Foundation
@testable import MacXeneonEdgeTouchDriverCore

/// Single-threaded virtual clock. Equal deadlines execute in scheduling order.
final class TestGestureScheduler: GestureScheduler {
    private final class Task: GestureScheduledTask {
        let deadline: UInt64
        let sequence: Int
        let action: () -> Void
        private(set) var isCancelled = false

        init(deadline: UInt64, sequence: Int, action: @escaping () -> Void) {
            self.deadline = deadline
            self.sequence = sequence
            self.action = action
        }

        func cancel() {
            isCancelled = true
        }
    }

    private(set) var now: DispatchTime
    private var nextSequence = 0
    private var tasks: [Task] = []
    private let executeCancelledActions: Bool

    /// Delivering cancelled work simulates a callback that has already started.
    init(nowMilliseconds: UInt64 = 0, executeCancelledActions: Bool = false) {
        now = DispatchTime(uptimeNanoseconds: nowMilliseconds * 1_000_000)
        self.executeCancelledActions = executeCancelledActions
    }

    @discardableResult
    func schedule(afterMilliseconds milliseconds: Int, action: @escaping () -> Void) -> GestureScheduledTask {
        let task = Task(
            deadline: now.uptimeNanoseconds + UInt64(max(0, milliseconds)) * 1_000_000,
            sequence: nextSequence,
            action: action
        )
        nextSequence += 1

        if milliseconds <= 0 {
            action()
        } else {
            tasks.append(task)
        }
        return task
    }

    func advance(byMilliseconds milliseconds: UInt64) {
        advance(toNanoseconds: now.uptimeNanoseconds + milliseconds * 1_000_000)
    }

    func advance(toMilliseconds milliseconds: UInt64) {
        advance(toNanoseconds: milliseconds * 1_000_000)
    }

    private func advance(toNanoseconds target: UInt64) {
        precondition(target >= now.uptimeNanoseconds, "Virtual time cannot move backwards")

        while let next = tasks.min(by: {
            ($0.deadline, $0.sequence) < ($1.deadline, $1.sequence)
        }), next.deadline <= target {
            tasks.removeAll { $0 === next }
            now = DispatchTime(uptimeNanoseconds: next.deadline)
            if !next.isCancelled || executeCancelledActions {
                next.action()
            }
        }
        now = DispatchTime(uptimeNanoseconds: target)
    }
}
