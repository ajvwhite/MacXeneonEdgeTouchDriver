import ApplicationServices
import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class AXFocusRestorerTests: XCTestCase {
    func testAlreadyFocusedApplicationAndWindowHaveNoRestoreSideEffects() {
        let fixture = FocusFixture()
        let restorer = fixture.makeRestorer()
        restorer.captureFocusedWindow()

        restorer.restoreCapturedWindow()

        XCTAssertTrue(fixture.calls.isEmpty)
    }

    func testEquivalentAXElementsUseCFEqualToRecognizeFocus() {
        let fixture = FocusFixture()
        let restorer = fixture.makeRestorer()
        restorer.captureFocusedWindow()
        fixture.focusedApplication = AXUIElementCreateApplication(FocusFixture.applicationPID)
        fixture.focusedWindow = AXUIElementCreateApplication(FocusFixture.windowPID)

        restorer.restoreCapturedWindow()

        XCTAssertTrue(fixture.calls.isEmpty)
    }

    func testDifferentApplicationRetainsFullRestorePath() {
        let fixture = FocusFixture()
        let restorer = fixture.makeRestorer()
        restorer.captureFocusedWindow()
        fixture.focusedApplication = fixture.otherApplication

        restorer.restoreCapturedWindow()

        fixture.assertFullRestore()
    }

    func testSiblingWindowRetainsFullRestorePath() {
        let fixture = FocusFixture()
        let restorer = fixture.makeRestorer()
        restorer.captureFocusedWindow()
        fixture.focusedWindow = fixture.siblingWindow

        restorer.restoreCapturedWindow()

        fixture.assertFullRestore()
    }

    func testUnavailableCurrentFocusRetainsFullRestorePath() {
        for attribute in [kAXFocusedApplicationAttribute, kAXFocusedWindowAttribute] {
            let fixture = FocusFixture()
            let restorer = fixture.makeRestorer()
            restorer.captureFocusedWindow()
            fixture.setFocusedValue(nil, attribute: attribute)

            restorer.restoreCapturedWindow()

            fixture.assertFullRestore()
        }
    }

    func testWrongTypeCurrentFocusRetainsFullRestorePath() {
        for attribute in [kAXFocusedApplicationAttribute, kAXFocusedWindowAttribute] {
            let fixture = FocusFixture()
            let restorer = fixture.makeRestorer()
            restorer.captureFocusedWindow()
            fixture.setFocusedValue(kCFBooleanTrue, attribute: attribute)

            restorer.restoreCapturedWindow()

            fixture.assertFullRestore()
        }
    }

    func testMissingOrWrongTypeCaptureDoesNotRestore() {
        for value: CFTypeRef? in [nil, kCFBooleanTrue] {
            for attribute in [kAXFocusedApplicationAttribute, kAXFocusedWindowAttribute] {
                let fixture = FocusFixture()
                fixture.setFocusedValue(value, attribute: attribute)
                let restorer = fixture.makeRestorer()
                restorer.captureFocusedWindow()

                restorer.restoreCapturedWindow()

                XCTAssertTrue(fixture.calls.isEmpty)
            }
        }
    }

    func testFailedNewCaptureClearsPreviousCapture() {
        let fixture = FocusFixture()
        let restorer = fixture.makeRestorer()
        restorer.captureFocusedWindow()
        fixture.focusedWindow = nil
        restorer.captureFocusedWindow()

        restorer.restoreCapturedWindow()

        XCTAssertTrue(fixture.calls.isEmpty)
    }

    func testAlreadyFocusedRestoreConsumesCapture() {
        let fixture = FocusFixture()
        let restorer = fixture.makeRestorer()
        restorer.captureFocusedWindow()
        restorer.restoreCapturedWindow()
        fixture.focusedWindow = fixture.siblingWindow

        restorer.restoreCapturedWindow()

        XCTAssertTrue(fixture.calls.isEmpty)
    }

    func testFullRestoreConsumesCapture() {
        let fixture = FocusFixture()
        let restorer = fixture.makeRestorer()
        restorer.captureFocusedWindow()
        fixture.focusedWindow = fixture.siblingWindow
        restorer.restoreCapturedWindow()
        fixture.focusedWindow = fixture.siblingWindow

        restorer.restoreCapturedWindow()

        fixture.assertFullRestore()
    }

    func testDiscardedCaptureDoesNotRestore() {
        let fixture = FocusFixture()
        let restorer = fixture.makeRestorer()
        restorer.captureFocusedWindow()
        fixture.focusedWindow = fixture.siblingWindow
        restorer.discardCapturedWindow()

        restorer.restoreCapturedWindow()

        XCTAssertTrue(fixture.calls.isEmpty)
    }

    func testGestureStillReleasesMouseAndReturnsCursorWhenFocusIsUnchanged() {
        let fixture = FocusFixture()
        let restorer = fixture.makeRestorer()
        let input = FocusTestInputSink()
        let cursor = FocusTestCursorController()
        let controller = GestureController(
            mapperProvider: { CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100)) },
            inputSink: input,
            cursorController: cursor,
            focusRestorer: restorer,
            timing: .immediate
        )

        controller.handle(TouchEvent(kind: .down, contactID: 0, rawX: 0, rawY: 0, timestamp: DispatchTime(uptimeNanoseconds: 1_000_000)))
        controller.handle(TouchEvent(kind: .up, contactID: 0, rawX: 0, rawY: 0, timestamp: DispatchTime(uptimeNanoseconds: 1_000_000)))

        XCTAssertEqual(input.calls, ["down", "up"])
        XCTAssertEqual(cursor.calls, ["borrow", "return"])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(fixture.calls.isEmpty)
    }
}

