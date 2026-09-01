import CoreGraphics
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class PairingStoreTests: XCTestCase {
    func testRuntimeAssignmentPersistsAcrossProcessRestartInSameBoot() throws {
        let url = temporaryURL()
        let device = TouchDeviceIdentity(locationID: 1)
        let display = makeDisplay(id: 41, serial: 0)
        let first = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")

        try first.assign(
            device: device,
            to: display,
            connectedDevices: [device],
            displays: [display]
        )
        let reloaded = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")

        XCTAssertEqual(
            reloaded.resolveDisplay(for: device, connectedDevices: [device], displays: [display]),
            display
        )
        XCTAssertEqual(reloaded.pairings.first?.scope, .bootSession)
    }

    func testSameBootDisplayIDReuseByDifferentHardwareIsRejectedAndPruned() throws {
        let store = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let device = TouchDeviceIdentity(locationID: 1)
        let originalDisplay = makeDisplay(id: 41, serial: 0)
        try store.assign(
            device: device,
            to: originalDisplay,
            connectedDevices: [device],
            displays: [originalDisplay]
        )
        let reusedDisplay = makeDisplay(
            id: 41,
            serial: 0,
            vendor: 9_999,
            model: 8_888
        )

        XCTAssertNil(store.resolveDisplay(
            for: device,
            connectedDevices: [device],
            displays: [reusedDisplay]
        ))
        XCTAssertEqual(
            try store.reconcileRuntimeDescriptors(
                connectedDevices: [device],
                displays: [reusedDisplay]
            ),
            1
        )
        XCTAssertTrue(store.pairings.isEmpty)
    }

    func testSameBootControllerLocationReuseByDifferentSerialIsRejectedAndPruned() throws {
        let store = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let originalDevice = TouchDeviceIdentity(locationID: 1, serialNumber: "TOUCH-A")
        let display = makeDisplay(id: 41, serial: 0)
        try store.assign(
            device: originalDevice,
            to: display,
            connectedDevices: [originalDevice],
            displays: [display]
        )
        let reusedLocation = TouchDeviceIdentity(locationID: 1, serialNumber: "TOUCH-B")

        XCTAssertNil(store.resolveDisplay(
            for: reusedLocation,
            connectedDevices: [reusedLocation],
            displays: [display]
        ))
        XCTAssertEqual(
            try store.reconcileRuntimeDescriptors(
                connectedDevices: [reusedLocation],
                displays: [display]
            ),
            1
        )
        XCTAssertTrue(store.pairings.isEmpty)
    }

    func testDescriptorReconciliationKeepsTemporarilyMissingEndpoints() throws {
        let store = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let device = TouchDeviceIdentity(locationID: 1)
        let display = makeDisplay(id: 41, serial: 0)
        try store.assign(device: device, to: display, connectedDevices: [device], displays: [display])

        XCTAssertEqual(
            try store.reconcileRuntimeDescriptors(connectedDevices: [], displays: []),
            0
        )
        XCTAssertEqual(store.pairings.count, 1)
    }

    func testExplicitRemovalInvalidatesOnlyBootSessionAuthority() throws {
        let bootStore = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let ambiguousDevice = TouchDeviceIdentity(locationID: 1)
        let ambiguousDisplay = makeDisplay(id: 41, serial: 0)
        try bootStore.assign(
            device: ambiguousDevice,
            to: ambiguousDisplay,
            connectedDevices: [ambiguousDevice],
            displays: [ambiguousDisplay]
        )

        try bootStore.invalidateBootSessionPairing(forDisplayID: ambiguousDisplay.displayID)
        XCTAssertTrue(bootStore.pairings.isEmpty)

        let hardwareStore = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let identifiedDevice = TouchDeviceIdentity(locationID: 2, serialNumber: "TOUCH-A")
        let identifiedDisplay = makeDisplay(id: 42, serial: 101)
        try hardwareStore.assign(
            device: identifiedDevice,
            to: identifiedDisplay,
            connectedDevices: [identifiedDevice],
            displays: [identifiedDisplay]
        )

        try hardwareStore.invalidateBootSessionPairing(for: identifiedDevice)
        try hardwareStore.invalidateBootSessionPairing(forDisplayID: identifiedDisplay.displayID)
        XCTAssertEqual(hardwareStore.pairings.first?.scope, .hardware)
    }

    func testAmbiguousRuntimeAssignmentIsNotTrustedAfterBootChanges() throws {
        let url = temporaryURL()
        let oldDevice = TouchDeviceIdentity(locationID: 1, serialNumber: "DUPLICATE")
        let oldDisplay = makeDisplay(id: 41, serial: 0)
        let first = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")
        try first.assign(
            device: oldDevice,
            to: oldDisplay,
            connectedDevices: [oldDevice],
            displays: [oldDisplay]
        )

        let newDevice = TouchDeviceIdentity(locationID: 2, serialNumber: "DUPLICATE")
        let newDisplay = makeDisplay(id: 51, serial: 0)
        let reloaded = PairingStore(url: url, bootSessionIdentifier: "BOOT-B")

        XCTAssertNil(reloaded.resolveDisplay(
            for: newDevice,
            connectedDevices: [newDevice],
            displays: [newDisplay]
        ))
        XCTAssertTrue(reloaded.pairings.isEmpty)
    }

    func testExpiredBootSessionRecordsArePrunedFromPersistence() throws {
        let url = temporaryURL()
        let device = TouchDeviceIdentity(locationID: 1)
        let display = makeDisplay(id: 41, serial: 0)
        let firstBoot = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")
        try firstBoot.assign(device: device, to: display, connectedDevices: [device], displays: [display])

        let secondBoot = PairingStore(url: url, bootSessionIdentifier: "BOOT-B")
        XCTAssertTrue(secondBoot.pairings.isEmpty)

        let oldBootReloaded = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")
        XCTAssertTrue(oldBootReloaded.pairings.isEmpty)
    }

    func testUniquePublicHardwareIdentitiesRestoreAcrossBootAndRuntimeIDChanges() throws {
        let url = temporaryURL()
        let oldDevice = TouchDeviceIdentity(locationID: 1, serialNumber: "TOUCH-A")
        let oldDisplay = makeDisplay(id: 41, serial: 101)
        let first = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")
        try first.assign(
            device: oldDevice,
            to: oldDisplay,
            connectedDevices: [oldDevice],
            displays: [oldDisplay]
        )

        let newDevice = TouchDeviceIdentity(locationID: 2, serialNumber: "TOUCH-A")
        let newDisplay = makeDisplay(id: 51, serial: 101, x: 2_000)
        let reloaded = PairingStore(url: url, bootSessionIdentifier: "BOOT-B")

        XCTAssertEqual(reloaded.pairings.first?.scope, .hardware)
        XCTAssertEqual(
            reloaded.resolveDisplay(for: newDevice, connectedDevices: [newDevice], displays: [newDisplay]),
            newDisplay
        )
    }

    func testDuplicateControllerSerialPreventsCrossBootResolution() throws {
        let url = temporaryURL()
        let firstDevice = TouchDeviceIdentity(locationID: 1, serialNumber: "SAME")
        let secondDevice = TouchDeviceIdentity(locationID: 2, serialNumber: "SAME")
        let firstDisplay = makeDisplay(id: 41, serial: 101)
        let secondDisplay = makeDisplay(id: 42, serial: 102)
        let devices: Set = [firstDevice, secondDevice]
        let displays = [firstDisplay, secondDisplay]
        let first = PairingStore(url: url, bootSessionIdentifier: "BOOT-A")
        try first.assign(device: firstDevice, to: firstDisplay, connectedDevices: devices, displays: displays)
        try first.assign(device: secondDevice, to: secondDisplay, connectedDevices: devices, displays: displays)

        let reloaded = PairingStore(url: url, bootSessionIdentifier: "BOOT-B")
        let currentDevices: Set = [
            TouchDeviceIdentity(locationID: 11, serialNumber: "SAME"),
            TouchDeviceIdentity(locationID: 12, serialNumber: "SAME")
        ]
        let currentDisplays = [makeDisplay(id: 51, serial: 101), makeDisplay(id: 52, serial: 102)]

        XCTAssertTrue(reloaded.pairings.isEmpty)
        XCTAssertNil(reloaded.resolveDisplay(
            for: currentDevices.first!,
            connectedDevices: currentDevices,
            displays: currentDisplays
        ))
    }

    func testDuplicateDisplaySerialPreventsHardwareScope() throws {
        let store = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let device = TouchDeviceIdentity(locationID: 1, serialNumber: "TOUCH-A")
        let firstDisplay = makeDisplay(id: 41, serial: 101)
        let secondDisplay = makeDisplay(id: 42, serial: 101)

        try store.assign(
            device: device,
            to: firstDisplay,
            connectedDevices: [device],
            displays: [firstDisplay, secondDisplay]
        )

        XCTAssertEqual(store.pairings.first?.scope, .bootSession)
    }

    func testAssignmentMaintainsOneToOneRuntimeMapping() throws {
        let store = PairingStore(url: temporaryURL(), bootSessionIdentifier: "BOOT-A")
        let first = TouchDeviceIdentity(locationID: 1)
        let second = TouchDeviceIdentity(locationID: 2)
        let display = makeDisplay(id: 41, serial: 0)
        let devices: Set = [first, second]
        try store.assign(device: first, to: display, connectedDevices: devices, displays: [display])

        try store.assign(device: second, to: display, connectedDevices: devices, displays: [display])

        XCTAssertNil(store.resolveDisplay(for: first, connectedDevices: devices, displays: [display]))
        XCTAssertEqual(
            store.resolveDisplay(for: second, connectedDevices: devices, displays: [display]),
            display
        )
    }

    func testVersionOnePairingsAreIgnoredSafely() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacy = Data(#"{"version":1,"pairings":[{"device":{"locationID":1},"displayUUID":"OLD"}]}"#.utf8)
        try legacy.write(to: url, options: .atomic)

        let store = PairingStore(url: url, bootSessionIdentifier: "BOOT-B")

        XCTAssertTrue(store.pairings.isEmpty)
    }

    func testBootSessionIdentifierUsesKernelBootTimeAcrossProcessTimes() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            PairingStore.currentBootSessionIdentifier(
                kernelBootTimeSeconds: 8_765,
                now: now,
                systemUptime: 1_000
            ),
            "boot-8765"
        )
        XCTAssertEqual(
            PairingStore.currentBootSessionIdentifier(
                kernelBootTimeSeconds: 8_765,
                now: now.addingTimeInterval(20),
                systemUptime: 1_020
            ),
            "boot-8765"
        )
    }

    func testBootSessionIdentifierFallbackCannotMatchKernelMarker() {
        XCTAssertEqual(
            PairingStore.currentBootSessionIdentifier(
                kernelBootTimeSeconds: nil,
                now: Date(timeIntervalSince1970: 10_000),
                systemUptime: 1_000
            ),
            "fallback-boot-9000"
        )
    }

    private func makeDisplay(
        id: CGDirectDisplayID,
        serial: UInt32,
        x: CGFloat = 0,
        vendor: UInt32 = CapturedXeneonDisplay.vendorNumber,
        model: UInt32 = CapturedXeneonDisplay.modelNumber
    ) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: id,
            runtimeIdentifier: "display-\(id)",
            vendorNumber: vendor,
            modelNumber: model,
            serialNumber: serial,
            bounds: CGRect(x: x, y: 200, width: 1_280, height: 480),
            pixelsWide: 1_280,
            pixelsHigh: 480
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MacXeneonEdgeTouchDriverTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pairings.json")
    }
}
