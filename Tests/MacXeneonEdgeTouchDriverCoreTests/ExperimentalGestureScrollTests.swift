import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class ExperimentalGestureScrollTests: XCTestCase {
    func testOwnershipPrecedesBeginAndFractionalDeltasArePreserved() throws {
        let fixture = ScrollFixture()
        var reducer = try ExperimentalTwoContactScrollReducer(scale: 1)
        XCTAssertEqual(reducer.consume(fixture.frame(1), ownership: .unowned), [.requestOwnership(1)])
        XCTAssertEqual(fixture.grant(&reducer), [.began(fixture.lease.id, anchor: .init(x: 5, y: 5))])
        XCTAssertEqual(reducer.consume(fixture.frame(2, offset: 0.25), ownership: .scroll(fixture.lease.id)),
                       [.changed(fixture.lease.id, deltaX: 0.25, deltaY: 0.25)])
        XCTAssertEqual(reducer.consume(fixture.frame(3, offset: 0.5), ownership: .scroll(fixture.lease.id)),
                       [.changed(fixture.lease.id, deltaX: 0.25, deltaY: 0.25)])
    }

    func testNoPromotionFromMouseOrLateSecondFinger() throws {
        let fixture = ScrollFixture()
        for ownership in [ExperimentalScrollOwnership.mousePress, .cleanup(fixture.lease.id)] {
            var reducer = try ExperimentalTwoContactScrollReducer(scale: 1)
            XCTAssertTrue(reducer.consume(fixture.frame(1), ownership: ownership).isEmpty)
            XCTAssertTrue(reducer.consume(fixture.frame(2), ownership: .unowned).isEmpty)
        }
        var reducer = try ExperimentalTwoContactScrollReducer(scale: 1)
        XCTAssertEqual(reducer.consume(fixture.frame(1, count: 1), ownership: .unowned), [.singleContactOnly])
        XCTAssertTrue(reducer.consume(fixture.frame(2), ownership: .unowned).isEmpty)
        _ = reducer.consume(fixture.frame(3, count: 0), ownership: .unowned)
        XCTAssertEqual(reducer.consume(fixture.frame(4), ownership: .unowned), [.requestOwnership(1)])
    }

    func testReorderedPairIsSamePairAndUnchangedFrameEmitsNothing() throws {
        let fixture = ScrollFixture()
        var reducer = try fixture.started()
        let ordinary = fixture.frame(2)
        let reordered = ExperimentalContactFrame(context: ordinary.context, sequence: ordinary.sequence,
                                                  timestamp: ordinary.timestamp, isComplete: true,
                                                  contacts: Array(ordinary.contacts.reversed()))
        XCTAssertTrue(reducer.consume(reordered, ownership: .scroll(fixture.lease.id)).isEmpty)
    }

    func testLiftEndsOnceAndRetainsOwnershipThroughTerminalAndCleanup() throws {
        let fixture = ScrollFixture()
        var reducer = try fixture.started()
        XCTAssertEqual(reducer.consume(fixture.frame(2, count: 1), ownership: .scroll(fixture.lease.id)), [.ended(fixture.lease.id)])
        XCTAssertFalse(reducer.completeCleanup(leaseID: fixture.lease.id))
        XCTAssertTrue(reducer.consume(fixture.frame(3, count: 0), ownership: .cleanup(fixture.lease.id)).isEmpty)
        reducer.recordTerminalResult(leaseID: fixture.lease.id, postInvoked: true)
        XCTAssertTrue(reducer.completeCleanup(leaseID: fixture.lease.id))
        XCTAssertEqual(reducer.consume(fixture.frame(4, contactSequenceBase: 3), ownership: .unowned), [.requestOwnership(2)])
    }

    func testRemainingFingerCannotBecomeMouseAfterCleanup() throws {
        let fixture = ScrollFixture()
        var reducer = try fixture.started()
        _ = reducer.consume(fixture.frame(2, count: 1), ownership: .scroll(fixture.lease.id))
        reducer.recordTerminalResult(leaseID: fixture.lease.id, postInvoked: true)
        XCTAssertTrue(reducer.completeCleanup(leaseID: fixture.lease.id))
        XCTAssertTrue(reducer.consume(fixture.frame(3, count: 1), ownership: .unowned).isEmpty)
        XCTAssertTrue(reducer.consume(fixture.frame(4), ownership: .unowned).isEmpty)
        _ = reducer.consume(fixture.frame(5, count: 0), ownership: .unowned)
        XCTAssertEqual(reducer.consume(fixture.frame(6, contactSequenceBase: 3), ownership: .unowned), [.requestOwnership(2)])
    }

    func testThirdContactAndLogicalIDReplacementCancelRatherThanEnd() throws {
        let fixture = ScrollFixture()
        var withThird = try fixture.started()
        XCTAssertEqual(withThird.consume(fixture.frame(2, count: 3), ownership: .scroll(fixture.lease.id)), [.cancelled(fixture.lease.id)])
        var replaced = try fixture.started()
        let contact = ExperimentalScrollContact(token: .init(source: fixture.context.source, contactSequence: 99, rawContactID: 0),
                                                point: .init(x: 0, y: 0))
        let frame = ExperimentalContactFrame(context: fixture.context, sequence: 2, timestamp: 2, isComplete: true, contacts: [contact])
        XCTAssertEqual(replaced.consume(frame, ownership: .scroll(fixture.lease.id)), [.cancelled(fixture.lease.id)])
    }

    func testInvalidAndUnorderedFramesCancelOnce() throws {
        let fixture = ScrollFixture()
        let duplicate = fixture.frame(2).contacts[0]
        let repeatedSequence = ExperimentalScrollContact(
            token: .init(source: fixture.context.source, contactSequence: duplicate.token.contactSequence, rawContactID: 1),
            point: .init(x: 10, y: 10))
        let invalidFrames = [
            ExperimentalContactFrame(context: fixture.context, sequence: 2, timestamp: 2, isComplete: false, contacts: []),
            ExperimentalContactFrame(context: fixture.context, sequence: 2, timestamp: 2, isComplete: true, contacts: [duplicate, duplicate]),
            ExperimentalContactFrame(context: fixture.context, sequence: 2, timestamp: 2, isComplete: true, contacts: [duplicate, repeatedSequence]),
            fixture.frame(1),
            ExperimentalContactFrame(context: fixture.context, sequence: 2, timestamp: 0, isComplete: true, contacts: fixture.frame(2).contacts),
            fixture.frame(2, offset: .infinity)
        ]
        for frame in invalidFrames {
            var reducer = try fixture.started()
            XCTAssertEqual(reducer.consume(frame, ownership: .scroll(fixture.lease.id)), [.cancelled(fixture.lease.id)])
            XCTAssertTrue(reducer.cancel(leaseID: fixture.lease.id).isEmpty)
        }
    }

    func testSourceAndRevisionChangesCancelAndCannotAcknowledgeForeignLifts() throws {
        let fixture = ScrollFixture()
        for context in [fixture.changedContext(generation: 2), fixture.changedContext(topology: 2),
                        fixture.changedContext(policy: 1), fixture.changedContext(activation: 1), fixture.changedContext(target: 1)] {
            var reducer = try fixture.started()
            XCTAssertEqual(reducer.consume(fixture.frame(2, context: context), ownership: .scroll(fixture.lease.id)), [.cancelled(fixture.lease.id)])
        }
        var reducer = try fixture.started()
        let foreign = fixture.changedContext(generation: 2)
        _ = reducer.consume(fixture.frame(2, context: foreign, count: 0), ownership: .scroll(fixture.lease.id))
        reducer.recordTerminalResult(leaseID: fixture.lease.id, postInvoked: true)
        XCTAssertTrue(reducer.completeCleanup(leaseID: fixture.lease.id))
        XCTAssertTrue(reducer.consume(fixture.frame(3, context: foreign), ownership: .unowned).isEmpty)
    }

    func testFailedTerminalAndStaleAcknowledgmentCannotReleaseOwnership() throws {
        let fixture = ScrollFixture()
        var reducer = try fixture.started()
        _ = reducer.consume(fixture.frame(2, count: 0), ownership: .scroll(fixture.lease.id))
        let stale = ExperimentalOwnerLeaseID(sessionID: fixture.ownerSession, generation: 99)
        reducer.recordTerminalResult(leaseID: stale, postInvoked: true)
        XCTAssertFalse(reducer.completeCleanup(leaseID: stale))
        XCTAssertFalse(reducer.completeCleanup(leaseID: fixture.lease.id))
        reducer.recordTerminalResult(leaseID: fixture.lease.id, postInvoked: false)
        reducer.recordTerminalResult(leaseID: fixture.lease.id, postInvoked: true)
        XCTAssertFalse(reducer.completeCleanup(leaseID: fixture.lease.id))
        XCTAssertTrue(reducer.consume(fixture.frame(3), ownership: .unowned).isEmpty)
    }

    func testStaleGrantOrWrongOwnerCannotBegin() throws {
        let fixture = ScrollFixture()
        var reducer = try ExperimentalTwoContactScrollReducer(scale: 1)
        _ = reducer.consume(fixture.frame(1), ownership: .unowned)
        XCTAssertTrue(reducer.grantOwnership(request: 99, lease: fixture.lease, ownership: .scroll(fixture.lease.id), context: fixture.context).isEmpty)
        XCTAssertTrue(reducer.grantOwnership(request: 1, lease: fixture.lease, ownership: .mousePress, context: fixture.context).isEmpty)
        XCTAssertTrue(fixture.grant(&reducer).isEmpty)
    }

    func testStaleCancellationCannotCancelNewerScroll() throws {
        let fixture = ScrollFixture()
        var reducer = try fixture.started()
        _ = reducer.consume(fixture.frame(2, count: 0), ownership: .scroll(fixture.lease.id))
        reducer.recordTerminalResult(leaseID: fixture.lease.id, postInvoked: true)
        XCTAssertTrue(reducer.completeCleanup(leaseID: fixture.lease.id))
        XCTAssertEqual(reducer.consume(fixture.frame(3, contactSequenceBase: 3), ownership: .unowned), [.requestOwnership(2)])
        let nextLease = ExperimentalOwnerLease(id: .init(sessionID: fixture.ownerSession, generation: 2),
                                                contact: fixture.frame(3, contactSequenceBase: 3).contacts[0].token,
                                                route: fixture.lease.route)
        XCTAssertEqual(reducer.grantOwnership(request: 2, lease: nextLease, ownership: .scroll(nextLease.id), context: fixture.context),
                       [.began(nextLease.id, anchor: .init(x: 5, y: 5))])
        XCTAssertTrue(reducer.cancel(leaseID: fixture.lease.id).isEmpty)
        XCTAssertEqual(reducer.consume(fixture.frame(4, offset: 1, contactSequenceBase: 3), ownership: .scroll(nextLease.id)),
                       [.changed(nextLease.id, deltaX: 1, deltaY: 1)])
    }

    func testStalePendingCancellationCannotCancelNewerRequest() throws {
        let fixture = ScrollFixture()
        var reducer = try ExperimentalTwoContactScrollReducer(scale: 1)
        _ = reducer.consume(fixture.frame(1), ownership: .unowned)
        reducer.cancelPending(request: 1)
        _ = reducer.consume(fixture.frame(2, count: 0), ownership: .unowned)
        XCTAssertEqual(reducer.consume(fixture.frame(3, contactSequenceBase: 3), ownership: .unowned), [.requestOwnership(2)])
        reducer.cancelPending(request: 1)
        let nextLease = ExperimentalOwnerLease(id: fixture.lease.id,
                                                contact: fixture.frame(3, contactSequenceBase: 3).contacts[0].token,
                                                route: fixture.lease.route)
        XCTAssertEqual(reducer.grantOwnership(request: 2, lease: nextLease,
                                              ownership: .scroll(fixture.lease.id), context: fixture.context),
                       [.began(fixture.lease.id, anchor: .init(x: 5, y: 5))])
    }

    func testCompletedPairLifecycleTokensCannotBeReused() throws {
        let fixture = ScrollFixture()
        var reducer = try fixture.started()
        _ = reducer.consume(fixture.frame(2, count: 0), ownership: .scroll(fixture.lease.id))
        reducer.recordTerminalResult(leaseID: fixture.lease.id, postInvoked: true)
        XCTAssertTrue(reducer.completeCleanup(leaseID: fixture.lease.id))
        XCTAssertTrue(reducer.consume(fixture.frame(3), ownership: .unowned).isEmpty)
        _ = reducer.consume(fixture.frame(4, count: 0), ownership: .unowned)
        XCTAssertEqual(reducer.consume(fixture.frame(5, contactSequenceBase: 3), ownership: .unowned), [.requestOwnership(2)])
    }

    func testPendingMovementSetsAnchorWithoutInventingEarlierScroll() throws {
        let fixture = ScrollFixture()
        var reducer = try ExperimentalTwoContactScrollReducer(scale: 1)
        _ = reducer.consume(fixture.frame(1), ownership: .unowned)
        XCTAssertTrue(reducer.consume(fixture.frame(2, offset: 20), ownership: .unowned).isEmpty)
        XCTAssertEqual(fixture.grant(&reducer), [.began(fixture.lease.id, anchor: .init(x: 25, y: 25))])
    }

    func testInvalidScaleAndOverflowAreRejected() throws {
        for scale in [0, -1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try ExperimentalTwoContactScrollReducer(scale: scale))
        }
        let fixture = ScrollFixture()
        var reducer = try fixture.started(scale: Double.greatestFiniteMagnitude)
        XCTAssertEqual(reducer.consume(fixture.frame(2, offset: 10), ownership: .scroll(fixture.lease.id)), [.cancelled(fixture.lease.id)])
    }
}

