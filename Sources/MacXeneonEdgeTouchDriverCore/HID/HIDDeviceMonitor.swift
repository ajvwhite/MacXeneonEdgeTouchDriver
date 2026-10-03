import Foundation
import IOKit
import IOKit.hid

/// Errors produced while opening or running the Xeneon Edge HID monitor.
public enum HIDDeviceMonitorError: Error, LocalizedError, Equatable {
    /// The IOHID manager could not be opened.
    case openFailed(IOReturn)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let result):
            return "IOHIDManagerOpen failed with \(formatIOReturn(result))."
        }
    }
}

/// Monitors the Xeneon Edge HID device and emits parsed single-touch events.
public final class HIDDeviceMonitor {
    /// Receives parsed touch events on the configured event queue.
    public typealias TouchEventHandler = (TouchEvent) -> Void

    /// Receives device match events on the configured event queue.
    public typealias DeviceMatchedHandler = () -> Void

    /// Receives device removal events on the configured event queue.
    public typealias DeviceRemovalHandler = () -> Void

    private static let defaultInputReportBufferLength = 256

    private let manager: IOHIDManager
    private let parser: HIDValueParser
    private let eventQueue: DispatchQueue
    private let touchEventHandler: TouchEventHandler
    private let deviceMatchedHandler: DeviceMatchedHandler
    private let deviceRemovalHandler: DeviceRemovalHandler
    private let openOptions: IOOptionBits

    private var reportRegistrations: [HIDReportRegistration] = []
    private var isStarted = false

