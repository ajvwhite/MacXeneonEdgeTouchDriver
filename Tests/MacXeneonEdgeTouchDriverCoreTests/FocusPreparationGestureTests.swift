import CoreGraphics
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class FocusPreparationGestureTests: XCTestCase {
    func testAcceptedRawUpFreezesFocusBeforeForcedMouseDownAndSyntheticUpDelay() {
        for upDelay in [20, 1_000] {
            let fixture = PreparationFixture(timing: releaseBoundaryTiming(upDelay: upDelay))
            fixture.send(.down, at: 0)
            fixture.focus.complete(0)
            XCTAssertTrue(fixture.effects.input.isEmpty)
            fixture.send(.up, at: 1)

            XCTAssertEqual(fixture.focus.boundarySnapshots.first, [.prepare, .borrow(start)],
                           "The release boundary must precede the quick tap's forced mouse-down.")
            XCTAssertEqual(fixture.focus.semanticBoundaryCount, 1)
            XCTAssertEqual(fixture.effects.input, [.down(start)])
            fixture.clock.advance(toMilliseconds: UInt64(upDelay))
            XCTAssertEqual(fixture.effects.input, [.down(start)])
            fixture.clock.advance(toMilliseconds: UInt64(upDelay + 1))
            XCTAssertEqual(fixture.effects.input, [.down(start), .up(start)])
            fixture.clock.advance(toMilliseconds: UInt64(upDelay + 11))

            XCTAssertEqual(fixture.focus.semanticBoundaryCount, 1,
                           "Defensive synthetic-up hooks must not freeze a second baseline.")
            XCTAssertEqual(fixture.effects.restoredCaptures, [0])
            fixture.assertFinished()
        }
    }

    func testEarlyRawUpDuringPendingCaptureFreezesBeforeBorrowAndForcedDown() {
        for upDelay in [20, 1_000] {
            let fixture = PreparationFixture(timing: releaseBoundaryTiming(upDelay: upDelay))
            fixture.send(.down, at: 0)
            fixture.send(.up, at: 1)

            XCTAssertEqual(fixture.focus.boundarySnapshots.first, [.prepare],
                           "An accepted up ends eligibility before continuing the pending gesture.")
            XCTAssertEqual(fixture.focus.semanticBoundaryCount, 1)
            XCTAssertEqual(fixture.effects.input, [.down(start)])
            fixture.focus.complete(0)
            fixture.clock.advance(toMilliseconds: UInt64(upDelay + 11))

            XCTAssertEqual(fixture.focus.semanticBoundaryCount, 1)
            XCTAssertEqual(fixture.effects.input, [.down(start), .up(start)])
            XCTAssertTrue(fixture.effects.restoredCaptures.isEmpty)
            fixture.assertFinished()
        }
    }

    func testForeignContactUpCannotFreezePendingOrAcceptedGesture() {
        let fixture = PreparationFixture(timing: releaseBoundaryTiming(upDelay: 20))
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1, contactID: 1)
        XCTAssertEqual(fixture.focus.semanticBoundaryCount, 0)
        XCTAssertTrue(fixture.effects.borrows.isEmpty)
        fixture.clock.advance(toMilliseconds: 2)
        fixture.focus.complete(0)
        fixture.send(.down, at: 3, contactID: 1)
        fixture.send(.up, at: 4, contactID: 1)
        XCTAssertEqual(fixture.focus.semanticBoundaryCount, 0)
        XCTAssertTrue(fixture.effects.input.isEmpty)

        fixture.send(.up, at: 5)
        XCTAssertEqual(fixture.focus.semanticBoundaryCount, 1)
        XCTAssertEqual(fixture.focus.boundarySnapshots.first, [.prepare, .borrow(start)])
        fixture.clock.advance(toMilliseconds: 35)
        XCTAssertEqual(fixture.effects.input, [.down(start), .up(start)])
        XCTAssertEqual(fixture.effects.restoredCaptures, [0])
        fixture.assertFinished()
    }

    func testCancelAfterRawUpKeepsTheFirstReleaseBoundaryAndBalancesInput() {
        let fixture = PreparationFixture(timing: releaseBoundaryTiming(upDelay: 1_000))
        fixture.send(.down, at: 0)
        fixture.focus.complete(0)
        fixture.send(.up, at: 1)
        let firstBoundary = fixture.focus.boundarySnapshots.first
        XCTAssertEqual(firstBoundary, [.prepare, .borrow(start)])
        fixture.clock.advance(toMilliseconds: 2)
        fixture.controller.forceCancel()
        fixture.controller.forceCancel()
        fixture.clock.advance(toMilliseconds: 2_000)

        XCTAssertEqual(fixture.focus.semanticBoundaryCount, 1)
        XCTAssertEqual(fixture.focus.boundarySnapshots.first, firstBoundary)
        XCTAssertEqual(fixture.effects.input, [.down(start), .up(start)])
        XCTAssertEqual(fixture.effects.restoredCaptures, [0])
        fixture.assertFinished()
    }

    func testRawUpAfterMapperLossEndsPendingEligibilityBeforeDroppingInput() {
        let fixture = PreparationFixture(timing: releaseBoundaryTiming(upDelay: 20))
        fixture.send(.down, at: 0)
        fixture.hasMapper = false
        fixture.send(.up, at: 1)

        XCTAssertEqual(fixture.focus.boundarySnapshots.first, [.prepare])
        XCTAssertEqual(fixture.focus.semanticBoundaryCount, 1)
        XCTAssertTrue(fixture.effects.borrows.isEmpty)
        XCTAssertTrue(fixture.effects.input.isEmpty)
        fixture.controller.forceCancel()
        let canceled = fixture.effects.events
        fixture.focus.complete(0)
        fixture.clock.advance(toMilliseconds: 2_000)

        XCTAssertEqual(fixture.effects.events, canceled)
        XCTAssertTrue(fixture.effects.restoredCaptures.isEmpty)
        XCTAssertEqual(fixture.controller.state, .idle)
    }

    private func releaseBoundaryTiming(upDelay: Int) -> GestureTiming {
        GestureTiming(warpToClickDelayMs: 1_000, downToUpDelayMs: upDelay,
                      clickToWarpBackDelayMs: 10, tapDebounceMs: 0)
    }

    func testDeadlineDeliversAndCleansUpTouchWhenFocusNeverCompletes() {
        let fixture = PreparationFixture()
        fixture.send(.down, at: 0)
        fixture.clock.advance(toMilliseconds: 29)
        XCTAssertTrue(fixture.effects.input.isEmpty)

        // Never deliver a focus callback. Advancing only the gesture clock must
        // be sufficient to press, drag, release, and return the cursor.
        fixture.clock.advance(toMilliseconds: 30)
        XCTAssertEqual(fixture.effects.input, [.down(start)])
        fixture.send(.move, at: 31, rawX: 4_000, rawY: 2_000)
        fixture.send(.up, at: 32, rawX: 4_000, rawY: 2_000)
        let moved = fixture.point(rawX: 4_000, rawY: 2_000)
        XCTAssertEqual(fixture.effects.input, [.down(start), .drag(moved), .up(moved)])
        XCTAssertEqual(fixture.focus.preparationCount, 1)
        XCTAssertTrue(fixture.effects.restoredCaptures.isEmpty)
        fixture.assertFinished()
    }

    func testCaptureAtZeroOrBeforeDeadlinePrecedesInputAndRemainsRestorable() {
        for completionTime: UInt64 in [0, 29] {
            let fixture = PreparationFixture()
            fixture.send(.down, at: 0)
            XCTAssertTrue(fixture.effects.input.isEmpty)
            XCTAssertTrue(fixture.effects.borrows.isEmpty)
            fixture.clock.advance(toMilliseconds: completionTime)
            fixture.focus.complete(0)

            XCTAssertEqual(fixture.effects.events, [.prepare, .borrow(start), .down(start)])
            fixture.send(.up, at: completionTime)
            XCTAssertEqual(fixture.effects.events, [
                .prepare, .borrow(start), .down(start), .up(start), .release(true), .restore(0)
            ])
            fixture.clock.advance(toMilliseconds: 100)
            XCTAssertEqual(fixture.effects.borrows, [start])
            XCTAssertEqual(fixture.effects.restoredCaptures, [0])
            fixture.assertFinished()
        }
    }

    func testCaptureAtOrAfterDeadlineCannotBecomeEligibleForRestoration() {
        for completionTime: UInt64 in [30, 31, 100] {
            let fixture = PreparationFixture()
            fixture.send(.down, at: 0)
            fixture.clock.advance(toMilliseconds: 29)
            XCTAssertTrue(fixture.effects.input.isEmpty)
            XCTAssertTrue(fixture.effects.borrows.isEmpty)

            fixture.clock.advance(toMilliseconds: 30)
            XCTAssertEqual(fixture.effects.events, [.prepare, .discard, .borrow(start), .down(start)])
            fixture.clock.advance(toMilliseconds: completionTime)
            let beforeLateCompletion = fixture.effects.events
            fixture.focus.complete(0)
            XCTAssertEqual(fixture.effects.events, beforeLateCompletion)
            fixture.send(.up, at: completionTime)

            XCTAssertEqual(fixture.effects.input, [.down(start), .up(start)])
            XCTAssertTrue(fixture.effects.restoredCaptures.isEmpty)
            fixture.assertFinished()
        }
    }

    func testCompletionQueuedBeforeTimerAtExactDeadlineStillCannotRestore() {
        let fixture = PreparationFixture()
        fixture.clock.schedule(afterMilliseconds: 30) { fixture.focus.complete(0) }
        fixture.send(.down, at: 0)
        fixture.clock.advance(toMilliseconds: 30)

        XCTAssertEqual(fixture.effects.events, [.prepare, .discard, .borrow(start), .down(start)])
        fixture.send(.up, at: 31)
        XCTAssertTrue(fixture.effects.restoredCaptures.isEmpty)
        fixture.assertFinished()
    }

    func testPreparationTimeBeforeReturningDoesNotExtendTheInputDeadline() {
        let fixture = PreparationFixture()
        let clock = fixture.clock
        fixture.focus.onPreparationStarted = { clock.advance(byMilliseconds: 20) }
        fixture.send(.down, at: 0)
        XCTAssertEqual(fixture.clock.now.uptimeNanoseconds, 20_000_000)
        XCTAssertTrue(fixture.effects.input.isEmpty)
        fixture.clock.advance(toMilliseconds: 29)
        XCTAssertTrue(fixture.effects.input.isEmpty)
        fixture.clock.advance(toMilliseconds: 30)
        XCTAssertEqual(fixture.effects.events, [.prepare, .discard, .borrow(start), .down(start)])
        fixture.send(.up, at: 31)
        XCTAssertTrue(fixture.effects.restoredCaptures.isEmpty)
        fixture.assertFinished()
    }

    func testQuickUpDeliversBalancedTapImmediatelyWithoutWaitingForCapture() {
        let fixture = PreparationFixture()
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1)

        XCTAssertEqual(fixture.clock.now.uptimeNanoseconds, 1_000_000)
        XCTAssertEqual(fixture.effects.events, [
            .prepare, .discard, .borrow(start), .down(start), .up(start), .release(true)
        ])
        fixture.assertFinished()
        let completed = fixture.effects.events
        fixture.focus.complete(0)
        fixture.clock.advance(toMilliseconds: 100)
        XCTAssertEqual(fixture.effects.events, completed)
    }

    func testFirstMoveContinuesImmediatelyAndPreservesEveryMoveInOrder() {
        let fixture = PreparationFixture()
        fixture.send(.down, at: 0)
        fixture.send(.move, at: 1, rawX: 4_000, rawY: 2_000)
        let first = fixture.point(rawX: 4_000, rawY: 2_000)
        XCTAssertEqual(fixture.effects.events, [
            .prepare, .discard, .borrow(start), .down(start), .update(first), .drag(first)
        ])
        fixture.send(.move, at: 2, rawX: 8_000, rawY: 4_000)
        fixture.send(.move, at: 3, rawX: 16_383, rawY: 9_599)
        fixture.send(.up, at: 4, rawX: 16_383, rawY: 9_599)

        XCTAssertEqual(fixture.effects.input, [
            .down(start), .drag(first), .drag(fixture.point(rawX: 8_000, rawY: 4_000)), .drag(end), .up(end)
        ])
        XCTAssertEqual(fixture.effects.borrows, [start])
        XCTAssertTrue(fixture.effects.restoredCaptures.isEmpty)
        fixture.assertFinished()
        let completed = fixture.effects.events
        fixture.focus.complete(0)
        fixture.clock.advance(toMilliseconds: 100)
        XCTAssertEqual(fixture.effects.events, completed)
    }

    func testFailedBorrowOnEarlyUpDoesNotRejectNextContactWithSameID() {
        let fixture = PreparationFixture()
        fixture.cursor.borrowSucceeds = false
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1)
        XCTAssertTrue(fixture.effects.input.isEmpty)
        XCTAssertEqual(fixture.controller.state, .idle)

        fixture.cursor.borrowSucceeds = true
        fixture.send(.down, at: 2, rawX: 16_383, rawY: 9_599)
        XCTAssertEqual(fixture.focus.preparationCount, 2)
        fixture.focus.complete(0)
        XCTAssertTrue(fixture.effects.input.isEmpty)
        fixture.focus.complete(1)
        fixture.send(.up, at: 3, rawX: 16_383, rawY: 9_599)
        fixture.clock.advance(toMilliseconds: 100)

        XCTAssertEqual(fixture.effects.borrows, [start, end])
        XCTAssertEqual(fixture.effects.input, [.down(end), .up(end)])
        XCTAssertEqual(fixture.effects.releases, [true])
        XCTAssertEqual(fixture.effects.restoredCaptures, [1])
        XCTAssertEqual(fixture.controller.state, .idle)
        fixture.effects.assertBalanced()
    }

    func testOldCompletionCannotCommitOrDiscardNextGestureWithSameContactID() {
        let fixture = PreparationFixture()
        fixture.send(.down, at: 0)
        fixture.send(.up, at: 1)
        fixture.send(.down, at: 2, rawX: 16_383, rawY: 9_599)
        let preparingNext = fixture.effects.events

        fixture.focus.complete(0)
        XCTAssertEqual(fixture.effects.events, preparingNext)
        XCTAssertEqual(fixture.effects.borrows, [start])
        fixture.focus.complete(1)
        XCTAssertEqual(fixture.effects.borrows, [start, end])
        XCTAssertEqual(fixture.effects.input, [.down(start), .up(start), .down(end)])

        let nextCommitted = fixture.effects.events
        fixture.focus.complete(0)
        fixture.clock.advance(toMilliseconds: 30)
        XCTAssertEqual(fixture.effects.events, nextCommitted)
        fixture.send(.up, at: 31, rawX: 16_383, rawY: 9_599)
        XCTAssertEqual(fixture.effects.restoredCaptures, [1])
        XCTAssertEqual(fixture.effects.input, [.down(start), .up(start), .down(end), .up(end)])
        fixture.assertFinished(expectedGestures: 2)
    }

    func testRepeatedFreshCompletionCannotBorrowOrPressTwice() {
        let fixture = PreparationFixture()
        fixture.send(.down, at: 0)
        fixture.focus.complete(0)
        let committed = fixture.effects.events
        fixture.focus.complete(0)
        XCTAssertEqual(fixture.effects.events, committed)
        fixture.send(.up, at: 1)
        let completed = fixture.effects.events
        fixture.focus.complete(0)
        fixture.clock.advance(toMilliseconds: 100)
        XCTAssertEqual(fixture.effects.events, completed)
        XCTAssertEqual(fixture.effects.restoredCaptures, [0])
        fixture.assertFinished()
    }

    func testCancellationBeforeCaptureNeverBorrowsOrPostsInput() {
        for watchdog in [false, true] {
            let fixture = PreparationFixture()
            fixture.send(.down, at: 0)
            fixture.clock.advance(toMilliseconds: 1)
            if watchdog {
                fixture.controller.handleIdleTimeout()
            } else {
                fixture.controller.forceCancel()
            }
            fixture.controller.forceCancel()
            let canceled = fixture.effects.events
            fixture.focus.complete(0)
            fixture.clock.advance(toMilliseconds: 100)

            XCTAssertEqual(fixture.effects.events, canceled)
            XCTAssertTrue(fixture.effects.borrows.isEmpty)
            XCTAssertTrue(fixture.effects.input.isEmpty)
            XCTAssertTrue(fixture.effects.releases.isEmpty)
            XCTAssertTrue(fixture.effects.restoredCaptures.isEmpty)
            XCTAssertEqual(fixture.focus.semanticBoundaryCount, 0)
            XCTAssertGreaterThanOrEqual(fixture.focus.discardCount, 1)
            XCTAssertEqual(fixture.controller.state, .idle)
        }
    }

    func testShutdownCleanupInvalidatesPendingCaptureAndCallbacks() {
        let fixture = PreparationFixture()
        fixture.send(.down, at: 0)
        fixture.controller.forceCancel()
        fixture.focus.shutdown()
        let stopped = fixture.effects.events
        fixture.focus.complete(0)
        fixture.clock.advance(toMilliseconds: 100)

        XCTAssertEqual(fixture.effects.events, stopped)
        XCTAssertTrue(fixture.effects.borrows.isEmpty)
        XCTAssertTrue(fixture.effects.input.isEmpty)
        XCTAssertTrue(fixture.effects.restoredCaptures.isEmpty)
        XCTAssertEqual(fixture.focus.semanticBoundaryCount, 0)
        XCTAssertGreaterThanOrEqual(fixture.focus.discardCount, 1)
        XCTAssertEqual(fixture.controller.state, .idle)
    }

    func testDuplicateDownCancelsPreparationAndRejectsContactThroughUp() {
        let fixture = PreparationFixture()
        fixture.send(.down, at: 0)
        fixture.send(.down, at: 1, rawX: 16_383, rawY: 9_599)
        fixture.send(.move, at: 2, rawX: 16_383, rawY: 9_599)
        fixture.send(.down, at: 3, rawX: 16_383, rawY: 9_599)
        fixture.focus.complete(0)
        fixture.clock.advance(toMilliseconds: 30)
        XCTAssertTrue(fixture.effects.borrows.isEmpty)
        XCTAssertTrue(fixture.effects.input.isEmpty)
        XCTAssertEqual(fixture.focus.preparationCount, 1)
        XCTAssertEqual(fixture.focus.semanticBoundaryCount, 0)

        fixture.send(.up, at: 31, rawX: 16_383, rawY: 9_599)
        XCTAssertEqual(fixture.focus.semanticBoundaryCount, 0, "A quarantined up must not freeze focus eligibility.")
        fixture.send(.down, at: 32, rawX: 16_383, rawY: 9_599)
        fixture.focus.complete(1)
        fixture.send(.up, at: 33, rawX: 16_383, rawY: 9_599)
        XCTAssertEqual(fixture.effects.input, [.down(end), .up(end)])
        XCTAssertEqual(fixture.effects.restoredCaptures, [1])
        XCTAssertEqual(fixture.focus.semanticBoundaryCount, 1)
        XCTAssertEqual(fixture.controller.state, .idle)
        fixture.effects.assertBalanced()
    }

    func testAllFocusAndCursorOptionsKeepInputAndReleaseBehavior() {
        for restoreFocus in [true, false] {
            for returnCursor in [true, false] {
                let fixture = PreparationFixture(restoreFocus: restoreFocus, returnCursor: returnCursor)
                fixture.send(.down, at: 0)
                if restoreFocus {
                    XCTAssertTrue(fixture.effects.input.isEmpty)
                    fixture.focus.complete(0)
                } else {
                    XCTAssertEqual(fixture.effects.events, [.borrow(start), .down(start)])
                    XCTAssertEqual(fixture.focus.preparationCount, 0)
                    XCTAssertEqual(fixture.focus.discardCount, 0)
                    XCTAssertEqual(fixture.focus.restoreRequests, 0)
                }
                XCTAssertEqual(fixture.clock.now.uptimeNanoseconds, 0)
                fixture.send(.up, at: 0)
                fixture.clock.advance(toMilliseconds: 100)

                XCTAssertEqual(fixture.effects.input, [.down(start), .up(start)])
                XCTAssertEqual(fixture.effects.releases, [returnCursor])
                XCTAssertEqual(fixture.effects.restoredCaptures, restoreFocus ? [0] : [])
                XCTAssertEqual(fixture.focus.semanticBoundaryCount, restoreFocus ? 1 : 0)
                fixture.assertFinished()
            }
        }
    }

    func testDefaultSynchronousPreparationPreservesConfiguredGestureTiming() {
        let clock = TestGestureScheduler(executeCancelledActions: true)
        let effects = PreparationEffects()
        let focus = SynchronousPreparationFocus(effects: effects)
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 100, y: 200, width: 2_560, height: 720))
        let controller = GestureController(
            mapperProvider: { mapper }, inputSink: PreparationInput(effects: effects),
            cursorController: PreparationCursor(effects: effects), focusRestorer: focus,
            timing: GestureTiming(configuration: DriverConfiguration.defaults.timing), scheduler: clock
        )
        func send(_ kind: TouchEvent.Kind) {
            controller.handle(TouchEvent(kind: kind, contactID: 0, rawX: 0, rawY: 0, timestamp: clock.now))
        }
        send(.down)
        XCTAssertEqual(effects.events, [.prepare, .borrow(start)])
        clock.advance(toMilliseconds: 9)
        XCTAssertTrue(effects.input.isEmpty)
        clock.advance(toMilliseconds: 10)
        XCTAssertEqual(effects.input, [.down(start)])
        clock.advance(toMilliseconds: 11)
        send(.up)
        clock.advance(toMilliseconds: 30)
        XCTAssertEqual(effects.input, [.down(start)])
        clock.advance(toMilliseconds: 31)
        XCTAssertEqual(effects.input, [.down(start), .up(start)])
        XCTAssertTrue(effects.releases.isEmpty)
        clock.advance(toMilliseconds: 40)
        XCTAssertTrue(effects.releases.isEmpty)
        clock.advance(toMilliseconds: 41)
        XCTAssertEqual(effects.events, [
            .prepare, .borrow(start), .down(start), .up(start), .release(true), .restore(0)
        ])
        XCTAssertEqual(controller.state, .idle)
        effects.assertBalanced()
    }
}