private struct ScrollFixture {
    let sourceSession = UUID()
    let ownerSession = UUID()
    var context: ExperimentalInteractionContext { changedContext() }
    var lease: ExperimentalOwnerLease {
        .init(id: .init(sessionID: ownerSession, generation: 1), contact: frame(1).contacts[0].token, route: context.route)
    }

    func changedContext(generation: UInt64 = 1, topology: UInt64 = 1, policy: UInt64 = 0,
                        activation: UInt64 = 0, target: UInt64 = 0) -> ExperimentalInteractionContext {
        .init(source: .init(sessionID: sourceSession, registrationGeneration: generation),
              route: .init(bindingID: "test-panel", bindingRevision: 1, topologyRevision: topology, displayID: 1),
              targetContextRevision: target, policyRevision: policy, activationRevision: activation)
    }

    func frame(_ sequence: UInt64, context supplied: ExperimentalInteractionContext? = nil,
               count: Int = 2, offset: Double = 0, contactSequenceBase: UInt64 = 1) -> ExperimentalContactFrame {
        let current = supplied ?? context
        let contacts = (0..<count).map { index in
            ExperimentalScrollContact(token: .init(source: current.source, contactSequence: contactSequenceBase + UInt64(index), rawContactID: index),
                                       point: .init(x: Double(index) * 10 + offset, y: Double(index) * 10 + offset))
        }
        return .init(context: current, sequence: sequence, timestamp: sequence, isComplete: true, contacts: contacts)
    }

    func grant(_ reducer: inout ExperimentalTwoContactScrollReducer) -> [ExperimentalScrollAction] {
        reducer.grantOwnership(request: 1, lease: lease, ownership: .scroll(lease.id), context: context)
    }

    func started(scale: Double = 1) throws -> ExperimentalTwoContactScrollReducer {
        var reducer = try ExperimentalTwoContactScrollReducer(scale: scale)
        XCTAssertEqual(reducer.consume(frame(1), ownership: .unowned), [.requestOwnership(1)])
        XCTAssertEqual(grant(&reducer), [.began(lease.id, anchor: .init(x: 5, y: 5))])
        return reducer
    }
}
