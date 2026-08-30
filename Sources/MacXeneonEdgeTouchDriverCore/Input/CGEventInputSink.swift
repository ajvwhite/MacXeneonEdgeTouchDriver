import CoreGraphics
import Foundation

/// Posts synthetic left-button mouse events through CoreGraphics.
public final class CGEventInputSink: SyntheticInputSink {
    private let eventSource: CGEventSource?
    private let eventTap: CGEventTapLocation

    /// Creates a CoreGraphics input sink.
    public init(
        eventSource: CGEventSource? = CGEventSource(stateID: .privateState),
        eventTap: CGEventTapLocation = .cghidEventTap
    ) {
        self.eventSource = eventSource
        self.eventTap = eventTap
    }

    public func postMouseDown(at point: CGPoint, clickCount: Int) {
        postMouseEvent(type: .leftMouseDown, at: point, clickCount: clickCount)
    }

    public func postMouseUp(at point: CGPoint, clickCount: Int) {
        postMouseEvent(type: .leftMouseUp, at: point, clickCount: clickCount)
    }

    public func postMouseDragged(to point: CGPoint) {
        postMouseEvent(type: .leftMouseDragged, at: point)
    }

    public func postScroll(deltaX: CGFloat, deltaY: CGFloat, phase: SyntheticScrollPhase) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY.rounded()),
            wheel2: Int32(deltaX.rounded()),
            wheel3: 0
        ) else {
            DriverLoggers.log(.error, category: .gesture, "Failed to create CoreGraphics pixel-scroll event.")
            return
        }

        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: eventTap)
    }

    private func postMouseEvent(type: CGEventType, at point: CGPoint, clickCount: Int = 1) {
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            DriverLoggers.log(.error, category: .gesture, "Failed to create CoreGraphics mouse event of type \(type.rawValue).")
            return
        }

        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.left.rawValue))
        if type == .leftMouseDown || type == .leftMouseUp {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        }
        event.post(tap: eventTap)
    }
}