private final class FocusFixture {
    enum Target: Equatable { case application, window, unexpected }
    enum Call: Equatable {
        case set(Target, String)
        case action(Target, String)
        case cursorPosition
        case mouse(CGEventType, CGPoint)
        case warp(CGPoint)
    }

    // These constructors only create inert handles. No test sends a request to AX,
    // reads the live cursor, or creates/posts a CGEvent: every operation is injected.
    static let applicationPID: pid_t = 700_001
    static let windowPID: pid_t = 700_002
    let systemWide = AXUIElementCreateApplication(700_000)
    let application = AXUIElementCreateApplication(applicationPID)
    let window = AXUIElementCreateApplication(windowPID)
    let siblingWindow = AXUIElementCreateApplication(700_003)
    let otherApplication = AXUIElementCreateApplication(700_004)
    var focusedApplication: CFTypeRef?
    var focusedWindow: CFTypeRef?
    var calls: [Call] = []
    private var writtenValues: [CFTypeRef] = []

    init() {
        focusedApplication = application
        focusedWindow = window
    }

    func setFocusedValue(_ value: CFTypeRef?, attribute: String) {
        if attribute == kAXFocusedApplicationAttribute {
            focusedApplication = value
        } else {
            focusedWindow = value
        }
    }

    func makeRestorer() -> AXFocusRestorer {
        AXFocusRestorer(systemWideElement: systemWide, operations: .init(
            copyAttribute: { [unowned self] element, attribute in
                if CFEqual(element, systemWide), attribute == kAXFocusedApplicationAttribute {
                    return focusedApplication
                }
                if CFEqual(element, application), attribute == kAXFocusedWindowAttribute {
                    return focusedWindow
                }
                if CFEqual(element, window), attribute == kAXPositionAttribute {
                    var point = CGPoint(x: 10, y: 20)
                    return AXValueCreate(.cgPoint, &point)
                }
                if CFEqual(element, window), attribute == kAXSizeAttribute {
                    var size = CGSize(width: 400, height: 300)
                    return AXValueCreate(.cgSize, &size)
                }
                return nil
            },
            setAttribute: { [unowned self] element, attribute, value in
                calls.append(.set(target(for: element), attribute))
                writtenValues.append(value)
                return .success
            },
            performAction: { [unowned self] element, action in
                calls.append(.action(target(for: element), action))
                return .success
            },
            cursorPosition: { [unowned self] in
                calls.append(.cursorPosition)
                return CGPoint(x: 500, y: 600)
            },
            postMouseEvent: { [unowned self] type, point in calls.append(.mouse(type, point)) },
            warpCursor: { [unowned self] point in calls.append(.warp(point)) }
        ))
    }

    func assertFullRestore(file: StaticString = #filePath, line: UInt = #line) {
        // Retains the existing guessed-titlebar fallback and its order of AX writes.
        XCTAssertEqual(calls, [
            .set(.application, kAXFocusedWindowAttribute),
            .set(.application, kAXMainWindowAttribute),
            .action(.window, kAXRaiseAction),
            .cursorPosition,
            .mouse(.leftMouseDown, CGPoint(x: 210, y: 32)),
            .mouse(.leftMouseUp, CGPoint(x: 210, y: 32)),
            .warp(CGPoint(x: 500, y: 600)),
            .set(.application, kAXFocusedWindowAttribute),
            .set(.application, kAXMainWindowAttribute),
            .set(.window, kAXMainAttribute),
            .set(.window, kAXFocusedAttribute)
        ], file: file, line: line)
        XCTAssertEqual(writtenValues.count, 6, file: file, line: line)
        for value in writtenValues.prefix(4) {
            XCTAssertTrue(CFEqual(value, window), file: file, line: line)
        }
        for value in writtenValues.dropFirst(4) {
            XCTAssertTrue(CFEqual(value, kCFBooleanTrue), file: file, line: line)
        }
    }

    private func target(for element: AXUIElement) -> Target {
        if CFEqual(element, application) { return .application }
        if CFEqual(element, window) { return .window }
        return .unexpected
    }
}

private final class FocusTestInputSink: SyntheticInputSink {
    var calls: [String] = []
    func postMouseDown(at point: CGPoint) { calls.append("down") }
    func postMouseUp(at point: CGPoint) { calls.append("up") }
    func postMouseDragged(to point: CGPoint) { calls.append("drag") }
}

private final class FocusTestCursorController: CursorController {
    var calls: [String] = []
    func borrow(warpingTo point: CGPoint) -> Bool { calls.append("borrow"); return true }
    func updatePosition(_ point: CGPoint) { calls.append("move") }
    func returnToOrigin() { calls.append("return") }
    func forceShow() { calls.append("show") }
}
