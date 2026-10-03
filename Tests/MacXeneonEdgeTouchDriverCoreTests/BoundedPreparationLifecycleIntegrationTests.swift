import CoreGraphics
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

// Temporary checks for combining bounded preparation with the independent gesture-cleanup changes.
final class BoundedPreparationLifecycleIntegrationTests: XCTestCase {
    func testForeignRejectedAndRepeatedUpsCannotFreezeAcceptedOrNextGesture() {
        for focusEnabled in [true, false] {
            for returnCursor in [true, false] {
                let fixture = BoundedApplicationFixture(focusEnabled: focusEnabled, returnCursor: returnCursor)
                fixture.send(.down, at: 0)
                fixture.send(.down, at: 1, contactID: 1)
                fixture.send(.up, at: 2, contactID: 1)
                XCTAssertEqual(fixture.focus.rawInputEndCount, 0)
                fixture.send(.move, at: 3, atEnd: true)
                fixture.send(.up, at: 4, atEnd: true)
                XCTAssertEqual(fixture.focus.inputEndCount, focusEnabled ? 1 : 0)
                let firstBoundaryCalls = fixture.focus.rawInputEndCount

                fixture.send(.up, at: 5)
                fixture.send(.down, at: 6)
                fixture.send(.up, at: 7)
                XCTAssertEqual(fixture.focus.rawInputEndCount, firstBoundaryCalls,
                               "Repeated and quarantined ups during cursor cleanup cannot freeze another baseline.")
                fixture.clock.advance(toMilliseconds: 104)
                fixture.send(.down, at: 110, atEnd: true)
                fixture.send(.up, at: 111, contactID: 1)
                XCTAssertEqual(fixture.focus.rawInputEndCount, firstBoundaryCalls)
                fixture.send(.up, at: 112, atEnd: true)
                XCTAssertEqual(fixture.focus.inputEndCount, focusEnabled ? 2 : 0)
                let secondRawReleaseCalls = fixture.focus.rawInputEndCount
                fixture.send(.up, at: 113, atEnd: true)
                XCTAssertEqual(fixture.focus.rawInputEndCount, secondRawReleaseCalls,
                               "A repeated accepted-ID up while waiting for synthetic up must be ignored.")
                fixture.clock.advance(toMilliseconds: 2_000)

                XCTAssertEqual(fixture.effects.input, [
                    .down(origin), .drag(endpoint), .up(endpoint), .down(endpoint), .up(endpoint)
                ])
                XCTAssertEqual(fixture.effects.releases, [returnCursor, returnCursor])
                XCTAssertEqual(fixture.focus.inputEndCount, focusEnabled ? 2 : 0)
            }
        }
    }

    func testSupersededSyntheticUpCannotFreezeNewGenerationBeforeItsRawUp() {
        for returnCursor in [true, false] {
            let fixture = BoundedApplicationFixture(focusEnabled: true, returnCursor: returnCursor)
            fixture.send(.down, at: 0)
            fixture.send(.up, at: 1)
            XCTAssertEqual(fixture.focus.inputEndCount, 1)
            fixture.clock.advance(toMilliseconds: 10)
            fixture.application.cancelActiveGesture()
            fixture.send(.down, at: 11, atEnd: true)
            let afterCancellation = fixture.focus.rawInputEndCount
            fixture.clock.advance(toMilliseconds: 21)

            XCTAssertEqual(fixture.focus.rawInputEndCount, afterCancellation,
                           "The canceled synthetic-up callback belongs to the prior generation.")
            XCTAssertEqual(fixture.focus.inputEndCount, 1)
            XCTAssertEqual(fixture.effects.input, [.down(origin), .up(origin), .down(endpoint)])
            fixture.send(.up, at: 22, atEnd: true)
            XCTAssertEqual(fixture.focus.inputEndCount, 2)
            fixture.clock.advance(toMilliseconds: 23)
            fixture.application.cancelActiveGesture()
            fixture.application.cancelActiveGesture()
            fixture.clock.advance(toMilliseconds: 2_000)

            XCTAssertEqual(fixture.focus.inputEndCount, 2,
                           "Cancellation after raw release must preserve the existing semantic boundary.")
            XCTAssertEqual(fixture.effects.input, [.down(origin), .up(origin), .down(endpoint), .up(endpoint)])
            XCTAssertEqual(fixture.effects.releases, [returnCursor, returnCursor])
        }
    }

