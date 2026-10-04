import Foundation
import XCTest
@testable import MacXeneonEdgeTouchDriverCore

final class ExperimentalRoutingOwnerTests: XCTestCase {
    private let session = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func source(_ generation: UInt64) -> ExperimentalSourceEpoch {
        ExperimentalSourceEpoch(sessionID: session, registrationGeneration: generation)
    }

    private func contact(_ source: ExperimentalSourceEpoch, _ sequence: UInt64) -> ExperimentalContactToken {
        ExperimentalContactToken(source: source, contactSequence: sequence)
    }

    private func route(_ id: UInt32, revision: UInt64 = 1) -> ExperimentalRouteToken {
        ExperimentalRouteToken(bindingID: "binding-\(id)", bindingRevision: revision, topologyRevision: revision, displayID: id)
    }

    private func ready(_ count: UInt64 = 2) -> ExperimentalOwnerArbiter {
        var arbiter = ExperimentalOwnerArbiter(sessionID: session)
        for index in 1...count {
            XCTAssertEqual(arbiter.register(source(index)), [])
            XCTAssertEqual(arbiter.installRoute(route(UInt32(index)), for: source(index)), [])
            XCTAssertEqual(arbiter.observeNeutral(from: source(index)), [])
        }
        return arbiter
    }

    func testHardwareContactZeroIsNamespacedByEpochAndContactSequence() {
        XCTAssertNotEqual(contact(source(1), 1), contact(source(2), 1))
        XCTAssertNotEqual(contact(source(1), 1), contact(source(1), 2))
        let anotherProcess = ExperimentalSourceEpoch(sessionID: UUID(), registrationGeneration: 1)
        XCTAssertNotEqual(source(1), anotherProcess)
    }

    func testNewSourceRequiresVerifiedNeutralAndDoesNotReplayFirstHeldContact() {
        var arbiter = ExperimentalOwnerArbiter(sessionID: session)
        let a = source(1)
        XCTAssertEqual(arbiter.register(a), [])
        XCTAssertEqual(arbiter.installRoute(route(1), for: a), [])
        XCTAssertEqual(arbiter.receive(contact(a, 1), phase: .down), [.dropped(.awaitingNeutral)])
        XCTAssertEqual(arbiter.receive(contact(a, 1), phase: .move), [.dropped(.quarantined)])
        XCTAssertNil(arbiter.owner)
        XCTAssertEqual(arbiter.receive(contact(a, 1), phase: .up), [.dropped(.quarantined)])
        let decisions = arbiter.receive(contact(a, 2), phase: .down)
        XCTAssertEqual(decisions, [.admitted(arbiter.owner!)])
    }

    func testOneOwnerRemainsThroughReleaseAndCleanup() {
        var arbiter = ready()
        let a = contact(source(1), 1)
        let b = contact(source(2), 1)
        _ = arbiter.receive(a, phase: .down)
        let lease = arbiter.owner!
        XCTAssertEqual(arbiter.receive(a, phase: .up), [.forwarded(lease, .up)])
        XCTAssertEqual(arbiter.ownerPhase, .finishing)
        XCTAssertEqual(arbiter.receive(b, phase: .down), [.dropped(.ownerBusy)])
        XCTAssertEqual(arbiter.owner, lease)
        XCTAssertEqual(arbiter.finish(lease.id), [.released(lease.id)])
        XCTAssertEqual(arbiter.receive(b, phase: .move), [.dropped(.quarantined)])
        XCTAssertNil(arbiter.owner)
        XCTAssertEqual(arbiter.receive(b, phase: .up), [.dropped(.quarantined)])
        _ = arbiter.receive(contact(source(2), 2), phase: .down)
        XCTAssertEqual(arbiter.owner?.contact.source, source(2))
    }

    func testBusyContactReleasedBeforeOwnerCompletesCanStartNewContactLater() {
        var arbiter = ready()
        _ = arbiter.receive(contact(source(1), 1), phase: .down)
        let lease = arbiter.owner!
        _ = arbiter.receive(contact(source(2), 1), phase: .down)
        _ = arbiter.receive(contact(source(2), 1), phase: .up)
        _ = arbiter.receive(lease.contact, phase: .up)
        _ = arbiter.finish(lease.id)
        _ = arbiter.receive(contact(source(2), 2), phase: .down)
        XCTAssertEqual(arbiter.owner?.contact, contact(source(2), 2))
    }