private let start = CGPoint(x: 100, y: 200)
private let end = CGPoint(x: CGFloat(2_660).nextDown, y: CGFloat(920).nextDown)

private final class PreparationFixture {
    let clock: TestGestureScheduler
    let effects: PreparationEffects
    let focus: PendingPreparationFocus
    let cursor: PreparationCursor
    let controller: GestureController
    let mapper = CoordinateMapper(displayBounds: CGRect(x: 100, y: 200, width: 2_560, height: 720))
    private let mapperAvailability: PreparationMapperAvailability
    var hasMapper: Bool {
        get { mapperAvailability.isAvailable }
        set { mapperAvailability.isAvailable = newValue }
    }
    var idleCount = 0

    init(restoreFocus: Bool = true, returnCursor: Bool = true, timing: GestureTiming = .immediate) {
        let clock = TestGestureScheduler(executeCancelledActions: true)
        let effects = PreparationEffects()
        let focus = PendingPreparationFocus(effects: effects)
        let cursor = PreparationCursor(effects: effects)
        let mapperAvailability = PreparationMapperAvailability()
        let selectedFocus: FocusRestorer = restoreFocus ? focus : NoOpFocusRestorer()
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 100, y: 200, width: 2_560, height: 720))
        self.clock = clock
        self.effects = effects
        self.focus = focus
        self.cursor = cursor
        self.mapperAvailability = mapperAvailability
        controller = GestureController(
            mapperProvider: { mapperAvailability.isAvailable ? mapper : nil }, inputSink: PreparationInput(effects: effects),
            cursorController: cursor, focusRestorer: selectedFocus,
            returnCursorToPreviousPosition: returnCursor, timing: timing, scheduler: clock
        )
        controller.onBecameIdle = { [weak self] in self?.idleCount += 1 }
    }

    func point(rawX: Int, rawY: Int) -> CGPoint { mapper.map(rawX: rawX, rawY: rawY) }

    func send(_ kind: TouchEvent.Kind, at time: UInt64, rawX: Int = 0, rawY: Int = 0, contactID: Int = 0) {
        clock.advance(toMilliseconds: time)
        controller.handle(TouchEvent(kind: kind, contactID: contactID, rawX: rawX, rawY: rawY, timestamp: clock.now))
    }

    func assertFinished(expectedGestures: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(controller.state, .idle, file: file, line: line)
        XCTAssertEqual(idleCount, expectedGestures, file: file, line: line)
        XCTAssertEqual(effects.releases.count, expectedGestures, file: file, line: line)
        effects.assertBalanced(file: file, line: line)
    }
}

