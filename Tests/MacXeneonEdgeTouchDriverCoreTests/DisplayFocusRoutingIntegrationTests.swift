import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

/// Exercises display routing with the combined gesture ownership and focus preparation paths.
final class DisplayFocusRoutingIntegrationTests: XCTestCase {
    func testGeometryLossOrChangeCancelsPreparationBeforeRecoveredContact() {
        for losesDisplay in [false, true] {
            let fixture = DisplayFocusFixture()
            fixture.send(.down)
            XCTAssertEqual(fixture.focus.preparationCount, 1)
            XCTAssertTrue(fixture.effects.input.isEmpty)
            fixture.clock.advance(toMilliseconds: 10)

            fixture.provider.displays = losesDisplay ? [] : [displayFocusSnapshot(at: displayFocusMoved)]
            fixture.application.handleDisplayReconfiguration(flags: .movedFlag)

            XCTAssertTrue(fixture.effects.borrows.isEmpty)
            XCTAssertTrue(fixture.effects.releases.isEmpty)
            XCTAssertTrue(fixture.effects.input.isEmpty)
            XCTAssertTrue(fixture.effects.restores.isEmpty)
            if losesDisplay {
                XCTAssertNil(fixture.resolver.currentMapper)
                fixture.provider.displays = [displayFocusSnapshot(at: displayFocusMoved)]
                fixture.application.handleDeviceMatched()
            }

            fixture.send(.down, at: 11)
            fixture.focus.complete(1)
            XCTAssertEqual(fixture.effects.input, [.down(displayFocusMoved)])
            let recoveredEffects = fixture.effects.events

            fixture.focus.complete(0)
            fixture.clock.advance(toMilliseconds: 41)
            fixture.focus.complete(0)

            XCTAssertEqual(fixture.effects.events, recoveredEffects,
                           "Old capture completions and cancelled deadlines must leave recovered input untouched")
            fixture.send(.up, at: 42)
            XCTAssertEqual(fixture.effects.input, [.down(displayFocusMoved), .up(displayFocusMoved)])
            XCTAssertEqual(fixture.effects.releases, [true])
            XCTAssertEqual(fixture.effects.restores, [1])
            fixture.effects.assertBalanced()
        }
    }

    func testBeginPhaseCancelsPreparationAndCannotAdmitInputBeforePostChange() {
        let fixture = DisplayFocusFixture()
        fixture.send(.down)
        fixture.clock.advance(toMilliseconds: 5)
        fixture.provider.displays = [displayFocusSnapshot(at: displayFocusMoved)]
        let readsBeforeBegin = fixture.provider.readCount

        fixture.application.handleDisplayReconfiguration(flags: .beginConfigurationFlag)
        fixture.focus.complete(0)
        fixture.send(.down, at: 6)
        fixture.send(.up, at: 7)
        fixture.clock.advance(toMilliseconds: 35)

        XCTAssertEqual(fixture.provider.readCount, readsBeforeBegin)
        XCTAssertEqual(fixture.focus.preparationCount, 1)
        XCTAssertTrue(fixture.effects.input.isEmpty)
        XCTAssertTrue(fixture.effects.borrows.isEmpty)
        XCTAssertNil(fixture.resolver.currentMapper)

        fixture.application.handleDisplayReconfiguration(flags: [])
        fixture.send(.down, at: 36)
        fixture.focus.complete(1)
        fixture.send(.up, at: 37)

        XCTAssertEqual(fixture.effects.input, [.down(displayFocusMoved), .up(displayFocusMoved)])
        XCTAssertEqual(fixture.effects.restores, [1])
        fixture.effects.assertBalanced()
    }

