import Foundation

/// Stable identity for one connected touch controller on the current USB topology.
public struct TouchDeviceIdentity: Hashable, Codable, Sendable {
    public let locationID: UInt32

    public init(locationID: UInt32) {
        self.locationID = locationID
    }

    public var hexadecimalLocationID: String {
        String(format: "0x%08X", locationID)
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
