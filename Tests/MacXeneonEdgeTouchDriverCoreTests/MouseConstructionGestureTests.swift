import CoreGraphics
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class MouseConstructionGestureTests: XCTestCase {
    func testFailedDownDropsFocusReleasesCursorAndQuarantinesUntilPhysicalUp() {
        let f = FailureGestureFixture()
        f.input.downResult = .constructionFailed
        f.send(.down)
        XCTAssertEqual(f.controller.state, .idle)
        XCTAssertEqual(f.cursor.releases, [true])
        XCTAssertEqual(f.focus.discards, 1)
        XCTAssertEqual(f.focus.restores, 0)
        XCTAssertEqual(f.input.calls, [.down(f.near)])
        f.controller.forceCancel()
        f.controller.handleIdleTimeout()
        f.input.downResult = .postInvoked
        f.send(.move, far: true)
        f.send(.down)
        XCTAssertEqual(f.input.calls.count, 1, "Lifecycle cleanup must not clear failed-contact quarantine")
        f.send(.up)
        f.send(.down)
        f.send(.up)
        XCTAssertEqual(f.input.calls, [.down(f.near), .down(f.near), .up(f.near)])
    }

    func testFailedDownWhileHandlingUpConsumesThatPhysicalBoundaryImmediately() {
        let f = FailureGestureFixture(timing: timing(down: 100))
        f.input.downResult = .constructionFailed
        f.send(.down)
        f.send(.up)
        XCTAssertEqual(f.controller.state, .idle)
        f.input.downResult = .postInvoked
        f.send(.down)
        f.send(.up)
        f.scheduler.advance(byMilliseconds: 200)
        XCTAssertEqual(f.input.calls, [.down(f.near), .down(f.near), .up(f.near)])
    }

    func testFailedDownDuringPreparationFlushedByUpConsumesThatUp() {
        let f = FailureGestureFixture()
        f.focus.holdPreparation = true
        f.input.downResult = .constructionFailed
        f.send(.down)
        f.send(.up)
        f.focus.holdPreparation = false
        f.input.downResult = .postInvoked
        f.send(.down)
        f.send(.up)
        XCTAssertEqual(f.input.calls, [.down(f.near), .down(f.near), .up(f.near)])
    }

    func testUnavailableSourceAndBusyDownAlsoAbortWithoutInventingARelease() {
        for result in [SyntheticInputResult.sourceUnavailable, .busy] {
            let f = FailureGestureFixture()
            f.input.downResult = result
            f.send(.down)
            f.send(.up)
            XCTAssertEqual(f.controller.state, .idle)
            XCTAssertEqual(f.input.calls, [.down(f.near)])
            XCTAssertEqual(f.cursor.releases, [true])
            XCTAssertEqual(f.focus.restores, 0)
        }
    }

    func testFailedDragRetainsOwnershipAndLatestAcceptedCoordinates() {
        let f = FailureGestureFixture()
        f.send(.down)
        f.input.dragResult = .constructionFailed
        f.send(.move, far: true)
        guard case .singleTouch(let context) = f.controller.state else { return XCTFail("Lost press") }
        XCTAssertTrue(context.isMouseDownPosted)
        XCTAssertFalse(context.hasMoved)
        XCTAssertEqual(context.lastPoint, f.far)
        f.controller.forceCancel()
        XCTAssertEqual(f.input.calls, [.down(f.near), .drag(f.far), .up(f.far)])
        XCTAssertEqual(f.cursor.releases, [true])
    }

    func testFailedDownHonorsNoReturnPreference() {
        let f = FailureGestureFixture(returnCursor: false)
        f.input.downResult = .constructionFailed
        f.send(.down)
        XCTAssertEqual(f.cursor.releases, [false])
        XCTAssertEqual(f.focus.restores, 0)
    }

    func testRepeatedLifecycleCleanupConsumesTheSameReleaseOnce() {
        let f = FailureGestureFixture(timing: timing(up: 50, returnCursor: 50))
        f.send(.down)
        f.send(.up)
        f.controller.forceCancel()
        f.controller.handleIdleTimeout()
        f.controller.forceCancel()
        f.scheduler.advance(byMilliseconds: 200)
        XCTAssertEqual(f.input.calls, [.down(f.near), .up(f.near)])
        XCTAssertEqual(f.cursor.releases, [true])
    }

    func testCancelledOldCallbacksCannotReleaseANewerReusedContactID() {
        let f = FailureGestureFixture(timing: timing(up: 50), deliverCancelled: true)
        f.send(.down)
        f.send(.up)
        f.controller.forceCancel()
        f.send(.down, far: true)
        f.scheduler.advance(byMilliseconds: 100)
        XCTAssertEqual(f.input.calls, [.down(f.near), .up(f.near), .down(f.far)])
        guard case .singleTouch(let context) = f.controller.state else { return XCTFail("New press lost") }
        XCTAssertTrue(context.isMouseDownPosted)
        f.send(.up, far: true)
        f.scheduler.advance(byMilliseconds: 100)
        XCTAssertEqual(f.input.calls.last, .up(f.far))
    }

    func testReentrantCancelDuringDownWaitsForResultThenReleasesExactlyOnce() {
        let f = FailureGestureFixture()
        f.input.onDown = {
            f.controller.forceCancel()
            f.controller.handleIdleTimeout()
            f.send(.down, id: 1)
            XCTAssertTrue(f.cursor.releases.isEmpty)
            XCTAssertEqual(f.input.calls.count, 1)
        }
        f.send(.down)
        XCTAssertEqual(f.input.calls, [.down(f.near), .up(f.near)])
        XCTAssertEqual(f.cursor.releases, [true])
        XCTAssertEqual(f.controller.state, .idle)
        f.input.onDown = nil
        f.send(.down, id: 1)
        XCTAssertEqual(f.input.calls.count, 2, "Reentrant rejected contact remains quarantined")
        f.send(.up, id: 1)
        f.send(.down, id: 1)
        XCTAssertEqual(f.input.calls.count, 3)
    }

    func testAcceptedUpDuringDownIsFrozenThenReleasedAfterDownReturns() {
        let f = FailureGestureFixture()
        f.input.onDown = {
            f.send(.up, far: true)
            XCTAssertEqual(f.focus.inputEnds, 1, "Freeze eligibility at the observed HID up")
            XCTAssertEqual(f.input.calls, [.down(f.near)], "Never post up inside the down call")
        }
        f.send(.down)
        XCTAssertEqual(f.input.calls, [.down(f.near), .up(f.far)])
        XCTAssertEqual(f.cursor.releases, [true])
        XCTAssertEqual(f.controller.state, .idle)
    }

    func testDuplicateActiveIDDownDuringDownCancelsBeforeItsPhysicalUp() {
        let f = FailureGestureFixture()
        f.input.onDown = { f.send(.down) }
        f.send(.down)
        XCTAssertEqual(f.input.calls, [.down(f.near), .up(f.near)])
        XCTAssertEqual(f.controller.state, .idle)
        f.input.onDown = nil
        f.send(.down)
        XCTAssertEqual(f.input.calls.count, 2, "Ambiguous contact remains quarantined")
        f.send(.up)
        f.send(.down)
        f.send(.up)
        XCTAssertEqual(f.input.calls.count, 4)
    }

    func testForeignRejectedDownAndUpDuringPostDoNotQuarantineItsNextReuse() {
        let f = FailureGestureFixture()
        f.input.onDown = { f.send(.down, id: 1); f.send(.up, id: 1) }
        f.send(.down)
        f.input.onDown = nil
        f.send(.up)
        f.send(.down, id: 1)
        f.send(.up, id: 1)
        XCTAssertEqual(f.input.calls, [.down(f.near), .up(f.near), .down(f.near), .up(f.near)])
    }

    func testAcceptedReentrantUpDuringFailedDownConsumesBoundary() {
        let f = FailureGestureFixture()
        f.input.downResult = .constructionFailed
        f.input.onDown = { f.send(.up) }
        f.send(.down)
        XCTAssertEqual(f.input.calls, [.down(f.near)])
        XCTAssertEqual(f.focus.restores, 0)
        f.input.onDown = nil
        f.input.downResult = .postInvoked
        f.send(.down)
        f.send(.up)
        XCTAssertEqual(f.input.calls, [.down(f.near), .down(f.near), .up(f.near)])
    }

    func testFailedDownWithDuplicateActiveDownAndUpDoesNotRequarantineCompletedContact() {
        let f = FailureGestureFixture()
        f.input.downResult = .constructionFailed
        f.input.onDown = { f.send(.down); f.send(.up) }
        f.send(.down)
        f.input.onDown = nil
        f.input.downResult = .postInvoked
        f.send(.down)
        f.send(.up)
        XCTAssertEqual(f.input.calls, [.down(f.near), .down(f.near), .up(f.near)])
    }

    func testForeignUpDuringFailedDownCannotEndActiveContact() {
        let f = FailureGestureFixture()
        f.input.downResult = .constructionFailed
        f.input.onDown = { f.send(.down, id: 1); f.send(.up, id: 1) }
        f.send(.down)
        f.input.onDown = nil
        f.input.downResult = .postInvoked
        f.send(.down)
        XCTAssertEqual(f.input.calls, [.down(f.near)])
        f.send(.up)
        f.send(.down)
        f.send(.up)
        XCTAssertEqual(f.input.calls, [.down(f.near), .down(f.near), .up(f.near)])
    }

    func testNewActiveIDDownAfterReentrantUpRemainsQuarantinedOnFailure() {
        let f = FailureGestureFixture()
        f.input.downResult = .constructionFailed
        f.input.onDown = { f.send(.up); f.send(.down) }
        f.send(.down)
        f.input.onDown = nil
        f.input.downResult = .postInvoked
        f.send(.down)
        XCTAssertEqual(f.input.calls, [.down(f.near)])
        f.send(.up)
        f.send(.down)
        f.send(.up)
        XCTAssertEqual(f.input.calls, [.down(f.near), .down(f.near), .up(f.near)])
    }

    func testTriggeringOriginalUpCannotConsumeNewerReentrantDownQuarantine() {
        for preparing in [false, true] {
            let f = FailureGestureFixture(timing: timing(down: preparing ? 0 : 100))
            f.focus.holdPreparation = preparing
            f.input.downResult = .constructionFailed
            f.input.onDown = { f.send(.down) }
            f.send(.down)
            f.send(.up) // Forces the delayed/preparing original down to run and fail.
            f.input.onDown = nil
            f.focus.holdPreparation = false
            f.input.downResult = .postInvoked
            f.send(.down)
            XCTAssertEqual(f.input.calls, [.down(f.near)], "Original up must not close the newer down")
            f.send(.up)
            f.send(.down)
            f.send(.up)
            XCTAssertEqual(f.input.calls, [.down(f.near), .down(f.near), .up(f.near)])
        }
    }

    func testOriginalUpFlushingPreparationCannotConsumeNewDownDuringFailureCleanup() {
        let f = FailureGestureFixture()
        f.focus.holdPreparation = true
        f.input.downResult = .constructionFailed
        f.cursor.onEffect = { if $0 == "release" { f.send(.down) } }
        f.send(.down)
        f.send(.up)
        f.cursor.onEffect = nil
        f.focus.holdPreparation = false
        f.input.downResult = .postInvoked
        f.send(.down)
        XCTAssertEqual(f.input.calls, [.down(f.near)], "Cleanup-reentrant contact must remain quarantined")
        f.send(.up)
        f.send(.down)
        f.send(.up)
        XCTAssertEqual(f.input.calls, [.down(f.near), .down(f.near), .up(f.near)])
    }

    func testOlderPreparationFlushingUpCannotReleaseNewGenerationStartedAtIdle() {
        let f = FailureGestureFixture()
        f.focus.holdPreparation = true
        f.input.downResult = .constructionFailed
        f.input.onDown = { f.send(.up) }
        var startReplacement = true
        f.controller.onBecameIdle = {
            guard startReplacement else { return }
            startReplacement = false
            f.focus.holdPreparation = false
            f.input.downResult = .postInvoked
            f.input.onDown = nil
            f.send(.down, far: true)
        }
        f.send(.down)
        f.send(.up)
        XCTAssertEqual(f.input.calls, [.down(f.near), .down(f.far)],
                       "The older outer up must not consume the new generation's press")
        guard case .singleTouch(let context) = f.controller.state else { return XCTFail("Replacement press lost") }
        XCTAssertTrue(context.isMouseDownPosted)
        f.send(.up, far: true)
        XCTAssertEqual(f.input.calls.last, .up(f.far))
    }

    func testAcceptedUpDuringFailedDragUsesReleaseCoordinatesAfterPostReturns() {
        let f = FailureGestureFixture()
        f.input.dragResult = .constructionFailed
        f.input.onDrag = { f.send(.up) }
        f.send(.down)
        f.send(.move, far: true)
        XCTAssertEqual(f.input.calls, [.down(f.near), .drag(f.far), .up(f.near)])
        XCTAssertEqual(f.controller.state, .idle)
    }

    func testDeferredUpAndReentrantCancellationUseAcceptedReleasePoint() {
        let f = FailureGestureFixture()
        f.input.onDown = { f.send(.up, far: true); f.controller.forceCancel() }
        f.send(.down)
        XCTAssertEqual(f.input.calls, [.down(f.near), .up(f.far)])
        XCTAssertEqual(f.cursor.releases, [true])
    }

    func testReentrantCancellationDuringFailedDownDoesNotEmitUpOrRestoreFocus() {
        let f = FailureGestureFixture()
        f.input.downResult = .constructionFailed
        f.input.onDown = { f.controller.forceCancel() }
        f.send(.down)
        XCTAssertEqual(f.input.calls, [.down(f.near)])
        XCTAssertEqual(f.cursor.releases, [true])
        XCTAssertEqual(f.focus.restores, 0)
    }

    func testReentrantCancelAndDownDuringNormalUpCannotDuplicateOrOvertakeRelease() {
        let f = FailureGestureFixture()
        f.input.onUp = {
            f.controller.forceCancel()
            f.controller.forceCancel()
            f.send(.down, id: 1)
            XCTAssertTrue(f.cursor.releases.isEmpty)
            XCTAssertEqual(f.input.calls.count, 2)
        }
        f.send(.down)
        f.send(.up)
        XCTAssertEqual(f.input.calls, [.down(f.near), .up(f.near)])
        XCTAssertEqual(f.cursor.releases, [true])
        XCTAssertEqual(f.controller.state, .idle)
    }

    func testReentrantCancelDuringForcedUpCannotDuplicateRelease() {
        let f = FailureGestureFixture(returnCursor: false)
        f.input.onUp = {
            f.controller.forceCancel()
            f.send(.down, id: 1)
        }
        f.send(.down)
        f.controller.forceCancel()
        XCTAssertEqual(f.input.calls, [.down(f.near), .up(f.near)])
        XCTAssertEqual(f.cursor.releases, [false])
    }

    func testReentrantCancelDuringFailedDragReleasesAcceptedPoint() {
        let f = FailureGestureFixture()
        f.input.dragResult = .constructionFailed
        f.input.onDrag = { f.controller.forceCancel() }
        f.send(.down)
        f.send(.move, far: true)
        XCTAssertEqual(f.input.calls, [.down(f.near), .drag(f.far), .up(f.far)])
        XCTAssertEqual(f.controller.state, .idle)
    }

    func testContractViolatingReleaseStaysOwnedAndDoesNotWarpOrRetry() {
        let f = FailureGestureFixture()
        f.input.upResult = .constructionFailed
        f.send(.down)
        f.send(.up)
        f.controller.forceCancel()
        f.controller.handleIdleTimeout()
        f.send(.down, id: 1)
        f.scheduler.advance(byMilliseconds: 1_000)
        guard case .singleTouch(let context) = f.controller.state else { return XCTFail("Must retain unresolved release") }
        XCTAssertTrue(context.isMouseDownPosted)
        XCTAssertEqual(f.input.calls, [.down(f.near), .up(f.near)])
        XCTAssertEqual(f.cursor.releases, [false], "Show/reassociate once without warping under an unresolved down")
        XCTAssertEqual(f.focus.restores, 0)
    }

    func testNormalDelaysAndOrderRemainUnchanged() {
        let f = FailureGestureFixture(timing: timing(down: 10, up: 20, returnCursor: 30))
        f.send(.down)
        XCTAssertTrue(f.input.calls.isEmpty)
        f.scheduler.advance(byMilliseconds: 10)
        f.send(.up)
        XCTAssertEqual(f.input.calls, [.down(f.near)])
        f.scheduler.advance(byMilliseconds: 19)
        XCTAssertEqual(f.input.calls.count, 1)
        f.scheduler.advance(byMilliseconds: 1)
        XCTAssertEqual(f.input.calls, [.down(f.near), .up(f.near)])
        XCTAssertTrue(f.cursor.releases.isEmpty)
        f.scheduler.advance(byMilliseconds: 29)
        XCTAssertTrue(f.cursor.releases.isEmpty)
        f.scheduler.advance(byMilliseconds: 1)
        XCTAssertEqual(f.effects, ["borrow", "down", "up", "release", "restore"])
        XCTAssertEqual(f.controller.state, .idle)
    }

    func testCGSinkPermanentFactoryFailureReleasesReserveBeforeNormalOrForcedCleanup() {
        for cancel in [false, true] {
            var attempts = 0
            var posts: [MouseInputEvent] = []
            var releaseTime: UInt64 = 10
            var flags: CGEventFlags = []
            var fixture: FailureGestureFixture!
            let sink = CGEventInputSink(environment: MouseInputEnvironment(
                makeEvent: { type, point in
                    attempts += 1
                    guard attempts <= 2 else { return nil }
                    return GestureConstructionEvent(type: type, point: point)
                },
                post: { event, _ in
                    if event.type == .leftMouseUp {
                        XCTAssertTrue(fixture.cursor.releases.isEmpty)
                        XCTAssertEqual(fixture.focus.restores, 0)
                    }
                    posts.append(event)
                },
                timestamp: { releaseTime }, sourceStateID: 777, flags: { flags }
            ))
            fixture = FailureGestureFixture(inputOverride: sink)
            fixture.send(.down)
            releaseTime = 900_000_000
            flags = .maskCommand
            fixture.send(.move, far: true) // Construction fails; coordinates are still accepted.
            if cancel { fixture.controller.forceCancel() } else { fixture.send(.up, far: true) }
            fixture.controller.forceCancel()
            fixture.scheduler.advance(byMilliseconds: 1_000)
            XCTAssertEqual(posts.map { $0.type }, [.leftMouseDown, .leftMouseUp])
            XCTAssertEqual(posts.last?.location, fixture.far)
            XCTAssertEqual(posts.last?.timestamp, releaseTime)
            XCTAssertEqual(posts.last?.flags, flags)
            XCTAssertEqual(posts.last?.getIntegerValueField(.mouseEventNumber), 314)
            XCTAssertEqual(fixture.cursor.releases, [true])
            XCTAssertEqual(fixture.controller.state, .idle)
            XCTAssertEqual(attempts, 4, "Reserve, down, failed drag, one failed fresh up; no retry")
        }
    }

    private func timing(down: Int = 0, up: Int = 0, returnCursor: Int = 0) -> GestureTiming {
        GestureTiming(warpToClickDelayMs: down, downToUpDelayMs: up,
                      clickToWarpBackDelayMs: returnCursor, tapDebounceMs: 0)
    }
}