    func testGeometryCancellationDiscardsFocusBeforeReleasingOwnedInput() {
        let fixture = DisplayFocusFixture()
        fixture.send(.down)
        fixture.focus.complete(0)
        fixture.send(.move, at: 1, far: true)
        fixture.effects.events.removeAll()
        fixture.provider.displays = [displayFocusSnapshot(at: displayFocusMoved)]

        fixture.application.handleDisplayReconfiguration(flags: .movedFlag)

        XCTAssertEqual(fixture.effects.events.prefix(4), [
            .discard, .inputEnded, .up(displayFocusFar), .release(true)
        ])
        XCTAssertTrue(fixture.effects.restores.isEmpty,
                      "Cancellation must revoke the old display contact's captured focus")
        fixture.send(.down, at: 2)
        fixture.focus.complete(1)
        fixture.send(.up, at: 3)
        XCTAssertEqual(fixture.effects.input, [
            .up(displayFocusFar), .down(displayFocusMoved), .up(displayFocusMoved)
        ])
        XCTAssertEqual(fixture.effects.restores, [1])
    }

    func testGeometryRecoveryPreservesAllFocusAndCursorSettings() {
        for restoreFocus in [false, true] {
            for returnCursor in [false, true] {
                let fixture = DisplayFocusFixture(restoreFocus: restoreFocus, returnCursor: returnCursor)
                fixture.send(.down)
                if restoreFocus { fixture.focus.complete(0) }
                fixture.send(.move, at: 1, far: true)
                fixture.provider.displays = []

                fixture.application.handleDisplayReconfiguration(flags: .removeFlag)
                XCTAssertEqual(fixture.effects.input, [
                    .down(displayFocusOrigin), .drag(displayFocusFar), .up(displayFocusFar)
                ])
                XCTAssertEqual(fixture.effects.releases, [returnCursor])
                XCTAssertTrue(fixture.effects.restores.isEmpty)

                fixture.provider.displays = [displayFocusSnapshot(at: displayFocusMoved)]
                fixture.application.handleDeviceMatched()
                fixture.send(.down, at: 2)
                if restoreFocus { fixture.focus.complete(1) }
                fixture.send(.up, at: 3)
                fixture.clock.advance(toMilliseconds: 40)

                XCTAssertEqual(fixture.effects.input, [
                    .down(displayFocusOrigin), .drag(displayFocusFar), .up(displayFocusFar),
                    .down(displayFocusMoved), .up(displayFocusMoved)
                ])
                XCTAssertEqual(fixture.effects.releases, [returnCursor, returnCursor])
                XCTAssertEqual(fixture.focus.preparationCount, restoreFocus ? 2 : 0)
                XCTAssertEqual(fixture.effects.restores, restoreFocus ? [1] : [])
                fixture.effects.assertBalanced()
            }
        }
    }

    func testUnfinishedFocusStillDeliversTouchWithValidDisplay() {
        let fixture = DisplayFocusFixture()
        fixture.send(.down)

        fixture.clock.advance(toMilliseconds: 30)
        fixture.send(.move, at: 31, far: true)
        fixture.send(.up, at: 32, far: true)
        fixture.focus.complete(0)

        XCTAssertEqual(fixture.effects.input, [
            .down(displayFocusOrigin), .drag(displayFocusFar), .up(displayFocusFar)
        ])
        XCTAssertEqual(fixture.effects.releases, [true])
        XCTAssertTrue(fixture.effects.restores.isEmpty)
        fixture.effects.assertBalanced()
    }

    func testMissingMapperReleasesOwnedInputWithoutWaitingForAnyDisplayRefresh() {
        for returnCursor in [false, true] {
            let clock = TestGestureScheduler(executeCancelledActions: true)
            let effects = DisplayFocusEffects()
            let focus = DisplayFocusPendingRestorer(effects: effects)
            let availability = DisplayFocusMapperAvailability()
            let controller = GestureController(
                mapperProvider: { availability.mapper },
                inputSink: DisplayFocusInput(effects: effects),
                cursorController: DisplayFocusCursor(effects: effects),
                focusRestorer: focus,
                returnCursorToPreviousPosition: returnCursor,
                timing: .immediate,
                scheduler: clock
            )
            controller.handle(displayFocusTouch(.down, at: clock))
            focus.complete(0)
            controller.handle(displayFocusTouch(.move, at: clock, far: true))

            availability.mapper = nil
            controller.handle(displayFocusTouch(.up, at: clock, far: true))
            clock.advance(toMilliseconds: 100)

            XCTAssertEqual(controller.state, .idle)
            XCTAssertEqual(effects.input, [
                .down(displayFocusOrigin), .drag(displayFocusFar), .up(displayFocusFar)
            ])
            XCTAssertEqual(effects.releases, [returnCursor])
            XCTAssertEqual(focus.acceptedInputEndCount, 1)
            effects.assertBalanced()
        }
    }
}

