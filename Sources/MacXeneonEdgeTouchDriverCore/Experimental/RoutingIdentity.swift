import Foundation

/// Identity of one callback registration, never a claim about a physical panel.
/// A new registration must receive a new generation, even if device addresses,
/// registry IDs, or USB ports are reused. These runtime tokens are not persisted.
public struct ExperimentalSourceEpoch: Hashable, Sendable {
    public let sessionID: UUID
    public let registrationGeneration: UInt64

    public init(sessionID: UUID, registrationGeneration: UInt64) {
        self.sessionID = sessionID
        self.registrationGeneration = registrationGeneration
    }
}

/// Namespaces the hardware contact ID by source and physical contact lifecycle.
/// The adapter supplies a strictly increasing sequence for each source epoch.
public struct ExperimentalContactToken: Hashable, Sendable {
    public let source: ExperimentalSourceEpoch
    public let contactSequence: UInt64
    public let rawContactID: Int

    public init(source: ExperimentalSourceEpoch, contactSequence: UInt64, rawContactID: Int = 0) {
        self.source = source
        self.contactSequence = contactSequence
        self.rawContactID = rawContactID
    }
}

/// A resolved route lease, not a persistent display identity. Topology revision
/// must advance for bounds, scale, rotation, membership, or identity changes.
public struct ExperimentalRouteToken: Hashable, Sendable {
    public let bindingID: String
    public let bindingRevision: UInt64
    public let topologyRevision: UInt64
    public let displayID: UInt32

    public init(bindingID: String, bindingRevision: UInt64, topologyRevision: UInt64, displayID: UInt32) {
        self.bindingID = bindingID
        self.bindingRevision = bindingRevision
        self.topologyRevision = topologyRevision
        self.displayID = displayID
    }
}

/// Explicit context for gesture recognizers. Equality is deliberately strict:
/// taps must not combine across a source, route, policy, or activation change.
public struct ExperimentalInteractionContext: Hashable, Sendable {
    public let source: ExperimentalSourceEpoch
    public let route: ExperimentalRouteToken
    public let targetContextRevision: UInt64
    public let policyRevision: UInt64
    public let activationRevision: UInt64

    public init(
        source: ExperimentalSourceEpoch,
        route: ExperimentalRouteToken,
        targetContextRevision: UInt64,
        policyRevision: UInt64 = 0,
        activationRevision: UInt64 = 0
    ) {
        self.source = source
        self.route = route
        self.targetContextRevision = targetContextRevision
        self.policyRevision = policyRevision
        self.activationRevision = activationRevision
    }
}

/// Completion authority is separate from a HID source/contact. A stale cleanup
/// acknowledgment cannot release a newer lease, including after reducer restart.
public struct ExperimentalOwnerLeaseID: Hashable, Sendable {
    /// Owner-arbiter incarnation, deliberately distinct from the source session.
    public let sessionID: UUID
    public let generation: UInt64

    public init(sessionID: UUID, generation: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
    }
}

public struct ExperimentalOwnerLease: Equatable, Sendable {
    public let id: ExperimentalOwnerLeaseID
    public let contact: ExperimentalContactToken
    public let route: ExperimentalRouteToken

    public init(id: ExperimentalOwnerLeaseID, contact: ExperimentalContactToken, route: ExperimentalRouteToken) {
        self.id = id
        self.contact = contact
        self.route = route
    }
}