private final class FailureGestureFixture {
    let input = FailureGestureSink()
    let cursor = FailureGestureCursor()
    let focus = FailureGestureFocus()
    let scheduler: TestGestureScheduler
    let mapper = CoordinateMapper(rawMinX: 0, rawMaxX: 100, rawMinY: 0, rawMaxY: 100,
                                  displayBounds: CGRect(x: 10, y: 20, width: 100, height: 100))
    var controller: GestureController!
    var effects: [String] = []
    var near: CGPoint { mapper.map(rawX: 0, rawY: 0) }
    var far: CGPoint { mapper.map(rawX: 50, rawY: 50) }

    init(timing: GestureTiming = .immediate, returnCursor: Bool = true, deliverCancelled: Bool = false,
         inputOverride: SyntheticInputSink? = nil) {
        scheduler = TestGestureScheduler(executeCancelledActions: deliverCancelled)
        controller = GestureController(mapperProvider: { [unowned self] in self.mapper },
                                       inputSink: inputOverride ?? input, cursorController: cursor, focusRestorer: focus,
                                       returnCursorToPreviousPosition: returnCursor,
                                       timing: timing, scheduler: scheduler)
        input.onEffect = { [weak self] in self?.effects.append($0) }
        cursor.onEffect = { [weak self] in self?.effects.append($0) }
        focus.onRestore = { [weak self] in self?.effects.append("restore") }
    }

