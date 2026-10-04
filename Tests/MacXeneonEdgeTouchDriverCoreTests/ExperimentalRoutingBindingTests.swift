import Foundation
import XCTest
@testable import MacXeneonEdgeTouchDriverCore

final class ExperimentalRoutingBindingTests: XCTestCase {
    private let session = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let geometry = ExperimentalDisplayGeometry(x: -1920, y: 100, width: 1920, height: 1080)

    private func endpoint(_ index: UInt64 = 1, parent: UInt64? = 100) -> ExperimentalEndpointObservation {
        ExperimentalEndpointObservation(source: ExperimentalSourceEpoch(sessionID: session, registrationGeneration: index), registryEntryID: index, controllerRegistryEntryID: parent, vendorID: 0x27c0, productID: 0x0859)
    }

    private func display(_ id: UInt32 = 10, serial: UInt32 = 0, active: Bool = true, mirrored: Bool = false, bounds: ExperimentalDisplayGeometry? = nil) -> ExperimentalDisplayObservation {
        ExperimentalDisplayObservation(displayID: id, vendorNumber: 1, modelNumber: 2, serialNumber: serial, geometry: bounds ?? geometry, isActive: active, isMirrored: mirrored)
    }

    private func binding(_ index: UInt64 = 1, displayID: UInt32 = 10, id: String? = nil, boot: String = "boot-1", expectedParent: UInt64? = nil, expectedSerial: UInt32? = nil) -> ExperimentalExplicitBinding {
        ExperimentalExplicitBinding(
            id: id ?? "binding-\(index)", bootSessionID: boot,
            endpoint: ExperimentalEndpointSelector(registryEntryID: index, vendorID: 0x27c0, productID: 0x0859, controllerRegistryEntryID: expectedParent),
            display: ExperimentalDisplaySelector(displayID: displayID, vendorNumber: 1, modelNumber: 2, serialNumber: expectedSerial)
        )
    }

    private func resolve(_ bindings: [ExperimentalExplicitBinding], endpoints: [ExperimentalEndpointObservation]? = nil, displays: [ExperimentalDisplayObservation]? = nil, boot: String? = "boot-1") -> ExperimentalBindingResolution {
        ExperimentalBindingValidator.resolve(bindings, currentBootSessionID: boot, endpoints: endpoints ?? [endpoint()], displays: displays ?? [display()], bindingRevision: 3, topologyRevision: 7)
    }

    private func assertBlocked(_ resolution: ExperimentalBindingResolution, _ reason: ExperimentalBindingFailure.Reason, file: StaticString = #filePath, line: UInt = #line) {
        guard case .blocked(let failures) = resolution else {
            XCTFail("Expected blocked resolution", file: file, line: line); return
        }
        XCTAssertTrue(failures.contains { $0.reason == reason }, "Expected \(reason), got \(failures)", file: file, line: line)
    }

