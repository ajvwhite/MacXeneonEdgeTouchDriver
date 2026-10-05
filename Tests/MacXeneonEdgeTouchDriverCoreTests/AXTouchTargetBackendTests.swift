import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
@testable import MacXeneonEdgeTouchDriverCore

final class AXTouchTargetBackendTests: XCTestCase {
    func testNonFocusableFloatingDialogIsRevalidatedWithoutMutation() {
        let f = TargetOperations(); f.dialog = true; f.windowSettable = false
        var visible = true
        let backend = AXTouchTargetBackend(operations: f, floatingWindow: { _, _, _ in visible })
        let target = backend.resolve(at: f.point, permit: { true })!
        XCTAssertFalse(target.requiresActivation)
        XCTAssertTrue(backend.focusWindow(target, at: f.point, permit: { true }))
        XCTAssertTrue(f.mutations.isEmpty)
        visible = false
        XCTAssertFalse(backend.focusWindow(target, at: f.point, permit: { true }))
        XCTAssertTrue(f.mutations.isEmpty)
    }

    func testDialogRequiresActivationWithoutFloatingProofOrWhenFocusable() {
        for settable in [false, true] {
            let f = TargetOperations(); f.dialog = true; f.windowSettable = settable
            let backend = AXTouchTargetBackend(operations: f, floatingWindow: { _, _, _ in !settable ? false : true })
            XCTAssertTrue(backend.resolve(at: f.point, permit: { true })!.requiresActivation)
        }
    }

    func testInactiveSiblingIsFocusedOnceAndConfirmed() {
        let f = TargetOperations()
        let backend = AXTouchTargetBackend(operations: f)
        let target = backend.resolve(at: f.point, permit: { true })!
        XCTAssertTrue(backend.focusWindow(target, at: f.point, permit: { true }))
        XCTAssertEqual(f.mutations, ["window"])
    }

    func testAlreadyFocusedTargetRequiresNoMutation() {
        let f = TargetOperations(); f.focusedWindow = "window"
        let backend = AXTouchTargetBackend(operations: f)
        let target = backend.resolve(at: f.point, permit: { true })!
        XCTAssertTrue(backend.focusWindow(target, at: f.point, permit: { true }))
        XCTAssertTrue(f.mutations.isEmpty)
    }

    func testInvalidGeometryAndForeignHitCannotResolve() {
        for scenario in 0..<5 {
            let f = TargetOperations()
            switch scenario {
            case 0: f.origin = CGPoint(x: CGFloat.nan, y: 0)
            case 1: f.size = CGSize(width: 0, height: 100)
            case 2: f.origin = CGPoint(x: 1000, y: 1000)
            case 3: f.hitPID = 44
            default: f.hitError = .cannotComplete
            }
            XCTAssertNil(AXTouchTargetBackend(operations: f).resolve(at: f.point, permit: { true }))
            XCTAssertTrue(f.mutations.isEmpty)
        }
    }

    func testMovedOrMinimizedWindowCannotBeActivated() {
        for minimized in [false, true] {
            let f = TargetOperations()
            let backend = AXTouchTargetBackend(operations: f)
            let target = backend.resolve(at: f.point, permit: { true })!
            if minimized { f.minimized = true } else { f.origin = CGPoint(x: 500, y: 500) }
            XCTAssertFalse(backend.focusWindow(target, at: f.point, permit: { true }))
            XCTAssertTrue(f.mutations.isEmpty)
        }
    }

    func testUncertainMutationCannotFallBackOrRetry() {
        let f = TargetOperations(); f.mutationError = .cannotComplete
        let backend = AXTouchTargetBackend(operations: f)
        let target = backend.resolve(at: f.point, permit: { true })!
        XCTAssertFalse(backend.focusWindow(target, at: f.point, permit: { true }))
        XCTAssertEqual(f.mutations, ["window"])
    }

    func testSuccessfulRequestWithoutFocusedWindowConfirmationFails() {
        let f = TargetOperations(); f.applyMutation = false
        let backend = AXTouchTargetBackend(operations: f)
        let target = backend.resolve(at: f.point, permit: { true })!
        XCTAssertFalse(backend.focusWindow(target, at: f.point, permit: { true }))
        XCTAssertEqual(f.mutations, ["window"])
    }

