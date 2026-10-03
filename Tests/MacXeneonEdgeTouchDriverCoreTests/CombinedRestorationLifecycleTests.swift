import CoreGraphics
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

// Temporary integration coverage for the independently reviewed focus, cleanup, and configuration changes.
final class CombinedRestorationLifecycleTests: XCTestCase {
    func testPostUpCancellationAndWatchdogNeverReleaseTheButtonTwice() {
        for option in options {
            for useWatchdog in [false, true] {
                XCTContext.runActivity(named: "\(option), watchdog=\(useWatchdog)") { _ in
                    let fixture = CombinedGestureFixture(option: option)
                    fixture.send(.down, at: 0)
                    fixture.send(.up, at: 1)
                    fixture.clock.advance(toMilliseconds: 21)
                    XCTAssertFalse(fixture.isPressed)
                    if useWatchdog {
                        fixture.controller.handleIdleTimeout()
                    } else {
                        fixture.controller.forceCancel()
                    }
                    fixture.controller.forceCancel()
                    fixture.controller.forceCancel()
                    fixture.clock.advance(toMilliseconds: 1_000)

                    XCTAssertEqual(fixture.effects.input, [.down(near), .up(near)])
                    XCTAssertEqual(fixture.effects.releases, [option.cursor])
                    XCTAssertEqual(fixture.effects.restores, option.focus ? 1 : 0)
                    XCTAssertEqual(fixture.idleCount, 1)
                    XCTAssertEqual(fixture.controller.state, .idle)
                    fixture.effects.assertBalanced()
                }
            }
        }
    }

    func testCancelledDownCannotPressTheNextGestureEarly() {
        for option in options {
            let fixture = CombinedGestureFixture(option: option, warp: 100)
            fixture.send(.down, at: 0)
            fixture.clock.advance(toMilliseconds: 1)
            fixture.controller.forceCancel()
            fixture.send(.down, at: 10, far: true)
            fixture.clock.advance(toMilliseconds: 100)

            XCTAssertTrue(fixture.effects.input.isEmpty)
            XCTAssertEqual(fixture.effects.releases, [option.cursor])
            XCTAssertEqual(fixture.idleCount, 1)
            fixture.clock.advance(toMilliseconds: 110)
            fixture.send(.up, at: 111, far: true)
            fixture.clock.advance(toMilliseconds: 231)
            XCTAssertEqual(fixture.effects.input, [.down(far), .up(far)])
            assertCompletedTwoGestures(fixture, option: option)
        }
    }

    func testCancelledUpCannotReleaseTheNextGesture() {
        for option in options {
            let fixture = CombinedGestureFixture(option: option)
            fixture.send(.down, at: 0)
            fixture.send(.up, at: 1)
            fixture.clock.advance(toMilliseconds: 10)
            fixture.controller.forceCancel()
            fixture.send(.down, at: 11, far: true)
            fixture.clock.advance(toMilliseconds: 21)

            XCTAssertEqual(fixture.effects.input, [.down(near), .up(near), .down(far)])
            XCTAssertTrue(fixture.isPressed)
            XCTAssertEqual(fixture.effects.releases, [option.cursor])
            fixture.send(.up, at: 22, far: true)
            fixture.clock.advance(toMilliseconds: 142)
            XCTAssertEqual(fixture.effects.input, [.down(near), .up(near), .down(far), .up(far)])
            assertCompletedTwoGestures(fixture, option: option)
        }
    }

    func testCancelledReturnCannotReleaseCursorOrRestoreFocusDuringNextGesture() {
        for option in options {
            let fixture = CombinedGestureFixture(option: option)
            fixture.send(.down, at: 0)
            fixture.send(.up, at: 1)
            fixture.clock.advance(toMilliseconds: 25)
            fixture.controller.forceCancel()
            fixture.send(.down, at: 30, far: true)
            fixture.clock.advance(toMilliseconds: 121)

            XCTAssertTrue(fixture.isPressed)
            XCTAssertEqual(fixture.effects.releases, [option.cursor])
            XCTAssertEqual(fixture.effects.restores, option.focus ? 1 : 0)
            XCTAssertEqual(fixture.idleCount, 1)
            fixture.send(.up, at: 122, far: true)
            fixture.clock.advance(toMilliseconds: 242)
            XCTAssertEqual(fixture.effects.input, [.down(near), .up(near), .down(far), .up(far)])
            assertCompletedTwoGestures(fixture, option: option)
        }
    }

