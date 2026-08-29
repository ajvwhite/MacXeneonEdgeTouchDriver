import Foundation

/// Persisted one-to-one association between a USB touch controller and a display UUID.
public struct TouchDisplayPairing: Codable, Equatable, Sendable {
    public let device: TouchDeviceIdentity
    public let displayUUID: String

    public init(device: TouchDeviceIdentity, displayUUID: String) {
        self.device = device
        self.displayUUID = displayUUID
    }
}

private struct PairingFile: Codable {
    var version = 1
    var pairings: [TouchDisplayPairing]
}

/// Loads and atomically persists touch-controller-to-display assignments.
public final class PairingStore {
    public private(set) var pairings: [TouchDisplayPairing]

    private let url: URL
    private let fileManager: FileManager

    public init(
        url: URL = PairingStore.defaultURL(),
        fileManager: FileManager = .default
    ) {
        self.url = url
        self.fileManager = fileManager
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

    public func displayUUID(for device: TouchDeviceIdentity) -> String? {
        pairings.first { $0.device == device }?.displayUUID
    }

    public func device(forDisplayUUID displayUUID: String) -> TouchDeviceIdentity? {
        pairings.first { $0.displayUUID == displayUUID }?.device
    }

    /// Assigns a one-to-one mapping. Older records for either endpoint are removed.
    public func assign(device: TouchDeviceIdentity, toDisplayUUID displayUUID: String) throws {
        pairings.removeAll { pairing in
            pairing.device == device || pairing.displayUUID == displayUUID
        }
        pairings.append(TouchDisplayPairing(device: device, displayUUID: displayUUID))
        pairings.sort { $0.device.locationID < $1.device.locationID }
        try save()
    }

    public func remove(device: TouchDeviceIdentity) throws {
        pairings.removeAll { $0.device == device }
        try save()
    }

    private func load() {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            pairings = try JSONDecoder().decode(PairingFile.self, from: data).pairings
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
}
