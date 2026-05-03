import Foundation

/// Display values captured with the `DisplayInfo` diagnostic on this machine.
public enum CapturedXeneonDisplay {
    /// Captured on 2026-05-02 with `swift run DisplayInfo`.
    public static let captureNote = "Captured on 2026-05-02 with swift run DisplayInfo."

    /// EDID vendor number reported for the Xeneon Edge.
    public static let vendorNumber: UInt32 = 3_672

    /// EDID model number reported for the Xeneon Edge.
    public static let modelNumber: UInt32 = 60_672

    /// Serial number reported by the Xeneon Edge. Not unique in this setup.
    public static let observedSerialNumber: UInt32 = 16_843_009

    /// Expected physical pixel width for the Xeneon Edge.
    public static let expectedWidth = 2_560

    /// Expected physical pixel height for the Xeneon Edge.
    public static let expectedHeight = 720
}
