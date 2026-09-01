import CoreGraphics
import Darwin
import Foundation

/// Lifetime of a persisted pairing.
public enum PairingScope: String, Codable, Equatable, Sendable {
    /// Runtime identifiers are trusted only during the boot in which calibration occurred.
    case bootSession

    /// Both endpoints exposed public hardware identifiers that were unique when calibrated.
    case hardware
}

/// Persisted one-to-one association between a USB touch controller and a display.
public struct TouchDisplayPairing: Codable, Equatable, Sendable {
    public let device: TouchDeviceIdentity
    public let displayID: CGDirectDisplayID
    public let displayVendorNumber: UInt32
    public let displayModelNumber: UInt32
    public let displaySerialNumber: UInt32
    public let bootSessionIdentifier: String
    public let scope: PairingScope

    public init(
        device: TouchDeviceIdentity,
        display: DisplaySnapshot,
        bootSessionIdentifier: String,
        scope: PairingScope
    ) {
        self.device = device
        self.displayID = display.displayID
        self.displayVendorNumber = display.vendorNumber
        self.displayModelNumber = display.modelNumber
        self.displaySerialNumber = display.serialNumber
        self.bootSessionIdentifier = bootSessionIdentifier
        self.scope = scope
    }

    var displayHardwareKey: String? {
        guard displaySerialNumber != 0 else { return nil }
        return "edid:\(displayVendorNumber):\(displayModelNumber):\(displaySerialNumber)"
    }
}

private struct PairingFile: Codable {
    var version = 2
    var pairings: [TouchDisplayPairing]
}

private struct LegacyPairingFile: Decodable {
    let version: Int
}

/// Loads, validates, resolves, and atomically persists touch-display assignments.
public final class PairingStore {
    public private(set) var pairings: [TouchDisplayPairing]

    private let url: URL
    private let fileManager: FileManager
    private let bootSessionIdentifier: String

    public init(
        url: URL = PairingStore.defaultURL(),
        fileManager: FileManager = .default,
        bootSessionIdentifier: String = PairingStore.currentBootSessionIdentifier()
    ) {
        self.url = url
        self.fileManager = fileManager
        self.bootSessionIdentifier = bootSessionIdentifier
        self.pairings = []
        load()
    }

