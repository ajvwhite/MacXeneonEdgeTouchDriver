import CoreGraphics
import Darwin
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class ApplicationPermissionStartupTests: XCTestCase {
    func testWaitingRunDoesNotTouchHardwareCursorOrFocusAndSIGTERMExitsSuccessfully() {
        let startup = StartupTestHarness()
        let effects = StartupRecordingEffects()
        var starts = 0
        var stops = 0
        let application = makeApplication(startup: startup, effects: effects, monitoring: DriverMonitoringHooks(
            start: { starts += 1 }, stop: { stops += 1 }
        ))
        startup.runLoop.onRun = {
            startup.worker.runRequest()
            startup.polling.advance(bySeconds: 600)
            XCTAssertEqual(starts, 0)
            XCTAssertTrue(effects.calls.isEmpty)
            startup.signals.send(SIGTERM)
        }

        XCTAssertEqual(application.run(), EXIT_SUCCESS)
        startup.permissions.currentSnapshot = .cgReady
        startup.worker.completeRequest()
        startup.polling.tasks[0].deliverEvenIfCancelled()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(effects.calls.isEmpty)
        XCTAssertEqual(startup.permissions.requestCount, 1)
    }

    func testGrantDuringApplicationRunStartsMonitoringOnlyOnce() {
        let startup = StartupTestHarness()
        let effects = StartupRecordingEffects()
        var starts = 0
        var stops = 0
        let application = makeApplication(startup: startup, effects: effects, monitoring: DriverMonitoringHooks(
            start: { starts += 1 }, stop: { stops += 1 }
        ))
        startup.runLoop.onRun = { [weak application] in
            XCTAssertEqual(starts, 0)
            startup.permissions.currentSnapshot = .cgReady
            startup.polling.advance(bySeconds: 2)
            startup.worker.completeRequest()
            startup.polling.tasks[0].deliverEvenIfCancelled()
            XCTAssertEqual(starts, 1)
            XCTAssertTrue(effects.calls.isEmpty)
            application?.stop()
        }
        XCTAssertEqual(application.run(), EXIT_SUCCESS)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(application.run(), EXIT_SUCCESS)
        XCTAssertEqual(starts, 1)
    }

    func testPostAccessReadyWithUnavailableFocusStillAllowsTouch() {
        let startup = StartupTestHarness(snapshot: .cgReady)
        let effects = StartupRecordingEffects()
        let clock = TestGestureScheduler()
        // This fake focus dependency captures no window and has no AX access.
        let gestures = GestureController(
            mapperProvider: { CoordinateMapper(displayBounds: CGRect(x: 100, y: 200, width: 2_560, height: 720)) },
            inputSink: effects,
            cursorController: effects,
            focusRestorer: effects,
            scheduler: clock
        )
        var starts = 0
        let application = makeApplication(startup: startup, effects: effects, monitoring: DriverMonitoringHooks(
            start: { starts += 1 }, stop: {}
        ))
        startup.runLoop.onRun = { [weak application] in
            XCTAssertEqual(starts, 1)
            XCTAssertTrue(effects.calls.isEmpty, "Startup must not require a focused window.")
            gestures.handle(TouchEvent(kind: .down, contactID: 0, rawX: 0, rawY: 0, timestamp: clock.now))
            gestures.handle(TouchEvent(kind: .up, contactID: 0, rawX: 0, rawY: 0, timestamp: clock.now))
            XCTAssertTrue(effects.calls.contains("mouseDown"))
            XCTAssertTrue(effects.calls.contains("mouseUp"))
            application?.stop()
        }
        XCTAssertEqual(application.run(), EXIT_SUCCESS)
        XCTAssertEqual(startup.worker.submissionCount, 0)
        XCTAssertFalse(startup.permissions.currentSnapshot.accessibilityTrusted)
    }

    func testApplicationReportsHardwareStartupFailureAfterWaiting() {
        let startup = StartupTestHarness()
        let effects = StartupRecordingEffects()
        var stops = 0
        let application = makeApplication(startup: startup, effects: effects, monitoring: DriverMonitoringHooks(
            start: { throw ApplicationStartupError.hardware }, stop: { stops += 1 }
        ))
        startup.runLoop.onRun = {
            startup.permissions.currentSnapshot = .cgReady
            startup.polling.advance(bySeconds: 2)
        }
        XCTAssertEqual(application.run(), EXIT_FAILURE)
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(startup.polling.tasks[0].isCancelled)
    }

    private func makeApplication(
        startup: StartupTestHarness,
        effects: StartupRecordingEffects,
        monitoring: DriverMonitoringHooks
    ) -> MacXeneonEdgeTouchDriverApplication {
        MacXeneonEdgeTouchDriverApplication(
            configuration: .defaults,
            displayResolver: DisplayResolver(activeDisplayProvider: { XCTFail("Unexpected display enumeration"); return [] }),
            inputSink: effects,
            cursorController: effects,
            focusRestorer: effects,
            startupDependencies: startup.dependencies,
            monitoringOverride: monitoring
        )
    }
}

private enum ApplicationStartupError: Error { case hardware }

private final class StartupRecordingEffects: SyntheticInputSink, CursorController, FocusRestorer {
    var calls: [String] = []
    func postMouseDown(at point: CGPoint) { calls.append("mouseDown") }
    func postMouseUp(at point: CGPoint) { calls.append("mouseUp") }
    func postMouseDragged(to point: CGPoint) { calls.append("mouseDragged") }
    func borrow(warpingTo point: CGPoint) -> Bool { calls.append("borrow"); return true }
    func updatePosition(_ point: CGPoint) { calls.append("update") }
    func returnToOrigin() { calls.append("return") }
    func forceShow() { calls.append("forceShow") }
    func captureFocusedWindow() { calls.append("captureUnavailableWindow") }
    func restoreCapturedWindow() { calls.append("restoreNoWindow") }
    func discardCapturedWindow() { calls.append("discardNoWindow") }
}
