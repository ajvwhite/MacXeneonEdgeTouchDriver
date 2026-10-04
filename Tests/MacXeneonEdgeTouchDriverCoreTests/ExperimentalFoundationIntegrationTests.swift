import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

/// Composition tests use decisions and fake acknowledgments only. They are not
/// a production adapter and do not read a device or construct an input event.
final class ExperimentalFoundationIntegrationTests: XCTestCase {
    private let session = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let point = ExperimentalGesturePoint(x: 20, y: 30)

    func testSourceScopedOwnerCompletesCleanupBeforeNextTapCanPair() throws {
        let source = epoch(1)
        let route = mapping(1)
        var owner = preparedOwner([(source, route)])
        var click = try classifier()
        let first = try admitted(owner.receive(contact(source, 1), phase: .down))
        XCTAssertEqual(begin(&click, first, time: 100), .clickCount(1))
        click.recordDownResult(leaseID: first.id, postInvoked: true)
        XCTAssertEqual(owner.receive(first.contact, phase: .up), [.forwarded(first, .up)])
        release(&click, first, time: 120)
        XCTAssertEqual(owner.owner, first)
        XCTAssertTrue(click.completeCleanup(leaseID: first.id))
        XCTAssertEqual(owner.finish(first.id), [.released(first.id)])

        let second = try admitted(owner.receive(contact(source, 2), phase: .down))
        XCTAssertEqual(begin(&click, second, time: 200), .clickCount(2))
    }

    func testForeignSourceSameRawIDCannotStealOwnerOrSeedDoubleClick() throws {
        let sourceA = epoch(1)
        let sourceB = epoch(2)
        let routeA = mapping(1)
        let routeB = mapping(2)
        var owner = preparedOwner([(sourceA, routeA), (sourceB, routeB)])
        var click = try classifier()
        let first = try admitted(owner.receive(contact(sourceA, 1), phase: .down))
        XCTAssertEqual(begin(&click, first, time: 100), .clickCount(1))
        click.recordDownResult(leaseID: first.id, postInvoked: true)
        let blocked = contact(sourceB, 1)
        XCTAssertEqual(owner.receive(blocked, phase: .down), [.dropped(.ownerBusy)])
        click.invalidateSequence()
        _ = owner.receive(first.contact, phase: .up)
        release(&click, first, time: 120)
        XCTAssertTrue(click.completeCleanup(leaseID: first.id))
        _ = owner.finish(first.id)
        XCTAssertEqual(owner.receive(blocked, phase: .move), [.dropped(.quarantined)])
        XCTAssertEqual(owner.receive(blocked, phase: .up), [.dropped(.quarantined)])
        let second = try admitted(owner.receive(contact(sourceB, 2), phase: .down))
        XCTAssertEqual(begin(&click, second, time: 200), .clickCount(1))
    }

    func testTouchStartingDuringCleanupStaysQuarantinedAndBreaksPair() throws {
        let source = epoch(1)
        var owner = preparedOwner([(source, mapping(1))])
        var click = try classifier()
        let first = try admitted(owner.receive(contact(source, 1), phase: .down))
        XCTAssertEqual(begin(&click, first, time: 100), .clickCount(1))
        click.recordDownResult(leaseID: first.id, postInvoked: true)
        _ = owner.receive(first.contact, phase: .up)
        release(&click, first, time: 120)
        let blocked = contact(source, 2)
        XCTAssertEqual(owner.receive(blocked, phase: .down), [.dropped(.ownerBusy)])
        click.invalidateSequence()
        XCTAssertTrue(click.completeCleanup(leaseID: first.id))
        _ = owner.finish(first.id)
        XCTAssertEqual(owner.receive(blocked, phase: .up), [.dropped(.quarantined)])
        let next = try admitted(owner.receive(contact(source, 3), phase: .down))
        XCTAssertEqual(begin(&click, next, time: 200), .clickCount(1))
    }

    func testTopologyCancellationRetainsReleaseOwnershipAndInvalidatesPairing() throws {
        let source = epoch(1)
        var owner = preparedOwner([(source, mapping(1))])
        var click = try classifier()
        let first = try admitted(owner.receive(contact(source, 1), phase: .down))
        XCTAssertEqual(begin(&click, first, time: 100), .clickCount(1))
        click.recordDownResult(leaseID: first.id, postInvoked: true)
        XCTAssertEqual(owner.invalidateTopology(), [.cancel(first, .topologyInvalidated)])
        click.cancel(leaseID: first.id)
        XCTAssertEqual(owner.owner, first)
        release(&click, first, time: 120)
        XCTAssertTrue(click.completeCleanup(leaseID: first.id))
        _ = owner.finish(first.id)
        _ = owner.installRoute(mapping(1, topology: 2), for: source)
        _ = owner.observeNeutral(from: source)
        let next = try admitted(owner.receive(contact(source, 2), phase: .down))
        XCTAssertEqual(begin(&click, next, time: 200), .clickCount(1))
    }

