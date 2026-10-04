import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

/// These tests enter the same owned-buffer callback, registration-local parser,
/// observation admission, controller and watchdog path as production. No hardware,
/// Accessibility requests, real input, installed driver or wall-clock sleeps occur.
final class StationaryHoldLivenessTests: XCTestCase {
    func testRecordedStationaryHoldRenewsWithoutNormalizedMoves() {
        onMain {
            let f = HoldFixture(configuration: .defaults)
            let source = f.makeSource()
            let offsets = RecordedStationaryHold.relativeNanoseconds
            XCTAssertEqual(offsets.count, 495)
            XCTAssertEqual(offsets[493], 4_088_022_208)
            XCTAssertEqual(offsets[494], 4_095_995_458)

            // The original integers remain authoritative. Construct every
            // receipt once; native DispatchTime alone supplies tick precision.
            let receipts = offsets.map { DispatchTime(uptimeNanoseconds: $0) }
            for (offset, receipt) in zip(offsets.dropLast(), receipts.dropLast()) {
                f.advance(to: receipt)
                source.report(RecordedStationaryHold.pressedPacket, timestamp: receipt)
                XCTAssertTrue(f.effects.ups.isEmpty, "Premature up at exact callback offset \(offset)")
                XCTAssertTrue(f.effects.releases.isEmpty)
                XCTAssertTrue(f.effects.restores.isEmpty)
            }
            let releaseReceipt = receipts.last!
            let releaseTime = releaseReceipt.uptimeNanoseconds
            f.advanceBefore(releaseReceipt)
            XCTAssertEqual(f.effects.downs, [f.point(8_457, 5_901)])
            XCTAssertEqual(f.effects.borrows, [f.point(8_457, 5_901)])
            XCTAssertTrue(f.effects.drags.isEmpty)
            XCTAssertTrue(f.effects.updates.isEmpty)
            XCTAssertEqual(f.focus.preparationCount, 1)
            XCTAssertEqual(f.focus.semanticBoundaryCount, 0)
            XCTAssertEqual(f.normalizedKinds, [.down])

            f.advance(to: releaseReceipt)
            source.report(RecordedStationaryHold.releasedPacket, timestamp: releaseReceipt)
            XCTAssertEqual(f.normalizedKinds, [.down, .up])
            XCTAssertEqual(f.observations.count, 495)
            XCTAssertEqual(f.observations.filter { $0.observation.isPressed }.count, 494)
            XCTAssertEqual(f.observations.filter { !$0.observation.isPressed }.count, 1)
            XCTAssertEqual(f.observations.filter { $0.observation.event == nil }.count, 493)
            XCTAssertEqual(Set(f.observations.map { $0.observation.sourceID }).count, 1)
            XCTAssertEqual(f.observations.map { $0.observation.timestamp }, receipts)
            XCTAssertEqual(Set(f.observations.map { $0.observation.contactEpoch }).count, 1)
            XCTAssertEqual(f.focus.semanticBoundaryCount, 1)
            XCTAssertTrue(f.effects.ups.isEmpty)
            let mouseUpDeadline = DispatchTime(uptimeNanoseconds: releaseTime + 20_000_000)
            f.advanceBefore(mouseUpDeadline)
            XCTAssertTrue(f.effects.ups.isEmpty)
            f.advance(to: mouseUpDeadline)
            XCTAssertEqual(f.effects.ups, [f.point(8_457, 5_901)])
            XCTAssertTrue(f.effects.releases.isEmpty)
            let cursorReturnDeadline = DispatchTime(uptimeNanoseconds: mouseUpDeadline.uptimeNanoseconds + 10_000_000)
            f.advanceBefore(cursorReturnDeadline)
            XCTAssertTrue(f.effects.releases.isEmpty)
            f.advance(to: cursorReturnDeadline)
            XCTAssertEqual(f.effects.releases, [true])
            XCTAssertEqual(f.effects.restores, [0])
            let point = f.point(8_457, 5_901)
            XCTAssertEqual(f.effects.events, [
                .prepare, .borrow(point), .down(point, .postInvoked), .inputEnded,
                .up(point, .postInvoked), .release(true), .restore(0)
            ])
            let completed = f.effects.events
            f.clock.advance(byMilliseconds: 3_000)
            XCTAssertEqual(f.effects.events, completed, "Canceled watchdogs must remain inert")
            f.effects.assertBalanced()
        }
    }

    func testSilentOwnerExpiresFromLastProcessedHeartbeat() {
        onMain {
            let f = HoldFixture()
            let source = f.makeSource()
            for offset in RecordedStationaryHold.relativeNanoseconds.dropLast() {
                // Retain the original integer offset; DispatchTime supplies the
                // platform's representable Mach-tick projection to production.
                let receipt = DispatchTime(uptimeNanoseconds: offset)
                f.advance(to: receipt)
                source.report(RecordedStationaryHold.pressedPacket, timestamp: receipt)
            }
            let lastReceipt = DispatchTime(uptimeNanoseconds: RecordedStationaryHold.relativeNanoseconds[493])
            let expiry = DispatchTime(uptimeNanoseconds: lastReceipt.uptimeNanoseconds + 2_000_000_000)
            f.advanceBefore(expiry)
            XCTAssertTrue(f.effects.ups.isEmpty)
            f.advance(to: expiry)
            XCTAssertEqual(f.effects.downs.count, 1)
            XCTAssertEqual(f.effects.ups.count, 1)
            XCTAssertEqual(f.effects.releases, [true])
            XCTAssertTrue(f.effects.restores.isEmpty, "Timeout must discard captured focus")
            let expired = f.effects.events
            let scheduled = f.clock.scheduledTaskCount
            source.pressed(at: f.clock.now)
            f.clock.advance(byMilliseconds: 2_000)
            source.pressed(at: f.clock.now)
            XCTAssertEqual(f.effects.events, expired)
            XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
            source.released(at: f.clock.now)
            source.pressed(at: f.clock.now)
            source.released(at: f.clock.now)
            XCTAssertEqual(f.effects.downs.count, 2)
            XCTAssertEqual(f.effects.ups.count, 2)
            XCTAssertEqual(f.effects.releases, [true, true])
            f.effects.assertBalanced()
        }
    }

    func testHeartbeatWinsAgainstDeliveredCanceledTimeout() {
        onMain {
            for equalDeadline in [false, true] {
                let f = HoldFixture(timeout: 100)
                let source = f.makeSource()
                source.pressed(at: f.clock.now)
                let heartbeatTime = DispatchTime(uptimeNanoseconds: equalDeadline ? 100_000_000 : 99_000_000)
                let originalDeadline = DispatchTime(uptimeNanoseconds: 100_000_000)
                if equalDeadline {
                    XCTAssertEqual(heartbeatTime, originalDeadline)
                } else {
                    XCTAssertLessThan(heartbeatTime.uptimeNanoseconds, originalDeadline.uptimeNanoseconds)
                }
                f.clock.advance(toNanoseconds: heartbeatTime.uptimeNanoseconds, beforeDueActions: {
                    source.pressed(at: heartbeatTime)
                })
                f.advance(to: originalDeadline)
                XCTAssertTrue(f.effects.ups.isEmpty, "Heartbeat-first invalidates even a delivered canceled timer")
                let refreshedDeadline = DispatchTime(uptimeNanoseconds: heartbeatTime.uptimeNanoseconds + 100_000_000)
                f.advanceBefore(refreshedDeadline)
                XCTAssertTrue(f.effects.ups.isEmpty)
                f.advance(to: refreshedDeadline)
                XCTAssertEqual(f.effects.ups.count, 1)
                XCTAssertEqual(f.normalizedKinds, [.down])
                XCTAssertTrue(f.effects.drags.isEmpty)
            }
        }
    }

    func testTimeoutWinsAgainstQueuedOldHeartbeat() {
        onMain {
            for receiptNS: UInt64 in [99_999_000, 100_000_000, 100_001_000] {
                let f = HoldFixture(timeout: 100)
                let source = f.makeSource()
                source.pressed(at: f.clock.now)
                f.deliverObservations = false
                let receipt = DispatchTime(uptimeNanoseconds: receiptNS)
                let deadline = DispatchTime(uptimeNanoseconds: 100_000_000)
                if receiptNS < 100_000_000 {
                    XCTAssertLessThan(receipt.uptimeNanoseconds, deadline.uptimeNanoseconds)
                } else if receiptNS > 100_000_000 {
                    XCTAssertGreaterThan(receipt.uptimeNanoseconds, deadline.uptimeNanoseconds)
                } else {
                    XCTAssertEqual(receipt, deadline)
                }
                source.pressed(at: receipt)
                let queued = f.observations.last!
                XCTAssertEqual(queued.observation.timestamp, receipt)
                f.advance(to: deadline)
                XCTAssertEqual(f.effects.ups.count, 1)
                let terminal = f.effects.events
                let scheduled = f.clock.scheduledTaskCount
                f.route(queued)
                f.clock.advance(byMilliseconds: 1_000)
                XCTAssertEqual(f.effects.events, terminal)
                XCTAssertEqual(f.clock.scheduledTaskCount, scheduled,
                               "Receipt time does not resurrect a timeout already committed on the queue")
            }
        }
    }