    func send(_ kind: TouchEvent.Kind, far: Bool = false, id: Int = 0) {
        controller.handle(TouchEvent(kind: kind, contactID: id, rawX: far ? 50 : 0,
                                     rawY: far ? 50 : 0, timestamp: scheduler.now))
    }
}

private final class FailureGestureSink: ReportingSyntheticInputSink {
    enum Call: Equatable { case down(CGPoint), up(CGPoint), drag(CGPoint) }
    var calls: [Call] = []
    var downResult: SyntheticInputResult = .postInvoked
    var upResult: SyntheticInputResult = .postInvoked
    var dragResult: SyntheticInputResult = .postInvoked
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onDrag: (() -> Void)?
    var onEffect: ((String) -> Void)?
    func postMouseDown(at point: CGPoint) { XCTFail("Controller must use reporting capability") }
    func postMouseUp(at point: CGPoint) { XCTFail("Controller must use reporting capability") }
    func postMouseDragged(to point: CGPoint) { XCTFail("Controller must use reporting capability") }
    func tryPostMouseDown(at point: CGPoint) -> SyntheticInputResult {
        calls.append(.down(point)); onEffect?("down"); onDown?(); return downResult
    }
    func tryPostMouseUp(at point: CGPoint) -> SyntheticInputResult {
        calls.append(.up(point)); onEffect?("up"); onUp?(); return upResult
    }
    func tryPostMouseDragged(to point: CGPoint) -> SyntheticInputResult {
        calls.append(.drag(point)); onEffect?("drag"); onDrag?(); return dragResult
    }
}

