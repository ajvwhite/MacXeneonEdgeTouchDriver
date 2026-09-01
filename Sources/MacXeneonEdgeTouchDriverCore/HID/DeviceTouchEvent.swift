import Foundation

/// Public identity data for one connected touch controller.
public struct TouchDeviceIdentity: Hashable, Codable, Sendable {
    /// Runtime USB location identifier. This is not stable across boots.
    public let locationID: UInt32

    /// Public USB serial number, when the controller reports one.
    public let serialNumber: String?

    public init(locationID: UInt32, serialNumber: String? = nil) {
        self.locationID = locationID
        let normalizedSerial = serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serialNumber = normalizedSerial?.isEmpty == false ? normalizedSerial : nil
    }

    public var hexadecimalLocationID: String {
        String(format: "0x%08X", locationID)
    }

    /// Hardware key usable only after the pairing coordinator proves uniqueness.
    public var hardwareKey: String? {
        serialNumber.map { "serial:\($0)" }
    }
}

/// A normalized touch event tagged with the physical controller that emitted it.
public struct DeviceTouchEvent: Equatable {
    public let device: TouchDeviceIdentity
    public let touch: TouchEvent

    public init(device: TouchDeviceIdentity, touch: TouchEvent) {
        self.device = device
        self.touch = touch
    }
}
