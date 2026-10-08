import Foundation

/// Cancellable delayed work; cancellation cannot undo an action already running.
protocol GestureScheduledTask {
    func cancel()
}

/// Keeps gesture deadlines and test event timestamps on the same monotonic clock.
protocol GestureScheduler {
    var now: DispatchTime { get }

    @discardableResult
    func schedule(at deadline: DispatchTime, action: @escaping () -> Void) -> GestureScheduledTask

    @discardableResult
    func schedule(afterMilliseconds milliseconds: Int, action: @escaping () -> Void) -> GestureScheduledTask
}

extension GestureScheduler {
    @discardableResult
    func schedule(at deadline: DispatchTime, action: @escaping () -> Void) -> GestureScheduledTask {
        let current = now.uptimeNanoseconds
        let remaining = deadline.uptimeNanoseconds > current ? deadline.uptimeNanoseconds - current : 0
        let milliseconds = Int(remaining / 1_000_000 + (remaining % 1_000_000 == 0 ? 0 : 1))
        return schedule(afterMilliseconds: milliseconds, action: action)
    }
}

/// Preserves the controller's synchronous behavior when no queue or delay is supplied.
final class DispatchGestureScheduler: GestureScheduler {
    private let queue: DispatchQueue?

    init(queue: DispatchQueue?) {
        self.queue = queue
    }

    var now: DispatchTime { .now() }

    @discardableResult
    func schedule(at deadline: DispatchTime, action: @escaping () -> Void) -> GestureScheduledTask {
        let workItem = DispatchWorkItem(block: action)
        guard deadline > now, let queue else {
            workItem.perform()
            return workItem
        }
        queue.asyncAfter(deadline: deadline, execute: workItem)
        return workItem
    }

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