    func testLifecycleCleanupWhilePreparingNeverBorrowsOrPostsInput() {
        for returnCursor in [true, false] {
            for path in ["removal", "shutdown", "watchdog"] {
                let fixture = BoundedApplicationFixture(focusEnabled: true, returnCursor: returnCursor,
                                                       pendingCapture: true, watchdog: 5)
                fixture.send(.down, at: 0)
                fixture.clock.advance(toMilliseconds: 1)
                switch path {
                case "removal": fixture.application.handleDeviceRemoval()
                case "shutdown":
                    fixture.focus.shutdown()
                    fixture.application.cancelActiveGesture()
                default: fixture.clock.advance(toMilliseconds: 5)
                }
                let canceled = fixture.effects.events
                fixture.focus.complete(0)
                fixture.clock.advance(toMilliseconds: 2_000)

                XCTAssertEqual(fixture.effects.events, canceled, path)
                XCTAssertTrue(fixture.effects.input.isEmpty, path)
                XCTAssertTrue(fixture.effects.borrows.isEmpty, path)
                XCTAssertTrue(fixture.effects.releases.isEmpty, path)
                XCTAssertTrue(fixture.effects.restores.isEmpty, path)
            }
        }
    }

    func testFocusChangeAfterButtonUpInvalidatesRestoreDuringCursorDelay() {
        for focusEnabled in [true, false] {
            for returnCursor in [true, false] {
                for changesFocus in [false, true] {
                    let fixture = BoundedApplicationFixture(focusEnabled: focusEnabled, returnCursor: returnCursor)
                    fixture.send(.down, at: 0)
                    fixture.send(.up, at: 1)
                    XCTAssertEqual(fixture.focus.inputEndCount, focusEnabled ? 1 : 0,
                                   "Eligibility ends at the accepted physical release, before the synthetic-up delay.")
                    XCTAssertEqual(fixture.effects.input, [.down(origin)])
                    fixture.clock.advance(toMilliseconds: 21)
                    XCTAssertEqual(fixture.effects.input, [.down(origin), .up(origin)])
                    XCTAssertTrue(fixture.effects.releases.isEmpty)
                    XCTAssertEqual(fixture.focus.inputEndCount, focusEnabled ? 1 : 0)
                    if focusEnabled {
                        XCTAssertEqual(Array(fixture.effects.events.suffix(2)), [.inputEnded, .up(origin)])
                    }
                    fixture.clock.advance(toMilliseconds: 22)
                    if changesFocus { fixture.focus.observeFocusChange() }
                    fixture.clock.advance(toMilliseconds: 121)

                    XCTAssertEqual(fixture.effects.releases, [returnCursor])
                    XCTAssertEqual(fixture.effects.restores, focusEnabled && !changesFocus ? [0] : [])
                    XCTAssertEqual(fixture.focus.preparationCount, focusEnabled ? 1 : 0)
                    fixture.clock.advance(toMilliseconds: 2_000)
                    XCTAssertEqual(fixture.effects.input, [.down(origin), .up(origin)])
                }
            }
        }
    }

    func testPendingNewCaptureAndOldMouseDownCannotPressOrRestoreWrongGeneration() {
        for returnCursor in [true, false] {
            let fixture = BoundedApplicationFixture(focusEnabled: true, returnCursor: returnCursor,
                                                   pendingCapture: true, warp: 100)
            fixture.send(.down, at: 0)
            fixture.focus.complete(0)
            fixture.clock.advance(toMilliseconds: 1)
            fixture.application.cancelActiveGesture()
            fixture.send(.down, at: 10, atEnd: true)
            let preparingNext = fixture.effects.events
            fixture.focus.complete(0)
            XCTAssertEqual(fixture.effects.events, preparingNext)
            fixture.clock.advance(toMilliseconds: 29)
            fixture.focus.complete(1)
            fixture.clock.advance(toMilliseconds: 100)

            XCTAssertTrue(fixture.effects.input.isEmpty, "The canceled first mouse-down must not press the new contact.")
            XCTAssertEqual(fixture.effects.borrows, [origin, endpoint])
            XCTAssertEqual(fixture.effects.releases, [returnCursor])
            fixture.clock.advance(toMilliseconds: 129)
            XCTAssertEqual(fixture.effects.input, [.down(endpoint)])
            fixture.send(.up, at: 130, atEnd: true)
            fixture.clock.advance(toMilliseconds: 150)
            let released = fixture.effects.events
            fixture.focus.complete(0)
            XCTAssertEqual(fixture.effects.events, released)
            fixture.clock.advance(toMilliseconds: 250)

            XCTAssertEqual(fixture.effects.input, [.down(endpoint), .up(endpoint)])
            XCTAssertEqual(fixture.effects.releases, [returnCursor, returnCursor])
            XCTAssertEqual(fixture.effects.restores, [1])
            XCTAssertEqual(fixture.focus.inputEndCount, 1)
        }
    }
}

private let origin = CGPoint(x: 100, y: 200)
private let endpoint = CGPoint(x: 2_660, y: 920)

