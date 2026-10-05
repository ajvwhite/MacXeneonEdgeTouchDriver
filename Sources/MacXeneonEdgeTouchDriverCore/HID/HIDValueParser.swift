import Foundation

/// Parses the Xeneon Edge's observed single-touch input report format.
public final class HIDValueParser {
    private var isTouching = false
    private var contactEpoch: UInt64 = 0
    private var lastRawX: Int?
    private var lastRawY: Int?

    /// Creates a parser with no active touch state.
    public init() {}

    /// Resets normalization, treating the next report as a fresh stream.
    /// Contact epochs remain monotonic for the lifetime of this parser.
    public func reset() {
        isTouching = false
        lastRawX = nil
        lastRawY = nil
    }

    /// Parses one raw HID input report into zero or one normalized touch events.
    public func parseReport(reportID: Int, bytes: [UInt8], timestamp: DispatchTime = .now()) -> TouchEvent? {
        parseValidatedReport(reportID: reportID, bytes: bytes, timestamp: timestamp)?.event
    }

    /// Production registrations call this path once per validated callback.
    func parseObservation(
        sourceID: HIDSourceID,
        reportID: Int,
        bytes: [UInt8],
        timestamp: DispatchTime = .now()
    ) -> HIDTouchObservation? {
        guard let parsed = parseValidatedReport(reportID: reportID, bytes: bytes, timestamp: timestamp) else {
            return nil
        }
        return HIDTouchObservation(
            sourceID: sourceID, contactEpoch: parsed.contactEpoch,
            isPressed: parsed.isPressed, timestamp: timestamp, event: parsed.event,
            rawX: Int(bytes[2]) | (Int(bytes[3]) << 8),
            rawY: Int(bytes[4]) | (Int(bytes[5]) << 8)
        )
    }

    private struct ParsedReport {
        let contactEpoch: UInt64
        let isPressed: Bool
        let event: TouchEvent?
    }

    private func parseValidatedReport(reportID: Int, bytes: [UInt8], timestamp: DispatchTime) -> ParsedReport? {
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
            precondition(contactEpoch < UInt64.max, "HID contact epochs exhausted.")
            contactEpoch += 1
            event = TouchEvent(kind: .down, contactID: 0, rawX: rawX, rawY: rawY, timestamp: timestamp)

        case (true, true):
            if rawX != lastRawX || rawY != lastRawY {
                event = TouchEvent(kind: .move, contactID: 0, rawX: rawX, rawY: rawY, timestamp: timestamp)
            } else {
                event = nil
            }

        case (true, false):
            event = TouchEvent(kind: .up, contactID: 0, rawX: rawX, rawY: rawY, timestamp: timestamp)

        case (false, false):
            event = nil
        }

        isTouching = isDown
        lastRawX = rawX
        lastRawY = rawY
        return ParsedReport(contactEpoch: contactEpoch, isPressed: isDown, event: event)
    }
}
