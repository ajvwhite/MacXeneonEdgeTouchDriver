import Foundation
import IOKit
import IOKit.hid

/// Identifies the controller and its nearest upstream hub, not an HID registration.
struct HIDUSBPowerIdentity: Equatable {
    let controllerID: UInt64
    let hubID: UInt64
    let locationID: Int
    let deviceRevision: Int
    let hubVendorID: Int
    let hubProductID: Int

    // This controller revision was captured through a complete monitor power
    // cycle with a finger held through final enumeration: it suppresses the
    // carried-over contact and reports the subsequent fresh contact normally.
    var hasQualifiedResetBehavior: Bool {
        controllerID != 0 && hubID != 0 && controllerID != hubID && locationID > 0 &&
            deviceRevision == 0x0150 && hubVendorID == 0x1a40 && hubProductID == 0x0801
    }

    static func read(device: IOHIDDevice) -> HIDUSBPowerIdentity? {
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return nil }
        var entry = service
        IOObjectRetain(entry)
        var controller: (UInt64, Int, Int)?
        var visited = Set<UInt64>()
        for _ in 0..<12 {
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS,
                  registryID != 0, visited.insert(registryID).inserted else {
                IOObjectRelease(entry); return nil
            }
            func number(_ key: String) -> Int? {
                (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            }
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
                guard let vendor = number("idVendor"), let product = number("idProduct") else {
                    IOObjectRelease(entry); return nil
                }
                if let controller {
                    IOObjectRelease(entry)
                    return HIDUSBPowerIdentity(controllerID: controller.0, hubID: registryID,
                        locationID: controller.1, deviceRevision: controller.2,
                        hubVendorID: vendor, hubProductID: product)
                }
                guard vendor == XeneonEdgeDevice.vendorID, product == XeneonEdgeDevice.productID,
                      let location = number("locationID"), let firmware = number("bcdDevice") else {
                    IOObjectRelease(entry); return nil
                }
                controller = (registryID, location, firmware)
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS else { return nil }
            entry = parent
        }
        IOObjectRelease(entry)
        return nil
    }
}

/// A new hub generation proves a physical monitor re-enumeration. A driver
/// restart or replacement HID alias with the same USB parents cannot qualify.
/// Qualification survives the controller's second boot enumeration for ten
/// seconds only, and is never inferred from silence or default cached values.
struct HIDUSBPowerResetTracker {
    private var removed: [Int: HIDUSBPowerIdentity] = [:]
    private var boot: [Int: (hubID: UInt64, expires: UInt64)] = [:]

    mutating func removed(_ identity: HIDUSBPowerIdentity) {
        removed[identity.locationID] = identity
    }

    mutating func qualifies(_ identity: HIDUSBPowerIdentity, now: UInt64) -> Bool {
        guard identity.hasQualifiedResetBehavior,
              let previous = removed[identity.locationID], previous.hasQualifiedResetBehavior,
              previous.controllerID != identity.controllerID else { return false }
        if previous.hubID != identity.hubID {
            // A new physical hub generation has a new qualified boot epoch.
            if let epoch = boot[identity.locationID], epoch.hubID == identity.hubID {
                return now < epoch.expires
            }
            let (expires, overflow) = now.addingReportingOverflow(10_000_000_000)
            guard !overflow else { return false }
            boot[identity.locationID] = (identity.hubID, expires)
            return true
        }
        guard let epoch = boot[identity.locationID], epoch.hubID == identity.hubID,
              now < epoch.expires else { return false }
        return true
    }

    mutating func invalidate() {
        removed.removeAll()
        boot.removeAll()
    }
}
