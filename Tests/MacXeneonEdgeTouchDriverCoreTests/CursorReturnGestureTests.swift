import CoreGraphics
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class CursorReturnGestureTests: XCTestCase {
    func testTapOptionsPreserveInputTimingAndCleanupOrder() {
        for timing in timings {
            for options in combinations {
                XCTContext.runActivity(named: "tap: \(options), \(timing.name)") { _ in
                    let harness = Harness(options: options, timing: timing.value)
                    harness.send(.down)
                    harness.scheduler.advance(byMilliseconds: 1)
                    harness.send(.up)

                    XCTAssertEqual(harness.trace.downCount, 1)
                    if timing.value.downToUpDelayMs > 0 {
                        XCTAssertEqual(harness.trace.upCount, 0)
                        XCTAssertTrue(harness.trace.releases.isEmpty)
                        harness.scheduler.advance(byMilliseconds: UInt64(timing.value.downToUpDelayMs - 1))
                        XCTAssertEqual(harness.trace.upCount, 0)
                        harness.scheduler.advance(byMilliseconds: 1)
                    }
                    XCTAssertEqual(harness.trace.upCount, 1)
                    finishReturnDelay(harness, milliseconds: timing.value.clickToWarpBackDelayMs)

                    XCTAssertEqual(harness.trace.effects, expected(
                        options,
                        input: [.down(Harness.start), .up(Harness.start)]
                    ))
                    XCTAssertEqual(harness.controller.state, .idle)
                    XCTAssertEqual(harness.idleTransitions, 1)
                }
            }
        }
    }

    func testDragOptionsKeepImmediateDragAndReleaseAtTheExistingDeadline() {
        for timing in timings {
            for options in combinations {
                XCTContext.runActivity(named: "drag: \(options), \(timing.name)") { _ in
                    let harness = Harness(options: options, timing: timing.value)
                    harness.send(.down)
                    harness.scheduler.advance(byMilliseconds: 1)
                    harness.send(.move, atEnd: true)

                    XCTAssertEqual(harness.trace.downCount, 1)
                    XCTAssertEqual(harness.trace.effects.suffix(2), [.update(Harness.end), .drag(Harness.end)])
                    harness.send(.up, atEnd: true)
                    XCTAssertEqual(harness.trace.upCount, 1, "Dragging must not acquire the tap's mouse-up delay.")
                    finishReturnDelay(harness, milliseconds: timing.value.clickToWarpBackDelayMs)

                    XCTAssertEqual(harness.trace.effects, expected(
                        options,
                        input: [.down(Harness.start), .update(Harness.end), .drag(Harness.end), .up(Harness.end)]
                    ))
                    XCTAssertEqual(harness.controller.state, .idle)
                    XCTAssertEqual(harness.idleTransitions, 1)
                }
            }
        }
    }

    func testCancelBeforeMouseDownReleasesBorrowWithoutPostingInput() {
        for options in combinations {
            XCTContext.runActivity(named: options.description) { _ in
                let harness = Harness(options: options, timing: cancellationTiming, executeCancelledActions: true)
                harness.send(.down)
                harness.scheduler.advance(byMilliseconds: 1)
                harness.controller.forceCancel()

                XCTAssertEqual(harness.trace.effects, expected(options, input: []))
                assertLateCallbacksHaveNoEffects(harness)
            }
        }
    }

    func testCancelDuringDragReleasesButtonBeforeCursorAndFocus() {
        for options in combinations {
            XCTContext.runActivity(named: options.description) { _ in
                let harness = Harness(options: options, timing: cancellationTiming, executeCancelledActions: true)
                harness.send(.down)
                harness.scheduler.advance(byMilliseconds: 1)
                harness.send(.move, atEnd: true)
                harness.controller.forceCancel()

                XCTAssertEqual(harness.trace.effects, expected(
                    options,
                    input: [.down(Harness.start), .update(Harness.end), .drag(Harness.end), .up(Harness.end)]
                ))
                assertLateCallbacksHaveNoEffects(harness)
            }
        }
    }

    func testCancelWhileWaitingForMouseUpReleasesOnceAndCancelsDelayedWork() {
        for options in combinations {
            XCTContext.runActivity(named: options.description) { _ in
                let harness = Harness(options: options, timing: cancellationTiming, executeCancelledActions: true)
                harness.send(.down)
                harness.scheduler.advance(byMilliseconds: 1)
                harness.send(.up)
                XCTAssertEqual(harness.trace.upCount, 0)
                harness.controller.forceCancel()

                XCTAssertEqual(harness.trace.effects, expected(
                    options,
                    input: [.down(Harness.start), .up(Harness.start)]
                ))
                assertLateCallbacksHaveNoEffects(harness)
            }
        }
    }

    func testWatchdogDuringTrackingHonorsBothOptionsAndReleasesTheButton() {
        for options in combinations {
            XCTContext.runActivity(named: options.description) { _ in
                let harness = Harness(options: options, timing: cancellationTiming, executeCancelledActions: true)
                harness.send(.down)
                harness.scheduler.advance(byMilliseconds: 10)
                XCTAssertEqual(harness.trace.downCount, 1)
                harness.controller.handleIdleTimeout()

                XCTAssertEqual(harness.trace.effects, expected(
                    options,
                    input: [.down(Harness.start), .up(Harness.start)]
                ))
                assertLateCallbacksHaveNoEffects(harness)
            }
        }
    }

    func testUnavailableFocusCaptureStillDeliversTouchAndReleasesCursor() {
        for shouldReturn in [true, false] {
            let options = Options(restoreFocus: true, returnCursor: shouldReturn)
            let harness = Harness(options: options, timing: .immediate, captureAvailable: false)
            harness.send(.down)
            harness.send(.up)

            XCTAssertEqual(harness.trace.effects, [
                .capture, .borrow(Harness.start), .down(Harness.start), .up(Harness.start), .release(shouldReturn)
            ])
            XCTAssertEqual(harness.focus.restoreRequests, 1)
            XCTAssertEqual(harness.controller.state, .idle)
        }
    }

    private var combinations: [Options] {
        [true, false].flatMap { focus in
            [true, false].map { Options(restoreFocus: focus, returnCursor: $0) }
        }
    }

    private var timings: [(name: String, value: GestureTiming)] {
        [
            ("immediate", .immediate),
            ("defaults", GestureTiming(configuration: DriverConfiguration.defaults.timing)),
            ("custom", GestureTiming(
                warpToClickDelayMs: 30, downToUpDelayMs: 40, clickToWarpBackDelayMs: 100, tapDebounceMs: 50
            ))
        ]
    }

    private var cancellationTiming: GestureTiming {
        GestureTiming(warpToClickDelayMs: 10, downToUpDelayMs: 20, clickToWarpBackDelayMs: 100, tapDebounceMs: 50)
    }

    private func expected(_ options: Options, input: [Effect]) -> [Effect] {
        (options.restoreFocus ? [.capture] : []) + [.borrow(Harness.start)] + input +
            [.release(options.returnCursor)] + (options.restoreFocus ? [.restore] : [])
    }

    private func finishReturnDelay(_ harness: Harness, milliseconds: Int, file: StaticString = #filePath, line: UInt = #line) {
        if milliseconds > 0 {
            XCTAssertTrue(harness.trace.releases.isEmpty, file: file, line: line)
            XCTAssertEqual(harness.idleTransitions, 0, file: file, line: line)
            harness.scheduler.advance(byMilliseconds: UInt64(milliseconds - 1))
            XCTAssertTrue(harness.trace.releases.isEmpty, file: file, line: line)
            harness.scheduler.advance(byMilliseconds: 1)
        }
        XCTAssertEqual(harness.trace.releases.count, 1, file: file, line: line)
    }

    private func assertLateCallbacksHaveNoEffects(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) {
        let effects = harness.trace.effects
        XCTAssertEqual(harness.controller.state, .idle, file: file, line: line)
        XCTAssertEqual(harness.idleTransitions, 1, file: file, line: line)
        harness.scheduler.advance(byMilliseconds: 1_000)
        XCTAssertEqual(harness.trace.effects, effects, file: file, line: line)
        XCTAssertEqual(harness.controller.state, .idle, file: file, line: line)
        XCTAssertEqual(harness.idleTransitions, 1, file: file, line: line)
    }
}