    func testOldSessionCannotRefreshSameIDReplacement() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let source = f.makeSource()
            source.pressed(at: f.clock.now)
            source.pressed(at: f.clock.now)
            let oldHeartbeat = f.observations.last!
            f.clock.advance(toMilliseconds: 10)
            f.application.cancelActiveGesture()
            source.released(at: f.clock.now)
            let oldUp = f.observations.last!
            source.pressed(at: f.clock.now)
            XCTAssertNotEqual(oldHeartbeat.observation.contactEpoch, f.observations.last!.observation.contactEpoch)
            let replacement = f.effects.events
            let scheduled = f.clock.scheduledTaskCount
            f.clock.advance(toMilliseconds: 50)
            f.route(oldHeartbeat)
            f.route(oldUp)
            XCTAssertEqual(f.effects.events, replacement)
            XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
            f.clock.advance(toMilliseconds: 100) // Old canceled timeout.
            XCTAssertEqual(f.effects.ups.count, 1)
            f.clock.advance(toMilliseconds: 110) // New generation's unchanged expiry.
            XCTAssertEqual(f.effects.ups.count, 2)
            XCTAssertEqual(f.effects.releases, [true, true])
            f.effects.assertBalanced()
        }
    }

    func testRejectedContactsNeverOwnHeartbeatWhenMappingIsMissingOrAmbiguous() {
        onMain {
            for ambiguous in [false, true] {
                let f = HoldFixture(timeout: 100)
                f.displays.values = ambiguous ? [holdDisplay(), holdDisplay(id: 43)] : []
                let source = f.makeSource()
                source.pressed(at: f.clock.now)
                let rejected = f.effects.events
                let scheduled = f.clock.scheduledTaskCount
                f.displays.values = [holdDisplay()]
                f.application.handleDeviceMatched()
                for time: UInt64 in [10, 100, 200] {
                    f.clock.advance(toMilliseconds: time)
                    source.pressed(at: f.clock.now)
                }
                XCTAssertEqual(f.effects.events, rejected)
                XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
                XCTAssertEqual(f.focus.preparationCount, 0)
                XCTAssertTrue(f.effects.borrows.isEmpty)
                source.released(at: f.clock.now)
                source.pressed(at: f.clock.now)
                source.released(at: f.clock.now)
                XCTAssertEqual(f.effects.downs.count, 1)
                f.effects.assertBalanced()
            }
        }
    }

    func testRejectedDebouncedContactCannotAcquireLivenessAfterDebounceElapses() {
        onMain {
            var configuration = holdConfiguration(timeout: 100)
            configuration.timing.tapDebounceMs = 50
            let f = HoldFixture(configuration: configuration)
            let source = f.makeSource()
            source.pressed(at: f.clock.now)
            source.released(at: f.clock.now)
            f.clock.advance(toMilliseconds: 1)
            source.pressed(at: f.clock.now)
            let rejected = f.effects.events
            let scheduled = f.clock.scheduledTaskCount
            f.clock.advance(toMilliseconds: 100)
            source.pressed(at: f.clock.now)
            XCTAssertEqual(f.effects.events, rejected)
            XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
            source.released(at: f.clock.now)
            source.pressed(at: f.clock.now)
            source.released(at: f.clock.now)
            XCTAssertEqual(f.effects.downs.count, 2)
            XCTAssertEqual(f.focus.preparationCount, 2)
            f.effects.assertBalanced()
        }
    }

    func testRejectedHeldContactCannotTakeOverAfterOwnerCleanup() {
        onMain {
            var configuration = holdConfiguration(timeout: 500)
            configuration.timing.downToUpDelayMs = 20
            configuration.timing.clickToWarpBackDelayMs = 100
            let f = HoldFixture(configuration: configuration)
            let source = f.makeSource()
            source.pressed(at: f.clock.now)
            source.released(at: f.clock.now)
            f.clock.advance(toMilliseconds: 10)
            source.pressed(at: f.clock.now) // Epoch 2 overlaps epoch 1's cleanup lease.
            f.clock.advance(toMilliseconds: 130)
            let completed = f.effects.events
            let scheduled = f.clock.scheduledTaskCount
            source.pressed(at: f.clock.now)
            f.clock.advance(toMilliseconds: 600)
            source.pressed(at: f.clock.now)
            XCTAssertEqual(f.effects.events, completed)
            XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
            XCTAssertEqual(f.effects.downs.count, 1)
            source.released(at: f.clock.now)
            source.pressed(at: f.clock.now)
            source.released(at: f.clock.now)
            f.clock.advance(byMilliseconds: 120)
            XCTAssertEqual(f.effects.downs.count, 2)
            XCTAssertEqual(f.effects.releases, [true, true])
            f.effects.assertBalanced()
        }
    }

    func testFailedBorrowAndDownCannotAcquireHeartbeatOwnership() {
        onMain {
            for failedBorrow in [false, true] {
                let f = HoldFixture(timeout: 100)
                f.cursor.borrowSucceeds = !failedBorrow
                f.input.downResult = failedBorrow ? .postInvoked : .constructionFailed
                let source = f.makeSource()
                source.pressed(at: f.clock.now)
                let failed = f.effects.events
                let scheduled = f.clock.scheduledTaskCount
                f.cursor.borrowSucceeds = true
                f.input.downResult = .postInvoked
                for time: UInt64 in [50, 100, 200] {
                    f.clock.advance(toMilliseconds: time)
                    source.pressed(at: f.clock.now)
                }
                XCTAssertEqual(f.effects.events, failed)
                XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
                XCTAssertTrue(f.effects.ups.isEmpty)
                XCTAssertTrue(f.effects.restores.isEmpty)
                XCTAssertEqual(f.focus.preparationCount, 1)
                source.released(at: f.clock.now)
                source.pressed(at: f.clock.now)
                source.released(at: f.clock.now)
                XCTAssertEqual(f.effects.successfulDowns.count, 1)
                XCTAssertEqual(f.effects.ups.count, 1)
                f.effects.assertBalanced()
            }
        }
    }

    func testReleaseBlockedContactCannotRenewOrRetryAfterPermanentContractViolation() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let source = f.makeSource()
            f.input.upResult = .constructionFailed
            source.pressed(at: f.clock.now)
            source.released(at: f.clock.now)
            let blocked = f.effects.events
            let scheduled = f.clock.scheduledTaskCount
            source.pressed(at: f.clock.now)
            source.pressed(at: f.clock.now)
            source.released(at: f.clock.now)
            f.clock.advance(byMilliseconds: 1_000)
            XCTAssertEqual(f.effects.events, blocked)
            XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
            XCTAssertEqual(f.effects.downs.count, 1)
            XCTAssertEqual(f.effects.ups.count, 1)
            XCTAssertEqual(f.effects.releases, [false])
            XCTAssertTrue(f.effects.restores.isEmpty)
        }
    }

    func testAcceptedUpSealsHeartbeatBeforeFocusReentryAndKeepsFixedCleanupBound() {
        onMain {
            var configuration = holdConfiguration(timeout: 100)
            configuration.timing.downToUpDelayMs = 500
            configuration.timing.clickToWarpBackDelayMs = 500
            let f = HoldFixture(configuration: configuration)
            let source = f.makeSource()
            source.pressed(at: f.clock.now)
            source.pressed(at: f.clock.now)
            let heartbeat = f.observations.last!
            var schedulesAroundReentry: (Int, Int)?
            f.focus.onInputEnd = {
                f.focus.onInputEnd = nil
                let before = f.clock.scheduledTaskCount
                f.route(heartbeat)
                schedulesAroundReentry = (before, f.clock.scheduledTaskCount)
            }
            f.clock.advance(toMilliseconds: 50)
            source.released(at: f.clock.now)
            XCTAssertEqual(schedulesAroundReentry?.0, schedulesAroundReentry?.1)
            XCTAssertEqual(f.focus.semanticBoundaryCount, 1)
            let scheduled = f.clock.scheduledTaskCount
            for time: UInt64 in [75, 100, 149] {
                f.clock.advance(toMilliseconds: time)
                f.route(heartbeat)
                source.released(at: f.clock.now)
            }
            XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
            XCTAssertTrue(f.effects.ups.isEmpty)
            f.clock.advance(toMilliseconds: 150)
            XCTAssertEqual(f.effects.ups.count, 1, "Fixed cleanup expiry is accepted-up plus 100 ms")
            XCTAssertEqual(f.effects.releases, [true])
            XCTAssertTrue(f.effects.restores.isEmpty, "Forced cleanup must revoke focus eligibility")
            let finished = f.effects.events
            f.clock.advance(toMilliseconds: 1_000)
            XCTAssertEqual(f.effects.events, finished)
            f.effects.assertBalanced()
        }
    }

    func testHeartbeatDoesNotFlushFocusPreparationOrChangeItsDeadline() {
        onMain {
            let f = HoldFixture(timeout: 100)
            f.focus.holdPreparation = true
            let source = f.makeSource()
            source.pressed(at: f.clock.now)
            for time: UInt64 in [1, 8, 16, 24, 29] {
                f.clock.advance(toMilliseconds: time)
                source.pressed(at: f.clock.now)
                XCTAssertTrue(f.effects.borrows.isEmpty)
                XCTAssertTrue(f.effects.downs.isEmpty)
                XCTAssertEqual(f.focus.preparationCount, 1)
            }
            let preparationDeadline = DispatchTime(uptimeNanoseconds: 30_000_000)
            f.advanceBefore(preparationDeadline)
            XCTAssertTrue(f.effects.downs.isEmpty)
            f.advance(to: preparationDeadline)
            XCTAssertEqual(f.effects.downs.count, 1)
            XCTAssertEqual(f.effects.borrows.count, 1)
            let prepared = f.effects.events
            f.focus.complete(0)
            XCTAssertEqual(f.effects.events, prepared, "Late capture must remain stale")
            source.released(at: f.clock.now)
            XCTAssertTrue(f.effects.restores.isEmpty)
            XCTAssertTrue(f.effects.drags.isEmpty)
            f.effects.assertBalanced()
        }
    }

    func testPreparationCompletionStillWinsNormallyWithHeartbeatOnlyInput() {
        onMain {
            let f = HoldFixture(timeout: 100)
            f.focus.holdPreparation = true
            let source = f.makeSource()
            source.pressed(at: f.clock.now)
            f.clock.advance(toMilliseconds: 10)
            source.pressed(at: f.clock.now)
            f.focus.complete(0)
            XCTAssertEqual(f.effects.downs.count, 1)
            f.clock.advance(toMilliseconds: 30)
            XCTAssertEqual(f.effects.downs.count, 1)
            source.released(at: f.clock.now)
            XCTAssertEqual(f.effects.restores, [0])
            f.effects.assertBalanced()
        }
    }

    func testDownAcceptanceBindsBeforeReentrantFocusPreparationUp() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let source = f.makeSource()
            f.focus.onPrepare = {
                f.focus.onPrepare = nil
                source.released(at: f.clock.now)
            }
            source.pressed(at: f.clock.now)
            XCTAssertEqual(f.normalizedKinds, [.down, .up])
            XCTAssertEqual(f.effects.downs.count, 1)
            XCTAssertEqual(f.effects.ups.count, 1)
            XCTAssertEqual(f.effects.releases, [true])
            XCTAssertEqual(f.focus.semanticBoundaryCount, 1)
            let finished = f.effects.events
            f.clock.advance(byMilliseconds: 500)
            XCTAssertEqual(f.effects.events, finished)
            f.effects.assertBalanced()
        }
    }

    func testDownAcceptanceBindsBeforeReentrantBorrowUp() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let source = f.makeSource()
            f.cursor.onBorrow = {
                f.cursor.onBorrow = nil
                source.released(at: f.clock.now)
            }
            source.pressed(at: f.clock.now)
            XCTAssertEqual(f.normalizedKinds, [.down, .up])
            XCTAssertEqual(f.effects.borrows.count, 1)
            XCTAssertEqual(f.effects.downs.count, 1)
            XCTAssertEqual(f.effects.ups.count, 1)
            XCTAssertEqual(f.effects.releases, [true])
            let finished = f.effects.events
            f.clock.advance(byMilliseconds: 500)
            XCTAssertEqual(f.effects.events, finished)
            f.effects.assertBalanced()
        }
    }

    func testAcceptedUpWhileMouseDownIsInFlightSealsHeartbeatBeforeFocusReentry() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let source = f.makeSource()
            f.input.onDown = {
                f.input.onDown = nil
                source.pressed(at: f.clock.now)
                let heartbeat = f.observations.last!
                f.focus.onInputEnd = {
                    f.focus.onInputEnd = nil
                    let before = f.clock.scheduledTaskCount
                    f.route(heartbeat)
                    XCTAssertEqual(f.clock.scheduledTaskCount, before)
                }
                source.released(at: f.clock.now)
            }
            source.pressed(at: f.clock.now)
            XCTAssertEqual(f.effects.downs.count, 1)
            XCTAssertEqual(f.effects.ups.count, 1)
            XCTAssertEqual(f.effects.releases, [true])
            XCTAssertEqual(f.focus.semanticBoundaryCount, 1)
            let finished = f.effects.events
            f.clock.advance(byMilliseconds: 500)
            XCTAssertEqual(f.effects.events, finished)
            f.effects.assertBalanced()
        }
    }

    func testReentrantCancellationAtEverySideEffectCannotAttachOuterWatchdog() {
        onMain {
            for effect in ["prepare", "borrow", "down", "up"] {
                let f = HoldFixture(timeout: 100)
                let source = f.makeSource()
                var cancelled = false
                let cancel = {
                    guard !cancelled else { return }
                    cancelled = true
                    f.application.cancelActiveGesture()
                }
                if effect == "prepare" { f.focus.onPrepare = cancel }
                if effect == "borrow" { f.cursor.onBorrow = cancel }
                if effect == "down" { f.input.onDown = cancel }
                if effect == "up" { f.input.onUp = cancel }
                source.pressed(at: f.clock.now)
                if effect == "up" { source.released(at: f.clock.now) }
                f.focus.onPrepare = nil
                f.cursor.onBorrow = nil
                f.input.onDown = nil
                f.input.onUp = nil
                let terminal = f.effects.events
                let scheduled = f.clock.scheduledTaskCount
                if effect != "up" { source.pressed(at: f.clock.now) }
                f.clock.advance(byMilliseconds: 1_000)
                XCTAssertEqual(f.effects.events, terminal, effect)
                XCTAssertEqual(f.clock.scheduledTaskCount, scheduled, effect)
                XCTAssertLessThanOrEqual(f.effects.successfulDowns.count, 1, effect)
                XCTAssertLessThanOrEqual(f.effects.ups.count, 1, effect)
                f.effects.assertBalanced()
            }
        }
    }

    func testDisplayCancellationIsTerminalForHeldSession() {
        onMain {
            for change in ["begin", "remove", "ambiguous", "move"] {
                let f = HoldFixture(timeout: 100)
                let source = f.makeSource()
                source.pressed(at: f.clock.now)
                if change == "remove" { f.displays.values = [] }
                if change == "ambiguous" { f.displays.values = [holdDisplay(), holdDisplay(id: 43)] }
                if change == "move" { f.displays.values = [holdDisplay(origin: CGPoint(x: -200, y: 900))] }
                f.application.handleDisplayReconfiguration(flags: change == "begin" ? .beginConfigurationFlag : .movedFlag)
                XCTAssertEqual(f.effects.ups.count, 1, change)
                XCTAssertEqual(f.effects.releases, [true], change)
                XCTAssertTrue(f.effects.restores.isEmpty, change)
                f.displays.values = [holdDisplay(origin: CGPoint(x: -200, y: 900))]
                f.application.handleDisplayReconfiguration(flags: [])
                let terminal = f.effects.events
                let scheduled = f.clock.scheduledTaskCount
                source.pressed(at: f.clock.now)
                f.clock.advance(byMilliseconds: 1_000)
                source.pressed(at: f.clock.now)
                XCTAssertEqual(f.effects.events, terminal, change)
                XCTAssertEqual(f.clock.scheduledTaskCount, scheduled, change)
                source.released(at: f.clock.now)
                source.pressed(at: f.clock.now)
                source.released(at: f.clock.now)
                XCTAssertEqual(f.effects.downs.last, CGPoint(x: -200, y: 900), change)
                XCTAssertEqual(f.effects.downs.count, 2, change)
                f.effects.assertBalanced()
            }
        }
    }

    func testDefaultDashboardRestorationMatrix() {
        onMain {
            let options: [(Bool?, Bool?)] = [(nil, nil), (true, true), (true, false), (false, true), (false, false)]
            for (focus, cursor) in options {
                for scenario in ["tap", "hold", "drag", "cancel"] {
                    var configuration = DriverConfiguration.defaults
                    if let focus { configuration.focus.restorePreviousWindow = focus }
                    if let cursor { configuration.cursor.returnToPreviousPosition = cursor }
                    let f = HoldFixture(configuration: configuration)
                    let source = f.makeSource()
                    source.pressed(at: f.clock.now)
                    XCTAssertTrue(f.effects.downs.isEmpty, "Default 10 ms warp delay is unchanged")
                    f.clock.advance(toMilliseconds: 10)
                    XCTAssertEqual(f.effects.downs.count, 1)
                    if scenario == "hold" || scenario == "cancel" {
                        for time: UInt64 in [500, 1_000, 1_500, 2_000, 2_500] {
                            f.clock.advance(toMilliseconds: time)
                            source.pressed(at: f.clock.now)
                        }
                    }
                    if scenario == "drag" {
                        source.pressed(at: f.clock.now, x: 2_000, y: 1_000)
                        XCTAssertEqual(f.effects.drags, [f.point(2_000, 1_000)])
                    }
                    let endedAt = f.clock.now.uptimeNanoseconds
                    if scenario == "cancel" {
                        f.application.cancelActiveGesture()
                        XCTAssertEqual(f.effects.ups.count, 1)
                    } else {
                        source.released(at: f.clock.now, x: scenario == "drag" ? 2_000 : 0,
                                        y: scenario == "drag" ? 1_000 : 0)
                        XCTAssertEqual(f.effects.ups.count, scenario == "drag" ? 1 : 0)
                    }
                    f.clock.advance(toNanoseconds: endedAt + 30_000_000)
                    XCTAssertEqual(f.effects.downs.count, 1)
                    XCTAssertEqual(f.effects.ups.count, 1)
                    XCTAssertEqual(f.effects.releases, [cursor ?? true])
                    XCTAssertEqual(f.focus.preparationCount, (focus ?? true) ? 1 : 0)
                    XCTAssertEqual(f.effects.restores, (focus ?? true) && scenario != "cancel" ? [0] : [])
                    XCTAssertEqual(f.effects.drags.count, scenario == "drag" ? 1 : 0)
                    XCTAssertEqual(f.effects.updates.count, scenario == "drag" ? 1 : 0)
                    let completed = f.effects.events
                    f.clock.advance(byMilliseconds: 3_000)
                    XCTAssertEqual(f.effects.events, completed)
                    f.effects.assertBalanced()
                }
            }
        }
    }

    func testForeignReportsCannotMutateOwnerParserOrGesture() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let owner = f.makeSource()
            let foreign = f.makeSource(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
            owner.pressed(at: f.clock.now)
            f.clock.advance(toMilliseconds: 40)
            foreign.released(at: f.clock.now)
            owner.pressed(at: f.clock.now)
            XCTAssertEqual(f.observations.filter { $0.observation.sourceID == owner.registration.sourceID }
                .compactMap { $0.observation.event?.kind }, [.down])
            let live = f.effects.events
            let scheduled = f.clock.scheduledTaskCount
            f.clock.advance(toMilliseconds: 50)
            foreign.pressed(at: f.clock.now, x: 10_000, y: 5_000)
            foreign.pressed(at: f.clock.now, x: 11_000, y: 5_500)
            foreign.released(at: f.clock.now)
            XCTAssertEqual(f.effects.events, live)
            XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
            XCTAssertEqual(f.focus.semanticBoundaryCount, 0)
            f.clock.advance(toMilliseconds: 139)
            XCTAssertTrue(f.effects.ups.isEmpty)
            f.clock.advance(toMilliseconds: 140)
            XCTAssertEqual(f.effects.ups, [f.point(0, 0)], "Only owner heartbeat at 40 ms renewed")
            XCTAssertTrue(f.effects.drags.isEmpty)
            XCTAssertTrue(f.effects.updates.isEmpty)
            f.effects.assertBalanced()
        }
    }

    func testOverlappingForeignContactStaysRejectedThroughItsOwnPhysicalUp() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let owner = f.makeSource()
            let foreign = f.makeSource(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
            owner.pressed(at: f.clock.now)
            foreign.pressed(at: f.clock.now, x: 100, y: 100)
            owner.released(at: f.clock.now)
            let completed = f.effects.events
            foreign.pressed(at: f.clock.now, x: 200, y: 200)
            f.clock.advance(byMilliseconds: 200)
            foreign.pressed(at: f.clock.now, x: 200, y: 200)
            XCTAssertEqual(f.effects.events, completed)
            owner.pressed(at: f.clock.now)
            owner.released(at: f.clock.now)
            XCTAssertEqual(f.effects.downs.count, 2, "A silent rejected source cannot starve the owner")
            foreign.released(at: f.clock.now, x: 200, y: 200)
            foreign.pressed(at: f.clock.now, x: 200, y: 200)
            foreign.released(at: f.clock.now, x: 200, y: 200)
            XCTAssertEqual(f.effects.downs, [f.point(0, 0), f.point(0, 0), f.point(200, 200)])
            f.effects.assertBalanced()
        }
    }

    func testFreshEndpointMayBeAdmittedAfterOwnerNormalCleanup() {
        onMain {
            let f = HoldFixture()
            let first = f.makeSource()
            let second = f.makeSource(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
            first.pressed(at: f.clock.now)
            first.released(at: f.clock.now)
            second.pressed(at: f.clock.now, x: 100, y: 100)
            second.released(at: f.clock.now, x: 100, y: 100)
            XCTAssertEqual(f.effects.downs, [f.point(0, 0), f.point(100, 100)])
            XCTAssertEqual(f.effects.ups, f.effects.downs)
            XCTAssertEqual(f.effects.releases, [true, true])
            f.effects.assertBalanced()
        }
    }

    func testNonownerRemovalCannotCancelOrResetOwnerParser() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let owner = f.makeSource()
            let other = f.makeSource(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
            owner.pressed(at: f.clock.now)
            other.pressed(at: f.clock.now, x: 10, y: 20) // Rejected, still held.
            let live = f.effects.events
            other.registration.invalidate()
            f.application.handleSourceRemoval(other.registration.sourceID)
            XCTAssertEqual(f.effects.events, live)
            f.clock.advance(toMilliseconds: 50)
            owner.pressed(at: f.clock.now)
            XCTAssertEqual(f.observations.filter { $0.observation.sourceID == owner.registration.sourceID }
                .compactMap { $0.observation.event?.kind }, [.down])
            f.clock.advance(toMilliseconds: 100)
            XCTAssertTrue(f.effects.ups.isEmpty)
            owner.released(at: f.clock.now)
            XCTAssertEqual(f.effects.ups.count, 1)
            XCTAssertEqual(f.effects.restores, [0])
            f.effects.assertBalanced()
        }
    }

    func testOwnerRemovalFencesQueuedHeartbeatsAndReusedSenderNeedsRelease() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let old = f.makeSource()
            old.pressed(at: f.clock.now)
            f.deliverObservations = false
            old.pressed(at: f.clock.now)
            let queued = f.observations.last!
            old.registration.invalidate()
            // A queued envelope is fenced even before the queue processes removal.
            let schedules = f.clock.scheduledTaskCount
            f.route(queued)
            XCTAssertEqual(f.clock.scheduledTaskCount, schedules)
            f.application.handleSourceRemoval(old.registration.sourceID)
            XCTAssertEqual(f.effects.ups.count, 1)
            XCTAssertTrue(f.effects.restores.isEmpty)
            let removed = f.effects.events
            f.route(queued)
            f.deliverObservations = true
            let replacement = f.makeSource(sender: old.sender)
            XCTAssertNotEqual(replacement.registration.sourceID, old.registration.sourceID)
            replacement.pressed(at: f.clock.now)
            replacement.pressed(at: f.clock.now)
            f.clock.advance(byMilliseconds: 200)
            XCTAssertEqual(f.effects.events, removed, "Reused sender cannot turn a still-held contact into a fresh down")
            replacement.released(at: f.clock.now)
            replacement.pressed(at: f.clock.now)
            let live = f.effects.events
            f.route(queued)
            XCTAssertEqual(f.effects.events, live)
            replacement.released(at: f.clock.now)
            XCTAssertEqual(f.effects.downs.count, 2)
            XCTAssertEqual(f.effects.ups.count, 2)
            f.effects.assertBalanced()
        }
    }

    func testIdleOrPhysicallyClosedOwnerRemovalDoesNotConsumeReplacementFirstTap() {
        onMain {
            for delayedCleanup in [false, true] {
                var configuration = holdConfiguration()
                configuration.timing.clickToWarpBackDelayMs = delayedCleanup ? 100 : 0
                let f = HoldFixture(configuration: configuration)
                let old = f.makeSource()
                old.pressed(at: f.clock.now)
                old.released(at: f.clock.now)
                old.registration.invalidate()
                f.application.handleSourceRemoval(old.registration.sourceID)
                let replacement = f.makeSource(sender: old.sender)
                replacement.pressed(at: f.clock.now)
                replacement.released(at: f.clock.now)
                f.clock.advance(byMilliseconds: 100)
                XCTAssertEqual(f.effects.downs.count, 2)
                XCTAssertEqual(f.effects.ups.count, 2)
                XCTAssertEqual(f.effects.releases, [true, true])
                f.effects.assertBalanced()
            }
        }
    }

    func testStopFencesQueuedObservationsAndRestartPreservesInterruptedHoldBarrier() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let old = f.makeSource()
            old.pressed(at: f.clock.now)
            f.deliverObservations = false
            old.pressed(at: f.clock.now)
            let queued = f.observations.last!
            old.registration.invalidate() // Production closes all ingress before its queue drain.
            f.application.handleHIDStop()
            let stopped = f.effects.events
            let scheduled = f.clock.scheduledTaskCount
            f.route(queued)
            f.clock.advance(byMilliseconds: 200)
            XCTAssertEqual(f.effects.events, stopped)
            XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
            f.deliverObservations = true
            let restart = f.makeSource(sender: old.sender)
            restart.pressed(at: f.clock.now)
            XCTAssertEqual(f.effects.events, stopped)
            restart.released(at: f.clock.now)
            restart.pressed(at: f.clock.now)
            restart.released(at: f.clock.now)
            XCTAssertEqual(f.effects.downs.count, 2)
            XCTAssertEqual(f.effects.ups.count, 2)
            XCTAssertEqual(f.effects.releases, [true, true])
            f.effects.assertBalanced()
        }
    }

    func testClosedEpochCannotBeReopenedByQueuedDownOrHeartbeat() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let source = f.makeSource()
            source.pressed(at: f.clock.now)
            let down = f.observations.last!
            source.pressed(at: f.clock.now)
            let heartbeat = f.observations.last!
            source.released(at: f.clock.now)
            let closed = f.effects.events
            let scheduled = f.clock.scheduledTaskCount
            f.route(down)
            f.route(heartbeat)
            f.clock.advance(byMilliseconds: 200)
            XCTAssertEqual(f.effects.events, closed)
            XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
            source.pressed(at: f.clock.now)
            source.released(at: f.clock.now)
            XCTAssertEqual(f.effects.downs.count, 2)
            f.effects.assertBalanced()
        }
    }

    func testForeignDownReenteringEveryAcceptanceSideEffectCannotStealOwnership() {
        onMain {
            for effect in ["prepare", "borrow", "down", "up"] {
                let f = HoldFixture(timeout: 100)
                let owner = f.makeSource()
                let foreign = f.makeSource(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
                var injected = false
                let inject = {
                    guard !injected else { return }
                    injected = true
                    foreign.pressed(at: f.clock.now, x: 5_000, y: 5_000)
                }
                if effect == "prepare" { f.focus.onPrepare = inject }
                if effect == "borrow" { f.cursor.onBorrow = inject }
                if effect == "down" { f.input.onDown = inject }
                if effect == "up" { f.input.onUp = inject }
                owner.pressed(at: f.clock.now)
                owner.released(at: f.clock.now)
                f.focus.onPrepare = nil
                f.cursor.onBorrow = nil
                f.input.onDown = nil
                f.input.onUp = nil
                foreign.pressed(at: f.clock.now, x: 6_000, y: 6_000)
                XCTAssertEqual(f.effects.downs, [f.point(0, 0)], effect)
                XCTAssertEqual(f.effects.ups, [f.point(0, 0)], effect)
                XCTAssertEqual(f.focus.preparationCount, 1, effect)
                foreign.released(at: f.clock.now)
                foreign.pressed(at: f.clock.now)
                foreign.released(at: f.clock.now)
                XCTAssertEqual(f.effects.downs.count, 2, effect)
                f.effects.assertBalanced()
            }
        }
    }

    func testNewerSameIDContactDuringDownOrUpCannotInheritOuterAcceptance() {
        onMain {
            for duringUp in [false, true] {
                let f = HoldFixture(timeout: 100)
                let source = f.makeSource()
                var injected = false
                let inject = {
                    guard !injected else { return }
                    injected = true
                    if !duringUp { source.released(at: f.clock.now) }
                    source.pressed(at: f.clock.now, x: 5_000, y: 5_000)
                }
                if duringUp { f.input.onUp = inject } else { f.input.onDown = inject }
                source.pressed(at: f.clock.now)
                if duringUp { source.released(at: f.clock.now) }
                f.input.onDown = nil
                f.input.onUp = nil
                let completed = f.effects.events
                let scheduled = f.clock.scheduledTaskCount
                source.pressed(at: f.clock.now, x: 5_000, y: 5_000)
                f.clock.advance(byMilliseconds: 200)
                XCTAssertEqual(f.effects.events, completed)
                XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
                XCTAssertEqual(f.effects.downs.count, 1)
                XCTAssertEqual(f.effects.ups.count, 1)
                source.released(at: f.clock.now)
                source.pressed(at: f.clock.now)
                source.released(at: f.clock.now)
                XCTAssertEqual(f.effects.downs.count, 2)
                f.effects.assertBalanced()
            }
        }
    }

    func testSynchronousWatchdogCannotReinstallExpiredState() {
        onMain {
            for replaceAfterExpiry in [false, true] {
                let scheduler = HoldInlineReplayScheduler()
                let f = HoldFixture(configuration: holdConfiguration(timeout: 0), schedulerOverride: scheduler)
                let source = f.makeSource()
                var replacementStarted = false
                scheduler.afterAction = {
                    guard replaceAfterExpiry, !replacementStarted, f.effects.ups.count == 1 else { return }
                    replacementStarted = true
                    source.released(at: scheduler.now)
                    source.pressed(at: scheduler.now)
                }
                source.pressed(at: scheduler.now)
                scheduler.afterAction = nil
                let completed = f.effects.events
                XCTAssertEqual(f.effects.downs.count, replaceAfterExpiry ? 2 : 1)
                XCTAssertEqual(f.effects.ups.count, f.effects.downs.count)
                XCTAssertTrue(scheduler.tasks.allSatisfy { $0.isCancelled }, "Returning inline handles must be canceled")
                let scheduled = scheduler.tasks.count
                source.pressed(at: scheduler.now)
                scheduler.replayEveryActionIncludingCancelled()
                XCTAssertEqual(f.effects.events, completed)
                XCTAssertEqual(scheduler.tasks.count, scheduled)
                f.effects.assertBalanced()
            }
        }
    }

    func testReplacementStartedFromFocusPreparationCannotInheritOlderOuterDeadline() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let source = f.makeSource()
            f.focus.onPrepare = {
                f.focus.onPrepare = nil
                source.released(at: f.clock.now)
                f.clock.advance(toMilliseconds: 25)
                source.pressed(at: f.clock.now, x: 500, y: 500)
            }
            source.pressed(at: f.clock.now)
            XCTAssertEqual(f.effects.downs, [f.point(0, 0), f.point(500, 500)])
            XCTAssertEqual(f.effects.ups, [f.point(0, 0)])
            let active = f.effects.events
            f.clock.advance(toMilliseconds: 124)
            XCTAssertEqual(f.effects.events, active)
            f.clock.advance(toMilliseconds: 125)
            XCTAssertEqual(f.effects.ups, [f.point(0, 0), f.point(500, 500)])
            XCTAssertEqual(f.effects.releases, [true, true])
            f.effects.assertBalanced()
        }
    }

    func testOwnerRemovalReleaseBarrierDoesNotLetAnotherRejectedSourceStarveRecovery() {
        onMain {
            let f = HoldFixture()
            let old = f.makeSource()
            let silent = f.makeSource(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
            old.pressed(at: f.clock.now)
            silent.pressed(at: f.clock.now)
            old.registration.invalidate()
            f.application.handleSourceRemoval(old.registration.sourceID)
            let replacement = f.makeSource(sender: old.sender)
            replacement.released(at: f.clock.now) // Source-local neutral observation clears its barrier.
            replacement.pressed(at: f.clock.now)
            replacement.released(at: f.clock.now)
            XCTAssertEqual(f.effects.downs.count, 2)
            let finished = f.effects.events
            silent.pressed(at: f.clock.now, x: 200, y: 200)
            XCTAssertEqual(f.effects.events, finished)
            silent.released(at: f.clock.now)
            silent.pressed(at: f.clock.now)
            silent.released(at: f.clock.now)
            XCTAssertEqual(f.effects.downs.count, 3)
            f.effects.assertBalanced()
        }
    }

    func testNormalStopRestartDoesNotIntroduceHeldContactRecoveryBarrier() {
        onMain {
            let f = HoldFixture()
            let old = f.makeSource()
            old.pressed(at: f.clock.now)
            old.released(at: f.clock.now)
            old.registration.invalidate()
            f.application.handleHIDStop()
            let replacement = f.makeSource(sender: old.sender)
            replacement.pressed(at: f.clock.now)
            replacement.released(at: f.clock.now)
            XCTAssertEqual(f.effects.downs.count, 2)
            XCTAssertEqual(f.effects.ups.count, 2)
            f.effects.assertBalanced()
        }
    }

    func testRetiringHistoricalTimedOutCancelledOrFailedSourceCannotBlockCurrentOwnerHeartbeat() {
        onMain {
            for oldOutcome in ["timeout", "cancel", "failed down"] {
                let f = HoldFixture(timeout: 100)
                let old = f.makeSource()
                if oldOutcome == "failed down" { f.input.downResult = .constructionFailed }
                old.pressed(at: f.clock.now)
                if oldOutcome == "timeout" { f.clock.advance(byMilliseconds: 100) }
                if oldOutcome == "cancel" { f.application.cancelActiveGesture() }
                f.input.downResult = .postInvoked
                // Old A remains physically pressed, but no longer owns the lease.
                let current = f.makeSource(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
                current.pressed(at: f.clock.now, x: 500, y: 500)
                let startedAt = f.clock.now.uptimeNanoseconds
                let owned = f.effects.events
                let oldUpCount = f.effects.ups.count
                let scheduledBeforeRemoval = f.clock.scheduledTaskCount
                f.clock.advance(toNanoseconds: startedAt + 10_000_000)
                old.registration.invalidate()
                f.application.handleSourceRemoval(old.registration.sourceID)
                XCTAssertEqual(f.effects.events, owned, oldOutcome)
                XCTAssertEqual(f.clock.scheduledTaskCount, scheduledBeforeRemoval, oldOutcome)

                for offset: UInt64 in [50, 100, 150, 200, 250, 300] {
                    f.clock.advance(toNanoseconds: startedAt + offset * 1_000_000)
                    current.pressed(at: f.clock.now, x: 500, y: 500)
                    XCTAssertEqual(f.effects.events, owned,
                                   "Historical \(oldOutcome) source removal must not quarantine the current owner")
                    XCTAssertEqual(f.effects.ups.count, oldUpCount, oldOutcome)
                }
                XCTAssertEqual(f.clock.scheduledTaskCount, scheduledBeforeRemoval + 6, oldOutcome)
                current.released(at: f.clock.now, x: 500, y: 500)
                XCTAssertEqual(f.effects.ups.count, oldUpCount + 1, oldOutcome)
                XCTAssertEqual(f.effects.ups.last, f.point(500, 500), oldOutcome)
                XCTAssertEqual(f.effects.restores, [1], oldOutcome)
                let finished = f.effects.events
                f.clock.advance(byMilliseconds: 500)
                XCTAssertEqual(f.effects.events, finished, oldOutcome)
                f.effects.assertBalanced()
            }
        }
    }

    func testHistoricalInvalidatedSourceCannotImposeStopRestartBarrierAfterNewerOwnerCompleted() {
        onMain {
            for oldOutcome in ["timeout", "cancel", "failed down"] {
                let f = HoldFixture(timeout: 100)
                let old = f.makeSource()
                if oldOutcome == "failed down" { f.input.downResult = .constructionFailed }
                old.pressed(at: f.clock.now)
                if oldOutcome == "timeout" { f.clock.advance(byMilliseconds: 100) }
                if oldOutcome == "cancel" { f.application.cancelActiveGesture() }
                f.input.downResult = .postInvoked
                let newer = f.makeSource(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
                newer.pressed(at: f.clock.now, x: 500, y: 500)
                newer.released(at: f.clock.now, x: 500, y: 500)
                XCTAssertEqual(f.effects.restores, [1], oldOutcome)
                let completedDowns = f.effects.successfulDowns.count
                let completedUps = f.effects.ups.count
                // Stop retires callbacks first, then drains this production seam.
                old.registration.invalidate()
                newer.registration.invalidate()
                f.application.handleHIDStop()
                let restarted = f.makeSource(sender: old.sender)
                restarted.pressed(at: f.clock.now, x: 1_000, y: 1_000)
                XCTAssertEqual(f.effects.successfulDowns.count, completedDowns + 1,
                               "Old \(oldOutcome) contact is not a currently interrupted owner")
                restarted.released(at: f.clock.now, x: 1_000, y: 1_000)
                XCTAssertEqual(f.effects.ups.count, completedUps + 1, oldOutcome)
                XCTAssertEqual(f.effects.ups.last, f.point(1_000, 1_000), oldOutcome)
                f.effects.assertBalanced()
            }
        }
    }

    func testContinuousRejectedForeignStreamCannotRenewSilentOwnerOrTakeOverAfterExpiry() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let owner = f.makeSource()
            let foreign = f.makeSource(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
            owner.pressed(at: f.clock.now)
            let scheduled = f.clock.scheduledTaskCount
            for time: UInt64 in [10, 30, 50, 70, 90, 99] {
                f.clock.advance(toMilliseconds: time)
                foreign.pressed(at: f.clock.now, x: Int(time), y: Int(time))
                XCTAssertTrue(f.effects.ups.isEmpty)
                XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
            }
            let ownerDeadline = DispatchTime(uptimeNanoseconds: 100_000_000)
            f.advanceBefore(ownerDeadline)
            XCTAssertTrue(f.effects.ups.isEmpty)
            f.advance(to: ownerDeadline)
            XCTAssertEqual(f.effects.downs, [f.point(0, 0)])
            XCTAssertEqual(f.effects.ups, [f.point(0, 0)], "Owner expires at its own unchanged 100 ms deadline")
            XCTAssertEqual(f.effects.releases, [true])
            XCTAssertTrue(f.effects.restores.isEmpty)
            let expired = f.effects.events
            for time: UInt64 in [101, 150, 200, 250, 300] {
                f.clock.advance(toMilliseconds: time)
                foreign.pressed(at: f.clock.now, x: Int(time), y: Int(time))
                XCTAssertEqual(f.effects.events, expired, "Already-held foreign contact cannot take over")
                XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
            }
            XCTAssertTrue(f.effects.drags.isEmpty)
            XCTAssertTrue(f.effects.updates.isEmpty)
            foreign.released(at: f.clock.now, x: 300, y: 300)
            foreign.pressed(at: f.clock.now, x: 300, y: 300)
            foreign.released(at: f.clock.now, x: 300, y: 300)
            XCTAssertEqual(f.effects.downs, [f.point(0, 0), f.point(300, 300)])
            XCTAssertEqual(f.effects.ups, f.effects.downs)
            XCTAssertEqual(f.effects.releases, [true, true])
            f.effects.assertBalanced()
        }
    }

    func testResolverReentrantOwnerUpPreventsStaleOuterDownAdmission() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let source = f.makeSource()
            f.displays.onNextRead = { source.released(at: f.clock.now) }
            source.pressed(at: f.clock.now)
            XCTAssertEqual(f.normalizedKinds, [.down, .up])
            XCTAssertTrue(f.effects.downs.isEmpty, "The physical epoch closed during display resolution")
            XCTAssertTrue(f.effects.borrows.isEmpty)
            XCTAssertEqual(f.focus.preparationCount, 0)
            XCTAssertEqual(f.clock.scheduledTaskCount, 0)
            f.clock.advance(byMilliseconds: 200)
            source.pressed(at: f.clock.now)
            source.released(at: f.clock.now)
            XCTAssertEqual(f.effects.downs.count, 1)
            XCTAssertEqual(f.effects.ups.count, 1)
            f.effects.assertBalanced()
        }
    }

    func testResolverReentrantReplacementCannotBeCancelledOrClaimedByOuterDown() {
        onMain {
            for sameSource in [false, true] {
                let f = HoldFixture(timeout: 100)
                let old = f.makeSource()
                let replacement = sameSource ? old : f.makeSource(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
                f.displays.onNextRead = {
                    old.released(at: f.clock.now)
                    replacement.pressed(at: f.clock.now, x: 500, y: 500)
                }
                old.pressed(at: f.clock.now)
                XCTAssertEqual(f.effects.downs, [f.point(500, 500)])
                XCTAssertTrue(f.effects.ups.isEmpty)
                XCTAssertEqual(f.effects.borrows, [f.point(500, 500)])
                XCTAssertEqual(f.focus.preparationCount, 1)
                let active = f.effects.events
                let scheduled = f.clock.scheduledTaskCount
                f.clock.advance(toMilliseconds: 50)
                replacement.pressed(at: f.clock.now, x: 500, y: 500)
                XCTAssertEqual(f.clock.scheduledTaskCount, scheduled + 1)
                f.clock.advance(toMilliseconds: 100)
                XCTAssertEqual(f.effects.events, active, "The stale outer admission must not cancel the accepted replacement")
                replacement.released(at: f.clock.now, x: 500, y: 500)
                XCTAssertEqual(f.effects.ups, [f.point(500, 500)])
                XCTAssertEqual(f.effects.restores, [0])
                f.effects.assertBalanced()
            }
        }
    }

    func testDisplayRefreshCleanupCannotCancelSourceAcceptedDuringFocusDiscard() {
        onMain {
            let f = HoldFixture(timeout: 100)
            f.application.handleDeviceMatched() // Establish old geometry without an input lease.
            let old = f.makeSource()
            let replacement = f.makeSource(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
            let movedOrigin = CGPoint(x: -200, y: 900)
            f.displays.values = [holdDisplay(origin: movedOrigin)]
            f.focus.onDiscard = {
                f.focus.onDiscard = nil
                replacement.pressed(at: f.clock.now)
            }
            old.pressed(at: f.clock.now) // Refresh cancels at idle, then the collaborator admits B.
            XCTAssertEqual(f.effects.downs, [movedOrigin])
            XCTAssertTrue(f.effects.ups.isEmpty)
            XCTAssertEqual(f.effects.borrows, [movedOrigin])
            XCTAssertEqual(f.focus.preparationCount, 1)
            let active = f.effects.events
            f.clock.advance(toMilliseconds: 50)
            old.pressed(at: f.clock.now)
            replacement.pressed(at: f.clock.now)
            f.clock.advance(toMilliseconds: 100)
            XCTAssertEqual(f.effects.events, active, "The older idle-cleanup frame must leave B's generation alive")
            replacement.released(at: f.clock.now)
            XCTAssertEqual(f.effects.ups, [movedOrigin])
            XCTAssertEqual(f.effects.restores, [0])
            XCTAssertEqual(f.effects.releases, [true])
            f.effects.assertBalanced()
        }
    }

    func testTimeoutFocusDiscardReentryCannotCancelNewlyAcceptedGeneration() {
        onMain {
            for sameSource in [false, true] {
                let f = HoldFixture(timeout: 100)
                let old = f.makeSource()
                let replacement = sameSource ? old : f.makeSource(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
                old.pressed(at: f.clock.now)
                f.focus.onDiscard = {
                    f.focus.onDiscard = nil
                    // Finish the old lease inside the collaborator, then accept a
                    // replacement before the outer timeout's cleanup frame returns.
                    f.application.cancelActiveGesture()
                    old.released(at: f.clock.now)
                    replacement.pressed(at: f.clock.now, x: 500, y: 500)
                }
                f.clock.advance(toMilliseconds: 100)
                XCTAssertEqual(f.effects.downs, [f.point(0, 0), f.point(500, 500)])
                XCTAssertEqual(f.effects.ups, [f.point(0, 0)])
                XCTAssertEqual(f.effects.releases, [true])
                XCTAssertEqual(f.focus.preparationCount, 2)
                let active = f.effects.events
                f.clock.advance(toMilliseconds: 150)
                replacement.pressed(at: f.clock.now, x: 500, y: 500)
                f.clock.advance(toMilliseconds: 200)
                XCTAssertEqual(f.effects.events, active, "The old timeout cannot act on the replacement generation")
                replacement.released(at: f.clock.now, x: 500, y: 500)
                XCTAssertEqual(f.effects.ups, [f.point(0, 0), f.point(500, 500)])
                XCTAssertEqual(f.effects.restores, [1])
                f.effects.assertBalanced()
            }
        }
    }

    func testOwnerUpDuringPreparationDeadlineDiscardCompletesWithoutWaitingForWatchdog() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let source = f.makeSource()
            f.focus.holdPreparation = true
            source.pressed(at: f.clock.now)
            f.focus.onDiscard = {
                f.focus.onDiscard = nil
                source.released(at: f.clock.now)
            }
            f.clock.advance(toMilliseconds: 29)
            XCTAssertTrue(f.effects.downs.isEmpty)
            XCTAssertTrue(f.effects.borrows.isEmpty)
            f.clock.advance(toMilliseconds: 30)
            XCTAssertEqual(f.clock.now.uptimeNanoseconds, 30_000_000)
            XCTAssertEqual(f.normalizedKinds, [.down, .up])
            XCTAssertEqual(f.effects.downs, [f.point(0, 0)])
            XCTAssertEqual(f.effects.ups, [f.point(0, 0)],
                           "Up received inside preparation discard must complete at 30 ms, not at the watchdog deadline")
            XCTAssertEqual(f.effects.borrows.count, 1)
            XCTAssertEqual(f.effects.releases, [true])
            XCTAssertEqual(f.focus.semanticBoundaryCount, 1)
            XCTAssertTrue(f.effects.restores.isEmpty)
            let completed = f.effects.events
            f.focus.complete(0)
            f.clock.advance(toMilliseconds: 200)
            XCTAssertEqual(f.effects.events, completed)
            f.effects.assertBalanced()
        }
    }

    func testOwnerUpDuringForcedMovePreparationDiscardCannotBeLostBeforeTracking() {
        onMain {
            let f = HoldFixture(timeout: 100)
            let source = f.makeSource()
            f.focus.holdPreparation = true
            source.pressed(at: f.clock.now)
            f.focus.onDiscard = {
                f.focus.onDiscard = nil
                source.released(at: f.clock.now, x: 500, y: 500)
            }
            f.clock.advance(toMilliseconds: 5)
            source.pressed(at: f.clock.now, x: 500, y: 500) // Normalized move forces preparation to finish.
            XCTAssertEqual(f.clock.now.uptimeNanoseconds, 5_000_000)
            XCTAssertEqual(f.normalizedKinds, [.down, .move, .up])
            XCTAssertEqual(f.effects.downs, [f.point(0, 0)])
            XCTAssertEqual(f.effects.ups, [f.point(500, 500)],
                           "The reentrant accepted up must release immediately at its accepted coordinates")
            XCTAssertEqual(f.effects.borrows, [f.point(0, 0)])
            XCTAssertEqual(f.effects.releases, [true])
            XCTAssertEqual(f.focus.semanticBoundaryCount, 1)
            XCTAssertTrue(f.effects.drags.isEmpty, "An older outer move cannot drag after the reentrant up completed")
            XCTAssertTrue(f.effects.updates.isEmpty)
            XCTAssertTrue(f.effects.restores.isEmpty)
            let completed = f.effects.events
            f.focus.complete(0)
            f.clock.advance(toMilliseconds: 200)
            XCTAssertEqual(f.effects.events, completed)
            f.effects.assertBalanced()
        }
    }

    func testCancellationDuringPreparationDiscardBeforeBorrowCreatesNoInputOwnership() {
        onMain {
            for forcedMove in [false, true] {
                let f = HoldFixture(timeout: 100)
                let source = f.makeSource()
                f.focus.holdPreparation = true
                source.pressed(at: f.clock.now)
                f.focus.onDiscard = {
                    f.focus.onDiscard = nil
                    f.application.cancelActiveGesture()
                }
                if forcedMove {
                    f.clock.advance(toMilliseconds: 5)
                    source.pressed(at: f.clock.now, x: 500, y: 500)
                } else {
                    f.clock.advance(toMilliseconds: 30)
                }
                XCTAssertTrue(f.effects.borrows.isEmpty)
                XCTAssertTrue(f.effects.downs.isEmpty)
                XCTAssertTrue(f.effects.ups.isEmpty)
                XCTAssertTrue(f.effects.releases.isEmpty, "Cancellation won before any cursor borrow")
                XCTAssertTrue(f.effects.restores.isEmpty)
                let canceled = f.effects.events
                let scheduled = f.clock.scheduledTaskCount
                source.pressed(at: f.clock.now, x: 500, y: 500)
                f.focus.complete(0)
                f.clock.advance(toMilliseconds: 200)
                XCTAssertEqual(f.effects.events, canceled)
                XCTAssertEqual(f.clock.scheduledTaskCount, scheduled)
                source.released(at: f.clock.now, x: 500, y: 500)
                f.focus.holdPreparation = false
                source.pressed(at: f.clock.now)
                source.released(at: f.clock.now)
                XCTAssertEqual(f.effects.downs, [f.point(0, 0)])
                XCTAssertEqual(f.effects.ups, [f.point(0, 0)])
                XCTAssertEqual(f.effects.releases, [true])
                f.effects.assertBalanced()
            }
        }
    }

    private func onMain(_ action: () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.sync(execute: action) }
    }
}