private final class BoundedApplicationFixture {
    let clock = TestGestureScheduler(executeCancelledActions: true)
    let effects = BoundedEffects()
    let focus: BoundedPendingFocus
    let application: MacXeneonEdgeTouchDriverApplication

    init(focusEnabled: Bool, returnCursor: Bool, pendingCapture: Bool = false, warp: Int = 0, watchdog: Int = 1_000) {
        let focus = BoundedPendingFocus(effects: effects, pendingCapture: pendingCapture)
        self.focus = focus
        var configuration = DriverConfiguration.defaults
        configuration.focus.restorePreviousWindow = focusEnabled
        configuration.cursor.returnToPreviousPosition = returnCursor
        configuration.timing.warpToClickDelayMs = warp
        configuration.timing.downToUpDelayMs = 20
        configuration.timing.clickToWarpBackDelayMs = 100
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
            inputSink: BoundedInput(effects: effects), cursorController: BoundedCursor(effects: effects),
            focusRestorer: focus, scheduler: clock
        )
    }

    func send(_ kind: TouchEvent.Kind, at time: UInt64, atEnd: Bool = false, contactID: Int = 0) {
        clock.advance(toMilliseconds: time)
        application.handleTouchEvent(TouchEvent(kind: kind, contactID: contactID, rawX: atEnd ? 16_383 : 0,
                                               rawY: atEnd ? 9_599 : 0, timestamp: clock.now))
    }
}

private final class BoundedEffects {
    enum Event: Equatable {
        case preparation, discard, inputEnded, borrow(CGPoint), down(CGPoint), up(CGPoint), drag(CGPoint)
        case release(Bool), restore(Int), show
    }
    var events: [Event] = []
    var input: [Event] {
        events.filter { if case .down = $0 { return true }; if case .up = $0 { return true }; if case .drag = $0 { return true }; return false }
    }
    var borrows: [CGPoint] { events.compactMap { if case .borrow(let point) = $0 { return point }; return nil } }
    var releases: [Bool] { events.compactMap { if case .release(let value) = $0 { return value }; return nil } }
    var restores: [Int] { events.compactMap { if case .restore(let id) = $0 { return id }; return nil } }
}

private final class BoundedPendingFocus: FocusRestorer {
    let effects: BoundedEffects
    let pendingCapture: Bool
    private var generation = 0
    private var capturedID: Int?
    private var isReleased = false
    private var callbacks: [(generation: Int, completion: () -> Void)] = []
    private var completed: Set<Int> = []
    private(set) var inputEndCount = 0
    private(set) var rawInputEndCount = 0
    var preparationCount: Int { callbacks.count }

    init(effects: BoundedEffects, pendingCapture: Bool) {
        self.effects = effects
        self.pendingCapture = pendingCapture
    }

    func prepareFocusedWindow(completion: @escaping () -> Void) {
        generation += 1
        capturedID = nil
        isReleased = false
        effects.events.append(.preparation)
        callbacks.append((generation, completion))
        if !pendingCapture { complete(callbacks.count - 1) }
    }

    func complete(_ index: Int) {
        guard callbacks.indices.contains(index) else { XCTFail("Missing pending capture"); return }
        let callback = callbacks[index]
        if callback.generation == generation, completed.insert(index).inserted { capturedID = index }
        callback.completion()
    }

    func captureFocusedWindow() { XCTFail("Use preparation") }

    func inputDidEnd() {
        rawInputEndCount += 1
        guard !isReleased else { return }
        inputEndCount += 1
        effects.events.append(.inputEnded)
        isReleased = true
    }

    func observeFocusChange() {
        if isReleased { capturedID = nil }
    }

    func restoreCapturedWindow() {
        if let capturedID { effects.events.append(.restore(capturedID)) }
        capturedID = nil
        generation += 1
    }

    func discardCapturedWindow() {
        effects.events.append(.discard)
        capturedID = nil
        generation += 1
    }
}

private final class BoundedInput: SyntheticInputSink {
    let effects: BoundedEffects
    init(effects: BoundedEffects) { self.effects = effects }
    func postMouseDown(at point: CGPoint) { effects.events.append(.down(point)) }
    func postMouseUp(at point: CGPoint) { effects.events.append(.up(point)) }
    func postMouseDragged(to point: CGPoint) { effects.events.append(.drag(point)) }
}

private final class BoundedCursor: CursorController {
    let effects: BoundedEffects
    init(effects: BoundedEffects) { self.effects = effects }
    func borrow(warpingTo point: CGPoint) -> Bool { effects.events.append(.borrow(point)); return true }
    func updatePosition(_ point: CGPoint) {}
    func releaseBorrow(returnToPreviousPosition: Bool) { effects.events.append(.release(returnToPreviousPosition)) }
    func returnToOrigin() { effects.events.append(.release(true)) }
    func forceShow() { effects.events.append(.show) }
}
