import CoreGraphics
import Darwin
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class PermissionFocusShutdownIntegrationTests: XCTestCase {
    func testExplicitStopInvalidatesPermissionBeforeReentrantFocusShutdown() {
        let startup = StartupTestHarness()
        let effects = PermissionFocusShutdownEffects()
        var starts = 0
        var stops = 0
        let application = makeApplication(startup: startup, effects: effects, monitoring: DriverMonitoringHooks(
            start: { starts += 1 }, stop: { stops += 1 }
        ))
        effects.onShutdown = {
            startup.permissions.currentSnapshot = .cgReady
            startup.polling.tasks[0].deliverEvenIfCancelled()
            startup.worker.completeRequest()
        }
        startup.runLoop.onRun = { [weak application] in application?.stop() }

        XCTAssertEqual(application.run(), EXIT_SUCCESS)

        XCTAssertEqual(starts, 0, "Focus cleanup cannot restart hardware during explicit stop.")
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(effects.events, ["focus.shutdown"])
        XCTAssertTrue(startup.polling.tasks[0].isCancelled)
    }

    func testSignalStopShutsFocusDownBeforeHardwareAndGestureTeardown() {
        let startup = StartupTestHarness(snapshot: .cgReady)
        let effects = PermissionFocusShutdownEffects()
        let application = makeApplication(startup: startup, effects: effects, monitoring: DriverMonitoringHooks(
            start: {}, stop: { effects.events.append("hardware.stop") }
        ))
        startup.runLoop.onRun = { startup.signals.send(SIGTERM) }

        XCTAssertEqual(application.run(), EXIT_SUCCESS)

        XCTAssertEqual(Array(effects.events.prefix(3)), ["focus.shutdown", "hardware.stop", "focus.discard"])
        XCTAssertFalse(effects.events.contains("focus.capture"))
        XCTAssertFalse(effects.events.contains("mouseDown"))
    }

    private func makeApplication(
        startup: StartupTestHarness,
        effects: PermissionFocusShutdownEffects,
        monitoring: DriverMonitoringHooks
    ) -> MacXeneonEdgeTouchDriverApplication {
        var configuration = DriverConfiguration.defaults
        configuration.focus.restorePreviousWindow = true
        return MacXeneonEdgeTouchDriverApplication(
            configuration: configuration,
            displayResolver: DisplayResolver(activeDisplayProvider: { XCTFail("Unexpected display enumeration"); return [] }),
            inputSink: effects,
            cursorController: effects,
            focusRestorer: effects,
            startupDependencies: startup.dependencies,
            monitoringOverride: monitoring
        )
    }
}

private final class PermissionFocusShutdownEffects: SyntheticInputSink, CursorController, FocusRestorer {
    var events: [String] = []
    var onShutdown: (() -> Void)?
    func postMouseDown(at point: CGPoint) { events.append("mouseDown") }
    func postMouseUp(at point: CGPoint) { events.append("mouseUp") }
    func postMouseDragged(to point: CGPoint) { events.append("mouseDragged") }
    func borrow(warpingTo point: CGPoint) -> Bool { events.append("borrow"); return true }
    func updatePosition(_ point: CGPoint) { events.append("update") }
    func returnToOrigin() { events.append("return") }
    func forceShow() { events.append("forceShow") }
    func captureFocusedWindow() { events.append("focus.capture") }
    func restoreCapturedWindow() { events.append("focus.restore") }
    func discardCapturedWindow() { events.append("focus.discard") }
    func shutdown() {
        events.append("focus.shutdown")
        onShutdown?()
    }
}