private final class PreparationMapperAvailability {
    var isAvailable = true
}

private final class PreparationEffects {
    enum Event: Equatable {
        case prepare, discard, borrow(CGPoint), update(CGPoint), down(CGPoint), drag(CGPoint), up(CGPoint)
        case release(Bool), restore(Int), show
    }
    var events: [Event] = []
    var input: [Event] {
        events.filter { if case .down = $0 { return true }; if case .drag = $0 { return true }; if case .up = $0 { return true }; return false }
    }
    var borrows: [CGPoint] { events.compactMap { if case .borrow(let point) = $0 { return point }; return nil } }
    var releases: [Bool] { events.compactMap { if case .release(let value) = $0 { return value }; return nil } }
    var restoredCaptures: [Int] { events.compactMap { if case .restore(let id) = $0 { return id }; return nil } }

    func assertBalanced(file: StaticString = #filePath, line: UInt = #line) {
        var pressed = false
        for event in input {
            switch event {
            case .down:
                XCTAssertFalse(pressed, "Repeated mouse-down", file: file, line: line)
                pressed = true
            case .up:
                XCTAssertTrue(pressed, "Mouse-up without ownership", file: file, line: line)
                pressed = false
            case .drag:
                XCTAssertTrue(pressed, "Drag without ownership", file: file, line: line)
            default: break
            }
        }
        XCTAssertFalse(pressed, "Unreleased button", file: file, line: line)
    }
}

