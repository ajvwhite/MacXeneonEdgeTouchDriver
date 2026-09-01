import CoreGraphics
import Foundation

/// Snapshot of a connected display needed for Xeneon matching.
public struct DisplaySnapshot: Equatable {
    /// CoreGraphics display identifier.
    public let displayID: CGDirectDisplayID

    /// Current-boot CoreGraphics display identifier rendered for logs and storage.
    public let runtimeIdentifier: String

    /// EDID vendor number.
    public let vendorNumber: UInt32

    /// EDID model number.
    public let modelNumber: UInt32

    /// EDID serial number.
    public let serialNumber: UInt32

    /// Current display bounds in Quartz coordinates.
    public let bounds: CGRect

    /// Physical pixel width.
    public let pixelsWide: Int

    /// Physical pixel height.
    public let pixelsHigh: Int

    /// Creates a display snapshot for matching or tests.
    public init(
        displayID: CGDirectDisplayID,
        runtimeIdentifier: String = "",
        vendorNumber: UInt32,
        modelNumber: UInt32,
        serialNumber: UInt32,
        bounds: CGRect,
        pixelsWide: Int,
        pixelsHigh: Int
    ) {
        self.displayID = displayID
        self.runtimeIdentifier = runtimeIdentifier.isEmpty ? "display-\(displayID)" : runtimeIdentifier
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.bounds = bounds
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
    }

    /// Public hardware key usable only after the pairing coordinator proves uniqueness.
    public var hardwareKey: String? {
        guard serialNumber != 0 else { return nil }
        return "edid:\(vendorNumber):\(modelNumber):\(serialNumber)"
    }
}

/// Resolves and tracks the Xeneon Edge display by EDID and physical size.
public final class DisplayResolver {
    /// Callback fired after `refresh()` changes the resolved display.
    public var onDisplayChanged: ((CGRect?) -> Void)?

    /// Current Xeneon display bounds, if resolved.
    public private(set) var currentBounds: CGRect?

    /// Current coordinate mapper for the Xeneon display, if resolved.
    public private(set) var currentMapper: CoordinateMapper?

    private let configuration: DriverConfiguration.Display
    private let activeDisplayProvider: () -> [DisplaySnapshot]
    private var currentDisplayID: CGDirectDisplayID?

    /// Creates a display resolver using the effective configuration.
    public convenience init(configuration: DriverConfiguration.Display = DriverConfiguration.defaults.display) {
        self.init(configuration: configuration, activeDisplayProvider: Self.activeDisplaySnapshots)
    }

    init(
        configuration: DriverConfiguration.Display = DriverConfiguration.defaults.display,
        activeDisplayProvider: @escaping () -> [DisplaySnapshot]
    ) {
        self.configuration = configuration
        self.activeDisplayProvider = activeDisplayProvider
    }

    /// Re-resolves the Xeneon display from the active display list.
    public func refresh() {
        let previousBounds = currentBounds
        let previousDisplayID = currentDisplayID
        let match = resolve()

        currentDisplayID = match?.displayID
        currentBounds = match?.bounds
        currentMapper = match.map { CoordinateMapper(displayBounds: $0.bounds) }

        if currentBounds != previousBounds || currentDisplayID != previousDisplayID {
            onDisplayChanged?(currentBounds)
        }
    }

    /// Returns the best current Xeneon display match.
    public func resolve() -> DisplaySnapshot? {
        resolve(from: activeDisplayProvider())
    }

    /// Returns the best Xeneon display match from supplied snapshots.
    public func resolve(from displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        let matches = matchingDisplays(from: displays)
        return matches.first
    }

    /// Returns all compatible displays in a stable visual order for pairing.
    public func matchingDisplays() -> [DisplaySnapshot] {
        matchingDisplays(from: activeDisplayProvider())
    }

    /// Returns a fresh snapshot of every active display, including incompatible displays.
    public func activeDisplays() -> [DisplaySnapshot] {
        activeDisplayProvider()
    }

    /// Returns all compatible displays from supplied snapshots.
    public func matchingDisplays(from displays: [DisplaySnapshot]) -> [DisplaySnapshot] {
        let vendorModelMatches = displays.filter { display in
            display.vendorNumber == configuration.vendorNumber &&
            display.modelNumber == configuration.modelNumber
        }

        let serialMatches: [DisplaySnapshot]
        if let serialNumber = configuration.serialNumber {
            serialMatches = vendorModelMatches.filter { $0.serialNumber == serialNumber }
        } else {
            serialMatches = vendorModelMatches
        }

        let sizeMatches = serialMatches.filter { display in
            display.pixelsWide == configuration.expectedWidth &&
            display.pixelsHigh == configuration.expectedHeight
        }

        let matches = sizeMatches.isEmpty
            ? (serialMatches.isEmpty ? vendorModelMatches : serialMatches)
            : sizeMatches

        return matches.sorted { lhs, rhs in
            if lhs.bounds.origin.x != rhs.bounds.origin.x {
                return lhs.bounds.origin.x < rhs.bounds.origin.x
            }
            return lhs.bounds.origin.y < rhs.bounds.origin.y
        }
    }

    /// Returns live snapshots for every active CoreGraphics display.
    public static func activeDisplaySnapshots() -> [DisplaySnapshot] {
        var displayCount: UInt32 = 0
        let countResult = CGGetActiveDisplayList(0, nil, &displayCount)
        guard countResult == .success else {
            DriverLoggers.log(.error, category: .display, "CGGetActiveDisplayList count failed: \(countResult.rawValue)")
            return []
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let listResult = CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
        guard listResult == .success else {
            DriverLoggers.log(.error, category: .display, "CGGetActiveDisplayList values failed: \(listResult.rawValue)")
            return []
        }

        return displayIDs.prefix(Int(displayCount)).map(makeSnapshot)
    }

    private static func makeSnapshot(displayID: CGDirectDisplayID) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: displayID,
            runtimeIdentifier: "display-\(displayID)",
            vendorNumber: CGDisplayVendorNumber(displayID),
            modelNumber: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID),
            bounds: CGDisplayBounds(displayID),
            pixelsWide: CGDisplayPixelsWide(displayID),
            pixelsHigh: CGDisplayPixelsHigh(displayID)
        )
    }

}
