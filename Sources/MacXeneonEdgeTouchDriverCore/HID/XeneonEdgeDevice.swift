import Foundation

/// Hardware constants for the Corsair Xeneon Edge WCH touchscreen controller.
public enum XeneonEdgeDevice {
    /// USB vendor ID reported by the touchscreen controller.
    public static let vendorID = 0x27c0

    /// USB product ID reported by the touchscreen controller.
    public static let productID = 0x0859

    /// Raw X coordinate range observed from the HID descriptor.
    public static let rawXRange = 0...16_383

    /// Raw Y coordinate range observed from the HID descriptor.
    public static let rawYRange = 0...9_599

    /// Report ID observed for all touch reports during the multi-touch feasibility gate.
    public static let touchReportID = 7

    /// HID report size observed for one-, two-, and three-finger interactions.
    public static let touchReportLength = 7

    /// Multi-touch capability observed with `HIDDump` on this hardware.
    public static let supportsMultiTouch = false
}