private let displayFocusOrigin = CGPoint(x: 100, y: 200)
private let displayFocusFar = CGPoint(x: CGFloat(2_660).nextDown, y: CGFloat(920).nextDown)
private let displayFocusMoved = CGPoint(x: -2_560, y: 500)

private func displayFocusSnapshot(at origin: CGPoint = displayFocusOrigin) -> DisplaySnapshot {
    DisplaySnapshot(
        displayID: 42,
        vendorNumber: CapturedXeneonDisplay.vendorNumber,
        modelNumber: CapturedXeneonDisplay.modelNumber,
        serialNumber: CapturedXeneonDisplay.observedSerialNumber,
        bounds: CGRect(origin: origin, size: CGSize(width: 2_560, height: 720)),
        pixelsWide: 2_560,
        pixelsHigh: 720
    )
}

private func displayFocusTouch(
    _ kind: TouchEvent.Kind,
    at clock: TestGestureScheduler,
    far: Bool = false
) -> TouchEvent {
    TouchEvent(
        kind: kind,
        contactID: 0,
        rawX: far ? XeneonEdgeDevice.rawXRange.upperBound : XeneonEdgeDevice.rawXRange.lowerBound,
        rawY: far ? XeneonEdgeDevice.rawYRange.upperBound : XeneonEdgeDevice.rawYRange.lowerBound,
        timestamp: clock.now
    )
}

private final class DisplayFocusProvider {
    var displays = [displayFocusSnapshot()]
    private(set) var readCount = 0
    func read() -> [DisplaySnapshot] {
        readCount += 1
        return displays
    }
}

private final class DisplayFocusMapperAvailability {
    var mapper: CoordinateMapper? = CoordinateMapper(displayBounds: displayFocusSnapshot().bounds)
}

private struct DisplayFocusFixture {
    let application: MacXeneonEdgeTouchDriverApplication
    let resolver: DisplayResolver
    let provider: DisplayFocusProvider
    let clock: TestGestureScheduler
    let effects: DisplayFocusEffects
    let focus: DisplayFocusPendingRestorer

    init(restoreFocus: Bool = true, returnCursor: Bool = true) {
        var configuration = DriverConfiguration.defaults
        configuration.focus.restorePreviousWindow = restoreFocus
        configuration.cursor.returnToPreviousPosition = returnCursor
        configuration.timing.warpToClickDelayMs = 0
        configuration.timing.downToUpDelayMs = 0
        configuration.timing.clickToWarpBackDelayMs = 0
        configuration.timing.tapDebounceMs = 0
        configuration.timing.stuckGestureTimeoutMs = 1_000
        let provider = DisplayFocusProvider()
        let resolver = DisplayResolver(activeDisplayProvider: provider.read)
        let clock = TestGestureScheduler(executeCancelledActions: true)
        let effects = DisplayFocusEffects()
        let focus = DisplayFocusPendingRestorer(effects: effects)
        application = MacXeneonEdgeTouchDriverApplication(
            configuration: configuration,
            displayResolver: resolver,
            inputSink: DisplayFocusInput(effects: effects),
            cursorController: DisplayFocusCursor(effects: effects),
            focusRestorer: focus,
            scheduler: clock
        )
        self.resolver = resolver
        self.provider = provider
        self.clock = clock
        self.effects = effects
        self.focus = focus
    }

    func send(_ kind: TouchEvent.Kind, at milliseconds: UInt64? = nil, far: Bool = false) {
        if let milliseconds { clock.advance(toMilliseconds: milliseconds) }
        application.handleTouchEvent(displayFocusTouch(kind, at: clock, far: far))
    }
}