private final class PendingPreparationFocus: FocusRestorer {
    private let effects: PreparationEffects
    private var generation = 0
    private var capturedID: Int?
    private var pending: [(generation: Int, completion: () -> Void)] = []
    private var completed: Set<Int> = []
    private(set) var discardCount = 0
    private(set) var restoreRequests = 0
    private(set) var boundarySnapshots: [[PreparationEffects.Event]] = []
    private(set) var semanticBoundaryCount = 0
    private var didEndInput = false
    var onPreparationStarted: (() -> Void)?
    var preparationCount: Int { pending.count }

    init(effects: PreparationEffects) { self.effects = effects }

    func prepareFocusedWindow(completion: @escaping () -> Void) {
        generation += 1
        capturedID = nil
        didEndInput = false
        effects.events.append(.prepare)
        pending.append((generation, completion))
        onPreparationStarted?()
    }

    func complete(_ index: Int) {
        guard pending.indices.contains(index) else {
            XCTFail("No pending focus preparation at index \(index)")
            return
        }
        let request = pending[index]
        if request.generation == generation, completed.insert(index).inserted {
            capturedID = index
        }
        // Deliver even obsolete/repeated callbacks, as a dispatched completion may already be queued.
        request.completion()
    }

    func captureFocusedWindow() { XCTFail("Asynchronous preparation must use its completion contract") }

