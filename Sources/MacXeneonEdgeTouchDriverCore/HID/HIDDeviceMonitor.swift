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
/// An active monitor must be retained and stopped on main before its final release.
/// The supplied event queue must be serial; handlers and their captured state
/// belong to that queue. stop() closes HID ingress and retires every source before
/// owners drain their event queue. Queued reports check their retirement fence;
/// already-running handlers and lifecycle callbacks still require that drain.
public final class HIDDeviceMonitor {
    /// Receives parsed touch events on the configured event queue.
    public typealias TouchEventHandler = (TouchEvent) -> Void

    /// Receives each valid report and its retirement fence as one ordered operation.
    public typealias ObservationHandler = (HIDTouchObservation, HIDSourceRetirementFence) -> Void

    /// Receives the exact lifetime of a removed endpoint on the event queue.
    public typealias SourceRemovalHandler = (HIDSourceID) -> Void

    /// Receives device match events on the configured event queue.
    public typealias DeviceMatchedHandler = () -> Void

    /// Receives device removal events on the configured event queue.
    public typealias DeviceRemovalHandler = () -> Void

    private static let defaultInputReportBufferLength = 256

    private let manager: IOHIDManager
    private let eventQueue: DispatchQueue
    private let touchEventHandler: TouchEventHandler
    private let observationDelivery: HIDSerialDelivery<HIDObservationDeliveryPayload>?
    private let sourceRemovalDelivery: HIDSerialDelivery<[HIDSourceID]>?
    private let deviceMatchedHandler: DeviceMatchedHandler
    private let deviceRemovalHandler: DeviceRemovalHandler
    private let openOptions: IOOptionBits

    private var reportRegistrations: [HIDReportRegistration] = []
    private var managerCallbackRegistration: HIDManagerCallbackRegistration?
    private var isStarted = false