    func testIgnoredContactCannotMoveReleaseOrScheduleReturnForAcceptedGestures() {
        for option in options {
            let fixture = CombinedGestureFixture(option: option, debounce: 50)
            fixture.send(.down, at: 0)
            fixture.send(.up, at: 1)
            fixture.send(.down, at: 10, far: true)
            fixture.send(.move, at: 12, far: true)
            fixture.send(.up, at: 20, far: true)
            fixture.clock.advance(toMilliseconds: 121)
            XCTAssertEqual(fixture.effects.input, [.down(near), .up(near)])
            XCTAssertTrue(fixture.effects.updates.isEmpty)

            fixture.send(.down, at: 130, far: true)
            fixture.clock.advance(toMilliseconds: 140)
            XCTAssertTrue(fixture.isPressed)
            XCTAssertEqual(fixture.effects.releases, [option.cursor])
            fixture.send(.move, at: 145, far: true)
            fixture.send(.up, at: 150, far: true)
            fixture.clock.advance(toMilliseconds: 250)
            XCTAssertEqual(fixture.effects.input, [.down(near), .up(near), .down(far), .drag(far), .up(far)])
            XCTAssertEqual(fixture.effects.updates, [far])
            assertCompletedTwoGestures(fixture, option: option)
        }
    }

    func testRemovalAndShutdownCleanupHonorOptionsInEveryDelayedPhase() {
        for option in options {
            for cancelTime: UInt64 in [10, 25, 45] {
                for removal in [false, true] {
                    XCTContext.runActivity(named: "\(option), cancel at \(cancelTime), removal=\(removal)") { _ in
                        let fixture = CombinedApplicationFixture(option: option, warp: 20)
                        fixture.send(.down, at: 0)
                        if cancelTime > 20 { fixture.send(.up, at: 20) }
                        fixture.clock.advance(toMilliseconds: cancelTime)
                        if removal {
                            fixture.application.handleDeviceRemoval()
                            fixture.application.handleDeviceRemoval()
                        } else {
                            // The shared teardown invoked by stop(), without starting HID or touching permissions.
                            fixture.application.cancelActiveGesture()
                            fixture.application.cancelActiveGesture()
                        }
                        fixture.clock.advance(toMilliseconds: 2_000)

                        XCTAssertEqual(fixture.effects.input, cancelTime < 20 ? [] : [.down(near), .up(near)])
                        XCTAssertEqual(fixture.effects.releases, [option.cursor])
                        XCTAssertEqual(fixture.effects.captures, option.focus ? 1 : 0)
                        XCTAssertEqual(fixture.effects.restores, option.focus ? 1 : 0)
                        fixture.effects.assertBalanced()
                    }
                }
            }
        }
    }

    func testCancelledApplicationWatchdogCannotEndTheNextGesture() {
        for option in options {
            let fixture = CombinedApplicationFixture(option: option, up: 0, back: 0, watchdog: 100)
            fixture.send(.down, at: 0)
            fixture.send(.up, at: 1)
            fixture.send(.down, at: 50)
            fixture.clock.advance(toMilliseconds: 101)

            XCTAssertEqual(fixture.effects.input, [.down(near), .up(near), .down(near)])
            XCTAssertEqual(fixture.effects.releases, [option.cursor])
            XCTAssertEqual(fixture.effects.restores, option.focus ? 1 : 0)
            fixture.clock.advance(toMilliseconds: 150)
            XCTAssertEqual(fixture.effects.input, [.down(near), .up(near), .down(near), .up(near)])
            XCTAssertEqual(fixture.effects.releases, [option.cursor, option.cursor])
            XCTAssertEqual(fixture.effects.restores, option.focus ? 2 : 0)
            fixture.effects.assertBalanced()
        }
    }

    private let options = [
        CombinedOptions(focus: true, cursor: true), CombinedOptions(focus: true, cursor: false),
        CombinedOptions(focus: false, cursor: true), CombinedOptions(focus: false, cursor: false)
    ]

    private func assertCompletedTwoGestures(_ fixture: CombinedGestureFixture, option: CombinedOptions,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.effects.releases, [option.cursor, option.cursor], file: file, line: line)
        XCTAssertEqual(fixture.effects.captures, option.focus ? 2 : 0, file: file, line: line)
        XCTAssertEqual(fixture.effects.restores, option.focus ? 2 : 0, file: file, line: line)
        XCTAssertEqual(fixture.idleCount, 2, file: file, line: line)
        XCTAssertEqual(fixture.controller.state, .idle, file: file, line: line)
        fixture.effects.assertBalanced(file: file, line: line)
    }
}

private let near = CGPoint(x: 100, y: 200)
private let far = CGPoint(x: 2_660, y: 920)

private struct CombinedOptions: CustomStringConvertible {
    let focus: Bool
    let cursor: Bool
    var description: String { "focus=\(focus), cursor=\(cursor)" }
}

private final class CombinedGestureFixture {
    let clock = TestGestureScheduler(executeCancelledActions: true)
    let effects = CombinedEffects()
    let controller: GestureController
    var idleCount = 0

