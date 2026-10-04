import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class ExperimentalGestureDoubleClickTests: XCTestCase {
    func testSequenceIsOneTwoOneWithMatchingCleanupRequired() throws {
        let fixture = ClickFixture()
        var reducer = try fixture.reducer()
        XCTAssertEqual(fixture.begin(&reducer, sequence: 1, time: 0), .clickCount(1))
        fixture.finish(&reducer, sequence: 1, time: 0)
        XCTAssertEqual(fixture.begin(&reducer, sequence: 2, time: 50), .clickCount(2))
        fixture.finish(&reducer, sequence: 2, time: 50)
        XCTAssertEqual(fixture.begin(&reducer, sequence: 3, time: 90), .clickCount(1))
    }

    func testCleanupPendingRejectsSecondDownAndInvalidatesCandidate() throws {
        let fixture = ClickFixture()
        var reducer = try fixture.reducer()
        XCTAssertEqual(fixture.begin(&reducer, sequence: 1, time: 0), .clickCount(1))
        fixture.release(&reducer, sequence: 1, time: 0)
        XCTAssertEqual(fixture.begin(&reducer, sequence: 2, time: 30), .rejected)
        XCTAssertTrue(reducer.completeCleanup(leaseID: fixture.lease(1).id))
        XCTAssertEqual(fixture.begin(&reducer, sequence: 3, time: 50), .clickCount(1))
    }

    func testInclusiveTimeAndDistanceBoundary() throws {
        let fixture = ClickFixture()
        var reducer = try fixture.reducer()
        _ = fixture.begin(&reducer, sequence: 1, time: 0)
        fixture.finish(&reducer, sequence: 1, time: 0)
        XCTAssertEqual(fixture.begin(&reducer, sequence: 2, time: 100, point: .init(x: 6, y: 8)), .clickCount(2))
    }

    func testOutsideEitherClockOrDistanceProducesIndependentClick() throws {
        let fixture = ClickFixture()
        let cases: [(UInt64, UInt64, ExperimentalGesturePoint)] = [
            (101, 111, .init(x: 0, y: 0)),
            (50, 111, .init(x: 0, y: 0)),
            (50, 60, .init(x: 10.01, y: 0))
        ]
        for (receipt, post, point) in cases {
            var reducer = try fixture.reducer()
            _ = fixture.begin(&reducer, sequence: 1, time: 0)
            fixture.finish(&reducer, sequence: 1, time: 0)
            XCTAssertEqual(reducer.begin(lease: fixture.lease(2), context: fixture.context,
                                         point: point, receiptTime: receipt, postTime: post), .clickCount(1))
        }
    }

    func testClockRollbackCannotPairOrTrap() throws {
        let fixture = ClickFixture()
        var reducer = try fixture.reducer()
        _ = fixture.begin(&reducer, sequence: 1, time: 100)
        fixture.finish(&reducer, sequence: 1, time: 100)
        XCTAssertEqual(fixture.begin(&reducer, sequence: 2, time: 50), .clickCount(1))
    }

    func testEveryContextRevisionAndSourceChangeBreaksPairing() throws {
        let fixture = ClickFixture()
        let contexts = [
            fixture.changedContext(target: 1), fixture.changedContext(policy: 1),
            fixture.changedContext(activation: 1), fixture.changedContext(binding: 2),
            fixture.changedContext(topology: 2), fixture.changedContext(display: 2),
            fixture.changedContext(sourceGeneration: 2)
        ]
        for context in contexts {
            var reducer = try fixture.reducer()
            _ = fixture.begin(&reducer, sequence: 1, time: 0)
            fixture.finish(&reducer, sequence: 1, time: 0)
            XCTAssertEqual(reducer.begin(lease: fixture.lease(2, context: context), context: context,
                                         point: .init(x: 0, y: 0), receiptTime: 50, postTime: 60), .clickCount(1))
        }
    }

    func testMovementCancellationAndLongHoldCannotSeedPair() throws {
        let fixture = ClickFixture()
        for mode in 0..<3 {
            var reducer = try fixture.reducer()
            _ = fixture.begin(&reducer, sequence: 1, time: 0)
            reducer.recordDownResult(leaseID: fixture.lease(1).id, postInvoked: true)
            if mode == 0 { reducer.recordMovement(leaseID: fixture.lease(1).id) }
            if mode == 1 { reducer.cancel(leaseID: fixture.lease(1).id) }
            reducer.recordRelease(leaseID: fixture.lease(1).id, context: fixture.context,
                                  point: .init(x: 0, y: 0), receiptTime: mode == 2 ? 150 : 20,
                                  postTime: mode == 2 ? 160 : 30, postInvoked: true)
            XCTAssertTrue(reducer.completeCleanup(leaseID: fixture.lease(1).id))
            XCTAssertEqual(fixture.begin(&reducer, sequence: 2, time: mode == 2 ? 170 : 50), .clickCount(1))
        }
    }

    func testFailedDownNeedsCleanupAndDoesNotRequireUp() throws {
        let fixture = ClickFixture()
        var reducer = try fixture.reducer()
        _ = fixture.begin(&reducer, sequence: 1, time: 0)
        XCTAssertFalse(reducer.completeCleanup(leaseID: fixture.lease(1).id))
        reducer.recordDownResult(leaseID: fixture.lease(1).id, postInvoked: false)
        XCTAssertTrue(reducer.completeCleanup(leaseID: fixture.lease(1).id))
        XCTAssertEqual(fixture.begin(&reducer, sequence: 2, time: 50), .clickCount(1))
    }

    func testFailedReleaseCannotBeForgivenByRetryOrCleanup() throws {
        let fixture = ClickFixture()
        var reducer = try fixture.reducer()
        _ = fixture.begin(&reducer, sequence: 1, time: 0)
        fixture.release(&reducer, sequence: 1, time: 0, postInvoked: false)
        fixture.release(&reducer, sequence: 1, time: 0, postInvoked: true)
        XCTAssertFalse(reducer.completeCleanup(leaseID: fixture.lease(1).id))
        XCTAssertEqual(reducer.activeLeaseID, fixture.lease(1).id)
        XCTAssertEqual(fixture.begin(&reducer, sequence: 2, time: 50), .rejected)
    }

    func testStaleCallbacksCannotChangeNewerPress() throws {
        let fixture = ClickFixture()
        var reducer = try fixture.reducer()
        _ = fixture.begin(&reducer, sequence: 1, time: 0)
        fixture.finish(&reducer, sequence: 1, time: 0)
        XCTAssertEqual(fixture.begin(&reducer, sequence: 2, time: 50), .clickCount(2))
        reducer.cancel(leaseID: fixture.lease(1).id)
        reducer.recordMovement(leaseID: fixture.lease(1).id)
        XCTAssertEqual(fixture.begin(&reducer, sequence: 1, time: 0), .rejected)
        XCTAssertFalse(reducer.completeCleanup(leaseID: fixture.lease(1).id))
        XCTAssertEqual(reducer.activeLeaseID, fixture.lease(2).id)
        fixture.finish(&reducer, sequence: 2, time: 50)
        XCTAssertNil(reducer.activeLeaseID)
    }

    func testStaleBeginCannotInvalidateNewFirstClick() throws {
        let fixture = ClickFixture()
        var reducer = try fixture.reducer()
        _ = fixture.begin(&reducer, sequence: 1, time: 0)
        fixture.finish(&reducer, sequence: 1, time: 0)
        XCTAssertEqual(fixture.begin(&reducer, sequence: 2, time: 200), .clickCount(1))
        XCTAssertEqual(fixture.begin(&reducer, sequence: 1, time: 0), .rejected)
        fixture.finish(&reducer, sequence: 2, time: 200)
        XCTAssertEqual(fixture.begin(&reducer, sequence: 3, time: 250), .clickCount(2))
    }

    func testMismatchedSourceAndInvalidNumbersFailClosed() throws {
        let fixture = ClickFixture()
        var reducer = try fixture.reducer()
        XCTAssertEqual(reducer.begin(lease: fixture.lease(1), context: fixture.changedContext(sourceGeneration: 2),
                                     point: .init(x: 0, y: 0), receiptTime: 0, postTime: 10), .rejected)
        XCTAssertEqual(fixture.begin(&reducer, sequence: 2, time: 0, point: .init(x: .nan, y: 0)), .rejected)
        XCTAssertEqual(reducer.begin(lease: fixture.lease(3), context: fixture.context,
                                     point: .init(x: 0, y: 0), receiptTime: 10, postTime: 9), .rejected)
        XCTAssertNil(reducer.activeLeaseID)
    }

    func testOwnerSessionAndRepeatedLogicalContactCannotPair() throws {
        let fixture = ClickFixture()
        var reducer = try fixture.reducer()
        _ = fixture.begin(&reducer, sequence: 1, time: 0)
        fixture.finish(&reducer, sequence: 1, time: 0)
        let reused = ExperimentalOwnerLease(id: fixture.lease(2).id,
                                            contact: fixture.lease(1).contact, route: fixture.context.route)
        XCTAssertEqual(reducer.begin(lease: reused, context: fixture.context, point: .init(x: 0, y: 0),
                                     receiptTime: 50, postTime: 60), .clickCount(1))

        var other = try fixture.reducer()
        _ = fixture.begin(&other, sequence: 1, time: 0)
        fixture.finish(&other, sequence: 1, time: 0)
        let newOwner = ExperimentalOwnerLease(id: .init(sessionID: UUID(), generation: 1),
                                              contact: fixture.lease(2).contact, route: fixture.context.route)
        XCTAssertEqual(other.begin(lease: newOwner, context: fixture.context, point: .init(x: 0, y: 0),
                                   receiptTime: 50, postTime: 60), .rejected)
    }

    func testNextDownCannotPairWithTimestampsBeforePreviousRelease() throws {
        let fixture = ClickFixture()
        var reducer = try fixture.reducer()
        _ = fixture.begin(&reducer, sequence: 1, time: 100)
        reducer.recordDownResult(leaseID: fixture.lease(1).id, postInvoked: true)
        reducer.recordRelease(leaseID: fixture.lease(1).id, context: fixture.context, point: .init(x: 0, y: 0),
                              receiptTime: 200, postTime: 210, postInvoked: true)
        XCTAssertTrue(reducer.completeCleanup(leaseID: fixture.lease(1).id))
        XCTAssertEqual(fixture.begin(&reducer, sequence: 2, time: 150), .clickCount(1))
    }

    func testInvalidPoliciesAreRejected() {
        XCTAssertThrowsError(try ExperimentalDoubleClickPolicy(intervalNanoseconds: 0, maximumDistance: 10))
        for distance in [-1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try ExperimentalDoubleClickPolicy(intervalNanoseconds: 100, maximumDistance: distance))
        }
    }
}