    func inputDidEnd() {
        boundarySnapshots.append(effects.events)
        guard !didEndInput else { return }
        didEndInput = true
        semanticBoundaryCount += 1
    }

    func restoreCapturedWindow() {
        restoreRequests += 1
        if let capturedID { effects.events.append(.restore(capturedID)) }
        capturedID = nil
        generation += 1
    }

    func discardCapturedWindow() {
        effects.events.append(.discard)
        discardCount += 1
        capturedID = nil
        generation += 1
    }
}

private final class SynchronousPreparationFocus: FocusRestorer {
    let effects: PreparationEffects
    init(effects: PreparationEffects) { self.effects = effects }
    func captureFocusedWindow() { effects.events.append(.prepare) }
    func restoreCapturedWindow() { effects.events.append(.restore(0)) }
    func discardCapturedWindow() { effects.events.append(.discard) }
}

private final class PreparationInput: SyntheticInputSink {
    let effects: PreparationEffects
    init(effects: PreparationEffects) { self.effects = effects }
    func postMouseDown(at point: CGPoint) { effects.events.append(.down(point)) }
    func postMouseUp(at point: CGPoint) { effects.events.append(.up(point)) }
    func postMouseDragged(to point: CGPoint) { effects.events.append(.drag(point)) }
}

private final class PreparationCursor: CursorController {
    let effects: PreparationEffects
    var borrowSucceeds = true
    init(effects: PreparationEffects) { self.effects = effects }
    func borrow(warpingTo point: CGPoint) -> Bool {
        effects.events.append(.borrow(point))
        return borrowSucceeds
    }
    func updatePosition(_ point: CGPoint) { effects.events.append(.update(point)) }
    func releaseBorrow(returnToPreviousPosition: Bool) { effects.events.append(.release(returnToPreviousPosition)) }
    func returnToOrigin() { effects.events.append(.release(true)) }
    func forceShow() { effects.events.append(.show) }
}
