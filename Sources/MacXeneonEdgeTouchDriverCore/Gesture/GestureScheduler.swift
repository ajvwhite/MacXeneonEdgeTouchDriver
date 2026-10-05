import Foundation

/// Cancellable delayed work; cancellation cannot undo an action already running.
protocol GestureScheduledTask {
    func cancel()
}

/// Keeps gesture deadlines and test event timestamps on the same monotonic clock.
protocol GestureScheduler {
    var now: DispatchTime { get }

    @discardableResult
    func schedule(afterMilliseconds milliseconds: Int, action: @escaping () -> Void) -> GestureScheduledTask
}

/// Preserves the controller's synchronous behavior when no queue or delay is supplied.
final class DispatchGestureScheduler: GestureScheduler {
    private let queue: DispatchQueue?

    init(queue: DispatchQueue?) {
        self.queue = queue
    }

    var now: DispatchTime { .now() }

    @discardableResult
    func schedule(afterMilliseconds milliseconds: Int, action: @escaping () -> Void) -> GestureScheduledTask {
        let workItem = DispatchWorkItem(block: action)

        guard milliseconds > 0, let queue else {
            workItem.perform()
            return workItem
        }

        queue.asyncAfter(deadline: now + .milliseconds(milliseconds), execute: workItem)
        return workItem
    }
}

extension DispatchWorkItem: GestureScheduledTask {}