private func holdConfiguration(timeout: Int = 2_000) -> DriverConfiguration {
    var result = DriverConfiguration.defaults
    result.timing.warpToClickDelayMs = 0
    result.timing.downToUpDelayMs = 0
    result.timing.clickToWarpBackDelayMs = 0
    result.timing.tapDebounceMs = 0
    result.timing.stuckGestureTimeoutMs = timeout
    return result
}

private func holdDisplay(id: CGDirectDisplayID = 42, origin: CGPoint = CGPoint(x: 100, y: 200)) -> DisplaySnapshot {
    DisplaySnapshot(displayID: id, vendorNumber: CapturedXeneonDisplay.vendorNumber,
                    modelNumber: CapturedXeneonDisplay.modelNumber,
                    serialNumber: CapturedXeneonDisplay.observedSerialNumber,
                    bounds: CGRect(origin: origin, size: CGSize(width: 2_560, height: 720)),
                    pixelsWide: CapturedXeneonDisplay.expectedWidth, pixelsHigh: CapturedXeneonDisplay.expectedHeight)
}

private struct HoldEnvelope {
    let observation: HIDTouchObservation
    let fence: HIDSourceRetirementFence
}

private final class HoldDisplays {
    var values = [holdDisplay()]
    var onNextRead: (() -> Void)?
    func read() -> [DisplaySnapshot] {
        let callback = onNextRead
        onNextRead = nil
        callback?()
        return values
    }
}

