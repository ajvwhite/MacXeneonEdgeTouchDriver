import CoreGraphics
import Foundation

// These internal seams permit deterministic tests without creating or posting CGEvents.
protocol MouseInputEvent: AnyObject {
    var type: CGEventType { get set }
    var location: CGPoint { get set }
    var timestamp: CGEventTimestamp { get set }
    var flags: CGEventFlags { get set }
    func getIntegerValueField(_ field: CGEventField) -> Int64
    func setIntegerValueField(_ field: CGEventField, value: Int64)
}

extension CGEvent: MouseInputEvent {}

struct MouseInputEnvironment {
    let makeEvent: (CGEventType, CGPoint) -> MouseInputEvent?
    let post: (MouseInputEvent, CGEventTapLocation) -> Void
    // Nanoseconds since startup, as required by CGEventTimestamp; not raw mach ticks.
    let timestamp: () -> CGEventTimestamp
    // The actual source table ID, including a private source's unique ID.
    let sourceStateID: Int64?
    let flags: () -> CGEventFlags
}

/// Posts synthetic left-button events. GestureController exclusively uses the
/// managed reporting API; that API reserves one release before posting a down.
/// The original Void API retains single-event behavior, without reserve guarantees.
/// Do not mix raw and managed calls within a press. Requires serial use.
public final class CGEventInputSink: ReportingSyntheticInputSink {
    private let environment: MouseInputEnvironment
    private let eventTap: CGEventTapLocation
    private var operationInFlight = false
    private var press: Press?

    private struct Press {
        // Strongly retained, distinct, and never posted before the one release attempt.
        let emergencyUp: MouseInputEvent
        let eventNumber: Int64
    }

    /// The normal default remains a private source. Managed/reporting calls fail
    /// closed for nil because the fallback source table cannot be safely inferred.
    /// The legacy Void methods still pass nil through to the CGEvent constructor.
    public convenience init(
        eventSource: CGEventSource? = CGEventSource(stateID: .privateState),
        eventTap: CGEventTapLocation = .cghidEventTap
    ) {
        self.init(
            environment: MouseInputEnvironment(
                makeEvent: { type, point in
                    CGEvent(mouseEventSource: eventSource, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)
                },
                post: { event, tap in
                    // The production factory above only creates CGEvent instances.
                    // CoreFoundation casts cannot conditionally test this type.
                    let event = event as! CGEvent
                    event.post(tap: tap)
                },
                timestamp: { DispatchTime.now().uptimeNanoseconds },
                sourceStateID: eventSource.map { Int64($0.sourceStateID.rawValue) },
                flags: {
                    // The factory and this closure strongly retain the same source.
                    guard let eventSource else { return [] }
                    return CGEventSource.flagsState(eventSource.sourceStateID)
                }
            ),
            eventTap: eventTap
        )
    }

    init(environment: MouseInputEnvironment, eventTap: CGEventTapLocation = .cghidEventTap) {
        self.environment = environment
        self.eventTap = eventTap
    }

    // Preserve legacy raw behavior, including nil source, unpaired up/drag and
    // repeated down calls. These methods cannot report or recover construction
    // failure. Never mix them with managed calls on the same in-flight press.
    public func postMouseDown(at point: CGPoint) { postLegacyEvent(type: .leftMouseDown, at: point) }
    public func postMouseUp(at point: CGPoint) { postLegacyEvent(type: .leftMouseUp, at: point) }
    public func postMouseDragged(to point: CGPoint) { postLegacyEvent(type: .leftMouseDragged, at: point) }

    public func tryPostMouseDown(at point: CGPoint) -> SyntheticInputResult {
        guard !operationInFlight, press == nil else { return .busy }
        operationInFlight = true
        defer { operationInFlight = false }
        guard let sourceStateID = environment.sourceStateID else {
            DriverLoggers.log(.error, category: .gesture, "No explicit CoreGraphics event source; dropping mouse down.")
            return .sourceUnavailable
        }
        // Reserve first, then construct the ordinary down. Neither is posted if a
        // prerequisite fails. No further failable event construction or copy is
        // needed by the fallback; setters and posting may still allocate internally.
        guard let emergencyUp = makeEvent(type: .leftMouseUp, at: point),
              let down = makeEvent(type: .leftMouseDown, at: point) else {
            return .constructionFailed
        }
        guard emergencyUp !== down,
              emergencyUp.getIntegerValueField(.eventSourceStateID) == sourceStateID,
              down.getIntegerValueField(.eventSourceStateID) == sourceStateID else {
            DriverLoggers.log(.error, category: .gesture, "Mouse event reserve does not match the explicit source.")
            return .sourceUnavailable
        }
        configureButton(down, click: true)
        press = Press(emergencyUp: emergencyUp,
                      eventNumber: down.getIntegerValueField(.mouseEventNumber))
        environment.post(down, eventTap)
        return .postInvoked
    }

    public func tryPostMouseUp(at point: CGPoint) -> SyntheticInputResult {
        guard !operationInFlight else { return .busy }
        guard let ownedPress = press else { return .noPendingMouseDown }
        operationInFlight = true
        // Consume before calling any injected/external operation. Reentry cannot
        // consume again, nor begin a newer press before this release has returned.
        press = nil
        defer { operationInFlight = false }
        let event: MouseInputEvent
        if let freshUp = makeEvent(type: .leftMouseUp, at: point) {
            event = freshUp
        } else {
            event = ownedPress.emergencyUp
            event.type = .leftMouseUp
            event.location = point
            event.timestamp = environment.timestamp()
            event.flags = environment.flags()
            event.setIntegerValueField(.mouseEventNumber, value: ownedPress.eventNumber)
        }
        configureButton(event, click: true)
        environment.post(event, eventTap)
        return .postInvoked
    }

    public func tryPostMouseDragged(to point: CGPoint) -> SyntheticInputResult {
        guard !operationInFlight else { return .busy }
        guard press != nil else { return .noPendingMouseDown }
        operationInFlight = true
        defer { operationInFlight = false }
        guard let event = makeEvent(type: .leftMouseDragged, at: point) else {
            return .constructionFailed
        }
        configureButton(event, click: false)
        environment.post(event, eventTap)
        return .postInvoked
    }

    private func postLegacyEvent(type: CGEventType, at point: CGPoint) {
        guard !operationInFlight, press == nil else {
            DriverLoggers.log(.error, category: .gesture, "Cannot mix raw mouse events with an active managed press.")
            return
        }
        operationInFlight = true
        defer { operationInFlight = false }
        guard let event = makeEvent(type: type, at: point) else { return }
        configureButton(event, click: type == .leftMouseDown || type == .leftMouseUp)
        environment.post(event, eventTap)
    }

    private func makeEvent(type: CGEventType, at point: CGPoint) -> MouseInputEvent? {
        guard let event = environment.makeEvent(type, point) else {
            DriverLoggers.log(.error, category: .gesture, "Failed to create CoreGraphics mouse event of type \(type.rawValue).")
            return nil
        }
        return event
    }

    private func configureButton(_ event: MouseInputEvent, click: Bool) {
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.left.rawValue))
        if click { event.setIntegerValueField(.mouseEventClickState, value: 1) }
    }
}