private struct Options: CustomStringConvertible {
    let restoreFocus: Bool
    let returnCursor: Bool

    var description: String { "restoreFocus=\(restoreFocus), returnCursor=\(returnCursor)" }
}

private enum Effect: Equatable {
    case capture
    case borrow(CGPoint)
    case down(CGPoint)
    case update(CGPoint)
    case drag(CGPoint)
    case up(CGPoint)
    case release(Bool)
    case restore
    case discard
    case legacyReturn
    case forceShow
}

private final class Trace {
    var effects: [Effect] = []
    var downCount: Int { effects.filter { if case .down = $0 { return true }; return false }.count }
    var upCount: Int { effects.filter { if case .up = $0 { return true }; return false }.count }
    var releases: [Bool] { effects.compactMap { if case .release(let value) = $0 { return value }; return nil } }
}

private final class Harness {
    static let start = CGPoint(x: 100, y: 200)
    static let end = CGPoint(x: CGFloat(2_660).nextDown, y: CGFloat(920).nextDown)

    let scheduler: TestGestureScheduler
    let trace: Trace
    let focus: RecordingFocus
    let controller: GestureController
    var idleTransitions = 0

    init(options: Options, timing: GestureTiming, executeCancelledActions: Bool = false, captureAvailable: Bool = true) {
        let scheduler = TestGestureScheduler(executeCancelledActions: executeCancelledActions)
        let trace = Trace()
        let focus = RecordingFocus(trace: trace, captureAvailable: captureAvailable)
        self.scheduler = scheduler
        self.trace = trace
        self.focus = focus
        let selectedFocus: FocusRestorer = options.restoreFocus ? focus : NoOpFocusRestorer()
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 100, y: 200, width: 2_560, height: 720))
        controller = GestureController(
            mapperProvider: { mapper },
            inputSink: RecordingInput(trace: trace),
            cursorController: RecordingCursor(trace: trace),
            focusRestorer: selectedFocus,
            returnCursorToPreviousPosition: options.returnCursor,
            timing: timing,
            scheduler: scheduler
        )
        controller.onBecameIdle = { [weak self] in self?.idleTransitions += 1 }
    }

    func send(_ kind: TouchEvent.Kind, atEnd: Bool = false) {
        controller.handle(TouchEvent(
            kind: kind, contactID: 0, rawX: atEnd ? 16_383 : 0, rawY: atEnd ? 9_599 : 0, timestamp: scheduler.now
        ))
    }
}

