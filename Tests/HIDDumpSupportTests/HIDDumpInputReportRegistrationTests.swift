import Foundation
import HIDDumpSupport
import IOKit
import IOKit.hid
import XCTest

final class HIDDumpInputReportRegistrationTests: XCTestCase {
    func testEveryReportIDAndBoundedLengthRemainsDiagnosticData() {
        onMain {
            let fixture = ReportFixture(capacity: 16)
            for reportID in [UInt32(0), 1, 7, 255, UInt32.max] {
                for length in [0, 1, 6, 7, 16] {
                    fixture.deliver(reportID: reportID, length: length)
                    XCTAssertEqual(fixture.reports.last?.reportID, reportID)
                    XCTAssertEqual(fixture.reports.last?.type, kIOHIDReportTypeInput)
                    XCTAssertEqual(fixture.reports.last?.bytes, Array(fixture.initialBytes.prefix(length)))
                }
            }
            XCTAssertEqual(fixture.reports.count, 25)
        }
    }

    func testFailedCompletionsAreRejectedBeforeReading() {
        assertRejected { fixture in
            for result in [kIOReturnError, kIOReturnAborted, kIOReturnNoDevice] {
                fixture.deliver(result: result, report: invalidReport)
            }
        }
    }

    func testNonInputTypesAreRejectedBeforeReading() {
        assertRejected { fixture in
            fixture.deliver(type: kIOHIDReportTypeOutput, report: invalidReport)
            fixture.deliver(type: kIOHIDReportTypeFeature, report: invalidReport)
            fixture.deliver(type: kIOHIDReportTypeCount, report: invalidReport)
        }
    }

    func testNegativeAndOversizedLengthsAreRejected() {
        assertRejected { fixture in
            for length in [CFIndex.min, -1, fixture.registration.length + 1, CFIndex.max] {
                fixture.deliver(length: length)
            }
        }
    }

    func testBoundsBelongToThisRegistration() {
        onMain {
            let short = ReportFixture(capacity: 1)
            let long = ReportFixture(capacity: 32)
            short.deliver(length: 2)
            long.deliver(length: 32)
            XCTAssertTrue(short.reports.isEmpty)
            XCTAssertEqual(long.reports.last?.bytes.count, 32)
            short.deliver(length: 1)
            XCTAssertEqual(short.reports.last?.bytes, [0])
        }
    }

    func testUnknownOffsetAndOtherLiveBuffersAreRejected() {
        assertRejected { fixture in
            let other = ReportFixture()
            fixture.deliver(report: invalidReport)
            fixture.deliver(report: fixture.registration.buffer.advanced(by: 1))
            fixture.deliver(report: other.registration.buffer)
            XCTAssertTrue(other.reports.isEmpty)
        }
    }

