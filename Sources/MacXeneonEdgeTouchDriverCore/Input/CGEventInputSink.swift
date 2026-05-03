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

    public func postMouseDown(at point: CGPoint) {
        postMouseEvent(type: .leftMouseDown, at: point)
    }

    public func postMouseUp(at point: CGPoint) {
        postMouseEvent(type: .leftMouseUp, at: point)
    }

    public func postMouseDragged(to point: CGPoint) {
        postMouseEvent(type: .leftMouseDragged, at: point)
    }

    private func postMouseEvent(type: CGEventType, at point: CGPoint) {
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
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: eventTap)
    }
}
