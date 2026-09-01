import Darwin
import Foundation
import IOKit
import IOKit.hid

private let touchscreenVendorID = 0x27c0
private let touchscreenProductID = 0x0859
private let defaultReportBufferLength = 256

private final class ReportRegistration {
    let device: IOHIDDevice
    let buffer: UnsafeMutablePointer<UInt8>
    let length: CFIndex
    let locationID: UInt32?
    unowned let application: HIDDumpApplication

    init(device: IOHIDDevice, length: Int, locationID: UInt32?, application: HIDDumpApplication) {
        self.device = device
        self.length = CFIndex(length)
        self.locationID = locationID
        self.application = application
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        self.buffer.initialize(repeating: 0, count: length)
    }

    deinit {
        buffer.deinitialize(count: Int(length))
        buffer.deallocate()
    }

    func matches(_ otherDevice: IOHIDDevice) -> Bool {
        CFEqual(device, otherDevice)
    }

    func handleInputReport(
        type: IOHIDReportType,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex
    ) {
        application.handleInputReport(
            locationID: locationID,
            type: type,
            reportID: reportID,
            report: report,
            reportLength: reportLength
        )
    }
}

private final class HIDDumpApplication {
    private let manager: IOHIDManager
    private var reportRegistrations: [ReportRegistration] = []
    private var valueEventCount = 0
    private var rawReportCount = 0

    init() {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func run() -> Int32 {
        setbuf(stdout, nil)
        printHeader()

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: touchscreenVendorID,
            kIOHIDProductIDKey as String: touchscreenProductID
        ]

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatchedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, context)
        IOHIDManagerRegisterInputValueCallback(manager, inputValueCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            fputs("Failed to open IOHIDManager: \(formatIOReturn(openResult))\n", stderr)
            fputs("Check that the Xeneon Edge is connected and that Terminal has Input Monitoring permission.\n", stderr)
            return EXIT_FAILURE
        }

        registerCurrentlyMatchedDevices()

        print("Listening in non-seize mode. Press Ctrl+C to quit.")
        print("Capture one-finger, two-finger, and three-finger interactions for the section 3.4 gate.")
        print(String(repeating: "-", count: 88))

        CFRunLoopRun()
        return EXIT_SUCCESS
    }

    fileprivate func handleDeviceMatched(_ device: IOHIDDevice) {
        guard !reportRegistrations.contains(where: { $0.matches(device) }) else {
            return
        }

        let registration = ReportRegistration(
            device: device,
            length: maxInputReportLength(for: device),
            locationID: deviceLocationID(device),
            application: self
        )
        reportRegistrations.append(registration)

        IOHIDDeviceRegisterInputReportCallback(
            device,
            registration.buffer,
            registration.length,
            inputReportCallback,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(registration).toOpaque())
        )

        print("Device matched:")
        print("  locationID: \(formatLocationID(registration.locationID))")
        print("  manufacturer: \(deviceProperty(device, key: kIOHIDManufacturerKey) ?? "Unknown")")
        print("  product: \(deviceProperty(device, key: kIOHIDProductKey) ?? "Unknown")")
        print("  transport: \(deviceProperty(device, key: kIOHIDTransportKey) ?? "Unknown")")
        print("  maxInputReportSize: \(registration.length)")
        print(String(repeating: "-", count: 88))
    }

    fileprivate func handleDeviceRemoved(_ device: IOHIDDevice) {
        reportRegistrations.removeAll { $0.matches(device) }
        print("Device removed.")
        print(String(repeating: "-", count: 88))
    }

    fileprivate func handleInputValue(_ value: IOHIDValue) {
        valueEventCount += 1

        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let integerValue = IOHIDValueGetIntegerValue(value)
        let logicalMin = IOHIDElementGetLogicalMin(element)
        let logicalMax = IOHIDElementGetLogicalMax(element)
        let reportID = IOHIDElementGetReportID(element)
        let timestamp = IOHIDValueGetTimeStamp(value)

        print(
            [
                "value #\(valueEventCount)",
                "time=\(timestamp)",
                "reportID=\(reportID)",
                "page=\(hex(usagePage)) \(usagePageName(usagePage))",
                "usage=\(hex(usage)) \(usageName(page: usagePage, usage: usage))",
                "value=\(integerValue)",
                "logicalMin=\(logicalMin)",
                "logicalMax=\(logicalMax)"
            ].joined(separator: " | ")
        )
    }

    fileprivate func handleInputReport(
        locationID: UInt32?,
        type: IOHIDReportType,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex
    ) {
        rawReportCount += 1

        let bytes = UnsafeBufferPointer(start: report, count: Int(reportLength))
        let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")

        print(
            [
                "raw #\(rawReportCount)",
                "wallTime=\(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds]))",
                "locationID=\(formatLocationID(locationID))",
                "type=\(reportTypeName(type))",
                "reportID=\(reportID)",
                "length=\(reportLength)",
                "bytes=\(hexBytes)"
            ].joined(separator: " | ")
        )
    }

    private func registerCurrentlyMatchedDevices() {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            print("No matching Xeneon Edge HID device found yet.")
            print("Expected VID \(hex(touchscreenVendorID)), PID \(hex(touchscreenProductID)).")
            print(String(repeating: "-", count: 88))
            return
        }

        devices.forEach(handleDeviceMatched)
    }

    private func maxInputReportLength(for device: IOHIDDevice) -> Int {
        let property = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString)
        let propertyValue = (property as? NSNumber)?.intValue ?? defaultReportBufferLength
        return max(propertyValue, defaultReportBufferLength)
    }

    private func deviceLocationID(_ device: IOHIDDevice) -> UInt32? {
        (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value
    }

    private func deviceProperty(_ device: IOHIDDevice, key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString).map { "\($0)" }
    }

    private func printHeader() {
        print("HIDDump")
        print("Target VID: \(hex(touchscreenVendorID))")
        print("Target PID: \(hex(touchscreenProductID))")
        print("Mode: shared/non-seize diagnostic")
        print(String(repeating: "-", count: 88))
    }
}