private final class HoldFixture {
    let clock = TestGestureScheduler(executeCancelledActions: true)
    let effects = HoldEffects()
    let displays = HoldDisplays()
    let input: HoldInput
    let cursor: HoldCursor
    let focus: HoldFocus
    let application: MacXeneonEdgeTouchDriverApplication
    var observations: [HoldEnvelope] = []
    var deliverObservations = true
    private var sources: [HoldSource] = []
    var normalizedKinds: [TouchEvent.Kind] { observations.compactMap { $0.observation.event?.kind } }

    init(configuration: DriverConfiguration = holdConfiguration(), schedulerOverride: GestureScheduler? = nil) {
        input = HoldInput(effects: effects)
        cursor = HoldCursor(effects: effects)
        focus = HoldFocus(effects: effects)
        let displays = self.displays
        application = MacXeneonEdgeTouchDriverApplication(
            configuration: configuration, displayResolver: DisplayResolver(activeDisplayProvider: { displays.read() }),
            inputSink: input, cursorController: cursor, focusRestorer: focus, scheduler: schedulerOverride ?? clock)
    }

    convenience init(timeout: Int) { self.init(configuration: holdConfiguration(timeout: timeout)) }

    func makeSource(sender: UnsafeMutableRawPointer = UnsafeMutableRawPointer(bitPattern: 0x1000)!) -> HoldSource {
        let source = HoldSource(sender: sender) { [weak self] observation, fence in
            guard let self else { return }
            let envelope = HoldEnvelope(observation: observation, fence: fence)
            self.observations.append(envelope)
            if self.deliverObservations { self.route(envelope) }
        }
        sources.append(source)
        return source
    }

