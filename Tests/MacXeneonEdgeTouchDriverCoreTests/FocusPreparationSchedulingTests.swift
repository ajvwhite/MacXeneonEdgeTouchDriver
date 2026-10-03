import CoreGraphics
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class FocusPreparationSchedulingTests: XCTestCase {
    func testRealGestureQueueContinuesWithoutAnAXCompletionAndCleansUp() {
        for restoreFocus in [true, false] {
            for returnCursor in [true, false] {
                let down = expectation(description: "down \(restoreFocus)/\(returnCursor)")
                let idle = expectation(description: "idle \(restoreFocus)/\(returnCursor)")
                let trace = SchedulingTrace()
                let queue = DispatchQueue(label: "focus-preparation-test")
                let focus: FocusRestorer = restoreFocus ? UnfinishedPreparation() : NoOpFocusRestorer()
                let controller = GestureController(
                    mapperProvider: { CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 2560, height: 720)) },
                    inputSink: SchedulingInput(trace: trace, down: down),
                    cursorController: SchedulingCursor(trace: trace),
                    focusRestorer: focus,
                    returnCursorToPreviousPosition: returnCursor,
                    timing: .immediate,
                    schedulingQueue: queue
                )
                controller.onBecameIdle = { idle.fulfill() }
                queue.async {
                    trace.start()
                    controller.handle(TouchEvent(kind: .down, contactID: 0, rawX: 0, rawY: 0, timestamp: .now()))
                }
                wait(for: [down], timeout: 2)
                queue.async { controller.forceCancel() }
                wait(for: [idle], timeout: 2)

                let result = trace.snapshot()
                XCTAssertEqual(result.events, ["borrow", "down", "up", "release:\(returnCursor)"])
                XCTAssertNotNil(result.downMilliseconds)
                print("Preparation input latency: focus=\(restoreFocus), cursor=\(returnCursor), ms=\(result.downMilliseconds ?? -1)")
            }
        }
    }
}

private final class SchedulingTrace {
    private let lock = NSLock()
    private var started: UInt64 = 0
    private var events: [String] = []
    private var downMilliseconds: Double?

    func start() {
        lock.lock()
        started = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        if event == "down" {
            downMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        }
        lock.unlock()
    }

    func snapshot() -> (events: [String], downMilliseconds: Double?) {
        lock.lock()
        defer { lock.unlock() }
        return (events, downMilliseconds)
    }
}

private final class UnfinishedPreparation: FocusRestorer {
    func prepareFocusedWindow(completion: @escaping () -> Void) {}
    func captureFocusedWindow() {}
    func restoreCapturedWindow() {}
    func discardCapturedWindow() {}
}

private final class SchedulingInput: SyntheticInputSink {
    let trace: SchedulingTrace
    let down: XCTestExpectation
    init(trace: SchedulingTrace, down: XCTestExpectation) { self.trace = trace; self.down = down }
    func postMouseDown(at point: CGPoint) { trace.record("down"); down.fulfill() }
    func postMouseUp(at point: CGPoint) { trace.record("up") }
    func postMouseDragged(to point: CGPoint) { trace.record("drag") }
}

private final class SchedulingCursor: CursorController {
    let trace: SchedulingTrace
    init(trace: SchedulingTrace) { self.trace = trace }
    func borrow(warpingTo point: CGPoint) -> Bool { trace.record("borrow"); return true }
    func updatePosition(_ point: CGPoint) {}
    func returnToOrigin() { releaseBorrow(returnToPreviousPosition: true) }
    func forceShow() { releaseBorrow(returnToPreviousPosition: false) }
    func releaseBorrow(returnToPreviousPosition: Bool) { trace.record("release:\(returnToPreviousPosition)") }
}
