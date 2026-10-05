import ApplicationServices
import Foundation
import XCTest
@testable import MacXeneonEdgeTouchDriverCore

final class AXFocusBackendTests: XCTestCase {
    func testPrimaryResolverUsesExactTypedWindowWithoutFallback() {
        let fixture = FocusBackendFixture()
        let target = known(fixture.backend.resolve(workspace: fixture.appA, permit: { true }))
        XCTAssertEqual(fixture.operations.id(target!.window), "a")
        XCTAssertEqual(fixture.operations.applicationCreations, [])
        XCTAssertEqual(fixture.operations.mutations, [])
        XCTAssertTrue(fixture.operations.timeouts.allSatisfy { $0 > 0 && $0 <= 0.05 })
    }

    func testOnlyCannotCompleteUsesCorroboratedWorkspaceFallback() {
        let fixture = FocusBackendFixture()
        fixture.operations.systemError = .cannotComplete
        XCTAssertEqual(known(fixture.backend.resolve(workspace: fixture.appA, permit: { true }))?.systemWideError, .cannotComplete)
        XCTAssertEqual(fixture.operations.applicationCreations, [11, 11])
        XCTAssertEqual(fixture.operations.calls.filter { $0 == "read:A:AXFrontmost" }.count, 2)
    }

    func testOtherRawSystemErrorsNeverFallback() {
        for error in [AXError.apiDisabled, .noValue, .attributeUnsupported, .invalidUIElement, .failure] {
            let fixture = FocusBackendFixture()
            fixture.operations.systemError = error
            let problem = unknown(fixture.backend.resolve(workspace: fixture.appA, permit: { true }))
            XCTAssertEqual(problem?.error, error)
            XCTAssertEqual(problem?.systemWideError, error)
            XCTAssertTrue(fixture.operations.applicationCreations.isEmpty)
            XCTAssertTrue(fixture.operations.mutations.isEmpty)
        }
    }

    func testFallbackRejectsFalseUnknownAndMalformedFrontmost() {
        for read in [AXFocusRead(error: .success, value: .bool(false)),
                     AXFocusRead(error: .cannotComplete, value: nil),
                     AXFocusRead(error: .success, value: .string("true"))] {
            let fixture = FocusBackendFixture()
            fixture.operations.systemError = .cannotComplete
            fixture.operations.reads["A:AXFrontmost"] = read
            let problem = unknown(fixture.backend.resolve(workspace: fixture.appA, permit: { true }))
            XCTAssertEqual(problem?.systemWideError, .cannotComplete)
            XCTAssertTrue(fixture.operations.mutations.isEmpty)
        }
    }

    func testSuccessfulMalformedPrimaryNeverFallback() {
        let fixture = FocusBackendFixture()
        fixture.operations.reads["system:AXFocusedApplication"] = AXFocusRead(error: .success, value: .string("A"))
        XCTAssertNotNil(unknown(fixture.backend.resolve(workspace: fixture.appA, permit: { true })))
        XCTAssertTrue(fixture.operations.applicationCreations.isEmpty)
    }

    func testApplicationAndWindowTypesRolesAndOwnersAreRequired() {
        let badReads: [(String, AXFocusRead)] = [
            ("A:AXRole", AXFocusRead(error: .success, value: .string(kAXWindowRole))),
            ("A:AXFocusedWindow", AXFocusRead(error: .success, value: .bool(true))),
            ("a:AXRole", AXFocusRead(error: .success, value: .string(kAXButtonRole))),
            ("a:AXRole", AXFocusRead(error: .noValue, value: nil))
        ]
        for (key, value) in badReads {
            let fixture = FocusBackendFixture()
            fixture.operations.reads[key] = value
            XCTAssertNotNil(unknown(fixture.backend.resolve(workspace: fixture.appA, permit: { true })), key)
        }
        for element in ["A", "a"] {
            let fixture = FocusBackendFixture()
            fixture.operations.owners[element] = 22
            XCTAssertNotNil(unknown(fixture.backend.resolve(workspace: fixture.appA, permit: { true })), element)
        }
    }

    func testSiblingChangeBetweenResolverSamplesIsUnknown() {
        let fixture = FocusBackendFixture()
        var reads = 0
        fixture.operations.onRead = { element, attribute in
            guard element == "A", attribute == kAXFocusedWindowAttribute else { return nil }
            reads += 1
            return AXFocusRead(error: .success, value: .element(fixture.operations.element(reads == 1 ? "a" : "sibling")))
        }
        XCTAssertEqual(unknown(fixture.backend.resolve(workspace: fixture.appA, permit: { true }))?.stage, "changed observation")
    }

