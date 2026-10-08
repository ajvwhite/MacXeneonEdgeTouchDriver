import IOKit

/// Opens one manager attempt, including cleanup of a partially opened manager.
enum HIDManagerOpenAttempt {
    static func perform(open: () -> IOReturn, close: () -> IOReturn) -> IOReturn {
        let result = open()
        if result != kIOReturnSuccess {
            // IOHIDManager marks itself open before opening its devices. Even a
            // denied attempt must be closed, or the next open can return success
            // without opening the devices or acquiring exclusive touch input.
            _ = close()
        }
        return result
    }
}
