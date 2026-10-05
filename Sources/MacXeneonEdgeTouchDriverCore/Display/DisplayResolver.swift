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

    /// Creates a display snapshot for matching or tests.
    public init(
        displayID: CGDirectDisplayID,
        vendorNumber: UInt32,
        modelNumber: UInt32,
        serialNumber: UInt32,
        bounds: CGRect,
        pixelsWide: Int,
        pixelsHigh: Int
    ) {
        self.displayID = displayID
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.bounds = bounds
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
    }
}

/// Resolves and tracks the Xeneon Edge display by EDID and physical size.
public final class DisplayResolver {
    /// Callback fired after committing a different display identity or bounds.
    public var onDisplayChanged: ((CGRect?) -> Void)?

    /// Last committed display snapshot, if resolved.
    public private(set) var currentSnapshot: DisplaySnapshot?

    /// Current Xeneon display bounds, if resolved.
    public private(set) var currentBounds: CGRect?

    /// Current coordinate mapper for the Xeneon display, if resolved.
    public private(set) var currentMapper: CoordinateMapper?

    private let configuration: DriverConfiguration.Display
    private let activeDisplayProvider: () -> [DisplaySnapshot]
    private let diagnosticLog: ((DriverLogLevel, DriverLogCategory, String) -> Void)?
    private var lastDiagnosticCandidates: [[UInt64]]?

    /// Creates a display resolver using the effective configuration.
    public convenience init(configuration: DriverConfiguration.Display = DriverConfiguration.defaults.display) {
        self.init(configuration: configuration, activeDisplayProvider: Self.activeDisplaySnapshots)
    }

    init(
        configuration: DriverConfiguration.Display = DriverConfiguration.defaults.display,
        activeDisplayProvider: @escaping () -> [DisplaySnapshot],
        diagnosticLog: ((DriverLogLevel, DriverLogCategory, String) -> Void)? = {
            DriverLoggers.log($0, category: $1, $2)
        }
    ) {
        self.configuration = configuration
        self.activeDisplayProvider = activeDisplayProvider
        self.diagnosticLog = diagnosticLog
    }

    /// Re-resolves the Xeneon display from the active display list.
    public func refresh() {
        update(with: resolve())
    }

    /// Commits a previously resolved snapshot without enumerating displays again.
    func update(with snapshot: DisplaySnapshot?) {
        let previousBounds = currentBounds
        let previousDisplayID = currentSnapshot?.displayID
        let match = snapshot.flatMap { Self.hasValidBounds($0) ? $0 : nil }

        currentSnapshot = match
        currentBounds = match?.bounds
        currentMapper = match.map { CoordinateMapper(displayBounds: $0.bounds) }

        if currentBounds != previousBounds || currentSnapshot?.displayID != previousDisplayID {
            onDisplayChanged?(currentBounds)
        }
    }

    /// Returns the best current Xeneon display match.
    public func resolve() -> DisplaySnapshot? {
        resolve(from: activeDisplayProvider())
    }

