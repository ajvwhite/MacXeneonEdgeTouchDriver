import AppKit
import CoreGraphics
import Darwin
import Foundation

private struct DisplayRecord {
    let displayID: CGDirectDisplayID
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32
    let localizedName: String
    let bounds: CGRect
    let pixelsWide: Int
    let pixelsHigh: Int
    let isMain: Bool
}

private struct DisplayInfoError: Error, CustomStringConvertible {
    let description: String
}

private final class DisplayInfoApplication {
    func run() -> Int32 {
        switch activeDisplays() {
        case .success(let displays):
            printHeader(displayCount: displays.count)
            displays.map(makeRecord).forEach(printRecord)
            return EXIT_SUCCESS

        case .failure(let error):
            fputs("DisplayInfo failed: \(error)\n", stderr)
            return EXIT_FAILURE
        }
    }

    private func activeDisplays() -> Result<[CGDirectDisplayID], DisplayInfoError> {
        var displayCount: UInt32 = 0
        var result = CGGetActiveDisplayList(0, nil, &displayCount)
        guard result == .success else {
            return .failure(DisplayInfoError(description: "CGGetActiveDisplayList count failed with \(formatIOReturn(result.rawValue))"))
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        result = CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        guard result == .success else {
            return .failure(DisplayInfoError(description: "CGGetActiveDisplayList values failed with \(formatIOReturn(result.rawValue))"))
        }

        return .success(Array(displays.prefix(Int(displayCount))))
    }

    private func makeRecord(for displayID: CGDirectDisplayID) -> DisplayRecord {
        DisplayRecord(
            displayID: displayID,
            vendorNumber: CGDisplayVendorNumber(displayID),
            modelNumber: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID),
            localizedName: localizedName(for: displayID),
            bounds: CGDisplayBounds(displayID),
            pixelsWide: CGDisplayPixelsWide(displayID),
            pixelsHigh: CGDisplayPixelsHigh(displayID),
            isMain: displayID == CGMainDisplayID()
        )
    }

    private func localizedName(for displayID: CGDirectDisplayID) -> String {
        let targetNumber = NSNumber(value: displayID)

        return NSScreen.screens.first { screen in
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == targetNumber
        }?.localizedName ?? "Unknown"
    }

    private func printHeader(displayCount: Int) {
        print("DisplayInfo")
        print("Active displays: \(displayCount)")
        print(String(repeating: "-", count: 72))
    }

    private func printRecord(_ record: DisplayRecord) {
        print("displayID: \(record.displayID)")
        print("  vendorNumber: \(record.vendorNumber)")
        print("  modelNumber: \(record.modelNumber)")
        print("  serialNumber: \(record.serialNumber)")
        print("  localizedName: \(record.localizedName)")
        print("  bounds: x=\(format(record.bounds.origin.x)) y=\(format(record.bounds.origin.y)) width=\(format(record.bounds.width)) height=\(format(record.bounds.height))")
        print("  pixelsWide: \(record.pixelsWide)")
        print("  pixelsHigh: \(record.pixelsHigh)")
        print("  isMain: \(record.isMain)")
        print(String(repeating: "-", count: 72))
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private func formatIOReturn(_ value: Int32) -> String {
        String(format: "0x%08X", UInt32(bitPattern: value))
    }
}

exit(DisplayInfoApplication().run())