    func route(_ envelope: HoldEnvelope) {
        HIDDeviceMonitor.deliverObservation(
            envelope.observation, fence: envelope.fence,
            touchEventHandler: { _ in XCTFail("Production observation delivery must not also use the legacy event callback") },
            observationHandler: { observation, fence in
                self.application.handleTouchObservation(observation, fence: fence)
            })
    }

    /// Use exact comparisons between representable native instants. A one-ns
    /// integer decrement can still project to the deadline on Darwin.
    func advanceBefore(_ deadline: DispatchTime, file: StaticString = #filePath, line: UInt = #line) {
        let before = DispatchTime(uptimeNanoseconds: deadline.uptimeNanoseconds - 1_000)
        XCTAssertLessThan(before.uptimeNanoseconds, deadline.uptimeNanoseconds, file: file, line: line)
        advance(to: before, file: file, line: line)
    }

    func advance(to time: DispatchTime, file: StaticString = #filePath, line: UInt = #line) {
        clock.advance(toNanoseconds: time.uptimeNanoseconds)
        XCTAssertEqual(clock.now, time, file: file, line: line)
    }

    func point(_ x: Int, _ y: Int) -> CGPoint {
        CoordinateMapper(displayBounds: holdDisplay().bounds).map(rawX: x, rawY: y)
    }
}