    func testCancellationDuringCapabilityReadPreventsMutation() {
        let f = TargetOperations()
        let backend = AXTouchTargetBackend(operations: f)
        let target = backend.resolve(at: f.point, permit: { true })!
        var permitted = true
        f.onCapability = { permitted = false }
        XCTAssertFalse(backend.focusWindow(target, at: f.point, permit: { permitted }))
        XCTAssertTrue(f.mutations.isEmpty)
    }

    func testFallbackUsesOnlyAdvertisedCapability() {
        for windowSettable in [false, true] {
            let f = TargetOperations(); f.appSettable = false; f.windowSettable = windowSettable
            let backend = AXTouchTargetBackend(operations: f)
            let target = backend.resolve(at: f.point, permit: { true })!
            XCTAssertTrue(backend.focusWindow(target, at: f.point, permit: { true }))
            XCTAssertEqual(f.mutations, [windowSettable ? "focused" : "raise"])
        }
        let f = TargetOperations(); f.appSettable = false; f.windowSettable = false; f.raiseSupported = false
        let backend = AXTouchTargetBackend(operations: f)
        XCTAssertFalse(backend.focusWindow(backend.resolve(at: f.point, permit: { true })!, at: f.point, permit: { true }))
        XCTAssertTrue(f.mutations.isEmpty)
    }
}

private final class TargetOperations: AXTouchTargetOperations {
    let point = CGPoint(x: -80, y: 30)
    var origin = CGPoint(x: -100, y: 0)
    var size = CGSize(width: 100, height: 100)
    var hitPID: pid_t = 33
    var hitError: AXError = .success
    var minimized = false
    var dialog = false
    var focusedWindow = "sibling"
    var appSettable = true
    var windowSettable = true
    var raiseSupported = true
    var mutationError: AXError = .success
    var applyMutation = true
    var mutations: [String] = []
    var onCapability: (() -> Void)?
    func handle(_ name: String) -> AXFocusElement { AXFocusElement(rawValue: name as NSString) }
    func name(_ element: AXFocusElement) -> String { element.rawValue as! String }
    func systemWideElement() -> AXFocusElement { handle("system") }
    func applicationElement(pid: pid_t) -> AXFocusElement { handle("app") }
    func setTimeout(_ element: AXFocusElement, seconds: Float) -> AXError { .success }
    func element(at point: CGPoint, system: AXFocusElement) -> (AXError, AXFocusElement?) { (hitError, handle("hit")) }
    func ownerPID(_ element: AXFocusElement) -> (AXError, pid_t) { (.success, name(element) == "hit" ? hitPID : 33) }
    func equal(_ lhs: AXFocusElement, _ rhs: AXFocusElement) -> Bool { name(lhs) == name(rhs) }
    func read(_ element: AXFocusElement, attribute: String) -> AXFocusRead {
        let value: AXFocusValue
        switch attribute {
        case kAXRoleAttribute: value = .string(name(element) == "app" ? kAXApplicationRole : name(element) == "window" ? kAXWindowRole : kAXButtonRole)
        case kAXWindowAttribute: value = .element(handle("window"))
        case kAXPositionAttribute: value = .point(origin)
        case kAXSizeAttribute: value = .size(size)
        case kAXSubroleAttribute: value = .string(dialog ? kAXDialogSubrole : kAXStandardWindowSubrole)
        case kAXFocusedAttribute: value = .bool(false)
        case kAXMinimizedAttribute: value = .bool(minimized)
        case kAXFocusedWindowAttribute: value = .element(handle(focusedWindow))
        default: return AXFocusRead(error: .attributeUnsupported, value: nil)
        }
        return AXFocusRead(error: .success, value: value)
    }
    func isSettable(_ element: AXFocusElement, attribute: String) -> (AXError, Bool) {
        onCapability?()
        return (.success, name(element) == "app" ? appSettable : windowSettable)
    }
    func actions(_ element: AXFocusElement) -> (AXError, [String]) { (.success, raiseSupported ? [kAXRaiseAction] : []) }
    private func mutate(_ action: String) -> AXError {
        mutations.append(action)
        if applyMutation { focusedWindow = "window" }
        return mutationError
    }
    func setFocusedWindow(_ window: AXFocusElement, application: AXFocusElement) -> AXError { mutate("window") }
    func setFocused(_ element: AXFocusElement) -> AXError { mutate("focused") }
    func raise(_ element: AXFocusElement) -> AXError { mutate("raise") }
    func observe(_ target: AXFocusTarget, permit: () -> Bool,
                 onChange: @escaping (FocusObservationEvent) -> Void) -> AXFocusObservationProtocol? { nil }
}
