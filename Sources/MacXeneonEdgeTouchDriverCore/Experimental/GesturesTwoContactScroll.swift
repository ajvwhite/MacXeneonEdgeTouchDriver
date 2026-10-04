import Foundation

public struct ExperimentalScrollContact: Equatable, Sendable {
    public let token: ExperimentalContactToken
    public let point: ExperimentalGesturePoint

    public init(token: ExperimentalContactToken, point: ExperimentalGesturePoint) {
        self.token = token
        self.point = point
    }
}

/// A decoder must prove completeness and authoritative source identity before
/// constructing production frames. This type alone establishes neither fact.
public struct ExperimentalContactFrame: Equatable, Sendable {
    public let context: ExperimentalInteractionContext
    public let sequence: UInt64
    public let timestamp: UInt64
    public let isComplete: Bool
    public let contacts: [ExperimentalScrollContact]

    public init(context: ExperimentalInteractionContext, sequence: UInt64, timestamp: UInt64,
                isComplete: Bool, contacts: [ExperimentalScrollContact]) {
        self.context = context
        self.sequence = sequence
        self.timestamp = timestamp
        self.isComplete = isComplete
        self.contacts = contacts
    }
}

public enum ExperimentalScrollOwnership: Equatable, Sendable {
    case unowned
    case mousePress
    case scroll(ExperimentalOwnerLeaseID)
    case cleanup(ExperimentalOwnerLeaseID)
}

public enum ExperimentalScrollAction: Equatable, Sendable {
    /// A mode-admission decision only; this model does not forward mouse input.
    case singleContactOnly
    case requestOwnership(UInt64)
    case began(ExperimentalOwnerLeaseID, anchor: ExperimentalGesturePoint)
    /// Unrounded mapped-point deltas; no CG pixel conversion or momentum implied.
    case changed(ExperimentalOwnerLeaseID, deltaX: Double, deltaY: Double)
    case ended(ExperimentalOwnerLeaseID)
    case cancelled(ExperimentalOwnerLeaseID)
}

/// Pure arbitration with no HID decoding, cursor movement, CGEvents or timers.
/// Two contacts must be present in the first complete nonempty frame. A late
/// second finger can never turn an already admitted mouse press into scrolling.
public struct ExperimentalTwoContactScrollReducer {
    private struct Tracking {
        let context: ExperimentalInteractionContext
        let first: ExperimentalContactToken
        let second: ExperimentalContactToken
        var centroid: ExperimentalGesturePoint
    }

    private enum State {
        case idle
        case awaitingOwnership(request: UInt64, tracking: Tracking)
        case scrolling(ExperimentalOwnerLeaseID, Tracking)
        case finishing(ExperimentalOwnerLeaseID, allLifted: Bool, terminalPosted: Bool?)
        case suppressed
    }

    private var state: State = .idle
    private var nextRequest: UInt64 = 0
    private var highestRequestedContactSequence: UInt64 = 0
    private var previousFrame: ExperimentalContactFrame?
    private var source: ExperimentalSourceEpoch?
    private var lastLeaseID: ExperimentalOwnerLeaseID?
    public let scale: Double

    public init(scale: Double) throws {
        guard scale.isFinite, scale > 0 else { throw ExperimentalGesturePolicyError.invalidScrollScale }
        self.scale = scale
    }

    public mutating func consume(_ frame: ExperimentalContactFrame,
                                 ownership: ExperimentalScrollOwnership) -> [ExperimentalScrollAction] {
        // One reducer belongs to one registration epoch. Reconnection creates a
        // fresh reducer; another source cannot acknowledge this source's lifts.
        if let source, source != frame.context.source { return invalidate(allLifted: false) }
        guard valid(frame) else { return invalidate(allLifted: false) }
        source = frame.context.source
        if let previousFrame, previousFrame.context.source == frame.context.source,
           (frame.sequence <= previousFrame.sequence || frame.timestamp < previousFrame.timestamp) {
            return invalidate(allLifted: false)
        }
        previousFrame = frame

        switch state {
        case .idle:
            guard !frame.contacts.isEmpty else { return [] }
            guard ownership == .unowned else {
                state = .suppressed
                return []
            }
            guard frame.contacts.count == 2 else {
                state = .suppressed
                return frame.contacts.count == 1 ? [.singleContactOnly] : []
            }
            guard frame.contacts.allSatisfy({ $0.token.contactSequence > highestRequestedContactSequence }) else {
                state = .suppressed
                return []
            }
            // Saturation is a fail-closed terminal capability limit, not wrapping
            // an old asynchronous ownership request back into validity.
            guard nextRequest < UInt64.max else { state = .suppressed; return [] }
            nextRequest += 1
            highestRequestedContactSequence = max(frame.contacts[0].token.contactSequence,
                                                   frame.contacts[1].token.contactSequence)
            let tracking = makeTracking(frame)
            state = .awaitingOwnership(request: nextRequest, tracking: tracking)
            return [.requestOwnership(nextRequest)]

        case .awaitingOwnership(let request, var tracking):
            guard ownership == .unowned, samePair(frame, tracking), frame.context == tracking.context else {
                return invalidate(allLifted: frame.contacts.isEmpty)
            }
            tracking.centroid = centroid(frame)
            state = .awaitingOwnership(request: request, tracking: tracking)
            return []

        case .scrolling(let leaseID, var tracking):
            guard ownership == .scroll(leaseID), frame.context == tracking.context else {
                return invalidate(allLifted: frame.contacts.isEmpty)
            }
            // A remaining contact must belong to the original pair. Replacing a
            // finger during a lift is cancellation, not a successful termination.
            if frame.contacts.count < 2,
               frame.contacts.allSatisfy({ $0.token == tracking.first || $0.token == tracking.second }) {
                state = .finishing(leaseID, allLifted: frame.contacts.isEmpty, terminalPosted: nil)
                return [.ended(leaseID)]
            }
            guard samePair(frame, tracking) else { return invalidate(allLifted: false) }
            let next = centroid(frame)
            let dx = (next.x - tracking.centroid.x) * scale
            let dy = (next.y - tracking.centroid.y) * scale
            guard dx.isFinite, dy.isFinite else { return invalidate(allLifted: false) }
            tracking.centroid = next
            state = .scrolling(leaseID, tracking)
            return dx == 0 && dy == 0 ? [] : [.changed(leaseID, deltaX: dx, deltaY: dy)]

        case .finishing(let leaseID, _, let terminalPosted):
            state = .finishing(leaseID, allLifted: frame.contacts.isEmpty, terminalPosted: terminalPosted)
            return []

        case .suppressed:
            if frame.contacts.isEmpty { state = .idle }
            return []
        }
    }