private final class HoldSource {
    let sender: UnsafeMutableRawPointer
    let registration: HIDInputReportRegistration

    init(sender: UnsafeMutableRawPointer, receive: @escaping (HIDTouchObservation, HIDSourceRetirementFence) -> Void) {
        self.sender = sender
        registration = HIDInputReportRegistration(sender: sender, length: 64, receiveObservation: receive)
    }

    func pressed(at timestamp: DispatchTime, x: Int = 0, y: Int = 0) {
        report([7, 1, UInt8(x & 255), UInt8((x >> 8) & 255), UInt8(y & 255), UInt8((y >> 8) & 255), 0], timestamp: timestamp)
    }

    func released(at timestamp: DispatchTime, x: Int = 0, y: Int = 0) {
        report([7, 0, UInt8(x & 255), UInt8((x >> 8) & 255), UInt8(y & 255), UInt8((y >> 8) & 255), 0], timestamp: timestamp)
    }

    func report(_ bytes: [UInt8], timestamp: DispatchTime) {
        precondition(bytes.count <= registration.length)
        for (index, byte) in bytes.enumerated() { registration.buffer[index] = byte }
        HIDInputReportRegistration.handleCallback(context: registration.context, result: kIOReturnSuccess,
            sender: sender, type: kIOHIDReportTypeInput, reportID: 7, report: registration.buffer,
            reportLength: bytes.count, timestamp: timestamp)
    }
}