    func testNonOwnerMoveUpAndRemovalCannotChangeOwner() {
        var arbiter = ready()
        _ = arbiter.receive(contact(source(1), 1), phase: .down)
        let lease = arbiter.owner!
        XCTAssertEqual(arbiter.receive(contact(source(2), 1), phase: .move), [.dropped(.staleContact)])
        XCTAssertEqual(arbiter.receive(contact(source(2), 1), phase: .up), [.dropped(.staleContact)])
        XCTAssertEqual(arbiter.retire(source(2)), [])
        XCTAssertEqual(arbiter.owner, lease)
        XCTAssertEqual(arbiter.ownerPhase, .tracking)
    }

    func testRetirementRejectsQueuedReportsAndOldEpochCannotReregister() {
        var arbiter = ready(1)
        let a = contact(source(1), 1)
        _ = arbiter.receive(a, phase: .down)
        let lease = arbiter.owner!
        XCTAssertEqual(arbiter.retire(source(1)), [.cancel(lease, .sourceRetired)])
        XCTAssertEqual(arbiter.receive(a, phase: .up), [.dropped(.sourceNotRegistered)])
        XCTAssertEqual(arbiter.register(source(1)), [.dropped(.staleSource)])
        XCTAssertEqual(arbiter.register(source(2)), [])
        _ = arbiter.installRoute(route(1), for: source(2))
        XCTAssertEqual(arbiter.receive(contact(source(2), 1), phase: .down), [.dropped(.awaitingNeutral)])
        XCTAssertEqual(arbiter.owner, lease)
        _ = arbiter.finish(lease.id)
        XCTAssertNil(arbiter.owner)
    }

    func testStaleCompletionCannotReleaseNewOwnerEvenWithSameHardwareContactID() {
        var arbiter = ready()
        _ = arbiter.receive(contact(source(1), 1), phase: .down)
        let oldLease = arbiter.owner!
        _ = arbiter.receive(oldLease.contact, phase: .up)
        _ = arbiter.finish(oldLease.id)
        _ = arbiter.receive(contact(source(2), 1), phase: .down)
        let newLease = arbiter.owner!
        XCTAssertEqual(arbiter.finish(oldLease.id), [.dropped(.staleCompletion)])
        XCTAssertEqual(arbiter.owner, newLease)
        let otherProcess = ExperimentalOwnerLeaseID(sessionID: UUID(), generation: newLease.id.generation)
        XCTAssertEqual(arbiter.finish(otherProcess), [.dropped(.staleCompletion)])
        XCTAssertEqual(arbiter.owner, newLease)
    }

    func testEarlyAdmissionFailureQuarantinesHeldContactWithoutBlockingOtherSource() {
        var arbiter = ready()
        _ = arbiter.receive(contact(source(1), 1), phase: .down)
        let lease = arbiter.owner!
        _ = arbiter.finish(lease.id)
        XCTAssertEqual(arbiter.receive(lease.contact, phase: .move), [.dropped(.quarantined)])
        _ = arbiter.receive(contact(source(2), 1), phase: .down)
        XCTAssertEqual(arbiter.owner?.contact.source, source(2))
        XCTAssertEqual(arbiter.receive(lease.contact, phase: .up), [.dropped(.quarantined)])
        XCTAssertEqual(arbiter.owner?.contact.source, source(2))
    }

    func testRouteChangeCancelsAndRequiresFreshBoundaryWithoutRewritingLease() {
        var arbiter = ready(1)
        _ = arbiter.receive(contact(source(1), 1), phase: .down)
        let lease = arbiter.owner!
        let replacement = route(1, revision: 2)
        XCTAssertEqual(arbiter.installRoute(replacement, for: source(1)), [.cancel(lease, .routeChanged)])
        XCTAssertEqual(arbiter.owner?.route, lease.route)
        _ = arbiter.finish(lease.id)
        XCTAssertEqual(arbiter.receive(lease.contact, phase: .move), [.dropped(.quarantined)])
        _ = arbiter.receive(lease.contact, phase: .up)
        _ = arbiter.receive(contact(source(1), 2), phase: .down)
        XCTAssertEqual(arbiter.owner?.route, replacement)
    }