    func testRelationshipRequiresApplicationInstanceAndExactWindow() {
        let fixture = FocusBackendFixture()
        XCTAssertEqual(fixture.backend.relationship(fixture.targetA, fixture.targetA), .same)
        let sibling = AXFocusTarget(application: fixture.targetA.application,
                                    window: fixture.operations.element("sibling"), workspaceApplication: fixture.appA)
        XCTAssertEqual(fixture.backend.relationship(fixture.targetA, sibling), .different)
        let replacement = AXFocusWorkspaceApplication(processIdentifier: 11, identity: NSObject(), isTerminated: false, isHidden: false)
        let reusedPID = AXFocusTarget(application: fixture.targetA.application,
                                      window: fixture.targetA.window, workspaceApplication: replacement)
        XCTAssertEqual(fixture.backend.relationship(fixture.targetA, reusedPID), .different)
    }

    func testAlreadyFocusedSkipsAllMutationCapabilitiesAndActions() {
        let fixture = FocusBackendFixture()
        guard case .skipped = fixture.backend.attemptRestore(captured: fixture.targetA, baseline: fixture.targetA,
            workspace: fixture.appA, capturedApplication: fixture.appA, permit: { true }) else {
            return XCTFail("Already focused must skip")
        }
        XCTAssertTrue(fixture.operations.mutations.isEmpty)
        XCTAssertFalse(fixture.operations.calls.contains { $0.hasPrefix("settable:") || $0.hasPrefix("actions:") })
    }

    func testSupportedFocusedWriteIsTheOnlyMutationEvenOnUncertainResult() {
        let fixture = FocusBackendFixture()
        fixture.selectB()
        fixture.operations.mutationError = .cannotComplete
        guard case let .attempted(error) = fixture.restore() else { return XCTFail("Expected one attempt") }
        XCTAssertEqual(error, .cannotComplete)
        XCTAssertEqual(fixture.operations.mutations, ["focused:a"])
        XCTAssertFalse(fixture.operations.calls.contains("actions:a"))
        XCTAssertEqual(fixture.operations.calls.last, "focused:a")
    }

    func testRaiseRequiresSuccessfulNonSettableFocusedAndAdvertisedAction() {
        let fixture = FocusBackendFixture()
        fixture.selectB()
        fixture.operations.settable = (.success, false)
        fixture.operations.actionNames = (.success, [kAXRaiseAction])
        guard case .attempted(.success) = fixture.restore() else { return XCTFail("Expected raise") }
        XCTAssertEqual(fixture.operations.mutations, ["raise:a"])

        let unsupported = FocusBackendFixture()
        unsupported.selectB()
        unsupported.operations.settable = (.success, false)
        unsupported.operations.actionNames = (.success, [])
        _ = unsupported.restore()
        XCTAssertTrue(unsupported.operations.mutations.isEmpty)

        let uncertain = FocusBackendFixture()
        uncertain.selectB()
        uncertain.operations.settable = (.cannotComplete, false)
        _ = uncertain.restore()
        XCTAssertTrue(uncertain.operations.mutations.isEmpty)
        XCTAssertFalse(uncertain.operations.calls.contains("actions:a"))
    }

    func testChangedProcessUnavailableTargetAndBaselineNeverMutate() {
        let replacement = FocusBackendFixture()
        replacement.selectB()
        let reusedPID = AXFocusWorkspaceApplication(processIdentifier: 11, identity: NSObject(), isTerminated: false, isHidden: false)
        _ = replacement.backend.attemptRestore(captured: replacement.targetA, baseline: replacement.targetB,
            workspace: replacement.appB, capturedApplication: reusedPID, permit: { true })
        XCTAssertTrue(replacement.operations.mutations.isEmpty)

        for property in ["terminated", "hidden"] {
            let fixture = FocusBackendFixture()
            fixture.selectB()
            let unavailable = AXFocusWorkspaceApplication(processIdentifier: 11, identity: fixture.appA.identity,
                isTerminated: property == "terminated", isHidden: property == "hidden")
            _ = fixture.backend.attemptRestore(captured: fixture.targetA, baseline: fixture.targetB,
                workspace: fixture.appB, capturedApplication: unavailable, permit: { true })
            XCTAssertTrue(fixture.operations.mutations.isEmpty)
        }

        let changed = FocusBackendFixture()
        changed.selectB()
        changed.operations.reads["B:AXFocusedWindow"] = AXFocusRead(error: .success, value: .element(changed.operations.element("b2")))
        _ = changed.restore()
        XCTAssertTrue(changed.operations.mutations.isEmpty)
    }