private final class HoldEffects {
    enum Event: Equatable {
        case prepare, discard, inputEnded, restore(Int), show
        case borrow(CGPoint), update(CGPoint), down(CGPoint, SyntheticInputResult)
        case drag(CGPoint, SyntheticInputResult), up(CGPoint, SyntheticInputResult), release(Bool)
    }
    var events: [Event] = []
    var downs: [CGPoint] { events.compactMap { if case .down(let p, _) = $0 { return p }; return nil } }
    var successfulDowns: [CGPoint] { events.compactMap { if case .down(let p, .postInvoked) = $0 { return p }; return nil } }
    var ups: [CGPoint] { events.compactMap { if case .up(let p, _) = $0 { return p }; return nil } }
    var drags: [CGPoint] { events.compactMap { if case .drag(let p, _) = $0 { return p }; return nil } }
    var updates: [CGPoint] { events.compactMap { if case .update(let p) = $0 { return p }; return nil } }
    var borrows: [CGPoint] { events.compactMap { if case .borrow(let p) = $0 { return p }; return nil } }
    var releases: [Bool] { events.compactMap { if case .release(let r) = $0 { return r }; return nil } }
    var restores: [Int] { events.compactMap { if case .restore(let id) = $0 { return id }; return nil } }

    func assertBalanced(file: StaticString = #filePath, line: UInt = #line) {
        var down = false
        for event in events {
            switch event {
            case .down(_, .postInvoked):
                XCTAssertFalse(down, "Duplicate posted down", file: file, line: line); down = true
            case .up(_, .postInvoked):
                XCTAssertTrue(down, "Unowned posted up", file: file, line: line); down = false
            case .drag(_, .postInvoked):
                XCTAssertTrue(down, "Unowned posted drag", file: file, line: line)
            default: break
            }
        }
        XCTAssertFalse(down, "Unreleased posted down", file: file, line: line)
    }
}

