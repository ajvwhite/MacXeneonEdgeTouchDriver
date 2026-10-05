import CoreGraphics
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class DoubleClickDeliveryTests: XCTestCase {
    func testTwoVerifiedTapsDeliverCountsOnBothButtons() {
        let f = DoubleClickFixture()
        f.tap(at: 0); f.tap(at: 100); f.tap(at: 200)
        XCTAssertEqual(f.input.counts, [1, 1, 2, 2, 1, 1])
    }

    func testValidSecondTapInsideDebounceStillReachesTarget() {
        let f = DoubleClickFixture(debounce: 50)
        f.tap(at: 0); f.tap(at: 30)
        XCTAssertEqual(f.input.counts, [1, 1, 2, 2])
    }

    func testNewWindowPhysicalInputAndCancellationPreventPairing() {
        for scenario in ["window", "physical", "cancel"] {
            let f = DoubleClickFixture()
            f.tap(at: 0)
            if scenario == "window" { f.preparer.window = "other" as CFString }
            if scenario == "physical" { f.permitted = false }
            if scenario == "cancel" { f.controller.forceCancel() }
            f.tap(at: 100)
            XCTAssertEqual(f.input.counts, [1, 1, 1, 1], scenario)
        }
    }

    func testDragCannotSeedDoubleClick() {
        let f = DoubleClickFixture()
        f.send(.down, at: 0)
        f.send(.move, at: 10, x: 100)
        f.send(.up, at: 20, x: 100)
        f.tap(at: 100, x: 100)
        XCTAssertEqual(f.input.counts, [1, 1, 1, 1])
    }
}

private final class DoubleClickFixture {
    let input = CountInput()
    let preparer = CountTarget()
    let clock = TestGestureScheduler(executeCancelledActions: true)
    let cursor = CountCursor()
    var permitted = true
    var controller: GestureController!
    init(debounce: Int = 0, options: GestureOptions = GestureOptions()) {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 2560, height: 720))
        let timing = GestureTiming(warpToClickDelayMs: 0, downToUpDelayMs: 0, clickToWarpBackDelayMs: 0, tapDebounceMs: debounce)
        controller = GestureController(mapperProvider: { mapper }, inputSink: input,
            cursorController: cursor, timing: timing, scheduler: clock,
            targetPreparer: preparer, doubleClickInterval: { 500_000_000 },
            captureDoubleClickPermit: { [weak self] in { self?.permitted == true } }, options: options)
    }
    func tap(at ms: UInt64, x: Int = 0) { send(.down, at: ms, x: x); send(.up, at: ms + 10, x: x) }
    func send(_ kind: TouchEvent.Kind, at ms: UInt64, x: Int = 0) {
        clock.advance(toMilliseconds: ms)
        controller.handle(TouchEvent(kind: kind, contactID: 0, rawX: x, rawY: 0, timestamp: clock.now))
    }
}
private final class CountTarget: TouchTargetPreparing {
    let requiresPreparation = false
    var window: CFTypeRef = "window" as CFString
    var preparedTargetIdentity: TouchTargetIdentity? { TouchTargetIdentity(pid: 10, application: "app" as CFString, window: window) }
    func prepare(at point: CGPoint, completion: @escaping (Bool) -> Void) { completion(true) }
    func cancel() {}
}
private final class CountInput: ClickCountSyntheticInputSink, ScrollInputSink {
    var scrolls: [(Double, Double, CGPoint)] = []
    var scrollFails = false
    var drags: [CGPoint] = []
    func tryPostScroll(deltaX: Double, deltaY: Double, at point: CGPoint) -> SyntheticInputResult {
        if scrollFails { return .constructionFailed }
        scrolls.append((deltaX, deltaY, point)); return .postInvoked
    }
    var counts: [Int] = []
    private var active: Int?
    func tryPostMouseDown(at point: CGPoint, clickCount: Int) -> SyntheticInputResult {
        guard active == nil else { return .busy }
        active = clickCount; counts.append(clickCount); return .postInvoked
    }
    func tryPostMouseDown(at point: CGPoint) -> SyntheticInputResult { tryPostMouseDown(at: point, clickCount: 1) }
    func tryPostMouseUp(at point: CGPoint) -> SyntheticInputResult {
        guard let count = active else { return .noPendingMouseDown }
        active = nil; counts.append(count); return .postInvoked
    }
    func tryPostMouseDragged(to point: CGPoint) -> SyntheticInputResult { drags.append(point); return .postInvoked }
    func postMouseDown(at point: CGPoint) { _ = tryPostMouseDown(at: point) }
    func postMouseUp(at point: CGPoint) { _ = tryPostMouseUp(at: point) }
    func postMouseDragged(to point: CGPoint) {}
}
private final class CountCursor: CursorController {
    var releases = 0
    func borrow(warpingTo point: CGPoint) -> Bool { true }
    func updatePosition(_ point: CGPoint) {}
    func returnToOrigin() {}
    func forceShow() {}
    func releaseBorrow(returnToPreviousPosition: Bool) { releases += 1 }
}