    public static func defaultURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MacXeneonEdgeTouchDriver", isDirectory: true)
            .appendingPathComponent("pairings.json", isDirectory: false)
    }

    /// A supported marker backed by the kernel-reported system boot time.
    public static func currentBootSessionIdentifier() -> String {
        currentBootSessionIdentifier(
            kernelBootTimeSeconds: kernelBootTimeSeconds(),
            now: Date(),
            systemUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    static func currentBootSessionIdentifier(
        kernelBootTimeSeconds: Int64?,
        now: Date = Date(),
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> String {
        if let kernelBootTimeSeconds {
            return "boot-\(kernelBootTimeSeconds)"
        }

        let bootEpochSeconds = Int64((now.timeIntervalSince1970 - systemUptime).rounded())
        return "fallback-boot-\(bootEpochSeconds)"
    }

    /// Resolves a controller to a current display without using display bounds as identity.
    public func resolveDisplay(
        for device: TouchDeviceIdentity,
        connectedDevices: Set<TouchDeviceIdentity>,
        displays: [DisplaySnapshot]
    ) -> DisplaySnapshot? {
        if let exact = pairings.first(where: {
            $0.bootSessionIdentifier == bootSessionIdentifier &&
            runtimeDevice($0.device, matches: device)
        }), let display = displays.first(where: {
            $0.displayID == exact.displayID && runtimeDisplay(exact, matches: $0)
        }) {
            return display
        }

        guard let deviceKey = device.hardwareKey,
              connectedDevices.filter({ $0.hardwareKey == deviceKey }).count == 1,
              pairings.filter({ $0.scope == .hardware && $0.device.hardwareKey == deviceKey }).count == 1,
              let pairing = pairings.first(where: {
                  $0.scope == .hardware && $0.device.hardwareKey == deviceKey
              }),
              let displayKey = pairing.displayHardwareKey,
              displays.filter({ $0.hardwareKey == displayKey }).count == 1,
              pairings.filter({ $0.scope == .hardware && $0.displayHardwareKey == displayKey }).count == 1 else {
            return nil
        }

        return displays.first { $0.hardwareKey == displayKey }
    }

    /// Removes same-boot pairings whose reused runtime identifiers now describe
    /// different public hardware. Missing endpoints are left for explicit removal
    /// callbacks so staged login enumeration cannot erase a valid pairing.
    @discardableResult
    public func reconcileRuntimeDescriptors(
        connectedDevices: Set<TouchDeviceIdentity>,
        displays: [DisplaySnapshot]
    ) throws -> Int {
        let originalCount = pairings.count
        pairings.removeAll { pairing in
            guard pairing.scope == .bootSession,
                  pairing.bootSessionIdentifier == bootSessionIdentifier else {
                return false
            }

            let deviceWasReused = connectedDevices
                .first { $0.locationID == pairing.device.locationID }
                .map { !runtimeDevice(pairing.device, matches: $0) } ?? false
            let displayWasReused = displays
                .first { $0.displayID == pairing.displayID }
                .map { !runtimeDisplay(pairing, matches: $0) } ?? false
            return deviceWasReused || displayWasReused
        }
        let removedCount = originalCount - pairings.count
        if removedCount > 0 { try save() }
        return removedCount
    }

    /// Invalidates ambiguous same-boot authority after a controller disconnects.
    public func invalidateBootSessionPairing(for device: TouchDeviceIdentity) throws {
        try removeBootSessionPairings {
            $0.device.locationID == device.locationID
        }
    }

    /// Invalidates ambiguous same-boot authority after display membership changes.
    public func invalidateBootSessionPairing(forDisplayID displayID: CGDirectDisplayID) throws {
        try removeBootSessionPairings { $0.displayID == displayID }
    }

    /// Assigns a mapping and chooses the strongest scope justified by current public data.
    public func assign(
        device: TouchDeviceIdentity,
        to display: DisplaySnapshot,
        connectedDevices: Set<TouchDeviceIdentity>,
        displays: [DisplaySnapshot]
    ) throws {
        let deviceKey = device.hardwareKey
        let displayKey = display.hardwareKey
        let hardwareIsUnique = deviceKey != nil &&
            displayKey != nil &&
            connectedDevices.filter { $0.hardwareKey == deviceKey }.count == 1 &&
            displays.filter { $0.hardwareKey == displayKey }.count == 1
        let scope: PairingScope = hardwareIsUnique ? .hardware : .bootSession

        pairings.removeAll { pairing in
            let sameRuntimeDevice = pairing.bootSessionIdentifier == bootSessionIdentifier &&
                pairing.device.locationID == device.locationID
            let sameRuntimeDisplay = pairing.bootSessionIdentifier == bootSessionIdentifier &&
                pairing.displayID == display.displayID
            let sameHardwareDevice = scope == .hardware && pairing.scope == .hardware &&
                pairing.device.hardwareKey == deviceKey
            let sameHardwareDisplay = scope == .hardware && pairing.scope == .hardware &&
                pairing.displayHardwareKey == displayKey
            return sameRuntimeDevice || sameRuntimeDisplay || sameHardwareDevice || sameHardwareDisplay
        }

        pairings.append(TouchDisplayPairing(
            device: device,
            display: display,
            bootSessionIdentifier: bootSessionIdentifier,
            scope: scope
        ))
        pairings.sort {
            if $0.bootSessionIdentifier != $1.bootSessionIdentifier {
                return $0.bootSessionIdentifier < $1.bootSessionIdentifier
            }
            return $0.device.locationID < $1.device.locationID
        }
        try save()
    }

    public func remove(device: TouchDeviceIdentity) throws {
        pairings.removeAll {
            $0.bootSessionIdentifier == bootSessionIdentifier &&
            $0.device.locationID == device.locationID
        }
        try save()
    }

    private func removeBootSessionPairings(
        where shouldRemove: (TouchDisplayPairing) -> Bool
    ) throws {
        let originalCount = pairings.count
        pairings.removeAll {
            $0.scope == .bootSession &&
            $0.bootSessionIdentifier == bootSessionIdentifier &&
            shouldRemove($0)
        }
        if pairings.count != originalCount { try save() }
    }

    private func runtimeDevice(
        _ saved: TouchDeviceIdentity,
        matches current: TouchDeviceIdentity
    ) -> Bool {
        saved.locationID == current.locationID &&
        saved.serialNumber == current.serialNumber
    }

    private func runtimeDisplay(
        _ pairing: TouchDisplayPairing,
        matches display: DisplaySnapshot
    ) -> Bool {
        pairing.displayID == display.displayID &&
        pairing.displayVendorNumber == display.vendorNumber &&
        pairing.displayModelNumber == display.modelNumber &&
        pairing.displaySerialNumber == display.serialNumber
    }

    private func load() {
        guard fileManager.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            if let legacy = try? JSONDecoder().decode(LegacyPairingFile.self, from: data),
               legacy.version < 2 {
                DriverLoggers.log(.notice, category: .display, "Ignoring version-one runtime pairings; calibration will create supported version-two identities.")
                pairings = []
                return
            }
            let decoded = try JSONDecoder().decode(PairingFile.self, from: data)
            let retainedPairings = decoded.pairings.filter {
                $0.scope == .hardware || $0.bootSessionIdentifier == bootSessionIdentifier
            }
            pairings = retainedPairings
            if retainedPairings.count != decoded.pairings.count {
                do {
                    try save()
                } catch {
                    DriverLoggers.log(
                        .error,
                        category: .display,
                        "Could not prune expired runtime pairings: \(error.localizedDescription)"
                    )
                }
            }
        } catch {
            DriverLoggers.log(.error, category: .display, "Could not load pairing file at \(url.path): \(error.localizedDescription)")
            pairings = []
        }
    }

    private func save() throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(PairingFile(pairings: pairings))
        try data.write(to: url, options: .atomic)
    }

    private static func kernelBootTimeSeconds() -> Int64? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        let result = sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
        guard result == 0, size == MemoryLayout<timeval>.size else { return nil }
        return Int64(bootTime.tv_sec)
    }
}