    func testUnknownFocusAndInactiveTargetSiblingChangeNeverMutate() {
        let unknown = FocusBackendFixture()
        unknown.selectB()
        unknown.operations.systemError = .apiDisabled
        _ = unknown.restore()
        XCTAssertTrue(unknown.operations.mutations.isEmpty)

        let sibling = FocusBackendFixture()
        sibling.selectB()
        sibling.operations.reads["A:AXFocusedWindow"] = AXFocusRead(error: .success, value: .element(sibling.operations.element("sibling")))
        _ = sibling.restore()
        XCTAssertTrue(sibling.operations.mutations.isEmpty)
    }

    func testNewModalSiblingAndMinimizedTargetNeverMutate() {
        let modal = FocusBackendFixture()
        modal.operations.reads["A:AXFocusedWindow"] = AXFocusRead(error: .success, value: .element(modal.operations.element("sibling")))
        modal.operations.reads["sibling:AXModal"] = AXFocusRead(error: .success, value: .bool(true))
        let sibling = AXFocusTarget(application: modal.targetA.application, window: modal.operations.element("sibling"), workspaceApplication: modal.appA)
        _ = modal.backend.attemptRestore(captured: modal.targetA, baseline: sibling,
            workspace: modal.appA, capturedApplication: modal.appA, permit: { true })
        XCTAssertTrue(modal.operations.mutations.isEmpty)

        let minimized = FocusBackendFixture()
        minimized.selectB()
        minimized.operations.reads["a:\(kAXMinimizedAttribute)"] = AXFocusRead(error: .success, value: .bool(true))
        _ = minimized.restore()
        XCTAssertTrue(minimized.operations.mutations.isEmpty)
    }

    func testSameApplicationNonModalSiblingCanRestoreExactCapturedWindow() {
        let fixture = FocusBackendFixture()
        fixture.operations.reads["A:AXFocusedWindow"] = AXFocusRead(error: .success, value: .element(fixture.operations.element("sibling")))
        let baseline = AXFocusTarget(application: fixture.targetA.application,
            window: fixture.operations.element("sibling"), workspaceApplication: fixture.appA)
        _ = fixture.backend.attemptRestore(captured: fixture.targetA, baseline: baseline,
            workspace: fixture.appA, capturedApplication: fixture.appA, permit: { true })
        XCTAssertEqual(fixture.operations.mutations, ["focused:a"])
    }

    func testCancellationAfterEveryPreparatoryCallPreventsMutation() {
        let reference = FocusBackendFixture()
        reference.selectB()
        _ = reference.restore()
        let preparationCount = reference.operations.calls.count - 1
        for cancelAfter in 1...preparationCount {
            let fixture = FocusBackendFixture()
            fixture.selectB()
            var permitted = true
            fixture.operations.onCall = { _ in
                if fixture.operations.calls.count == cancelAfter { permitted = false }
            }
            _ = fixture.restore(permit: { permitted })
            XCTAssertTrue(fixture.operations.mutations.isEmpty, "Mutation after cancellation at call \(cancelAfter)")
        }
    }

    func testCancellationDuringMutationAllowsNoFollowingOperation() {
        let fixture = FocusBackendFixture()
        fixture.selectB()
        var permitted = true
        fixture.operations.onCall = { if $0 == "focused:a" { permitted = false } }
        _ = fixture.restore(permit: { permitted })
        XCTAssertEqual(fixture.operations.mutations, ["focused:a"])
        XCTAssertEqual(fixture.operations.calls.last, "focused:a")
    }

    func testFailedOrCancelledObserverSetupReturnsNoObservation() {
        let fixture = FocusBackendFixture()
        XCTAssertNil(fixture.backend.prepareObservation(target: fixture.targetA, permit: { true }, onChange: { _ in }))
        XCTAssertEqual(fixture.operations.observationAttempts, 1)
        XCTAssertNil(fixture.backend.prepareObservation(target: fixture.targetA, permit: { false }, onChange: { _ in }))
        XCTAssertEqual(fixture.operations.observationAttempts, 1)
    }

    private func known(_ result: AXFocusResolution, file: StaticString = #filePath, line: UInt = #line) -> AXFocusTarget? {
        guard case let .known(target) = result else { XCTFail("Expected known focus", file: file, line: line); return nil }
        return target
    }

    private func unknown(_ result: AXFocusResolution, file: StaticString = #filePath, line: UInt = #line) -> AXFocusFailure? {
        guard case let .unknown(problem) = result else { XCTFail("Expected unknown focus", file: file, line: line); return nil }
        return problem
    }
}