    func testTopologyInvalidationDoesNotAutoRestoreOldBindings() {
        var arbiter = ready(1)
        _ = arbiter.receive(contact(source(1), 1), phase: .down)
        let lease = arbiter.owner!
        XCTAssertEqual(arbiter.invalidateTopology(), [.cancel(lease, .topologyInvalidated)])
        _ = arbiter.finish(lease.id)
        _ = arbiter.observeNeutral(from: source(1))
        XCTAssertEqual(arbiter.receive(contact(source(1), 2), phase: .down), [.dropped(.noBinding)])
        _ = arbiter.receive(contact(source(1), 2), phase: .up)
        _ = arbiter.installRoute(route(1, revision: 2), for: source(1))
        XCTAssertEqual(arbiter.receive(contact(source(1), 3), phase: .down), [.dropped(.awaitingNeutral)])
    }

    func testOverlappingDownCancelsOldContactAndOldUpCannotClearNewQuarantine() {
        var arbiter = ready(1)
        let a1 = contact(source(1), 1), a2 = contact(source(1), 2)
        _ = arbiter.receive(a1, phase: .down)
        let lease = arbiter.owner!
        XCTAssertEqual(arbiter.receive(a2, phase: .down), [.cancel(lease, .overlappingContact), .dropped(.overlappingContact)])
        XCTAssertEqual(arbiter.receive(a1, phase: .up), [.dropped(.staleContact)])
        _ = arbiter.finish(lease.id)
        XCTAssertEqual(arbiter.receive(a2, phase: .move), [.dropped(.quarantined)])
        _ = arbiter.receive(a2, phase: .up)
        XCTAssertEqual(arbiter.receive(contact(source(1), 3), phase: .down), [.dropped(.awaitingNeutral)])
        XCTAssertNil(arbiter.owner)
        _ = arbiter.observeNeutral(from: source(1))
        _ = arbiter.receive(contact(source(1), 4), phase: .down)
        XCTAssertNotNil(arbiter.owner)
    }

    func testOverlappingNewContactUpAndOldCleanupDoNotProveAllContactsReleased() {
        var arbiter = ready(1)
        let a1 = contact(source(1), 1), a2 = contact(source(1), 2)
        _ = arbiter.receive(a1, phase: .down)
        let lease = arbiter.owner!
        _ = arbiter.receive(a2, phase: .down)
        XCTAssertEqual(arbiter.receive(a2, phase: .up), [.dropped(.quarantined)])
        _ = arbiter.finish(lease.id)
        // No a1 up or decoder-verified all-up frame has arrived.
        XCTAssertEqual(arbiter.receive(contact(source(1), 3), phase: .down), [.dropped(.awaitingNeutral)])
        XCTAssertNil(arbiter.owner)
        _ = arbiter.receive(contact(source(1), 3), phase: .up)
        // Even another complete newest lifecycle cannot clear inconsistency.
        XCTAssertEqual(arbiter.receive(contact(source(1), 4), phase: .down), [.dropped(.awaitingNeutral)])
        _ = arbiter.observeNeutral(from: source(1))
        _ = arbiter.receive(contact(source(1), 5), phase: .down)
        XCTAssertEqual(arbiter.owner?.contact, contact(source(1), 5))
    }

    func testReconstructedArbiterWithSameSourceSessionRejectsPreviousCompletion() {
        var old = ready(1)
        _ = old.receive(contact(source(1), 1), phase: .down)
        let oldLease = old.owner!
        var replacement = ready(1)
        _ = replacement.receive(contact(source(1), 1), phase: .down)
        let newLease = replacement.owner!
        XCTAssertEqual(oldLease.contact, newLease.contact)
        XCTAssertEqual(oldLease.id.generation, newLease.id.generation)
        XCTAssertNotEqual(oldLease.id.sessionID, newLease.id.sessionID)
        XCTAssertEqual(replacement.finish(oldLease.id), [.dropped(.staleCompletion)])
        XCTAssertEqual(replacement.owner, newLease)
        XCTAssertEqual(replacement.finish(newLease.id), [.released(newLease.id)])
    }