    func testFailedReleaseCannotAcknowledgeCleanupOrFreeGlobalOwner() throws {
        let source = epoch(1)
        var owner = preparedOwner([(source, mapping(1))])
        var click = try classifier()
        let first = try admitted(owner.receive(contact(source, 1), phase: .down))
        XCTAssertEqual(begin(&click, first, time: 100), .clickCount(1))
        click.recordDownResult(leaseID: first.id, postInvoked: true)
        _ = owner.receive(first.contact, phase: .up)
        release(&click, first, time: 120, posted: false)
        let complete = click.completeCleanup(leaseID: first.id)
        if complete { _ = owner.finish(first.id) }
        XCTAssertFalse(complete)
        XCTAssertEqual(owner.owner, first)
        XCTAssertEqual(owner.receive(contact(source, 2), phase: .down), [.dropped(.ownerBusy)])
    }

    func testStaleSourceAndCleanupCannotReleaseReconnectedSourceLease() throws {
        let old = epoch(1)
        let replacement = epoch(2)
        var owner = preparedOwner([(old, mapping(1))])
        let first = try admitted(owner.receive(contact(old, 1), phase: .down))
        XCTAssertEqual(owner.retire(old), [.cancel(first, .sourceRetired)])
        _ = owner.finish(first.id)
        _ = owner.register(replacement)
        _ = owner.installRoute(mapping(1), for: replacement)
        _ = owner.observeNeutral(from: replacement)
        let next = try admitted(owner.receive(contact(replacement, 1), phase: .down))
        XCTAssertEqual(owner.receive(first.contact, phase: .up), [.dropped(.sourceNotRegistered)])
        XCTAssertEqual(owner.finish(first.id), [.dropped(.staleCompletion)])
        XCTAssertEqual(owner.owner, next)
    }

    func testScrollCannotReplaceMouseOwnershipAndRequiresFreshAllUpBoundary() throws {
        let source = epoch(1)
        let route = mapping(1)
        let context = ExperimentalInteractionContext(source: source, route: route, targetContextRevision: 1)
        var scroll = try ExperimentalTwoContactScrollReducer(scale: 1)
        let pair = [
            ExperimentalScrollContact(token: contact(source, 1, raw: 0), point: point),
            ExperimentalScrollContact(token: contact(source, 2, raw: 1), point: .init(x: 40, y: 30))
        ]
        func frame(_ sequence: UInt64, _ contacts: [ExperimentalScrollContact]) -> ExperimentalContactFrame {
            ExperimentalContactFrame(context: context, sequence: sequence, timestamp: sequence,
                                     isComplete: true, contacts: contacts)
        }
        XCTAssertEqual(scroll.consume(frame(1, pair), ownership: .mousePress), [])
        XCTAssertEqual(scroll.consume(frame(2, pair), ownership: .unowned), [])
        XCTAssertEqual(scroll.consume(frame(3, []), ownership: .unowned), [])
        let nextPair = [
            ExperimentalScrollContact(token: contact(source, 3, raw: 0), point: point),
            ExperimentalScrollContact(token: contact(source, 4, raw: 1), point: .init(x: 40, y: 30))
        ]
        XCTAssertEqual(scroll.consume(frame(4, nextPair), ownership: .unowned), [.requestOwnership(1)])
    }

    func testPairRepresentativeLeaseStaysOwnedThroughTerminalAndRemainingFinger() throws {
        let source = epoch(1)
        let route = mapping(1)
        let context = ExperimentalInteractionContext(source: source, route: route, targetContextRevision: 1)
        var owner = preparedOwner([(source, route)])
        var scroll = try ExperimentalTwoContactScrollReducer(scale: 1)
        let first = ExperimentalScrollContact(token: contact(source, 1, raw: 0), point: point)
        let second = ExperimentalScrollContact(token: contact(source, 2, raw: 1), point: .init(x: 40, y: 30))
        func frame(_ sequence: UInt64, _ contacts: [ExperimentalScrollContact]) -> ExperimentalContactFrame {
            ExperimentalContactFrame(context: context, sequence: sequence, timestamp: sequence,
                                     isComplete: true, contacts: contacts)
        }
        // A complete-frame adapter must classify the pair before admitting any
        // mouse down. Only its representative enters the single-contact arbiter.
        XCTAssertEqual(scroll.consume(frame(1, [first, second]), ownership: .unowned), [.requestOwnership(1)])
        let lease = try admitted(owner.receive(first.token, phase: .down))
        XCTAssertEqual(scroll.grantOwnership(request: 1, lease: lease, ownership: .scroll(lease.id), context: context),
                       [.began(lease.id, anchor: .init(x: 30, y: 30))])
        XCTAssertEqual(scroll.consume(frame(2, [first]), ownership: .scroll(lease.id)), [.ended(lease.id)])
        XCTAssertEqual(owner.owner, lease)
        XCTAssertFalse(scroll.completeCleanup(leaseID: lease.id))
        scroll.recordTerminalResult(leaseID: lease.id, postInvoked: true)
        XCTAssertTrue(scroll.completeCleanup(leaseID: lease.id))
        _ = owner.finish(lease.id)
        XCTAssertEqual(owner.receive(first.token, phase: .move), [.dropped(.quarantined)])
        XCTAssertEqual(scroll.consume(frame(3, [first]), ownership: .unowned), [])
        XCTAssertEqual(scroll.consume(frame(4, []), ownership: .unowned), [])
        _ = owner.observeNeutral(from: source)
        XCTAssertNil(owner.owner)
    }

