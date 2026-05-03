import AppKit
import CoreGraphics
import Foundation

/// Snapshot of a connected display needed for Xeneon matching.
public struct DisplaySnapshot: Equatable {
    /// CoreGraphics display identifier.
    public let displayID: CGDirectDisplayID

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

    /// Localized display name, used only for diagnostics.
    public let localizedName: String

    /// Creates a display snapshot for matching or tests.
    public init(
        displayID: CGDirectDisplayID,
        vendorNumber: UInt32,
        modelNumber: UInt32,
        serialNumber: UInt32,
        bounds: CGRect,
        pixelsWide: Int,
        pixelsHigh: Int,
        localizedName: String
    ) {
        self.displayID = displayID
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.bounds = bounds
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
        self.localizedName = localizedName
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
    private var currentDisplayID: CGDirectDisplayID?

    /// Creates a display resolver using the effective configuration.
    public init(configuration: DriverConfiguration.Display = DriverConfiguration.defaults.display) {
        self.configuration = configuration
    }

    /// Re-resolves the Xeneon display from the active display list.
    public func refresh() {
        let previousBounds = currentBounds
        let match = resolve()

        currentDisplayID = match?.displayID
        currentBounds = match?.bounds
        currentMapper = match.map { CoordinateMapper(displayBounds: $0.bounds) }

        if currentBounds != previousBounds {
            onDisplayChanged?(currentBounds)
        }
    }

    /// Returns the best current Xeneon display match.
    public func resolve() -> DisplaySnapshot? {
        resolve(from: activeDisplaySnapshots())
    }

    /// Returns the best Xeneon display match from supplied snapshots.
    public func resolve(from displays: [DisplaySnapshot]) -> DisplaySnapshot? {
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

        return sizeMatches.first ?? serialMatches.first ?? vendorModelMatches.first
    }

    private func activeDisplaySnapshots() -> [DisplaySnapshot] {
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

    private func makeSnapshot(displayID: CGDirectDisplayID) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: displayID,
            vendorNumber: CGDisplayVendorNumber(displayID),
            modelNumber: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID),
            bounds: CGDisplayBounds(displayID),
            pixelsWide: CGDisplayPixelsWide(displayID),
            pixelsHigh: CGDisplayPixelsHigh(displayID),
            localizedName: localizedName(for: displayID)
        )
    }

    private func localizedName(for displayID: CGDirectDisplayID) -> String {
        let targetNumber = NSNumber(value: displayID)

        return NSScreen.screens.first { screen in
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == targetNumber
        }?.localizedName ?? "Unknown"
    }
}
