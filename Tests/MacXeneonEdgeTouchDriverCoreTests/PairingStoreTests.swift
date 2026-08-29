import Foundation
import MacXeneonEdgeTouchDriverCore
import XCTest

final class PairingStoreTests: XCTestCase {
    func testAssignmentsPersistAcrossStoreInstances() throws {
        let url = temporaryURL()
        let device = TouchDeviceIdentity(locationID: 0x0110_0000)
        let first = PairingStore(url: url)

        try first.assign(device: device, toDisplayUUID: "DISPLAY-A")
        let reloaded = PairingStore(url: url)

        XCTAssertEqual(reloaded.displayUUID(for: device), "DISPLAY-A")
    }

    func testAssignmentMaintainsOneToOneMapping() throws {
        let store = PairingStore(url: temporaryURL())
        let first = TouchDeviceIdentity(locationID: 1)
        let second = TouchDeviceIdentity(locationID: 2)
        try store.assign(device: first, toDisplayUUID: "DISPLAY-A")

        try store.assign(device: second, toDisplayUUID: "DISPLAY-A")

        XCTAssertNil(store.displayUUID(for: first))
        XCTAssertEqual(store.displayUUID(for: second), "DISPLAY-A")
        XCTAssertEqual(store.device(forDisplayUUID: "DISPLAY-A"), second)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MacXeneonEdgeTouchDriverTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pairings.json")
    }
}
