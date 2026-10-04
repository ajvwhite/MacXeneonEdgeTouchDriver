import Foundation

public enum ExperimentalContactPhase: Equatable, Sendable {
    case down, move, up
}

public enum ExperimentalRoutingReason: String, Equatable, Sendable {
    case stopped, staleSource, sourceNotRegistered, sourceCapacityExceeded
    case awaitingNeutral, noBinding, ownerBusy, quarantined, staleContact
    case overlappingContact, sourceRetired, routeChanged, topologyInvalidated
    case neutralWithoutRelease, explicitCancellation, staleCompletion, leaseExhausted
}

/// Decisions carry no side effects. A future adapter must acknowledge finish
/// only after its existing cursor/button/focus cleanup contract has completed.
public enum ExperimentalRoutingDecision: Equatable, Sendable {
    case admitted(ExperimentalOwnerLease)
    case forwarded(ExperimentalOwnerLease, ExperimentalContactPhase)
    case cancel(ExperimentalOwnerLease, ExperimentalRoutingReason)
    case released(ExperimentalOwnerLeaseID)
    case dropped(ExperimentalRoutingReason)
}

/// Single-contact-per-source, global-owner reducer. Source registration is an
/// explicit ordered operation: contact reports can never resurrect a source.
/// Valid neutral samples come from a reviewed decoder, never report silence or
/// a nil lifecycle event. This model opens no device and emits no OS input.
/// All mutation has one serial owner. A live adapter must order route changes,
/// reports, and neutral frames, rejecting queued observations from older route
/// authority before invoking this reducer. Copies are snapshots, not independent
/// live owners; create a new arbiter to obtain a fresh ownership incarnation.
public struct ExperimentalOwnerArbiter: Sendable {
    public enum OwnerPhase: Equatable, Sendable { case tracking, finishing, cancelling }

    private struct SourceState: Sendable {
        var route: ExperimentalRouteToken?
        var armed = false
        var activeContact: ExperimentalContactToken?
        var lastContactSequence: UInt64 = 0
        var quarantined = false
        // Once overlapping lifecycles make stream state inconsistent, an up
        // for only the newest token cannot prove that every contact has ended.
        var requiresExplicitNeutral = false
    }

    public let sessionID: UUID
    public private(set) var owner: ExperimentalOwnerLease?
    public private(set) var ownerPhase: OwnerPhase?
    public private(set) var isStopped = false
    public var registeredSourceCount: Int { sources.count }
    public var quarantinedSourceCount: Int { sources.values.filter(\.quarantined).count }

    private let maximumSources: Int
    private let ownerIncarnationID: UUID
    private var sources: [ExperimentalSourceEpoch: SourceState] = [:]
    private var highestRegistrationGeneration: UInt64 = 0
    private var lastLeaseGeneration: UInt64 = 0

    public init(sessionID: UUID, maximumSources: Int = 64) {
        self.init(sessionID: sessionID, maximumSources: maximumSources,
                  lastLeaseGeneration: 0, ownerIncarnationID: UUID())
    }

    // Deterministic test seam. Public construction always creates a fresh owner
    // incarnation, even when a source/monitor session UUID is deliberately reused.
    init(sessionID: UUID, maximumSources: Int = 64, lastLeaseGeneration: UInt64, ownerIncarnationID: UUID = UUID()) {
        self.sessionID = sessionID
        self.maximumSources = max(0, maximumSources)
        self.ownerIncarnationID = ownerIncarnationID
        self.lastLeaseGeneration = lastLeaseGeneration
    }

    /// Registration generations must increase in actual registration order.
    /// Register every source before installing routes, including unbound sources.
    public mutating func register(_ source: ExperimentalSourceEpoch) -> [ExperimentalRoutingDecision] {
        guard !isStopped else { return [.dropped(.stopped)] }
        guard source.sessionID == sessionID else { return [.dropped(.staleSource)] }
        if sources[source] != nil { return [] }
        guard source.registrationGeneration > highestRegistrationGeneration else {
            return [.dropped(.staleSource)]
        }
        guard sources.count < maximumSources else { return [.dropped(.sourceCapacityExceeded)] }
        highestRegistrationGeneration = source.registrationGeneration
        sources[source] = SourceState()
        return []
    }

    /// Binding changes disarm the source until a fresh neutral boundary. They
    /// cannot remap a contact already in progress or release the owner early.
    public mutating func installRoute(_ route: ExperimentalRouteToken?, for source: ExperimentalSourceEpoch) -> [ExperimentalRoutingDecision] {
        guard !isStopped else { return [.dropped(.stopped)] }
        guard var state = sources[source] else { return [.dropped(.sourceNotRegistered)] }
        guard state.route != route else { return [] }
        state.route = route
        state.armed = false
        state.quarantined = state.activeContact != nil
        sources[source] = state
        return owner?.contact.source == source ? cancelOwner(reason: .routeChanged) : []
    }

