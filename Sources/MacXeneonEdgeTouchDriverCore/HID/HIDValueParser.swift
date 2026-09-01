import Foundation

/// Parses the Xeneon Edge's observed single-touch input report format.
public final class HIDValueParser {
    private var isTouching = false

    /// Creates a parser with no active touch state.
    public init() {}

    /// Resets parser state, treating the next report as a fresh stream.
    public func reset() {
        isTouching = false
    }

    /// Parses one raw HID input report into zero or one normalized touch events.
    public func parseReport(reportID: Int, bytes: [UInt8], timestamp: DispatchTime = .now()) -> TouchEvent? {
        guard reportID == XeneonEdgeDevice.touchReportID else {
            return nil
        }

        guard bytes.count >= XeneonEdgeDevice.touchReportLength else {
            return nil
        }

        let isDown = bytes[1] != 0
        let rawX = Int(bytes[2]) | (Int(bytes[3]) << 8)
        let rawY = Int(bytes[4]) | (Int(bytes[5]) << 8)

        let event: TouchEvent?
        switch (isTouching, isDown) {
        case (false, true):
            event = TouchEvent(kind: .down, contactID: 0, rawX: rawX, rawY: rawY, timestamp: timestamp)

        case (true, true):
            // Preserve stationary samples for storm-mode confidence tracking. The
            // validator removes redundant movement before gesture synthesis.
            event = TouchEvent(kind: .move, contactID: 0, rawX: rawX, rawY: rawY, timestamp: timestamp)

        case (true, false):
            event = TouchEvent(kind: .up, contactID: 0, rawX: rawX, rawY: rawY, timestamp: timestamp)

        case (false, false):
            event = nil
        }

        isTouching = isDown
        return event
    }
}
