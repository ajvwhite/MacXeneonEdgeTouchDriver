import Foundation

/// A mapped screen point. Pure gesture models do not read screen or input state.
public struct ExperimentalGesturePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    var isFinite: Bool { x.isFinite && y.isFinite }

    func distance(to other: Self) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

public enum ExperimentalGesturePolicyError: Error, Equatable {
    case invalidInterval
    case invalidDistance
    case invalidScrollScale
}

/// Driver policy, not a reconstruction of all macOS double-click heuristics.
public struct ExperimentalDoubleClickPolicy: Equatable, Sendable {
    public let intervalNanoseconds: UInt64
    public let maximumDistance: Double

    public init(intervalNanoseconds: UInt64, maximumDistance: Double) throws {
        guard intervalNanoseconds > 0 else { throw ExperimentalGesturePolicyError.invalidInterval }
        guard maximumDistance.isFinite, maximumDistance >= 0 else {
            throw ExperimentalGesturePolicyError.invalidDistance
        }
        self.intervalNanoseconds = intervalNanoseconds
        self.maximumDistance = maximumDistance
    }
}

public enum ExperimentalClickDecision: Equatable, Sendable {
    case rejected
    case clickCount(Int)
}

/// Pure, source-scoped spatial/time experiment. No event construction or posting.
/// Equal revision snapshots do NOT certify an unchanged recipient or absence of
/// unrelated physical input. Live target-aware dispatch remains unavailable.
/// Every begun press retains its lease until explicit release and cleanup results.
public struct ExperimentalDoubleClickReducer {
    private struct Candidate {
        let ownerSessionID: UUID
        let contact: ExperimentalContactToken
        let context: ExperimentalInteractionContext
        let point: ExperimentalGesturePoint
        let receiptTime: UInt64
        let postTime: UInt64
        var releaseReceiptTime: UInt64?
        var releasePostTime: UInt64?
    }

    private struct Press {
        let lease: ExperimentalOwnerLease
        var candidate: Candidate
        let count: Int
        var downPosted: Bool?
        var moved = false
        var invalidated = false
        var releasePosted = false
        var releaseBlocked = false
        var qualifies = false
    }

    public let policy: ExperimentalDoubleClickPolicy
    private var candidate: Candidate?
    private var press: Press?
    private var lastLeaseID: ExperimentalOwnerLeaseID?

    public init(policy: ExperimentalDoubleClickPolicy) { self.policy = policy }

    public var activeLeaseID: ExperimentalOwnerLeaseID? { press?.lease.id }

    /// Call immediately before the proposed down, using caller-supplied monotonic
    /// receipt and pre-invocation time samples. The latter cannot establish when
    /// a future poster actually runs. A result must follow even on failure.
    public mutating func begin(
        lease: ExperimentalOwnerLease,
        context: ExperimentalInteractionContext,
        point: ExperimentalGesturePoint,
        receiptTime: UInt64,
        postTime: UInt64
    ) -> ExperimentalClickDecision {
        // Stale/repeated lease callbacks cannot invalidate newer owned work.
        guard isNewLease(lease.id) else { return .rejected }
        guard press == nil else {
            invalidateSequence()
            return .rejected
        }
        guard lease.contact.source == context.source, lease.route == context.route,
              point.isFinite, receiptTime <= postTime else {
            candidate = nil
            return .rejected
        }

        let next = Candidate(ownerSessionID: lease.id.sessionID, contact: lease.contact, context: context, point: point,
                             receiptTime: receiptTime, postTime: postTime)
        var count = 1
        if let previous = candidate,
           previous.ownerSessionID == lease.id.sessionID,
           previous.context == context,
           previous.contact.contactSequence < lease.contact.contactSequence,
           let releaseReceiptTime = previous.releaseReceiptTime,
           let releasePostTime = previous.releasePostTime,
           receiptTime >= releaseReceiptTime, postTime >= releasePostTime,
           withinInterval(receiptTime, since: previous.receiptTime),
           withinInterval(postTime, since: previous.postTime),
           previous.point.distance(to: point) <= policy.maximumDistance {
            count = 2
        }
        // Consume before any external caller can act. Third click starts at one.
        candidate = nil
        lastLeaseID = lease.id
        press = Press(lease: lease, candidate: next, count: count)
        return .clickCount(count)
    }

    /// `true` means poster invocation only, never delivery acknowledgment.
    public mutating func recordDownResult(leaseID: ExperimentalOwnerLeaseID, postInvoked: Bool) {
        guard var active = press, active.lease.id == leaseID, active.downPosted == nil else { return }
        active.downPosted = postInvoked
        if !postInvoked { active.invalidated = true }
        press = active
    }

    public mutating func recordMovement(leaseID: ExperimentalOwnerLeaseID) {
        guard var active = press, active.lease.id == leaseID else { return }
        active.moved = true
        active.qualifies = false
        press = active
        candidate = nil
    }

    /// Release metadata must retain the count chosen at begin, even after a move
    /// or cancellation. This model does not issue that release itself.
    public mutating func recordRelease(
        leaseID: ExperimentalOwnerLeaseID,
        context: ExperimentalInteractionContext,
        point: ExperimentalGesturePoint,
        receiptTime: UInt64,
        postTime: UInt64,
        postInvoked: Bool
    ) {
        guard var active = press, active.lease.id == leaseID,
              active.downPosted == true, !active.releasePosted, !active.releaseBlocked else { return }
        active.releasePosted = postInvoked
        active.releaseBlocked = !postInvoked
        active.candidate.releaseReceiptTime = receiptTime
        active.candidate.releasePostTime = postTime
        active.qualifies = postInvoked && active.count == 1 && !active.moved && !active.invalidated &&
            context == active.candidate.context && point.isFinite && receiptTime <= postTime &&
            withinInterval(receiptTime, since: active.candidate.receiptTime) &&
            withinInterval(postTime, since: active.candidate.postTime) &&
            active.candidate.point.distance(to: point) <= policy.maximumDistance
        press = active
    }

    /// Invalidations never forgive an owned release or pending cleanup.
    public mutating func invalidateSequence() {
        candidate = nil
        if var active = press {
            active.invalidated = true
            active.qualifies = false
            press = active
        }
    }

    /// A stale cancellation cannot invalidate a newer lease.
    public mutating func cancel(leaseID: ExperimentalOwnerLeaseID) {
        guard press?.lease.id == leaseID else { return }
        invalidateSequence()
    }

    /// Caller acknowledges the exact global owner has finished cursor/focus
    /// cleanup. Failed release retains ownership and cannot be hidden by cleanup.
    @discardableResult
    public mutating func completeCleanup(leaseID: ExperimentalOwnerLeaseID) -> Bool {
        guard let active = press, active.lease.id == leaseID, !active.releaseBlocked,
              active.downPosted == false || active.releasePosted else { return false }
        candidate = active.qualifies ? active.candidate : nil
        press = nil
        return true
    }

    private func withinInterval(_ time: UInt64, since earlier: UInt64) -> Bool {
        time >= earlier && time - earlier <= policy.intervalNanoseconds
    }

    private func isNewLease(_ id: ExperimentalOwnerLeaseID) -> Bool {
        guard let lastLeaseID else { return true }
        // A new owner session requires a new reducer. This prevents A -> B -> A
        // session re-entry without retaining an unbounded history of lease IDs.
        return id.sessionID == lastLeaseID.sessionID && id.generation > lastLeaseID.generation
    }
}
