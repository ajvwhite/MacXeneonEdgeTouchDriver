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
    /// Receives every valid raw touch report plus its optional lifecycle event.
    public typealias TouchReportHandler = (TouchDeviceIdentity, DispatchTime, TouchEvent?) -> Void

    /// Receives device match events on the configured event queue.
    public typealias DeviceMatchedHandler = (TouchDeviceIdentity) -> Void

    /// Receives device removal events on the configured event queue.
    public typealias DeviceRemovalHandler = (TouchDeviceIdentity) -> Void

    private static let defaultInputReportBufferLength = 256

    private let manager: IOHIDManager
    private let eventQueue: DispatchQueue
    private let touchReportHandler: TouchReportHandler
    private let deviceMatchedHandler: DeviceMatchedHandler
    private let deviceRemovalHandler: DeviceRemovalHandler
    private let openOptions: IOOptionBits

    private var reportRegistrations: [HIDReportRegistration] = []
    // Removed devices retain their callback contexts until monitor shutdown.
    private var retiredRegistrations: [HIDReportRegistration] = []
    private var isStarted = false

    /// Creates a HID monitor for the Xeneon Edge touchscreen controller.
    ///
    /// - Parameters:
    ///   - seizeDevice: Use `true` for the production driver so macOS does not
    ///     also consume the touchscreen as a generic pointer device.
    public init(
        eventQueue: DispatchQueue,
        seizeDevice: Bool = true,
        touchReportHandler: @escaping TouchReportHandler,
        deviceRemovalHandler: @escaping DeviceRemovalHandler,
        deviceMatchedHandler: @escaping DeviceMatchedHandler = { _ in }
    ) {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.eventQueue = eventQueue
        self.touchReportHandler = touchReportHandler
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
        guard !isStarted else {
            return
        }

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: XeneonEdgeDevice.vendorID,
            kIOHIDProductIDKey as String: XeneonEdgeDevice.productID,
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse
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

        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, openOptions)
        reportRegistrations.forEach { $0.invalidate() }
        retiredRegistrations.forEach { $0.invalidate() }
        reportRegistrations.removeAll()
        retiredRegistrations.removeAll()
        isStarted = false
    }

    fileprivate func handleDeviceMatched(_ device: IOHIDDevice) {
        guard !reportRegistrations.contains(where: { $0.matches(device) }) else {
            return
        }

        guard let locationNumber = IOHIDDeviceGetProperty(
            device,
            kIOHIDLocationIDKey as CFString
        ) as? NSNumber else {
            DriverLoggers.log(.error, category: .hid, "Ignoring matching touch interface without a location ID.")
            return
        }

        let identity = TouchDeviceIdentity(
            locationID: locationNumber.uint32Value,
            serialNumber: deviceProperty(device, key: kIOHIDSerialNumberKey)
        )
        let registration = HIDReportRegistration(
            device: device,
            identity: identity,
            length: maxInputReportLength(for: device),
            monitor: self
        )
        reportRegistrations.append(registration)

        IOHIDDeviceRegisterInputReportCallback(
            device,
            registration.buffer,
            registration.length,
            hidInputReportCallback,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(registration).toOpaque())
        )

        DriverLoggers.log(
            .notice,
            category: .hid,
            "WCH touch mouse interface matched at \(identity.hexadecimalLocationID). Manufacturer: \(self.deviceProperty(device, key: kIOHIDManufacturerKey) ?? "Unknown"), product: \(self.deviceProperty(device, key: kIOHIDProductKey) ?? "Unknown"), max input report size: \(registration.length)"
        )

        eventQueue.async { [deviceMatchedHandler, identity] in
            deviceMatchedHandler(identity)
        }
    }

    fileprivate func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard let index = reportRegistrations.firstIndex(where: { $0.matches(device) }) else {
            return
        }
        let registration = reportRegistrations.remove(at: index)
        registration.invalidate()
        retiredRegistrations.append(registration)

        DriverLoggers.log(.notice, category: .hid, "WCH touch interface at \(registration.identity.hexadecimalLocationID) removed; canceling only that device session.")
        eventQueue.async { [deviceRemovalHandler, identity = registration.identity] in
            deviceRemovalHandler(identity)
        }
    }

    fileprivate func emitReport(
        device: TouchDeviceIdentity,
        timestamp: DispatchTime,
        event: TouchEvent?
    ) {
        eventQueue.async { [touchReportHandler] in
            touchReportHandler(device, timestamp, event)
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
    let identity: TouchDeviceIdentity
    let buffer: UnsafeMutablePointer<UInt8>
    let length: CFIndex
    private let parser = HIDValueParser()
    private weak var monitor: HIDDeviceMonitor?
    private var isActive = true

    init(
        device: IOHIDDevice,
        identity: TouchDeviceIdentity,
        length: Int,
        monitor: HIDDeviceMonitor
    ) {
        self.device = device
        self.identity = identity
        self.length = CFIndex(length)
        self.monitor = monitor
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

    func invalidate() {
        isActive = false
        parser.reset()
        monitor = nil
    }

    func handleInputReport(
        type: IOHIDReportType,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex
    ) {
        guard isActive, type == kIOHIDReportTypeInput else {
            return
        }
        let bytes = Array(UnsafeBufferPointer(start: report, count: Int(reportLength)))
        let timestamp = DispatchTime.now()
        guard Int(reportID) == XeneonEdgeDevice.touchReportID,
              bytes.count >= XeneonEdgeDevice.touchReportLength else {
            return
        }
        guard let touch = parser.parseReport(
            reportID: Int(reportID),
            bytes: bytes,
            timestamp: timestamp
        ) else {
            monitor?.emitReport(device: identity, timestamp: timestamp, event: nil)
            return
        }
        monitor?.emitReport(device: identity, timestamp: timestamp, event: touch)
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

private let hidInputReportCallback: IOHIDReportCallback = { context, _, _, type, reportID, report, reportLength in
    guard let context else {
        return
    }

    let registration = Unmanaged<HIDReportRegistration>.fromOpaque(context).takeUnretainedValue()
    registration.handleInputReport(type: type, reportID: reportID, report: report, reportLength: reportLength)
}

private func formatIOReturn(_ value: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: value))
}