    func testInvalidatedPreBeginGrantRequiresExplicitOwnerCompletionWithoutTerminalPost() throws {
        let source = epoch(1)
        let route = mapping(1)
        let context = ExperimentalInteractionContext(source: source, route: route, targetContextRevision: 1)
        var owner = preparedOwner([(source, route)])
        var scroll = try ExperimentalTwoContactScrollReducer(scale: 1)
        let first = ExperimentalScrollContact(token: contact(source, 1, raw: 0), point: point)
        let second = ExperimentalScrollContact(token: contact(source, 2, raw: 1), point: .init(x: 40, y: 30))
        let initial = ExperimentalContactFrame(context: context, sequence: 1, timestamp: 1,
                                               isComplete: true, contacts: [first, second])
        XCTAssertEqual(scroll.consume(initial, ownership: .unowned), [.requestOwnership(1)])
        let lease = try admitted(owner.receive(first.token, phase: .down))
        // Admission was allocated, but the asynchronous grant has not arrived.
        scroll.cancelPending(request: 1)
        let grant = scroll.grantOwnership(request: 1, lease: lease, ownership: .scroll(lease.id), context: context)
        XCTAssertEqual(grant, [])
        XCTAssertEqual(owner.owner, lease, "No reducer can silently complete another component's lease.")
        // A dispatcher must recognize rejected pre-began admission and finish
        // that exact lease. No scroll terminal is owed because began never ran.
        XCTAssertEqual(owner.finish(lease.id), [.released(lease.id)])
        XCTAssertEqual(owner.receive(first.token, phase: .move), [.dropped(.quarantined)])
        XCTAssertNil(owner.owner)
    }

    private func epoch(_ generation: UInt64) -> ExperimentalSourceEpoch {
        ExperimentalSourceEpoch(sessionID: session, registrationGeneration: generation)
    }

    private func mapping(_ display: UInt32, topology: UInt64 = 1) -> ExperimentalRouteToken {
        ExperimentalRouteToken(bindingID: "panel-\(display)", bindingRevision: 1, topologyRevision: topology, displayID: display)
    }

    private func contact(_ source: ExperimentalSourceEpoch, _ sequence: UInt64, raw: Int = 0) -> ExperimentalContactToken {
        ExperimentalContactToken(source: source, contactSequence: sequence, rawContactID: raw)
    }

    private func preparedOwner(_ bindings: [(ExperimentalSourceEpoch, ExperimentalRouteToken)]) -> ExperimentalOwnerArbiter {
        var owner = ExperimentalOwnerArbiter(sessionID: session)
        for (source, route) in bindings {
            _ = owner.register(source)
            _ = owner.installRoute(route, for: source)
            _ = owner.observeNeutral(from: source)
        }
        return owner
    }

    private func admitted(_ decisions: [ExperimentalRoutingDecision]) throws -> ExperimentalOwnerLease {
        try XCTUnwrap(decisions.compactMap { decision in
            if case .admitted(let lease) = decision { return lease }
            return nil
        }.first)
    }

    private func classifier() throws -> ExperimentalDoubleClickReducer {
        ExperimentalDoubleClickReducer(policy: try .init(intervalNanoseconds: 1_000, maximumDistance: 5))
    }

    private func begin(_ click: inout ExperimentalDoubleClickReducer, _ lease: ExperimentalOwnerLease, time: UInt64) -> ExperimentalClickDecision {
        click.begin(lease: lease, context: .init(source: lease.contact.source, route: lease.route, targetContextRevision: 1),
                    point: point, receiptTime: time, postTime: time + 1)
    }

    private func release(_ click: inout ExperimentalDoubleClickReducer, _ lease: ExperimentalOwnerLease,
                         time: UInt64, posted: Bool = true) {
        click.recordRelease(leaseID: lease.id, context: .init(source: lease.contact.source, route: lease.route, targetContextRevision: 1),
                            point: point, receiptTime: time, postTime: time + 1, postInvoked: posted)
    }
}
