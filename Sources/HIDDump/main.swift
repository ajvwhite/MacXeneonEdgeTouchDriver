import Darwin
import Foundation
import HIDDumpSupport
import MacXeneonEdgeTouchDriverCore
import IOKit
import IOKit.hid
import IOKit.hidsystem

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
    private var recordHandle: FileHandle?
    private var recordingFailed = false
    private let recordPath: String?

    init(recordPath: String? = nil) {
        self.recordPath = recordPath
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func run() -> Int32 {
        precondition(Thread.isMainThread, "HIDDump must run on the main thread.")
        setbuf(stdout, nil)
        if let recordPath {
            let fd = Darwin.open(recordPath, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
            guard fd >= 0 else { fputs("Cannot create recording; choose a new file path.\n", stderr); return EXIT_FAILURE }
            recordHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        defer { try? recordHandle?.close() }
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
        print("Try one-, two- and three-finger touches to compare report formats.")
        print(String(repeating: "-", count: 88))

        CFRunLoopRun()
        return recordingFailed ? EXIT_FAILURE : EXIT_SUCCESS
    }

    fileprivate func handleDeviceMatched(_ device: IOHIDDevice) {
        guard isRunning, !reportRegistrations.contains(where: { $0.matches(device) }) else {
            return
        }

        let registration = ReportRegistration(
            device: device,
            length: maxInputReportLength(for: device),
            receive: { [weak self] type, reportID, bytes in
                self?.handleInputReport(device: device, type: type, reportID: reportID, bytes: bytes)
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
        removed.forEach { record(device: $0.device, kind: .removal, reportID: 0, bytes: []); $0.input.invalidate() }
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
        device: IOHIDDevice,
        type: IOHIDReportType,
        reportID: UInt32,
        bytes: [UInt8]
    ) {
        guard isRunning else { return }
        rawReportCount += 1
        if type == kIOHIDReportTypeInput {
            record(device: device, kind: .report, reportID: reportID, bytes: bytes)
        }

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

    private func record(device: IOHIDDevice, kind: HIDReportTraceRecord.Kind, reportID: UInt32, bytes: [UInt8]) {
        guard let handle = recordHandle, !recordingFailed else { return }
        var source: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &source) == KERN_SUCCESS,
              source != 0 else { recordingFailed = true; CFRunLoopStop(CFRunLoopGetMain()); return }
        do {
            let record = HIDReportTraceRecord(kind: kind, sourceID: source,
                timestampNanoseconds: DispatchTime.now().uptimeNanoseconds, reportID: reportID, bytes: bytes,
                wallClockMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000),
                controllerLocationID: (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try handle.write(contentsOf: encoder.encode(record))
            try handle.write(contentsOf: Data([10]))
        } catch {
            recordingFailed = true
            fputs("Recording failed; capture stopped: \(error)\n", stderr)
            CFRunLoopStop(CFRunLoopGetMain())
        }
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

/// Enumerates descriptor metadata and cached input values. The optional open
/// requires an existing HID grant and uses non-seize access. Neither mode requests
/// permissions, registers callbacks, posts input or queries feature reports.
private func describeInputCache(openDevice: Bool = false) -> Int32 {
    guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
        fputs("HID listen access is not granted; no permission request was made.\n", stderr)
        return EX_NOPERM
    }
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: touchscreenVendorID,
                                          kIOHIDProductIDKey: touchscreenProductID] as CFDictionary)
    if openDevice {
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            fputs("Could not open HID for cached reads: \(formatIOReturn(result))\n", stderr)
            return EXIT_FAILURE
        }
    }
    defer { if openDevice { _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) } }
    let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
    var snapshots: [[String: Any]] = []
    for device in devices {
        var registryID: UInt64 = 0
        _ = IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
        let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        var values: [[String: Any]] = []
        for element in elements {
            let type = IOHIDElementGetType(element)
            guard type == kIOHIDElementTypeInput_Misc || type == kIOHIDElementTypeInput_Button
                    || type == kIOHIDElementTypeInput_Axis || type == kIOHIDElementTypeInput_ScanCodes else { continue }
            // This header's nonnull out parameter imports as Unmanaged. Read
            // it only on success; Get returns a borrowed value owned by IOKit.
            let output = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
            defer { output.deallocate() }
            let result = IOHIDDeviceGetValueWithOptions(device, element, output,
                                                        IOHIDDeviceGetValueOptions.withoutUpdate.rawValue)
            var row: [String: Any] = ["cookie": IOHIDElementGetCookie(element),
                "reportID": IOHIDElementGetReportID(element), "usagePage": IOHIDElementGetUsagePage(element),
                "usage": IOHIDElementGetUsage(element), "logicalMin": IOHIDElementGetLogicalMin(element),
                "logicalMax": IOHIDElementGetLogicalMax(element), "result": formatIOReturn(result)]
            if result == kIOReturnSuccess {
                let value = output.pointee.takeUnretainedValue()
                let length = IOHIDValueGetLength(value)
                if length > 0 && length <= MemoryLayout<CFIndex>.size {
                    row["value"] = IOHIDValueGetIntegerValue(value)
                }
                row["timestampMachTicks"] = IOHIDValueGetTimeStamp(value)
                row["length"] = length
            }
            values.append(row)
        }
        snapshots.append(["registryID": registryID, "inputElements": values])
    }
    do {
        let bytes = try JSONSerialization.data(withJSONObject: ["cachedValuesOnly": true, "hidOpened": openDevice, "devices": snapshots],
                                               options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data([10]))
        return devices.isEmpty ? EXIT_FAILURE : EXIT_SUCCESS
    } catch {
        fputs("Could not encode input-cache diagnostics: \(error.localizedDescription)\n", stderr)
        return EXIT_FAILURE
    }
}

if CommandLine.arguments.dropFirst().elementsEqual(["--describe-input-cache"]) {
    exit(describeInputCache())
}
if CommandLine.arguments.dropFirst().elementsEqual(["--describe-input-cache", "--open"]) {
    exit(describeInputCache(openDevice: true))
}
let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty { exit(HIDDumpApplication().run()) }
if args.count == 2, args[0] == "--record" { exit(HIDDumpApplication(recordPath: args[1]).run()) }
fputs("Usage: HIDDump [--record new-file.jsonl | --describe-input-cache [--open]]\n", stderr)
exit(EX_USAGE)