    /// Ownership is granted explicitly by the shared global arbiter. Caller must
    /// reserve a terminal event before posting began; this pure model cannot do so.
    public mutating func grantOwnership(request: UInt64, lease: ExperimentalOwnerLease,
                                        ownership: ExperimentalScrollOwnership,
                                        context: ExperimentalInteractionContext) -> [ExperimentalScrollAction] {
        guard case .awaitingOwnership(let current, let tracking) = state, current == request else { return [] }
        guard ownership == .scroll(lease.id), context == tracking.context,
              lease.route == tracking.context.route,
              lease.contact == tracking.first || lease.contact == tracking.second,
              isNewLease(lease.id) else {
            state = .suppressed
            return []
        }
        lastLeaseID = lease.id
        state = .scrolling(lease.id, tracking)
        return [.began(lease.id, anchor: tracking.centroid)]
    }

    /// At most one terminal action. Stale cancellation cannot target a newer lease.
    public mutating func cancel(leaseID: ExperimentalOwnerLeaseID) -> [ExperimentalScrollAction] {
        guard case .scrolling(let current, _) = state, current == leaseID else { return [] }
        return invalidate(allLifted: false)
    }

    public mutating func cancelPending(request: UInt64) {
        guard case .awaitingOwnership(let current, _) = state, current == request else { return }
        state = .suppressed
    }

    /// A failed terminal result cannot be repaired by pretending cleanup ran.
    /// The dispatcher must retain unresolved ownership, just as for mouse up.
    public mutating func recordTerminalResult(leaseID: ExperimentalOwnerLeaseID, postInvoked: Bool) {
        guard case .finishing(let current, let allLifted, nil) = state, current == leaseID else { return }
        state = .finishing(current, allLifted: allLifted, terminalPosted: postInvoked)
    }

    @discardableResult
    public mutating func completeCleanup(leaseID: ExperimentalOwnerLeaseID) -> Bool {
        guard case .finishing(let current, let allLifted, true?) = state, current == leaseID else { return false }
        state = allLifted ? .idle : .suppressed
        return true
    }

    private mutating func invalidate(allLifted: Bool) -> [ExperimentalScrollAction] {
        if case .scrolling(let leaseID, _) = state {
            state = .finishing(leaseID, allLifted: allLifted, terminalPosted: nil)
            return [.cancelled(leaseID)]
        }
        if case .finishing(let leaseID, _, let terminalPosted) = state {
            state = .finishing(leaseID, allLifted: false, terminalPosted: terminalPosted)
            return []
        }
        state = allLifted ? .idle : .suppressed
        return []
    }

    private func valid(_ frame: ExperimentalContactFrame) -> Bool {
        guard frame.isComplete else { return false }
        // Bound work without accepting a truncated large frame as two contacts.
        guard frame.contacts.count <= 3 else { return false }
        var ids = Set<Int>()
        var sequences = Set<UInt64>()
        for contact in frame.contacts {
            guard contact.token.source == frame.context.source, contact.point.isFinite,
                  ids.insert(contact.token.rawContactID).inserted,
                  sequences.insert(contact.token.contactSequence).inserted else { return false }
        }
        return true
    }

    private func samePair(_ frame: ExperimentalContactFrame, _ tracking: Tracking) -> Bool {
        frame.contacts.count == 2 && frame.contacts.contains(where: { $0.token == tracking.first }) &&
            frame.contacts.contains(where: { $0.token == tracking.second })
    }

    private func makeTracking(_ frame: ExperimentalContactFrame) -> Tracking {
        Tracking(context: frame.context, first: frame.contacts[0].token,
                 second: frame.contacts[1].token, centroid: centroid(frame))
    }

    private func centroid(_ frame: ExperimentalContactFrame) -> ExperimentalGesturePoint {
        // Halve before summing so finite same-sign coordinates cannot overflow.
        ExperimentalGesturePoint(x: frame.contacts[0].point.x / 2 + frame.contacts[1].point.x / 2,
                                 y: frame.contacts[0].point.y / 2 + frame.contacts[1].point.y / 2)
    }

    private func isNewLease(_ id: ExperimentalOwnerLeaseID) -> Bool {
        guard let lastLeaseID else { return true }
        return id.sessionID == lastLeaseID.sessionID && id.generation > lastLeaseID.generation
    }
}