private enum DisplayFocusEvent: Equatable {
    case prepare
    case discard
    case inputEnded
    case restore(Int)
    case down(CGPoint)
    case drag(CGPoint)
    case up(CGPoint)
    case borrow(CGPoint)
    case release(Bool)
    case show
}

private final class DisplayFocusEffects {
    var events: [DisplayFocusEvent] = []
    var input: [DisplayFocusEvent] {
        events.filter {
            switch $0 {
            case .down, .drag, .up: return true
            default: return false
            }
        }
    }
    var borrows: [CGPoint] { events.compactMap { if case .borrow(let point) = $0 { return point }; return nil } }
    var releases: [Bool] { events.compactMap { if case .release(let value) = $0 { return value }; return nil } }
    var restores: [Int] { events.compactMap { if case .restore(let id) = $0 { return id }; return nil } }

    func assertBalanced(file: StaticString = #filePath, line: UInt = #line) {
        var isPressed = false
        for event in input {
            switch event {
            case .down:
                XCTAssertFalse(isPressed, "A new down must not overlap an owned button", file: file, line: line)
                isPressed = true
            case .drag:
                XCTAssertTrue(isPressed, "A drag requires an owned button", file: file, line: line)
            case .up:
                XCTAssertTrue(isPressed, "An up requires an owned button", file: file, line: line)
                isPressed = false
            default: break
            }
        }
        XCTAssertFalse(isPressed, "The contact must release its button", file: file, line: line)
    }
}

private final class DisplayFocusPendingRestorer: FocusRestorer {
    let effects: DisplayFocusEffects
    private var generation = 0
    private var captured: Int?
    private var inputEnded = false
    private var callbacks: [(generation: Int, completion: () -> Void)] = []
    private(set) var acceptedInputEndCount = 0
    var preparationCount: Int { callbacks.count }

    init(effects: DisplayFocusEffects) { self.effects = effects }

    func prepareFocusedWindow(completion: @escaping () -> Void) {
        generation += 1
        captured = nil
        inputEnded = false
        effects.events.append(.prepare)
        callbacks.append((generation, completion))
    }

    func complete(_ index: Int) {
        guard callbacks.indices.contains(index) else {
            XCTFail("Missing requested focus preparation")
            return
        }
        let callback = callbacks[index]
        if callback.generation == generation { captured = index }
        callback.completion()
    }

    func captureFocusedWindow() { XCTFail("Combined controller must use focus preparation") }

    func inputDidEnd() {
        guard !inputEnded else { return }
        inputEnded = true
        acceptedInputEndCount += 1
        effects.events.append(.inputEnded)
    }

    func restoreCapturedWindow() {
        if let captured { effects.events.append(.restore(captured)) }
        captured = nil
        generation += 1
    }

    func discardCapturedWindow() {
        effects.events.append(.discard)
        captured = nil
        generation += 1
    }
}

private final class DisplayFocusInput: SyntheticInputSink {
    let effects: DisplayFocusEffects
    init(effects: DisplayFocusEffects) { self.effects = effects }
    func postMouseDown(at point: CGPoint) { effects.events.append(.down(point)) }
    func postMouseDragged(to point: CGPoint) { effects.events.append(.drag(point)) }
    func postMouseUp(at point: CGPoint) { effects.events.append(.up(point)) }
}

private final class DisplayFocusCursor: CursorController {
    let effects: DisplayFocusEffects
    init(effects: DisplayFocusEffects) { self.effects = effects }
    func borrow(warpingTo point: CGPoint) -> Bool { effects.events.append(.borrow(point)); return true }
    func updatePosition(_ point: CGPoint) {}
    func releaseBorrow(returnToPreviousPosition: Bool) { effects.events.append(.release(returnToPreviousPosition)) }
    func returnToOrigin() { effects.events.append(.release(true)) }
    func forceShow() { effects.events.append(.show) }
}