    func testOwnerIncarnationCanBeInjectedOnlyThroughInternalTestSeam() {
        let incarnation = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        var arbiter = ExperimentalOwnerArbiter(sessionID: session, lastLeaseGeneration: 40, ownerIncarnationID: incarnation)
        _ = arbiter.register(source(1))
        _ = arbiter.installRoute(route(1), for: source(1))
        _ = arbiter.observeNeutral(from: source(1))
        _ = arbiter.receive(contact(source(1), 1), phase: .down)
        XCTAssertEqual(arbiter.owner?.id, ExperimentalOwnerLeaseID(sessionID: incarnation, generation: 41))
        XCTAssertEqual(arbiter.owner?.contact.source.sessionID, session)
    }

    func testDuplicateDownSequenceDoesNotCreateSecondLease() {
        var arbiter = ready(1)
        let a = contact(source(1), 1)
        _ = arbiter.receive(a, phase: .down)
        let lease = arbiter.owner!
        XCTAssertEqual(arbiter.receive(a, phase: .down), [.dropped(.staleContact)])
        XCTAssertEqual(arbiter.owner, lease)
    }

    func testNeutralWithoutLifecycleReleaseCancelsRatherThanSynthesizesClick() {
        var arbiter = ready(1)
        _ = arbiter.receive(contact(source(1), 1), phase: .down)
        let lease = arbiter.owner!
        XCTAssertEqual(arbiter.observeNeutral(from: source(1)), [.cancel(lease, .neutralWithoutRelease)])
        XCTAssertEqual(arbiter.ownerPhase, .cancelling)
        XCTAssertEqual(arbiter.cancel(), [])
        XCTAssertEqual(arbiter.owner, lease)
    }

    func testStopIsTerminalButStillAcceptsOwnedCleanupCompletion() {
        var arbiter = ready(1)
        _ = arbiter.receive(contact(source(1), 1), phase: .down)
        let lease = arbiter.owner!
        XCTAssertEqual(arbiter.stop(), [.cancel(lease, .stopped)])
        XCTAssertEqual(arbiter.stop(), [])
        XCTAssertEqual(arbiter.register(source(2)), [.dropped(.stopped)])
        XCTAssertEqual(arbiter.receive(lease.contact, phase: .up), [.dropped(.stopped)])
        XCTAssertEqual(arbiter.finish(lease.id), [.released(lease.id)])
        XCTAssertEqual(arbiter.registeredSourceCount, 0)
    }

    func testRegistrationAndLeaseCountersDoNotWrapOrReuse() {
        var arbiter = ExperimentalOwnerArbiter(sessionID: session, maximumSources: 1, lastLeaseGeneration: UInt64.max)
        XCTAssertEqual(arbiter.register(source(1)), [])
        XCTAssertEqual(arbiter.register(source(2)), [.dropped(.sourceCapacityExceeded)])
        _ = arbiter.installRoute(route(1), for: source(1))
        _ = arbiter.observeNeutral(from: source(1))
        XCTAssertEqual(arbiter.receive(contact(source(1), 1), phase: .down), [.dropped(.leaseExhausted)])
        XCTAssertNil(arbiter.owner)
        _ = arbiter.retire(source(1))
        XCTAssertEqual(arbiter.register(source(2)), [])
        XCTAssertEqual(arbiter.registeredSourceCount, 1)
        XCTAssertEqual(arbiter.quarantinedSourceCount, 0)
    }

    func testContextChangesBreakGesturePairingEquality() {
        let context = ExperimentalInteractionContext(source: source(1), route: route(1), targetContextRevision: 1, policyRevision: 1, activationRevision: 1)
        let changes = [
            ExperimentalInteractionContext(source: source(2), route: route(1), targetContextRevision: 1, policyRevision: 1, activationRevision: 1),
            ExperimentalInteractionContext(source: source(1), route: route(1, revision: 2), targetContextRevision: 1, policyRevision: 1, activationRevision: 1),
            ExperimentalInteractionContext(source: source(1), route: route(1), targetContextRevision: 2, policyRevision: 1, activationRevision: 1),
            ExperimentalInteractionContext(source: source(1), route: route(1), targetContextRevision: 1, policyRevision: 2, activationRevision: 1),
            ExperimentalInteractionContext(source: source(1), route: route(1), targetContextRevision: 1, policyRevision: 1, activationRevision: 2)
        ]
        for changed in changes { XCTAssertNotEqual(context, changed) }
    }
}