private final class FailureGestureCursor: CursorController {
    var releases: [Bool] = []
    var onEffect: ((String) -> Void)?
    func borrow(warpingTo point: CGPoint) -> Bool { onEffect?("borrow"); return true }
    func updatePosition(_ point: CGPoint) { onEffect?("move") }
    func returnToOrigin() { XCTFail("Use releaseBorrow") }
    func releaseBorrow(returnToPreviousPosition: Bool) {
        releases.append(returnToPreviousPosition); onEffect?("release")
    }
    func forceShow() {}
}

private final class FailureGestureFocus: FocusRestorer {
    var discards = 0
    var restores = 0
    var inputEnds = 0
    var holdPreparation = false
    var onRestore: (() -> Void)?
    func prepareFocusedWindow(completion: @escaping () -> Void) {
        if !holdPreparation { completion() }
    }
    func captureFocusedWindow() {}
    func inputDidEnd() { inputEnds += 1 }
    func restoreCapturedWindow() { restores += 1; onRestore?() }
    func discardCapturedWindow() { discards += 1 }
}

private final class GestureConstructionEvent: MouseInputEvent {
    var type: CGEventType
    var location: CGPoint
    var timestamp: CGEventTimestamp = 1
    var flags: CGEventFlags = []
    private var fields: [CGEventField: Int64] = [.eventSourceStateID: 777, .mouseEventNumber: 314]
    init(type: CGEventType, point: CGPoint) { self.type = type; location = point }
    func getIntegerValueField(_ field: CGEventField) -> Int64 { fields[field, default: 0] }
    func setIntegerValueField(_ field: CGEventField, value: Int64) { fields[field] = value }
}