    func testMissingUnknownAndOtherLiveSendersAreRejected() {
        assertRejected { fixture in
            fixture.deliver(sender: nil)
            fixture.deliver(sender: UnsafeMutableRawPointer(bitPattern: 1))
            let other = ReportFixture(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
            fixture.deliver(sender: other.sender)
            XCTAssertTrue(other.reports.isEmpty)
        }
    }

    func testMissingUnknownAndWrongOwnerContextsAreRejected() {
        assertRejected { fixture in
            fixture.deliver(context: nil)
            fixture.deliver(context: UnsafeMutableRawPointer(bitPattern: UInt.max))
            let owner = NSObject()
            let unrelated = HIDDumpCallbackContext(owner: owner)
            fixture.deliver(context: unrelated.context)
            withExtendedLifetime(owner) {}
        }
    }

    func testAnotherLiveContextCannotImpersonateTheRegistration() {
        onMain {
            let first = ReportFixture()
            let second = ReportFixture(sender: first.sender)
            first.deliver(context: second.registration.context)
            XCTAssertTrue(first.reports.isEmpty)
            XCTAssertTrue(second.reports.isEmpty)
            second.deliver()
            XCTAssertEqual(second.reports.count, 1)
        }
    }

    func testRetirementIsIdempotentAndCannotBindToReplacement() {
        onMain {
            let first = ReportFixture()
            let oldContext = first.registration.context
            first.registration.invalidate()
            first.registration.invalidate()
            first.deliver()
            XCTAssertTrue(first.reports.isEmpty)

            let replacement = ReportFixture(sender: first.sender)
            XCTAssertNotEqual(oldContext, replacement.registration.context)
            replacement.deliver(context: oldContext)
            XCTAssertTrue(replacement.reports.isEmpty)
            replacement.deliver()
            XCTAssertEqual(replacement.reports.count, 1)
        }
    }

    func testReleasedRegistrationRejectsDanglingBufferBeforeRead() {
        onMain {
            let sender = UnsafeMutableRawPointer(bitPattern: 0x1000)!
            var received = 0
            var registration: HIDDumpInputReportRegistration? = HIDDumpInputReportRegistration(
                sender: sender, length: 8, receive: { _, _, _ in received += 1 }
            )
            weak var observed: HIDDumpInputReportRegistration?
            observed = registration
            let context = registration!.context
            let report = registration!.buffer
            registration = nil
            XCTAssertNil(observed)
            HIDDumpInputReportRegistration.handleCallback(
                context: context, result: kIOReturnSuccess, sender: sender,
                type: kIOHIDReportTypeInput, reportID: 0, report: report, reportLength: 8
            )
            XCTAssertEqual(received, 0)
        }
    }

    func testDeliveredBytesAreIndependentOfReusedInputBuffer() {
        onMain {
            let fixture = ReportFixture()
            fixture.deliver()
            fixture.registration.buffer[0] = 255
            XCTAssertEqual(fixture.reports[0].bytes[0], 0)
            fixture.deliver()
            XCTAssertEqual(fixture.reports[1].bytes[0], 255)
        }
    }

    func testReceiverCanRetireAndReleaseItsRegistrationDuringDelivery() {
        onMain {
            let sender = UnsafeMutableRawPointer(bitPattern: 0x1000)!
            var registration: HIDDumpInputReportRegistration?
            weak var observed: HIDDumpInputReportRegistration?
            var received = 0
            var savedBytes: [UInt8]?
            registration = HIDDumpInputReportRegistration(sender: sender, length: 4) { _, _, bytes in
                received += 1
                registration?.invalidate()
                registration = nil
                XCTAssertNotNil(observed)
                savedBytes = bytes
            }
            observed = registration
            let context = registration!.context
            let report = registration!.buffer
            for index in 0..<4 { report[index] = UInt8(index) }
            HIDDumpInputReportRegistration.handleCallback(
                context: context, result: kIOReturnSuccess, sender: sender,
                type: kIOHIDReportTypeInput, reportID: 99, report: report, reportLength: 4
            )
            XCTAssertNil(observed)
            XCTAssertEqual(savedBytes, [0, 1, 2, 3])
            HIDDumpInputReportRegistration.handleCallback(
                context: context, result: kIOReturnSuccess, sender: sender,
                type: kIOHIDReportTypeInput, reportID: 99, report: report, reportLength: 4
            )
            XCTAssertEqual(received, 1)
        }
    }

    func testOffMainCallbackIsRejectedBeforeOwnerLookupOrReading() {
        onMain {
            let fixture = ReportFixture()
            // Only numeric identities cross threads; main retains the allocation.
            let context = UInt(bitPattern: fixture.registration.context)
            let sender = UInt(bitPattern: fixture.sender)
            let report = UInt(bitPattern: fixture.registration.buffer)
            let completed = DispatchSemaphore(value: 0)
            let worker = Thread {
                XCTAssertFalse(Thread.isMainThread)
                HIDDumpInputReportRegistration.handleCallback(
                    context: UnsafeMutableRawPointer(bitPattern: context),
                    result: kIOReturnSuccess,
                    sender: UnsafeMutableRawPointer(bitPattern: sender),
                    type: kIOHIDReportTypeInput, reportID: 7,
                    report: UnsafeMutablePointer<UInt8>(bitPattern: report)!, reportLength: 8
                )
                completed.signal()
            }
            worker.start()
            completed.wait()
            XCTAssertTrue(fixture.reports.isEmpty)
            fixture.deliver()
            XCTAssertEqual(fixture.reports.count, 1)
        }
    }

    private func assertRejected(_ action: (ReportFixture) -> Void) {
        onMain {
            let fixture = ReportFixture()
            action(fixture)
            XCTAssertTrue(fixture.reports.isEmpty)
            fixture.deliver()
            XCTAssertEqual(fixture.reports.count, 1)
        }
    }
}

private var invalidReport: UnsafeMutablePointer<UInt8> { UnsafeMutablePointer(bitPattern: 1)! }

private final class ReportFixture {
    struct Report {
        let type: IOHIDReportType
        let reportID: UInt32
        let bytes: [UInt8]
    }

    let sender: UnsafeMutableRawPointer
    let initialBytes: [UInt8]
    private(set) var registration: HIDDumpInputReportRegistration!
    private(set) var reports: [Report] = []

    init(capacity: Int = 8, sender: UnsafeMutableRawPointer = UnsafeMutableRawPointer(bitPattern: 0x1000)!) {
        self.sender = sender
        initialBytes = (0..<capacity).map { UInt8($0 % 256) }
        registration = HIDDumpInputReportRegistration(sender: sender, length: capacity) { [weak self] type, id, bytes in
            self?.reports.append(Report(type: type, reportID: id, bytes: bytes))
        }
        for (index, byte) in initialBytes.enumerated() { registration.buffer[index] = byte }
    }

    func deliver(
        result: IOReturn = kIOReturnSuccess,
        type: IOHIDReportType = kIOHIDReportTypeInput,
        reportID: UInt32 = 7,
        report: UnsafeMutablePointer<UInt8>? = nil,
        length: CFIndex = 8
    ) {
        deliver(context: registration.context, sender: sender, result: result, type: type,
                reportID: reportID, report: report, length: length)
    }

    func deliver(sender: UnsafeMutableRawPointer?) {
        deliver(context: registration.context, sender: sender)
    }

    func deliver(context: UnsafeMutableRawPointer?) {
        deliver(context: context, sender: sender)
    }

    private func deliver(
        context: UnsafeMutableRawPointer?, sender: UnsafeMutableRawPointer?,
        result: IOReturn = kIOReturnSuccess, type: IOHIDReportType = kIOHIDReportTypeInput,
        reportID: UInt32 = 7, report: UnsafeMutablePointer<UInt8>? = nil, length: CFIndex = 8
    ) {
        HIDDumpInputReportRegistration.handleCallback(
            context: context, result: result, sender: sender, type: type, reportID: reportID,
            report: report ?? registration.buffer, reportLength: length
        )
    }
}

func onMain(_ action: () -> Void) {
    if Thread.isMainThread { action() }
    else { DispatchQueue.main.sync(execute: action) }
}