    /// Creates a HID monitor for the Xeneon Edge touchscreen controller.
    ///
    /// - Parameters:
    ///   - seizeDevice: Use `true` for the production driver so macOS does not
    ///     also consume the touchscreen as a generic pointer device.
    ///   - observationHandler: When supplied, receives validated observations in
    ///     place of `touchEventHandler`, including duplicate pressed reports.
    ///   - sourceRemovalHandler: When supplied, receives source-specific removals
    ///     in place of the legacy source-blind `deviceRemovalHandler`.
    ///
    /// Each registration owns its parser. The former shared `parser:` injection
    /// parameter is intentionally removed; normalized callback usage is unchanged.
    public init(
        eventQueue: DispatchQueue,
        seizeDevice: Bool = true,
        touchEventHandler: @escaping TouchEventHandler,
        deviceRemovalHandler: @escaping DeviceRemovalHandler,
        deviceMatchedHandler: @escaping DeviceMatchedHandler = {},
        observationHandler: ObservationHandler? = nil,
        sourceRemovalHandler: SourceRemovalHandler? = nil
    ) {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.eventQueue = eventQueue
        self.touchEventHandler = touchEventHandler
        if let observationHandler {
            self.observationDelivery = HIDSerialDelivery<HIDObservationDeliveryPayload>(queue: eventQueue) { payload in
                // Observation mode never invokes the legacy event callback.
                Self.deliverObservation(
                    payload.observation, fence: payload.fence, touchEventHandler: { _ in },
                    observationHandler: observationHandler
                )
            }
        } else {
            self.observationDelivery = nil
        }
        if let sourceRemovalHandler {
            self.sourceRemovalDelivery = HIDSerialDelivery<[HIDSourceID]>(queue: eventQueue) { sourceIDs in
                sourceIDs.forEach(sourceRemovalHandler)
            }
        } else {
            self.sourceRemovalDelivery = nil
        }
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
        let callbacks = HIDManagerCallbackRegistration(monitor: self)
        managerCallbackRegistration = callbacks
        let context = callbacks.context

        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatchedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemovedCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, openOptions)
        guard openResult == kIOReturnSuccess else {
            callbacks.invalidate()
            managerCallbackRegistration = nil
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
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
        managerCallbackRegistration?.invalidate()
        managerCallbackRegistration = nil
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        reportRegistrations.forEach { $0.input.invalidate() }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, openOptions)
        reportRegistrations.forEach { $0.unregisterCallback() }
        reportRegistrations.removeAll()
    }

    fileprivate func handleDeviceMatched(_ device: IOHIDDevice) {
        precondition(Thread.isMainThread, "HID callbacks must use the main run loop.")
        guard isStarted, !reportRegistrations.contains(where: { $0.matches(device) }) else {
            return
        }

        let registration = HIDReportRegistration(
            device: device,
            length: maxInputReportLength(for: device),
            receiveObservation: { [weak self] observation, fence in
                self?.handleObservation(observation, fence: fence)
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
        precondition(Thread.isMainThread, "HID callbacks must use the main run loop.")
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

        DriverLoggers.log(.notice, category: .hid, "Xeneon Edge HID device removed; canceling active gesture if needed.")
        let sourceIDs = removed.map { $0.input.sourceID }
        if let sourceRemovalDelivery {
            sourceRemovalDelivery.enqueue(sourceIDs)
        } else {
            eventQueue.async { [deviceRemovalHandler] in
                deviceRemovalHandler()
            }
        }
    }

    private func handleObservation(_ observation: HIDTouchObservation, fence: HIDSourceRetirementFence) {
        precondition(Thread.isMainThread, "HID reports must use the main run loop.")
        guard isStarted, !fence.isRetired else { return }

        // Only immutable values and the locked retirement fence cross queues.
        // Event and liveness are delivered together, never as independent tasks.
        if let observationDelivery {
            observationDelivery.enqueue(HIDObservationDeliveryPayload(observation: observation, fence: fence))
        } else {
            eventQueue.async { [touchEventHandler] in
                Self.deliverObservation(
                    observation, fence: fence, touchEventHandler: touchEventHandler,
                    observationHandler: nil
                )
            }
        }
    }

    /// The queue-delivery seam is shared by production and offline lifetime tests.
    /// It has no reference to a main-only monitor, registration, buffer or parser.
    static func deliverObservation(
        _ observation: HIDTouchObservation,
        fence: HIDSourceRetirementFence,
        touchEventHandler: TouchEventHandler,
        observationHandler: ObservationHandler?
    ) {
        guard !fence.isRetired else { return }
        if let observationHandler {
            observationHandler(observation, fence)
        } else if let event = observation.event {
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

    init(
        device: IOHIDDevice, length: Int,
        receiveObservation: @escaping (HIDTouchObservation, HIDSourceRetirementFence) -> Void
    ) {
        self.device = device
        self.input = HIDInputReportRegistration(
            sender: Unmanaged.passUnretained(device).toOpaque(),
            length: length,
            receiveObservation: receiveObservation
        )
    }

    func unregisterCallback() {
        IOHIDDeviceRegisterInputReportCallback(device, input.buffer, input.length, nil, input.context)
    }

    func matches(_ otherDevice: IOHIDDevice) -> Bool {
        CFEqual(device, otherDevice)
    }
}

private func hidDeviceMatchedCallback(
    _ context: UnsafeMutableRawPointer?, _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice
) {
    guard let monitor = HIDManagerCallbackRegistration.monitor(for: context) else { return }
    monitor.handleDeviceMatched(device)
}

private func hidDeviceRemovedCallback(
    _ context: UnsafeMutableRawPointer?, _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice
) {
    guard let monitor = HIDManagerCallbackRegistration.monitor(for: context) else { return }
    monitor.handleDeviceRemoved(device)
}

private func hidInputReportCallback(
    _ context: UnsafeMutableRawPointer?, _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?, _ type: IOHIDReportType,
    _ reportID: UInt32, _ report: UnsafeMutablePointer<UInt8>, _ reportLength: CFIndex
) {
    HIDInputReportRegistration.handleCallback(
        context: context, result: result, sender: sender, type: type,
        reportID: reportID, report: report, reportLength: reportLength
    )
}

private func formatIOReturn(_ value: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: value))
}