private struct ClickFixture {
    let sourceSession = UUID()
    let ownerSession = UUID()
    var context: ExperimentalInteractionContext { changedContext() }

    func changedContext(target: UInt64 = 0, policy: UInt64 = 0, activation: UInt64 = 0,
                        binding: UInt64 = 1, topology: UInt64 = 1, display: UInt32 = 1,
                        sourceGeneration: UInt64 = 1) -> ExperimentalInteractionContext {
        ExperimentalInteractionContext(
            source: .init(sessionID: sourceSession, registrationGeneration: sourceGeneration),
            route: .init(bindingID: "test-panel", bindingRevision: binding,
                         topologyRevision: topology, displayID: display),
            targetContextRevision: target, policyRevision: policy, activationRevision: activation)
    }

    func lease(_ sequence: UInt64, context supplied: ExperimentalInteractionContext? = nil) -> ExperimentalOwnerLease {
        let current = supplied ?? context
        return .init(id: .init(sessionID: ownerSession, generation: sequence),
                     contact: .init(source: current.source, contactSequence: sequence), route: current.route)
    }

    func reducer() throws -> ExperimentalDoubleClickReducer {
        .init(policy: try .init(intervalNanoseconds: 100, maximumDistance: 10))
    }

    func begin(_ reducer: inout ExperimentalDoubleClickReducer, sequence: UInt64, time: UInt64,
               point: ExperimentalGesturePoint = .init(x: 0, y: 0)) -> ExperimentalClickDecision {
        reducer.begin(lease: lease(sequence), context: context, point: point, receiptTime: time, postTime: time + 10)
    }

    func release(_ reducer: inout ExperimentalDoubleClickReducer, sequence: UInt64, time: UInt64,
                 postInvoked: Bool = true) {
        reducer.recordDownResult(leaseID: lease(sequence).id, postInvoked: true)
        reducer.recordRelease(leaseID: lease(sequence).id, context: context, point: .init(x: 0, y: 0),
                              receiptTime: time + 20, postTime: time + 30, postInvoked: postInvoked)
    }

    func finish(_ reducer: inout ExperimentalDoubleClickReducer, sequence: UInt64, time: UInt64) {
        release(&reducer, sequence: sequence, time: time)
        XCTAssertTrue(reducer.completeCleanup(leaseID: lease(sequence).id))
    }
}