private final class FocusBackendFixture {
    let operations = FakeAXFocusOperations()
    let appA = AXFocusWorkspaceApplication(processIdentifier: 11, identity: NSObject(), isTerminated: false, isHidden: false)
    let appB = AXFocusWorkspaceApplication(processIdentifier: 22, identity: NSObject(), isTerminated: false, isHidden: false)
    lazy var backend = AXFocusBackend(operations: operations)
    var targetA: AXFocusTarget { AXFocusTarget(application: operations.element("A"), window: operations.element("a"), workspaceApplication: appA) }
    var targetB: AXFocusTarget { AXFocusTarget(application: operations.element("B"), window: operations.element("b"), workspaceApplication: appB) }
    func selectB() { operations.focusedApplication = "B" }
    func restore(permit: () -> Bool = { true }) -> AXFocusAttemptResult {
        backend.attemptRestore(captured: targetA, baseline: targetB, workspace: appB, capturedApplication: appA, permit: permit)
    }
}

private final class FakeAXFocusOperations: AXFocusOperations {
    var systemError: AXError = .success
    var focusedApplication = "A"
    var owners: [String: pid_t] = ["A": 11, "a": 11, "sibling": 11, "B": 22, "b": 22, "b2": 22]
    var reads: [String: AXFocusRead] = [:]
    var onRead: ((String, String) -> AXFocusRead?)?
    var onCall: ((String) -> Void)?
    var calls: [String] = []
    var mutations: [String] = []
    var applicationCreations: [pid_t] = []
    var timeouts: [Float] = []
    var settable: (AXError, Bool) = (.success, true)
    var actionNames: (AXError, [String]) = (.success, [kAXRaiseAction])
    var mutationError: AXError = .success
    var observationAttempts = 0

    func element(_ name: String) -> AXFocusElement { AXFocusElement(rawValue: name as NSString) }
    func id(_ element: AXFocusElement) -> String { element.rawValue as! String }
    private func record(_ call: String) { calls.append(call); onCall?(call) }
    func systemWideElement() -> AXFocusElement { element("system") }
    func applicationElement(pid: pid_t) -> AXFocusElement { applicationCreations.append(pid); return element(pid == 11 ? "A" : "B") }
    func setTimeout(_ element: AXFocusElement, seconds: Float) -> AXError { record("timeout:\(id(element))"); timeouts.append(seconds); return .success }
    func ownerPID(_ element: AXFocusElement) -> (AXError, pid_t) { record("owner:\(id(element))"); return (.success, owners[id(element)] ?? 0) }
    func equal(_ lhs: AXFocusElement, _ rhs: AXFocusElement) -> Bool { id(lhs) == id(rhs) }
    func read(_ element: AXFocusElement, attribute: String) -> AXFocusRead {
        let name = id(element)
        record("read:\(name):\(attribute)")
        if let value = onRead?(name, attribute) ?? reads["\(name):\(attribute)"] { return value }
        switch attribute {
        case kAXFocusedApplicationAttribute: return AXFocusRead(error: systemError, value: systemError == .success ? .element(self.element(focusedApplication)) : nil)
        case kAXRoleAttribute: return AXFocusRead(error: .success, value: .string(["A", "B"].contains(name) ? kAXApplicationRole : kAXWindowRole))
        case kAXFocusedWindowAttribute: return AXFocusRead(error: .success, value: .element(self.element(name == "A" ? "a" : "b")))
        case kAXFrontmostAttribute: return AXFocusRead(error: .success, value: .bool(name == focusedApplication))
        case kAXMinimizedAttribute, kAXModalAttribute: return AXFocusRead(error: .success, value: .bool(false))
        default: return AXFocusRead(error: .attributeUnsupported, value: nil)
        }
    }
    func isSettable(_ element: AXFocusElement, attribute: String) -> (AXError, Bool) { record("settable:\(id(element))"); return settable }
    func actions(_ element: AXFocusElement) -> (AXError, [String]) { record("actions:\(id(element))"); return actionNames }
    func setFocused(_ element: AXFocusElement) -> AXError { mutate("focused:\(id(element))") }
    func raise(_ element: AXFocusElement) -> AXError { mutate("raise:\(id(element))") }
    private func mutate(_ call: String) -> AXError { record(call); mutations.append(call); return mutationError }
    func observe(_ target: AXFocusTarget, permit: () -> Bool,
                 onChange: @escaping (FocusObservationEvent) -> Void) -> AXFocusObservationProtocol? {
        observationAttempts += 1
        return nil
    }
}