    /// Observe a decoder-verified all-up frame, including an idle report that
    /// emitted no TouchEvent. A missing lifecycle up cancels rather than clicks.
    /// The frame must have current source/route ingress authority and be observed
    /// after the latest route installation or invalidation, not replayed from an
    /// older queue backlog. Only this operation clears overlap inconsistency.
    public mutating func observeNeutral(from source: ExperimentalSourceEpoch) -> [ExperimentalRoutingDecision] {
        guard !isStopped else { return [.dropped(.stopped)] }
        guard var state = sources[source] else { return [.dropped(.sourceNotRegistered)] }
        state.activeContact = nil
        state.quarantined = false
        state.armed = true
        state.requiresExplicitNeutral = false
        sources[source] = state
        if owner?.contact.source == source, ownerPhase == .tracking {
            return cancelOwner(reason: .neutralWithoutRelease)
        }
        return []
    }

    public mutating func receive(_ contact: ExperimentalContactToken, phase: ExperimentalContactPhase) -> [ExperimentalRoutingDecision] {
        guard !isStopped else { return [.dropped(.stopped)] }
        guard var state = sources[contact.source] else { return [.dropped(.sourceNotRegistered)] }

        switch phase {
        case .down:
            guard contact.contactSequence > state.lastContactSequence else { return [.dropped(.staleContact)] }
            state.lastContactSequence = contact.contactSequence
            let overlaps = state.activeContact != nil
            state.activeContact = contact
            if overlaps {
                state.quarantined = true
                state.armed = false
                state.requiresExplicitNeutral = true
                sources[contact.source] = state
                let cancellation = owner?.contact.source == contact.source ? cancelOwner(reason: .overlappingContact) : []
                return cancellation + [.dropped(.overlappingContact)]
            }
            let rejection: ExperimentalRoutingReason?
            if !state.armed || state.requiresExplicitNeutral { rejection = .awaitingNeutral }
            else if state.route == nil { rejection = .noBinding }
            else if owner != nil { rejection = .ownerBusy }
            else if lastLeaseGeneration == UInt64.max { rejection = .leaseExhausted }
            else { rejection = nil }
            if let rejection {
                state.quarantined = true
                sources[contact.source] = state
                return [.dropped(rejection)]
            }
            // Route existence was proved above, before any lease is allocated.
            guard let route = state.route else { return [.dropped(.noBinding)] }
            lastLeaseGeneration += 1
            let lease = ExperimentalOwnerLease(
                id: ExperimentalOwnerLeaseID(sessionID: ownerIncarnationID, generation: lastLeaseGeneration),
                contact: contact,
                route: route
            )
            state.quarantined = false
            sources[contact.source] = state
            owner = lease
            ownerPhase = .tracking
            return [.admitted(lease)]

        case .move, .up:
            guard state.activeContact == contact else { return [.dropped(.staleContact)] }
            let wasQuarantined = state.quarantined
            if phase == .up {
                state.activeContact = nil
                state.quarantined = false
                state.armed = !state.requiresExplicitNeutral
                sources[contact.source] = state
            }
            guard !wasQuarantined else { return [.dropped(.quarantined)] }
            guard let lease = owner, lease.contact == contact, ownerPhase == .tracking else {
                return [.dropped(.staleContact)]
            }
            if phase == .up { ownerPhase = .finishing }
            return [.forwarded(lease, phase)]
        }
    }

    /// Terminal ownership acknowledgment, including admission failure before any
    /// mouse down. A still-held contact remains rejected until its own up/neutral.
    public mutating func finish(_ id: ExperimentalOwnerLeaseID) -> [ExperimentalRoutingDecision] {
        guard let lease = owner, lease.id == id else { return [.dropped(.staleCompletion)] }
        if var state = sources[lease.contact.source], state.activeContact == lease.contact {
            state.quarantined = true
            state.armed = false
            sources[lease.contact.source] = state
        }
        owner = nil
        ownerPhase = nil
        return [.released(id)]
    }

    /// Retirement invalidates queued old-epoch reports and only cancels that
    /// source's owner. A sibling/non-owner removal cannot cancel another route.
    public mutating func retire(_ source: ExperimentalSourceEpoch) -> [ExperimentalRoutingDecision] {
        guard sources.removeValue(forKey: source) != nil else { return [.dropped(.sourceNotRegistered)] }
        return owner?.contact.source == source ? cancelOwner(reason: .sourceRetired) : []
    }

    /// All route leases become unusable at the beginning of display change.
    /// Installation of a validated new snapshot is a separate explicit step.
    public mutating func invalidateTopology() -> [ExperimentalRoutingDecision] {
        for source in Array(sources.keys) {
            guard var state = sources[source] else { continue }
            state.route = nil
            state.armed = false
            state.quarantined = state.activeContact != nil
            sources[source] = state
        }
        return cancelOwner(reason: .topologyInvalidated)
    }

    public mutating func cancel() -> [ExperimentalRoutingDecision] {
        if let source = owner?.contact.source, var state = sources[source] {
            state.quarantined = state.activeContact != nil
            state.armed = false
            sources[source] = state
        }
        return cancelOwner(reason: .explicitCancellation)
    }

    public mutating func stop() -> [ExperimentalRoutingDecision] {
        isStopped = true
        sources.removeAll()
        return cancelOwner(reason: .stopped)
    }

    private mutating func cancelOwner(reason: ExperimentalRoutingReason) -> [ExperimentalRoutingDecision] {
        guard let lease = owner, ownerPhase != .cancelling else { return [] }
        ownerPhase = .cancelling
        return [.cancel(lease, reason)]
    }
}
