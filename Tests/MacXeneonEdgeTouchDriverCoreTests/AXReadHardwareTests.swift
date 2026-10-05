import ApplicationServices
import CoreGraphics
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

/// Opt-in native read check. Focus a harmless text field in a browser first.
/// This diagnostic never activates windows, changes focus, posts input or prompts.
final class AXReadHardwareTests: XCTestCase {
    func testFocusedTypingRecipientAndInactiveTargetAreResolvable() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XENEON_RUN_AX_READ_TESTS"] == "1" else {
            throw XCTSkip("Set XENEON_RUN_AX_READ_TESTS=1 with a harmless field focused and target coordinates supplied.")
        }
        guard Thread.isMainThread else { XCTFail("Workspace inspection must run on main"); return }
        guard AXIsProcessTrusted() else { XCTFail("Accessibility is not granted; no prompt was requested."); return }
        guard let pid = environment["XENEON_AX_TEST_PID"].flatMap(Int32.init), pid > 0,
              let application = WorkspaceFocusMonitor().application(processIdentifier: pid) else {
            XCTFail("Supply XENEON_AX_TEST_PID for the application with the harmless field focused.")
            return
        }
        let finished = expectation(description: "bounded worker reads")
        DispatchQueue(label: "AXReadHardwareTests.worker").async {
            defer { finished.fulfill() }
            self.check(application: application, environment: environment)
        }
        wait(for: [finished], timeout: 5)
    }

    private func check(application: AXFocusWorkspaceApplication, environment: [String: String]) {
        let operations = SystemAXFocusOperations()
        let app = operations.applicationElement(pid: application.processIdentifier)
        _ = operations.setTimeout(app, seconds: 0.05)
        guard case .bool(true)? = operations.read(app, attribute: kAXFrontmostAttribute).value else {
            XCTFail("The supplied application is not Accessibility frontmost."); return
        }
        let backend = AXFocusBackend(timeout: 0.05)
        let started = DispatchTime.now().uptimeNanoseconds
        let permit = { DispatchTime.now().uptimeNanoseconds - started < 150_000_000 }
        let resolution = backend.resolve(workspace: application, permit: permit)
        guard case let .known(captured) = resolution else {
            if case let .unknown(failure) = resolution {
                XCTFail("Native focus resolution failed at \(failure.stage), AX error \(failure.error?.rawValue ?? 0)")
            }
            return
        }
        print("Capture elapsed ms=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)")
        let appCapability = SystemAXFocusOperations().isSettable(captured.application, attribute: kAXFocusedUIElementAttribute)
        print("Application recipient setter=\(appCapability.1), error=\(appCapability.0.rawValue)")
        XCTAssertNotNil(captured.focusedElement, "Focus a harmless editable control before running this check.")
        if let element = captured.focusedElement {
            let operations = SystemAXFocusOperations()
            guard case .string(kAXTextFieldRole)? = operations.read(element, attribute: kAXRoleAttribute).value else { XCTFail("Captured recipient is not the prepared text field."); return }
            let capability = operations.isSettable(element, attribute: kAXFocusedAttribute)
            XCTAssertEqual(capability.0, .success)
            XCTAssertTrue(capability.1 || appCapability.1, "Exact recipient must advertise a focus setter.")
            print("Captured native keyboard recipient; AXFocused settable=\(capability.1), error=\(capability.0.rawValue)")
        }
        guard let x = environment["XENEON_AX_TEST_X"].flatMap(Double.init),
              let y = environment["XENEON_AX_TEST_Y"].flatMap(Double.init) else {
            XCTFail("Supply finite global target coordinates in XENEON_AX_TEST_X and XENEON_AX_TEST_Y.")
            return
        }
        let target = AXTouchTargetBackend(timeout: 0.05).resolve(at: CGPoint(x: x, y: y), permit: permit)
        XCTAssertTrue(permit(), "Read preparation must fit the production contact budget.")
        XCTAssertNotNil(target, "The supported target must resolve while its window is inactive.")
        if let target {
            XCTAssertEqual(target.pid, application.processIdentifier)
            XCTAssertFalse(operations.equal(target.window, captured.window), "Use an inactive sibling window as the target.")
        }
        print("Native inactive touch target resolved=\(target != nil)")
    }
}