extension DoubleClickDeliveryTests {
    func testOptionalScrollModeTapStillClicksAndDoubleClicks() {
        let f = DoubleClickFixture(options: GestureOptions(mode: .scroll))
        f.tap(at: 0); f.tap(at: 100)
        XCTAssertEqual(f.input.counts, [1, 1, 2, 2])
        XCTAssertTrue(f.input.scrolls.isEmpty)
        f.clock.advance(toMilliseconds: 1000)
        XCTAssertEqual(f.input.counts, [1, 1, 2, 2], "Canceled hold callbacks cannot post later presses")
        XCTAssertEqual(f.cursor.releases, 2)
    }

    func testEarlyMovementScrollsWithoutMouseDownIncludingCancelledHoldTask() {
        let f = DoubleClickFixture(options: GestureOptions(mode: .scroll))
        f.send(.down, at: 0)
        f.send(.move, at: 20, x: 1000)
        XCTAssertEqual(f.input.scrolls.count, 1)
        XCTAssertTrue(f.input.counts.isEmpty)
        f.clock.advance(toMilliseconds: 300)
        XCTAssertTrue(f.input.counts.isEmpty, "Even a canceled timer already running must not post down")
        f.send(.move, at: 310, x: 1200)
        f.send(.up, at: 320, x: 1200)
        XCTAssertEqual(f.input.scrolls.count, 2)
        XCTAssertTrue(f.input.drags.isEmpty)
        XCTAssertEqual(f.cursor.releases, 1)
        XCTAssertEqual(f.controller.state, .idle)
    }

    func testHoldThenMovementDragsInsteadOfScrolling() {
        let f = DoubleClickFixture(options: GestureOptions(mode: .scroll))
        f.send(.down, at: 0)
        f.clock.advance(toMilliseconds: 300)
        XCTAssertEqual(f.input.counts, [1])
        f.send(.move, at: 310, x: 1000)
        f.send(.up, at: 320, x: 1000)
        XCTAssertEqual(f.input.counts, [1, 1])
        XCTAssertEqual(f.input.drags.count, 1)
        XCTAssertTrue(f.input.scrolls.isEmpty)
        XCTAssertEqual(f.cursor.releases, 1)
    }

    func testJitterBelowThresholdDoesNotScrollOrStartEarlyDrag() {
        let f = DoubleClickFixture(options: GestureOptions(mode: .scroll))
        f.send(.down, at: 0)
        f.send(.move, at: 10, x: 10)
        XCTAssertTrue(f.input.counts.isEmpty)
        XCTAssertTrue(f.input.scrolls.isEmpty)
        f.send(.up, at: 20, x: 10)
        XCTAssertEqual(f.input.counts, [1, 1])
    }

    func testScrollConstructionFailureReleasesCursorWithoutClick() {
        let f = DoubleClickFixture(options: GestureOptions(mode: .scroll))
        f.input.scrollFails = true
        f.send(.down, at: 0); f.send(.move, at: 20, x: 1000)
        XCTAssertEqual(f.controller.state, .idle)
        XCTAssertTrue(f.input.counts.isEmpty)
        XCTAssertEqual(f.cursor.releases, 1)
    }

    func testDirectModeStillDragsImmediately() {
        let f = DoubleClickFixture()
        f.send(.down, at: 0); f.send(.move, at: 20, x: 1000); f.send(.up, at: 30, x: 1000)
        XCTAssertEqual(f.input.counts, [1, 1])
        XCTAssertEqual(f.input.drags.count, 1)
        XCTAssertTrue(f.input.scrolls.isEmpty)
    }

    func testDoubleClickCanBeDisabledWithoutDroppingSeparateTaps() {
        let f = DoubleClickFixture(options: GestureOptions(doubleClickEnabled: false))
        f.tap(at: 0); f.tap(at: 100)
        XCTAssertEqual(f.input.counts, [1, 1, 1, 1])
    }
}