private final class HoldInput: ReportingSyntheticInputSink {
    let effects: HoldEffects
    var downResult: SyntheticInputResult = .postInvoked
    var upResult: SyntheticInputResult = .postInvoked
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    init(effects: HoldEffects) { self.effects = effects }
    func postMouseDown(at point: CGPoint) { XCTFail("Use the reporting input path") }
    func postMouseUp(at point: CGPoint) { XCTFail("Use the reporting input path") }
    func postMouseDragged(to point: CGPoint) { XCTFail("Use the reporting input path") }
    func tryPostMouseDown(at point: CGPoint) -> SyntheticInputResult {
        let result = downResult
        effects.events.append(.down(point, result)); onDown?(); return result
    }
    func tryPostMouseUp(at point: CGPoint) -> SyntheticInputResult {
        let result = upResult
        effects.events.append(.up(point, result)); onUp?(); return result
    }
    func tryPostMouseDragged(to point: CGPoint) -> SyntheticInputResult {
        effects.events.append(.drag(point, .postInvoked)); return .postInvoked
    }
}

private final class HoldCursor: CursorController {
    let effects: HoldEffects
    var borrowSucceeds = true
    var onBorrow: (() -> Void)?
    init(effects: HoldEffects) { self.effects = effects }
    func borrow(warpingTo point: CGPoint) -> Bool {
        effects.events.append(.borrow(point)); onBorrow?(); return borrowSucceeds
    }
    func updatePosition(_ point: CGPoint) { effects.events.append(.update(point)) }
    func returnToOrigin() { effects.events.append(.release(true)) }
    func releaseBorrow(returnToPreviousPosition: Bool) { effects.events.append(.release(returnToPreviousPosition)) }
    func forceShow() { effects.events.append(.show) }
}

private final class HoldFocus: FocusRestorer {
    let effects: HoldEffects
    var holdPreparation = false
    var onPrepare: (() -> Void)?
    var onInputEnd: (() -> Void)?
    var onDiscard: (() -> Void)?
    private var generation = 0
    private var capture: Int?
    private var ended = false
    private var pending: [(Int, () -> Void)] = []
    private(set) var semanticBoundaryCount = 0
    var preparationCount: Int { pending.count }
    init(effects: HoldEffects) { self.effects = effects }
    func prepareFocusedWindow(completion: @escaping () -> Void) {
        generation += 1
        capture = nil
        ended = false
        let index = pending.count
        pending.append((generation, completion))
        effects.events.append(.prepare)
        onPrepare?()
        if !holdPreparation { complete(index) }
    }
    func complete(_ index: Int) {
        guard pending.indices.contains(index) else { return XCTFail("Missing focus preparation") }
        let (expected, completion) = pending[index]
        if expected == generation { capture = index }
        completion()
    }
    func captureFocusedWindow() { XCTFail("Use completion-aware preparation") }
    func inputDidEnd() {
        if !ended { ended = true; semanticBoundaryCount += 1; effects.events.append(.inputEnded) }
        onInputEnd?()
    }
    func restoreCapturedWindow() {
        if let capture { effects.events.append(.restore(capture)) }
        capture = nil; generation += 1
    }
    func discardCapturedWindow() {
        effects.events.append(.discard)
        capture = nil
        generation += 1
        onDiscard?()
    }
}

/// Models schedule() calling inline before returning its cancellable handle.
private final class HoldInlineReplayScheduler: GestureScheduler {
    final class Task: GestureScheduledTask {
        let action: () -> Void
        private(set) var isCancelled = false
        init(action: @escaping () -> Void) { self.action = action }
        func cancel() { isCancelled = true }
    }
    let now = DispatchTime(uptimeNanoseconds: 0)
    var tasks: [Task] = []
    var afterAction: (() -> Void)?
    func schedule(afterMilliseconds milliseconds: Int, action: @escaping () -> Void) -> GestureScheduledTask {
        let task = Task(action: action)
        tasks.append(task)
        action()
        afterAction?()
        return task
    }
    func replayEveryActionIncludingCancelled() {
        let snapshot = tasks
        for task in snapshot { task.action() }
    }
}