private final class RecordingInput: SyntheticInputSink {
    let trace: Trace
    init(trace: Trace) { self.trace = trace }
    func postMouseDown(at point: CGPoint) { trace.effects.append(.down(point)) }
    func postMouseUp(at point: CGPoint) { trace.effects.append(.up(point)) }
    func postMouseDragged(to point: CGPoint) { trace.effects.append(.drag(point)) }
}

private final class RecordingCursor: CursorController {
    let trace: Trace
    init(trace: Trace) { self.trace = trace }
    func borrow(warpingTo point: CGPoint) -> Bool {
        trace.effects.append(.borrow(point))
        return true
    }
    func updatePosition(_ point: CGPoint) { trace.effects.append(.update(point)) }
    func releaseBorrow(returnToPreviousPosition: Bool) { trace.effects.append(.release(returnToPreviousPosition)) }
    func returnToOrigin() { trace.effects.append(.legacyReturn) }
    func forceShow() { trace.effects.append(.forceShow) }
}

private final class RecordingFocus: FocusRestorer {
    let trace: Trace
    let captureAvailable: Bool
    var hasCapture = false
    var restoreRequests = 0

    init(trace: Trace, captureAvailable: Bool) {
        self.trace = trace
        self.captureAvailable = captureAvailable
    }

    func captureFocusedWindow() {
        trace.effects.append(.capture)
        hasCapture = captureAvailable
    }

    func restoreCapturedWindow() {
        restoreRequests += 1
        if hasCapture { trace.effects.append(.restore) }
        hasCapture = false
    }

    func discardCapturedWindow() {
        trace.effects.append(.discard)
        hasCapture = false
    }
}
