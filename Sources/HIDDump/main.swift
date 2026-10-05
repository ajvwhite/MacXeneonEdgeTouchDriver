import Darwin
import Foundation
import HIDDumpSupport
import IOKit
import IOKit.hid

private let touchscreenVendorID = 0x27c0
private let touchscreenProductID = 0x0859
private let defaultReportBufferLength = 256

private final class ReportRegistration {
    let device: IOHIDDevice
    let input: HIDDumpInputReportRegistration

    init(
        device: IOHIDDevice,
        length: Int,
        receive: @escaping (IOHIDReportType, UInt32, [UInt8]) -> Void
    ) {
        self.device = device
        input = HIDDumpInputReportRegistration(
            sender: Unmanaged.passUnretained(device).toOpaque(), length: length, receive: receive
        )
    }

    func unregisterCallback() {
        IOHIDDeviceRegisterInputReportCallback(device, input.buffer, input.length, nil, input.context)
    }

    func matches(_ otherDevice: IOHIDDevice) -> Bool {
        CFEqual(device, otherDevice)
    }
}

private final class HIDDumpApplication {
    private let manager: IOHIDManager
    private var reportRegistrations: [ReportRegistration] = []
    private var managerCallbackContext: HIDDumpCallbackContext?
    private var isRunning = false
    private var valueEventCount = 0
    private var rawReportCount = 0

    init() {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func run() -> Int32 {
        precondition(Thread.isMainThread, "HIDDump must run on the main thread.")
        setbuf(stdout, nil)
        printHeader()

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: touchscreenVendorID,
            kIOHIDProductIDKey as String: touchscreenProductID
        ]

        let callbacks = HIDDumpCallbackContext(owner: self)
        managerCallbackContext = callbacks
        let context = callbacks.context
        isRunning = true
        defer { stop() }

        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, makeDeviceMatchedCallback(), context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, makeDeviceRemovedCallback(), context)
        IOHIDManagerRegisterInputValueCallback(manager, makeInputValueCallback(), context)
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
        guard isRunning, !reportRegistrations.contains(where: { $0.matches(device) }) else {
            return
        }

        let registration = ReportRegistration(
            device: device,
            length: maxInputReportLength(for: device),
            receive: { [weak self] type, reportID, bytes in
                self?.handleInputReport(type: type, reportID: reportID, bytes: bytes)
            }
        )
        reportRegistrations.append(registration)

        IOHIDDeviceRegisterInputReportCallback(
            device,
            registration.input.buffer,
            registration.input.length,
            makeInputReportCallback(),
            registration.input.context
        )

        print("Device matched:")
        print("  manufacturer: \(deviceProperty(device, key: kIOHIDManufacturerKey) ?? "Unknown")")
        print("  product: \(deviceProperty(device, key: kIOHIDProductKey) ?? "Unknown")")
        print("  transport: \(deviceProperty(device, key: kIOHIDTransportKey) ?? "Unknown")")
        print("  maxInputReportSize: \(registration.input.length)")
        print(String(repeating: "-", count: 88))
    }

    fileprivate func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard isRunning else { return }
        let removed = reportRegistrations.filter { $0.matches(device) }
        removed.forEach { $0.input.invalidate() }
        // IOKit can still own the device at removal. Keep its allocation alive
        // until input is unscheduled and this exact callback token is removed.
        removed.forEach {
            IOHIDDeviceUnscheduleFromRunLoop($0.device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputValueCallback($0.device, nil, managerCallbackContext?.context)
            $0.unregisterCallback()
        }
        reportRegistrations.removeAll { $0.matches(device) }
        print("Device removed.")
        print(String(repeating: "-", count: 88))
    }

    fileprivate func handleInputValue(_ value: IOHIDValue, sender: UnsafeMutableRawPointer?) {
        // Manager value callbacks retain the originating device as sender.
        guard isRunning, let registration = reportRegistrations.first(where: {
            sender == Unmanaged.passUnretained($0.device).toOpaque()
        }) else { return }
        let element = IOHIDValueGetElement(value)
        guard registration.matches(IOHIDElementGetDevice(element)) else { return }
        valueEventCount += 1
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
        type: IOHIDReportType,
        reportID: UInt32,
        bytes: [UInt8]
    ) {
        guard isRunning else { return }
        rawReportCount += 1

        let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")

        print(
            [
                "raw #\(rawReportCount)",
                "type=\(reportTypeName(type))",
                "reportID=\(reportID)",
                "length=\(bytes.count)",
                "bytes=\(hexBytes)"
            ].joined(separator: " | ")
        )
    }

    fileprivate func acceptsManagerSender(_ sender: UnsafeMutableRawPointer?) -> Bool {
        isRunning && sender == Unmanaged.passUnretained(manager).toOpaque()
    }

    private func stop() {
        precondition(Thread.isMainThread, "HIDDump must stop on the main thread.")
        guard isRunning else { return }
        isRunning = false
        let valueCallbackContext = managerCallbackContext?.context
        managerCallbackContext?.invalidate()
        managerCallbackContext = nil
        reportRegistrations.forEach { $0.input.invalidate() }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        // Device callback registrations are keyed by their original context.
        IOHIDManagerRegisterInputValueCallback(manager, nil, valueCallbackContext)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        reportRegistrations.forEach { $0.unregisterCallback() }
        reportRegistrations.removeAll()
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

// Build noncapturing C callbacks at registration instead of storing function values at top level.
private func makeDeviceMatchedCallback() -> IOHIDDeviceCallback {
    { context, result, sender, device in
        guard let application = HIDDumpCallbackContext.owner(
            for: context, result: result, as: HIDDumpApplication.self
        ), application.acceptsManagerSender(sender) else { return }
        application.handleDeviceMatched(device)
    }
}

private func makeDeviceRemovedCallback() -> IOHIDDeviceCallback {
    { context, result, sender, device in
        guard let application = HIDDumpCallbackContext.owner(
            for: context, result: result, as: HIDDumpApplication.self
        ), application.acceptsManagerSender(sender) else { return }
        application.handleDeviceRemoved(device)
    }
}

private func makeInputValueCallback() -> IOHIDValueCallback {
    { context, result, sender, value in
        guard let application = HIDDumpCallbackContext.owner(
            for: context, result: result, as: HIDDumpApplication.self
        ) else { return }
        application.handleInputValue(value, sender: sender)
    }
}

private func makeInputReportCallback() -> IOHIDReportCallback {
    { context, result, sender, type, reportID, report, reportLength in
        HIDDumpInputReportRegistration.handleCallback(
            context: context, result: result, sender: sender, type: type,
            reportID: reportID, report: report, reportLength: reportLength
        )
    }
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

exit(HIDDumpApplication().run())