private let deviceMatchedCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else {
        return
    }

    let application = Unmanaged<HIDDumpApplication>.fromOpaque(context).takeUnretainedValue()
    application.handleDeviceMatched(device)
}

private let deviceRemovedCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else {
        return
    }

    let application = Unmanaged<HIDDumpApplication>.fromOpaque(context).takeUnretainedValue()
    application.handleDeviceRemoved(device)
}

private let inputValueCallback: IOHIDValueCallback = { context, _, _, value in
    guard let context else {
        return
    }

    let application = Unmanaged<HIDDumpApplication>.fromOpaque(context).takeUnretainedValue()
    application.handleInputValue(value)
}

private let inputReportCallback: IOHIDReportCallback = { context, _, _, type, reportID, report, reportLength in
    guard let context else {
        return
    }

    let registration = Unmanaged<ReportRegistration>.fromOpaque(context).takeUnretainedValue()
    registration.handleInputReport(type: type, reportID: reportID, report: report, reportLength: reportLength)
}

private func usagePageName(_ page: UInt32) -> String {
    switch page {
    case 0x01:
        return "Generic Desktop"
    case 0x09:
        return "Button"
    case 0x0D:
        return "Digitizer"
    default:
        return "Unknown"
    }
}

private func usageName(page: UInt32, usage: UInt32) -> String {
    switch (page, usage) {
    case (0x01, 0x30):
        return "X"
    case (0x01, 0x31):
        return "Y"
    case (0x01, 0x32):
        return "Z"
    case (0x09, 0x01):
        return "Button 1"
    case (0x0D, 0x22):
        return "Finger"
    case (0x0D, 0x42):
        return "Tip Switch"
    case (0x0D, 0x47):
        return "Confidence"
    case (0x0D, 0x48):
        return "Width"
    case (0x0D, 0x49):
        return "Height"
    case (0x0D, 0x51):
        return "Contact ID"
    case (0x0D, 0x54):
        return "Contact Count"
    case (0x0D, 0x55):
        return "Contact Count Max"
    default:
        return "Unknown"
    }
}

private func reportTypeName(_ type: IOHIDReportType) -> String {
    switch type {
    case kIOHIDReportTypeInput:
        return "input"
    case kIOHIDReportTypeOutput:
        return "output"
    case kIOHIDReportTypeFeature:
        return "feature"
    default:
        return "unknown"
    }
}

private func hex<T: FixedWidthInteger>(_ value: T) -> String {
    "0x" + String(Int64(value), radix: 16, uppercase: true)
}

private func formatIOReturn(_ value: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: value))
}

private func formatLocationID(_ value: UInt32?) -> String {
    guard let value else { return "unknown" }
    return String(format: "0x%08X", value)
}

exit(HIDDumpApplication().run())