    init(option: CombinedOptions, warp: Int = 0, debounce: Int = 0) {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 100, y: 200, width: 2_560, height: 720))
        let focus: FocusRestorer = option.focus ? CombinedFocus(effects: effects) : NoOpFocusRestorer()
        controller = GestureController(
            mapperProvider: { mapper }, inputSink: CombinedInput(effects: effects),
            cursorController: CombinedCursor(effects: effects), focusRestorer: focus,
            returnCursorToPreviousPosition: option.cursor,
            timing: GestureTiming(warpToClickDelayMs: warp, downToUpDelayMs: 20,
                                  clickToWarpBackDelayMs: 100, tapDebounceMs: debounce), scheduler: clock
        )
        controller.onBecameIdle = { [weak self] in self?.idleCount += 1 }
    }

    var isPressed: Bool {
        guard case .singleTouch(let context) = controller.state else { return false }
        return context.isMouseDownPosted
    }

    func send(_ kind: TouchEvent.Kind, at time: UInt64, far: Bool = false) {
        clock.advance(toMilliseconds: time)
        controller.handle(TouchEvent(kind: kind, contactID: 0, rawX: far ? 16_383 : 0,
                                     rawY: far ? 9_599 : 0, timestamp: clock.now))
    }
}

private final class CombinedApplicationFixture {
    let clock = TestGestureScheduler(executeCancelledActions: true)
    let effects = CombinedEffects()
    let application: MacXeneonEdgeTouchDriverApplication

    init(option: CombinedOptions, warp: Int = 0, up: Int = 20, back: Int = 100, watchdog: Int = 1_000) {
        var configuration = DriverConfiguration.defaults
        configuration.focus.restorePreviousWindow = option.focus
        configuration.cursor.returnToPreviousPosition = option.cursor
        configuration.timing.warpToClickDelayMs = warp
        configuration.timing.downToUpDelayMs = up
        configuration.timing.clickToWarpBackDelayMs = back
        configuration.timing.tapDebounceMs = 0
        configuration.timing.stuckGestureTimeoutMs = watchdog
        let display = DisplaySnapshot(
            displayID: 42, vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber, serialNumber: CapturedXeneonDisplay.observedSerialNumber,
            bounds: CGRect(x: 100, y: 200, width: 2_560, height: 720),
            pixelsWide: CapturedXeneonDisplay.expectedWidth, pixelsHigh: CapturedXeneonDisplay.expectedHeight
        )
        application = MacXeneonEdgeTouchDriverApplication(
            configuration: configuration, displayResolver: DisplayResolver(activeDisplayProvider: { [display] }),
            inputSink: CombinedInput(effects: effects), cursorController: CombinedCursor(effects: effects),
            focusRestorer: CombinedFocus(effects: effects), scheduler: clock
        )
    }

    func send(_ kind: TouchEvent.Kind, at time: UInt64) {
        clock.advance(toMilliseconds: time)
        application.handleTouchEvent(TouchEvent(kind: kind, contactID: 0, rawX: 0, rawY: 0, timestamp: clock.now))
    }
}

private final class CombinedEffects {
    enum Input: Equatable { case down(CGPoint), up(CGPoint), drag(CGPoint) }
    var input: [Input] = []
    var releases: [Bool] = []
    var updates: [CGPoint] = []
    var captures = 0
    var restores = 0

    func assertBalanced(file: StaticString = #filePath, line: UInt = #line) {
        var pressed = false
        for event in input {
            switch event {
            case .down:
                XCTAssertFalse(pressed, "Duplicate down", file: file, line: line)
                pressed = true
            case .up:
                XCTAssertTrue(pressed, "Up without ownership", file: file, line: line)
                pressed = false
            case .drag:
                XCTAssertTrue(pressed, "Drag without ownership", file: file, line: line)
            }
        }
        XCTAssertFalse(pressed, "Button left down", file: file, line: line)
    }
}

private final class CombinedInput: SyntheticInputSink {
    let effects: CombinedEffects
    init(effects: CombinedEffects) { self.effects = effects }
    func postMouseDown(at point: CGPoint) { effects.input.append(.down(point)) }
    func postMouseUp(at point: CGPoint) { effects.input.append(.up(point)) }
    func postMouseDragged(to point: CGPoint) { effects.input.append(.drag(point)) }
}

private final class CombinedCursor: CursorController {
    let effects: CombinedEffects
    init(effects: CombinedEffects) { self.effects = effects }
    func borrow(warpingTo point: CGPoint) -> Bool { true }
    func updatePosition(_ point: CGPoint) { effects.updates.append(point) }
    func releaseBorrow(returnToPreviousPosition: Bool) { effects.releases.append(returnToPreviousPosition) }
    func returnToOrigin() { effects.releases.append(true) }
    func forceShow() {}
}

private final class CombinedFocus: FocusRestorer {
    let effects: CombinedEffects
    init(effects: CombinedEffects) { self.effects = effects }
    func captureFocusedWindow() { effects.captures += 1 }
    func restoreCapturedWindow() { effects.restores += 1 }
    func discardCapturedWindow() {}
}
