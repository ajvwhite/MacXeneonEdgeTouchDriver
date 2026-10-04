import Foundation
import IOKit
import IOKit.hid

/// Owns the diagnostic input allocation until report delivery has been stopped.
/// Creation, callback delivery, invalidation and final release belong to main.
public final class HIDDumpInputReportRegistration {
    public let buffer: UnsafeMutablePointer<UInt8>
    public let length: CFIndex
    public var context: UnsafeMutableRawPointer { callbackContext!.context }

    private let sender: UnsafeMutableRawPointer
    private let receive: (IOHIDReportType, UInt32, [UInt8]) -> Void
    private var callbackContext: HIDDumpCallbackContext?

    public init(
        sender: UnsafeMutableRawPointer,
        length: Int,
        receive: @escaping (IOHIDReportType, UInt32, [UInt8]) -> Void
    ) {
        precondition(Thread.isMainThread, "HIDDump registrations must use the main thread.")
        precondition(length > 0)
        self.sender = sender
        self.length = CFIndex(length)
        self.receive = receive
        buffer = .allocate(capacity: length)
        buffer.initialize(repeating: 0, count: length)
        callbackContext = HIDDumpCallbackContext(owner: self)
    }

    deinit {
        invalidate()
        buffer.deinitialize(count: Int(length))
        buffer.deallocate()
    }

    /// Close admission before unscheduling/unregistering, while retaining the buffer.
    public func invalidate() {
        precondition(Thread.isMainThread, "HIDDump registrations must use the main thread.")
        callbackContext?.invalidate()
    }

    /// Exact ingress used by the C callback and hardware-free tests.
    public static func handleCallback(
        context: UnsafeMutableRawPointer?,
        result: IOReturn,
        sender: UnsafeMutableRawPointer?,
        type: IOHIDReportType,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex
    ) {
        guard Thread.isMainThread,
              result == kIOReturnSuccess,
              type == kIOHIDReportTypeInput,
              reportLength >= 0,
              let registration = HIDDumpCallbackContext.owner(
                for: context, result: result, as: HIDDumpInputReportRegistration.self
              ),
              sender == registration.sender,
              report == registration.buffer,
              reportLength <= registration.length else { return }

        // Unlike the production touch parser, this diagnostic preserves every
        // report ID and every bounded length, including zero-length reports.
        // Read only the known allocation, never an unchecked callback pointer.
        let bytes = Array(UnsafeBufferPointer(start: registration.buffer, count: Int(reportLength)))
        withExtendedLifetime(registration) {
            registration.receive(type, reportID, bytes)
        }
    }
}