    func testSingleExplicitEndpointDoesNotRequirePretendPhysicalIdentity() {
        let result = resolve([binding()], endpoints: [endpoint(parent: nil)])
        guard case .resolved(let values) = result else { return XCTFail("Expected exact endpoint route") }
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].source, endpoint().source)
        XCTAssertNil(values[0].controllerRegistryEntryID)
        XCTAssertEqual(values[0].route, ExperimentalRouteToken(bindingID: "binding-1", bindingRevision: 3, topologyRevision: 7, displayID: 10))
        XCTAssertEqual(values[0].geometry, geometry)
    }

    func testEmptyUnavailableAndChangedBootFailClosed() {
        assertBlocked(resolve([]), .emptyBindings)
        assertBlocked(resolve([binding()], boot: nil), .bootSessionUnavailable)
        assertBlocked(resolve([binding()], boot: " "), .bootSessionUnavailable)
        assertBlocked(resolve([binding(boot: "boot-0")]), .bootSessionMismatch)
    }

    func testEmptyOrZeroSelectorsAreRejected() {
        assertBlocked(resolve([binding(id: " ")]), .invalidSelector)
        assertBlocked(resolve([binding(0)]), .invalidSelector)
        assertBlocked(resolve([binding(displayID: 0)]), .invalidSelector)
    }

    func testDuplicateBindingNamesFailEvenForOtherwiseDistinctPairs() {
        assertBlocked(resolve([binding(id: "same"), binding(2, displayID: 20, id: "same")], endpoints: [endpoint(), endpoint(2, parent: 200)], displays: [display(), display(20)]), .duplicateBindingID)
    }

    func testEndpointMissingAndDuplicateRegistryEntriesNeverFallBack() {
        assertBlocked(resolve([binding()], endpoints: [endpoint(2)]), .endpointMissing)
        assertBlocked(resolve([binding()], endpoints: [endpoint(), endpoint()]), .endpointAmbiguous)
    }

    func testReusedEndpointIDMustStillMatchIdentityGuards() {
        let wrong = ExperimentalEndpointObservation(source: endpoint().source, registryEntryID: 1, controllerRegistryEntryID: 100, vendorID: 0x1234, productID: 0x0859)
        assertBlocked(resolve([binding()], endpoints: [wrong]), .endpointIdentityMismatch)
        assertBlocked(resolve([binding(expectedParent: 200)]), .endpointIdentityMismatch)
        assertBlocked(resolve([binding(expectedParent: 100)], endpoints: [endpoint(parent: nil)]), .endpointIdentityMismatch)
    }

    func testDisplayMissingAndDuplicateRuntimeIDsNeverUseFirstOrMainDisplay() {
        assertBlocked(resolve([binding()], displays: [display(20)]), .displayMissing)
        assertBlocked(resolve([binding()], displays: [display(), display()]), .displayAmbiguous)
    }

    func testDisplayIdentityMismatchIsRejectedDespiteSameBoundsAndRuntimeID() {
        let wrong = ExperimentalDisplayObservation(displayID: 10, vendorNumber: 1, modelNumber: 3, serialNumber: 0, geometry: geometry)
        assertBlocked(resolve([binding()], displays: [wrong]), .displayIdentityMismatch)
        assertBlocked(resolve([binding(expectedSerial: 42)], displays: [display(serial: 41)]), .displayIdentityMismatch)
    }

    func testInactiveMirroredAndInvalidGeometryAreUnusable() {
        assertBlocked(resolve([binding()], displays: [display(active: false)]), .displayUnavailable)
        assertBlocked(resolve([binding()], displays: [display(mirrored: true)]), .displayUnavailable)
        let invalid = [
            ExperimentalDisplayGeometry(x: 0, y: 0, width: 0, height: 100),
            ExperimentalDisplayGeometry(x: .nan, y: 0, width: 100, height: 100),
            ExperimentalDisplayGeometry(x: 0, y: 0, width: .infinity, height: 100),
            ExperimentalDisplayGeometry(x: Double.greatestFiniteMagnitude, y: 0, width: Double.greatestFiniteMagnitude, height: 100),
            ExperimentalDisplayGeometry(x: Double.greatestFiniteMagnitude, y: 0, width: 1, height: 100)
        ]
        for value in invalid {
            assertBlocked(resolve([binding()], displays: [display(bounds: value)]), .displayUnavailable)
        }
    }

    func testMultipleBindingsRequireDistinctProvenControllerParents() {
        let pairs = [binding(), binding(2, displayID: 20)]
        let targets = [display(), display(20)]
        assertBlocked(resolve(pairs, endpoints: [endpoint(parent: nil), endpoint(2, parent: 200)], displays: targets), .controllerProvenanceRequired)
        assertBlocked(resolve(pairs, endpoints: [endpoint(), endpoint(2, parent: 100)], displays: targets), .duplicateController)
        guard case .resolved(let result) = resolve(pairs, endpoints: [endpoint(), endpoint(2, parent: 200)], displays: targets) else {
            return XCTFail("Two independently proven controller routes should resolve")
        }
        XCTAssertEqual(result.count, 2)
    }

    func testOneToOneBindingsRejectRepeatedSourceAndDisplay() {
        assertBlocked(resolve([binding(id: "a"), binding(displayID: 20, id: "b")], displays: [display(), display(20)]), .duplicateSource)
        assertBlocked(resolve([binding(), binding(2)], endpoints: [endpoint(), endpoint(2, parent: 200)]), .duplicateDisplay)
    }

    func testOneBadBindingPreventsPartialActivation() {
        let result = resolve([binding(), binding(2, displayID: 20)], endpoints: [endpoint(), endpoint(2, parent: 200)])
        assertBlocked(result, .displayMissing)
        if case .resolved = result { XCTFail("No partial routes may escape a failed validation") }
    }

    func testEnumerationOrderHasNoEffectAndUnselectedMonitorIsIgnored() {
        let pairs = [binding(), binding(2, displayID: 20)]
        let a = endpoint(), b = endpoint(2, parent: 200)
        let d1 = display(), d2 = display(20), extra = display(99)
        XCTAssertEqual(resolve(pairs, endpoints: [a, b], displays: [d1, d2, extra]), resolve(pairs, endpoints: [b, a], displays: [extra, d2, d1]))
    }

    func testDuplicateOrMissingSerialIsNeverPromotedToPersistentAuthority() {
        let pairs = [binding(expectedSerial: 0), binding(2, displayID: 20, expectedSerial: 0)]
        guard case .resolved(let result) = resolve(pairs, endpoints: [endpoint(), endpoint(2, parent: 200)], displays: [display(), display(20)]) else {
            return XCTFail("Exact current-boot runtime selectors do not need unique serials")
        }
        XCTAssertEqual(result.count, 2)
        assertBlocked(resolve(pairs, endpoints: [endpoint(), endpoint(2, parent: 200)], displays: [display(), display(20)], boot: "different-boot"), .bootSessionMismatch)
    }
}
