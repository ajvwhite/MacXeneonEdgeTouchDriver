import Foundation

/// Read-only startup diagnostics. This does not request permissions, open HID,
/// start monitoring or post input. Readiness is not proof of event delivery.
public struct DriverPermissionStatus: Codable {
    public let postEventAccess: Bool
    public let accessibilityTrusted: Bool
    public let hidInputAccess: String
    public let readyForUnattendedStart: Bool

    public static func inspect() -> Self {
        let snapshot = SystemSyntheticPermissionProvider().snapshot()
        return Self(postEventAccess: snapshot.postEventAccess,
                    accessibilityTrusted: snapshot.accessibilityTrusted,
                    hidInputAccess: snapshot.hidInputAccess.rawValue,
                    readyForUnattendedStart: snapshot.hasRequiredSyntheticAccess && snapshot.hidInputAccess == .granted)
    }
}