    /// Returns the best Xeneon display match from supplied snapshots.
    public func resolve(from displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        let vendorModelMatches = displays.filter { display in
            display.vendorNumber == configuration.vendorNumber &&
            display.modelNumber == configuration.modelNumber &&
            Self.hasValidBounds(display)
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

        let bestMatches = sizeMatches.isEmpty ? serialMatches : sizeMatches
        let match = bestMatches.count == 1 ? bestMatches.first : nil
        recordDiagnostic(
            displays: displays,
            vendorModelMatches: vendorModelMatches,
            bestMatches: bestMatches,
            prefersSize: !sizeMatches.isEmpty,
            selected: match
        )
        return match
    }

    private func recordDiagnostic(
        displays: [DisplaySnapshot],
        vendorModelMatches: [DisplaySnapshot],
        bestMatches: [DisplaySnapshot],
        prefersSize: Bool,
        selected: DisplaySnapshot?
    ) {
        guard let diagnosticLog else { return }

        // Canonical value keys avoid formatting a dump for every touch. They cover
        // every selector input; with immutable configuration, the outcome is also
        // unchanged. Preserve duplicate rows: two identical records are ambiguous.
        let candidates = displays.map { (snapshot: $0, key: Self.diagnosticKey($0)) }
            .sorted { $0.key.lexicographicallyPrecedes($1.key) }
        let keys = candidates.map { $0.key }
        guard keys != lastDiagnosticCandidates else { return }
        lastDiagnosticCandidates = keys

        let preference = prefersSize ? "expected-pixels" : "fallback"
        let outcome: String
        if let selected {
            outcome = "selectedID=\(selected.displayID) preference=\(preference)"
        } else if bestMatches.count > 1 {
            let ids = bestMatches.map { $0.displayID }.sorted().map { String($0) }.joined(separator: ",")
            outcome = "ambiguous preference=\(preference) bestIDs=[\(ids)]"
        } else if displays.isEmpty {
            outcome = "no-match reason=no-active-displays"
        } else if vendorModelMatches.isEmpty {
            let hasIdentityMatch = displays.contains {
                $0.vendorNumber == configuration.vendorNumber && $0.modelNumber == configuration.modelNumber
            }
            outcome = hasIdentityMatch ? "no-match reason=no-valid-bounds" : "no-match reason=no-vendor-model-match"
        } else {
            outcome = "no-match reason=no-valid-configured-serial-match"
        }

        let details = candidates.map { candidate in
            let display = candidate.snapshot
            let bounds = display.bounds
            let coordinates = [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height]
                .map(Self.diagnosticCoordinate).joined(separator: ",")
            return "{id=\(display.displayID) vendor=\(display.vendorNumber) model=\(display.modelNumber) " +
                "serial=\(display.serialNumber) bounds=(\(coordinates)) " +
                "pixels=\(display.pixelsWide)x\(display.pixelsHigh) validBounds=\(Self.hasValidBounds(display))}"
        }.joined(separator: ", ")
        let vendor = configuration.vendorNumber.map { String($0) } ?? "unset"
        let model = configuration.modelNumber.map { String($0) } ?? "unset"
        let serial = configuration.serialNumber.map { String($0) } ?? "any"
        diagnosticLog(.debug, .display,
            "Display selection: \(outcome); target vendor=\(vendor) model=\(model) serial=\(serial) " +
            "pixels=\(configuration.expectedWidth)x\(configuration.expectedHeight); candidates=[\(details)]")
    }

    private static func diagnosticKey(_ display: DisplaySnapshot) -> [UInt64] {
        let bounds = display.bounds
        return [
            UInt64(display.displayID), UInt64(display.vendorNumber), UInt64(display.modelNumber), UInt64(display.serialNumber),
            diagnosticCoordinateKey(bounds.origin.x), diagnosticCoordinateKey(bounds.origin.y),
            diagnosticCoordinateKey(bounds.size.width), diagnosticCoordinateKey(bounds.size.height),
            UInt64(bitPattern: Int64(display.pixelsWide)), UInt64(bitPattern: Int64(display.pixelsHigh))
        ]
    }

    private static func diagnosticCoordinateKey(_ value: CGFloat) -> UInt64 {
        // NaN is not equal to itself; canonicalize it and signed zero so unchanged
        // invalid snapshots cannot flood the log. Keep all finite precision.
        if value.isNaN { return Double.nan.bitPattern }
        return Double(value == 0 ? 0 : value).bitPattern
    }

    private static func diagnosticCoordinate(_ value: CGFloat) -> String {
        if value.isNaN { return "nan" }
        if value == .infinity { return "inf" }
        if value == -.infinity { return "-inf" }
        if value == 0 { return "0" }
        return String(describing: value)
    }

    private static func hasValidBounds(_ display: DisplaySnapshot) -> Bool {
        let bounds = display.bounds
        return !bounds.isNull && !bounds.isInfinite &&
            bounds.origin.x.isFinite && bounds.origin.y.isFinite &&
            bounds.size.width.isFinite && bounds.size.height.isFinite &&
            bounds.size.width > 0 && bounds.size.height > 0 &&
            bounds.maxX.isFinite && bounds.maxY.isFinite &&
            bounds.minX < bounds.maxX && bounds.minY < bounds.maxY
    }

    private static func activeDisplaySnapshots() -> [DisplaySnapshot] {
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
            vendorNumber: CGDisplayVendorNumber(displayID),
            modelNumber: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID),
            bounds: CGDisplayBounds(displayID),
            pixelsWide: CGDisplayPixelsWide(displayID),
            pixelsHigh: CGDisplayPixelsHigh(displayID)
        )
    }
}
