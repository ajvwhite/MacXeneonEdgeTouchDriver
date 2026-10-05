import Darwin
import Foundation
import IOKit
import IOKit.hid

/// Cached values are evidence only when the full supported input descriptor is
/// initialized and two reads agree. Timestamps are native Mach ticks, not receipt
/// times or a claim that IOKit reads have a hard execution deadline.
struct HIDCachedInputValue: Equatable {
    let usagePage: UInt32
    let usage: UInt32
    let minimum: Int
    let maximum: Int
    let value: Int
    let timestamp: UInt64
}

struct HIDNeutralState: Equatable {
    let reportTimestamp: UInt64

    static func certify(first: [HIDCachedInputValue], second: [HIDCachedInputValue],
                        after lossTimestamp: UInt64, now: UInt64) -> HIDNeutralState? {
        guard first == second, first.count == 6 else { return nil }
        let expected: [(UInt32, UInt32, Int, Int)] = [
            (9, 1, 0, 1), (9, 2, 0, 1), (9, 3, 0, 1),
            (1, 48, 0, 16_383), (1, 49, 0, 9_599), (1, 56, -127, 127)
        ]
        for (value, descriptor) in zip(first, expected) {
            guard value.usagePage == descriptor.0, value.usage == descriptor.1,
                  value.minimum == descriptor.2, value.maximum == descriptor.3,
                  (value.minimum...value.maximum).contains(value.value),
                  value.timestamp > 0, value.timestamp <= now else { return nil }
        }
        let buttons = first.prefix(3)
        guard buttons.allSatisfy({ $0.value == 0 }),
              buttons.map(\.timestamp).max()! > lossTimestamp else { return nil }
        return HIDNeutralState(reportTimestamp: first.map(\.timestamp).max()!)
    }
}

/// Main-run-loop reads of already-open input elements. No feature query,
/// permission request, input posting, or assumed zero on a failed read.
final class HIDNeutralStateReader {
    private let device: IOHIDDevice
    private let elements: [IOHIDElement]

    init?(device: IOHIDDevice) {
        let inputs = (IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] ?? []).filter {
            let type = IOHIDElementGetType($0)
            return IOHIDElementGetReportID($0) == XeneonEdgeDevice.touchReportID &&
                (type == kIOHIDElementTypeInput_Misc || type == kIOHIDElementTypeInput_Button ||
                 type == kIOHIDElementTypeInput_Axis)
        }
        guard inputs.count == 6, inputs.allSatisfy({ CFEqual(IOHIDElementGetDevice($0), device) }) else { return nil }
        guard inputs.allSatisfy({ element in
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let bits: UInt32 = page == 9 ? 1 : (usage == 56 ? 8 : 16)
            return IOHIDElementGetReportCount(element) == 1 &&
                IOHIDElementGetReportSize(element) == bits && !IOHIDElementIsArray(element) &&
                IOHIDElementIsRelative(element) == (page == 1 && usage == 56)
        }) else { return nil }
        self.device = device
        self.elements = inputs.sorted {
            // Buttons precede axes; ordering is fixed for both complete samples.
            let a = IOHIDElementGetUsagePage($0), b = IOHIDElementGetUsagePage($1)
            if a != b { return a > b }
            return IOHIDElementGetUsage($0) < IOHIDElementGetUsage($1)
        }
    }

    func read(after lossTimestamp: UInt64) -> HIDNeutralState? {
        precondition(Thread.isMainThread)
        let started = mach_absolute_time()
        let budget = DispatchTime.now() + .milliseconds(4)
        guard let first = sample(before: budget), let second = sample(before: budget),
              DispatchTime.now() <= budget else { return nil }
        return HIDNeutralState.certify(first: first, second: second, after: lossTimestamp,
                                       now: max(started, mach_absolute_time()))
    }

    private func sample(before deadline: DispatchTime) -> [HIDCachedInputValue]? {
        var sample: [HIDCachedInputValue] = []
        for element in elements {
            guard DispatchTime.now() < deadline else { return nil }
            let output = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
            defer { output.deallocate() }
            guard IOHIDDeviceGetValueWithOptions(device, element, output,
                    IOHIDDeviceGetValueOptions.withoutUpdate.rawValue) == kIOReturnSuccess else { return nil }
            let value = output.pointee.takeUnretainedValue()
            let length = IOHIDValueGetLength(value)
            guard CFEqual(IOHIDValueGetElement(value), element), length > 0,
                  length <= MemoryLayout<CFIndex>.size else { return nil }
            sample.append(HIDCachedInputValue(usagePage: IOHIDElementGetUsagePage(element),
                usage: IOHIDElementGetUsage(element), minimum: IOHIDElementGetLogicalMin(element),
                maximum: IOHIDElementGetLogicalMax(element), value: IOHIDValueGetIntegerValue(value),
                timestamp: IOHIDValueGetTimeStamp(value)))
        }
        return sample
    }
}
