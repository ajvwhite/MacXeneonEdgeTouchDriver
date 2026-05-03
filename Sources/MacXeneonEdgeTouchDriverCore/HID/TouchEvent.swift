import Foundation

/// A normalized touch event produced from the Xeneon Edge HID report stream.
public struct TouchEvent: Equatable {
    /// Contact lifecycle event.
    public enum Kind: Equatable {
        case down
        case move
        case up
    }

    /// Event kind.
    public let kind: Kind

    /// Contact identifier. Current hardware is single-touch, so this is always `0`.
    public let contactID: Int

    /// Raw X coordinate in the device coordinate range.
    public let rawX: Int

    /// Raw Y coordinate in the device coordinate range.
    public let rawY: Int

    /// Event timestamp.
    public let timestamp: DispatchTime

    /// Creates a touch event.
    public init(kind: Kind, contactID: Int, rawX: Int, rawY: Int, timestamp: DispatchTime) {
        self.kind = kind
        self.contactID = contactID
        self.rawX = rawX
        self.rawY = rawY
        self.timestamp = timestamp
    }
}