    /// Creates a HID monitor for the Xeneon Edge touchscreen controller.
    ///
    /// - Parameters:
    ///   - seizeDevice: Use `true` for the production driver so macOS does not
    ///     also consume the touchscreen as a generic pointer device.
    public init(
        parser: HIDValueParser = HIDValueParser(),
        eventQueue: DispatchQueue,
        seizeDevice: Bool = true,
        touchEventHandler: @escaping TouchEventHandler,
        deviceRemovalHandler: @escaping DeviceRemovalHandler,
        deviceMatchedHandler: @escaping DeviceMatchedHandler = {}
    ) {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.parser = parser
        self.eventQueue = eventQueue
        self.touchEventHandler = touchEventHandler
        self.deviceMatchedHandler = deviceMatchedHandler
        self.deviceRemovalHandler = deviceRemovalHandler
        self.openOptions = seizeDevice
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)
    }

    deinit {
        stop()
    }

    /// Starts monitoring on the main CFRunLoop.
    public func start() throws {
        precondition(Thread.isMainThread, "HID monitoring must start on the main thread.")
        guard !isStarted else {
            return
        }

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: XeneonEdgeDevice.vendorID,
            kIOHIDProductIDKey as String: XeneonEdgeDevice.productID
        ]
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatchedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemovedCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, openOptions)
        guard openResult == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            throw HIDDeviceMonitorError.openFailed(openResult)
        }

        isStarted = true
        registerCurrentlyMatchedDevices()
    }

    /// Stops monitoring and releases report buffers.
    public func stop() {
        guard isStarted else {
            return
        }

        precondition(Thread.isMainThread, "HID monitoring must stop on the main thread.")
        isStarted = false
        reportRegistrations.forEach { $0.input.invalidate() }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, openOptions)
        reportRegistrations.forEach { $0.unregisterCallback() }
        reportRegistrations.removeAll()
        parser.reset()
    }

    fileprivate func handleDeviceMatched(_ device: IOHIDDevice) {
        guard isStarted, !reportRegistrations.contains(where: { $0.matches(device) }) else {
            return
        }

        let registration = HIDReportRegistration(
            device: device,
            length: maxInputReportLength(for: device),
            receive: { [weak self] reportID, bytes, timestamp in
                self?.handleInputReport(reportID: reportID, bytes: bytes, timestamp: timestamp)
            }
        )
        reportRegistrations.append(registration)

        IOHIDDeviceRegisterInputReportCallback(
            device,
            registration.input.buffer,
            registration.input.length,
            hidInputReportCallback,
            registration.input.context
        )

        DriverLoggers.log(
            .notice,
            category: .hid,
            "Xeneon Edge HID device matched. Manufacturer: \(self.deviceProperty(device, key: kIOHIDManufacturerKey) ?? "Unknown"), product: \(self.deviceProperty(device, key: kIOHIDProductKey) ?? "Unknown"), max input report size: \(registration.input.length)"
        )

        eventQueue.async { [deviceMatchedHandler] in
            deviceMatchedHandler()
        }
    }

    fileprivate func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard isStarted else { return }
        let removed = reportRegistrations.filter { $0.matches(device) }
        removed.forEach { $0.input.invalidate() }
        // Removal can precede the manager dropping its device reference. Stop
        // report delivery before releasing our preallocated input buffers.
        removed.forEach {
            IOHIDDeviceUnscheduleFromRunLoop($0.device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            $0.unregisterCallback()
        }
        reportRegistrations.removeAll { $0.matches(device) }
        parser.reset()

        DriverLoggers.log(.notice, category: .hid, "Xeneon Edge HID device removed; canceling active gesture if needed.")
        eventQueue.async { [deviceRemovalHandler] in
            deviceRemovalHandler()
        }
    }

    private func handleInputReport(reportID: UInt32, bytes: [UInt8], timestamp: DispatchTime) {
        guard isStarted, let event = parser.parseReport(
            reportID: Int(reportID),
            bytes: bytes,
            timestamp: timestamp
        ) else {
            return
        }

        eventQueue.async { [touchEventHandler] in
            touchEventHandler(event)
        }
    }

    private func registerCurrentlyMatchedDevices() {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            DriverLoggers.log(
                .notice,
                category: .hid,
                "No matching Xeneon Edge HID device found yet. Waiting for VID \(String(format: "0x%04X", XeneonEdgeDevice.vendorID)), PID \(String(format: "0x%04X", XeneonEdgeDevice.productID))."
            )
            return
        }

        devices.forEach(handleDeviceMatched)
    }

    private func maxInputReportLength(for device: IOHIDDevice) -> Int {
        let property = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString)
        let propertyValue = (property as? NSNumber)?.intValue ?? Self.defaultInputReportBufferLength
        return max(propertyValue, XeneonEdgeDevice.touchReportLength)
    }

    private func deviceProperty(_ device: IOHIDDevice, key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString).map { "\($0)" }
    }
}

private final class HIDReportRegistration {
    let device: IOHIDDevice
    let input: HIDInputReportRegistration

    init(device: IOHIDDevice, length: Int, receive: @escaping (UInt32, [UInt8], DispatchTime) -> Void) {
        self.device = device
        self.input = HIDInputReportRegistration(
            sender: Unmanaged.passUnretained(device).toOpaque(),
            length: length,
            receive: receive
        )
    }

    func unregisterCallback() {
        IOHIDDeviceRegisterInputReportCallback(device, input.buffer, input.length, nil, input.context)
    }

    func matches(_ otherDevice: IOHIDDevice) -> Bool {
        CFEqual(device, otherDevice)
    }
}

private let hidDeviceMatchedCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else {
        return
    }

    let monitor = Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handleDeviceMatched(device)
}

private let hidDeviceRemovedCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else {
        return
    }

    let monitor = Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handleDeviceRemoved(device)
}

private let hidInputReportCallback: IOHIDReportCallback = { context, result, sender, type, reportID, report, reportLength in
    HIDInputReportRegistration.handleCallback(
        context: context,
        result: result,
        sender: sender,
        type: type,
        reportID: reportID,
        report: report,
        reportLength: reportLength
    )
}

private func formatIOReturn(_ value: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: value))
}
