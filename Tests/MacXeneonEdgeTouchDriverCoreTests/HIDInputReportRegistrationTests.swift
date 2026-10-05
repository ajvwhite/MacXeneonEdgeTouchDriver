import Foundation
import IOKit
import IOKit.hid
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class HIDInputReportRegistrationTests: XCTestCase {
    func testValidReportsPreserveDownDuplicateMoveAndUpBehavior() {
        onMain {
            let fixture = InputReportFixture()
            fixture.write(isDown: true, x: 10, y: 20)
            let timestamp = DispatchTime(uptimeNanoseconds: 100)
            fixture.deliver(timestamp: timestamp)
            fixture.deliver()
            fixture.write(isDown: true, x: 11, y: 21)
            fixture.deliver()
            fixture.write(isDown: false, x: 11, y: 21)
            fixture.deliver()

            XCTAssertEqual(fixture.receivedReports, 4)
            XCTAssertEqual(fixture.observations.count, 4)
            XCTAssertEqual(fixture.observations.map(\.contactEpoch), [1, 1, 1, 1])
            XCTAssertEqual(fixture.observations.map(\.isPressed), [true, true, true, false])
            XCTAssertEqual(fixture.observations.map(\.sourceID), Array(repeating: fixture.registration.sourceID, count: 4))
            XCTAssertNil(fixture.observations[1].event)
            XCTAssertEqual(fixture.observations.first?.timestamp.uptimeNanoseconds, timestamp.uptimeNanoseconds)
            XCTAssertEqual(fixture.events.map(\.kind), [.down, .move, .up])
            XCTAssertEqual(fixture.events.map(\.rawX), [10, 11, 11])
            XCTAssertEqual(fixture.events.map(\.rawY), [20, 21, 21])
            XCTAssertEqual(fixture.events.first?.timestamp.uptimeNanoseconds, timestamp.uptimeNanoseconds)
        }
    }

    func testCachedReleaseRejectsOlderHeldPacketsAndPreservesFirstFreshDown() {
        onMain {
            let f = InputReportFixture()
            XCTAssertTrue(f.registration.installNeutralState(HIDNeutralState(reportTimestamp: 100)))
            f.write(isDown: true)
            for timestamp: UInt64 in [0, 99, 100] { f.deliver(providerTimestamp: timestamp) }
            f.deliver() // Missing provider timestamp cannot prove ordering.
            XCTAssertTrue(f.events.isEmpty)
            XCTAssertEqual(f.receivedReports, 0)
            f.deliver(providerTimestamp: 101)
            XCTAssertEqual(f.events.map(\.kind), [.down])
            XCTAssertEqual(f.observations.first?.contactEpoch, 1)
            f.write(isDown: false)
            f.deliver(providerTimestamp: 102)
            XCTAssertEqual(f.events.map(\.kind), [.down, .up])
        }
    }

    func testCacheCannotReplaceAnAdmittedContactOrRetiredRegistration() {
        onMain {
            let f = InputReportFixture()
            f.write(isDown: true)
            f.deliver(providerTimestamp: 80)
            XCTAssertFalse(f.registration.installNeutralState(HIDNeutralState(reportTimestamp: 100)))
            f.write(isDown: false)
            f.deliver(providerTimestamp: 81)
            XCTAssertEqual(f.events.map(\.kind), [.down, .up])
            let retired = InputReportFixture()
            retired.registration.invalidate()
            XCTAssertFalse(retired.registration.installNeutralState(HIDNeutralState(reportTimestamp: 100)))
        }
    }

    func testProviderWithoutTimestampsRequiresExplicitRawRelease() {
        onMain {
            let f = InputReportFixture()
            XCTAssertTrue(f.registration.installNeutralState(HIDNeutralState(reportTimestamp: 100)))
            f.write(isDown: true)
            f.deliver(providerTimestamp: 0)
            XCTAssertTrue(f.events.isEmpty)
            f.write(isDown: false)
            f.deliver(providerTimestamp: 0)
            f.write(isDown: true)
            f.deliver(providerTimestamp: 0)
            XCTAssertEqual(f.events.map(\.kind), [.down])
        }
    }

    func testFailedCompletionDoesNotReachParser() {
        assertRejectedWithoutParserMutation { fixture in
            fixture.deliver(result: kIOReturnError)
            fixture.deliver(result: kIOReturnAborted)
            fixture.deliver(result: kIOReturnNoDevice)
        }
    }

    func testNonInputTypesDoNotReachParser() {
        assertRejectedWithoutParserMutation { fixture in
            fixture.deliver(type: kIOHIDReportTypeOutput)
            fixture.deliver(type: kIOHIDReportTypeFeature)
        }
    }

    func testUnexpectedReportIDsDoNotReachParser() {
        assertRejectedWithoutParserMutation { fixture in
            fixture.deliver(reportID: 0)
            fixture.deliver(reportID: 99)
            fixture.deliver(reportID: UInt32.max)
        }
    }

    func testUnknownAndMissingSendersDoNotReachParser() {
        assertRejectedWithoutParserMutation { fixture in
            // These are identities only; the ingress must never dereference them.
            fixture.deliver(sender: UnsafeMutableRawPointer(bitPattern: 1))
            fixture.deliver(sender: nil)
        }
    }

    func testAnotherLiveRegistrationCannotImpersonateTheSource() {
        onMain {
            let first = InputReportFixture()
            let second = InputReportFixture(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
            first.write(isDown: true)
            first.deliver(sender: second.sender)
            XCTAssertEqual(first.receivedReports, 0)
            XCTAssertTrue(first.observations.isEmpty)
            XCTAssertEqual(second.receivedReports, 0)
            XCTAssertTrue(second.observations.isEmpty)
            first.deliver()
            XCTAssertEqual(first.events.map(\.kind), [.down])
        }
    }

    func testNegativeZeroShortAndOversizedLengthsDoNotReachParser() {
        assertRejectedWithoutParserMutation { fixture in
            for length in [CFIndex.min, -1, 0, 1, XeneonEdgeDevice.touchReportLength - 1,
                           fixture.registration.length + 1, CFIndex.max] {
                fixture.deliver(length: length)
            }
        }
    }

    func testBoundUsesThisRegistrationsActualAllocation() {
        onMain {
            let short = InputReportFixture(capacity: XeneonEdgeDevice.touchReportLength)
            let larger = InputReportFixture(capacity: 32)
            short.write(isDown: true)
            larger.write(isDown: true)
            short.deliver(length: XeneonEdgeDevice.touchReportLength + 1)
            larger.deliver(length: 32)
            XCTAssertEqual(short.receivedReports, 0)
            XCTAssertTrue(short.observations.isEmpty)
            XCTAssertEqual(larger.receivedReports, 1)
            XCTAssertEqual(larger.lastBytes?.count, 32)
            short.deliver()
            XCTAssertEqual(short.events.map(\.kind), [.down])
        }
    }

    func testUnknownReportPointerIsRejectedBeforeRead() {
        assertRejectedWithoutParserMutation { fixture in
            fixture.deliver(report: UnsafeMutablePointer<UInt8>(bitPattern: 1)!)
            fixture.deliver(report: fixture.registration.buffer.advanced(by: 1))
        }
    }

    func testUnknownAndMissingContextsAreRejectedWithoutDereferencingThem() {
        assertRejectedWithoutParserMutation { fixture in
            fixture.deliver(context: UnsafeMutableRawPointer(bitPattern: UInt.max))
            fixture.deliver(context: nil)
        }
    }

    func testRetirementIsIdempotentAndLateCallbackCannotReachNewRegistration() {
        onMain {
            let first = InputReportFixture()
            let oldContext = first.registration.context
            first.write(isDown: true)
            first.registration.invalidate()
            first.registration.invalidate()
            first.deliver()
            XCTAssertEqual(first.receivedReports, 0)
            XCTAssertTrue(first.observations.isEmpty)

            let replacement = InputReportFixture(sender: first.sender)
            XCTAssertNotEqual(oldContext, replacement.registration.context)
            XCTAssertNotEqual(first.registration.sourceID, replacement.registration.sourceID)
            XCTAssertTrue(first.registration.retirementFence.isRetired)
            XCTAssertFalse(replacement.registration.retirementFence.isRetired)
            replacement.write(isDown: true)
            // Even when every other callback argument belongs to the replacement,
            // a retired token cannot be mistaken for the replacement generation.
            replacement.deliver(context: oldContext)
            XCTAssertEqual(replacement.receivedReports, 0)
            XCTAssertTrue(replacement.observations.isEmpty)
            replacement.deliver()
            XCTAssertEqual(replacement.events.map(\.kind), [.down])
            XCTAssertEqual(replacement.observations.first?.contactEpoch, 1)
        }
    }

    func testReleasedRegistrationAndBufferAreNotRetainedByCallbackRegistry() {
        onMain {
            let sender = UnsafeMutableRawPointer(bitPattern: 0x1000)!
            var received = 0
            var observed = 0
            var registration: HIDInputReportRegistration? = HIDInputReportRegistration(
                sender: sender, length: 7,
                receiveObservation: { _, _ in observed += 1 },
                receive: { _, _, _ in received += 1 }
            )
            weak var weakRegistration: HIDInputReportRegistration?
            weakRegistration = registration
            let context = registration!.context
            let report = registration!.buffer
            registration = nil
            XCTAssertNil(weakRegistration)

            // The saved report address is now dangling. A retired token must be
            // rejected before the report address is used to read any bytes.
            HIDInputReportRegistration.handleCallback(
                context: context, result: kIOReturnSuccess, sender: sender,
                type: kIOHIDReportTypeInput, reportID: 7, report: report, reportLength: 7
            )
            XCTAssertEqual(received, 0)
            XCTAssertEqual(observed, 0)
        }
    }

    func testBoundedReportsKeepExistingPayloadInterpretation() {
        onMain {
            let fixture = InputReportFixture(capacity: 16)
            fixture.write(isDown: true, x: 65_535, y: 65_535)
            fixture.registration.buffer[0] = 0xEE
            fixture.registration.buffer[1] = 0x80
            fixture.registration.buffer[6] = 0xFF
            fixture.deliver(length: 16)
            XCTAssertEqual(fixture.events.map(\.kind), [.down])
            XCTAssertEqual(fixture.events.first?.rawX, 65_535)
            XCTAssertEqual(fixture.events.first?.rawY, 65_535)
            XCTAssertEqual(fixture.lastBytes?.count, 16)
            XCTAssertEqual(fixture.observations.count, 1)
            XCTAssertEqual(fixture.observations.first?.contactEpoch, 1)
            XCTAssertEqual(fixture.observations.first?.isPressed, true)
        }
    }

    func testOffMainCallbackDoesNotReachReceiverOrParser() {
        onMain {
            let fixture = InputReportFixture()
            fixture.write(isDown: true)
            // Only numeric identities cross the thread boundary. The main-thread
            // fixture owns the allocation until this worker completes; ingress
            // must reject off-main delivery before looking up or reading it.
            let contextIdentity = UInt(bitPattern: fixture.registration.context)
            let senderIdentity = UInt(bitPattern: fixture.sender)
            let reportIdentity = UInt(bitPattern: fixture.registration.buffer)
            let completed = DispatchSemaphore(value: 0)
            let worker = Thread {
                XCTAssertFalse(Thread.isMainThread)
                HIDInputReportRegistration.handleCallback(
                    context: UnsafeMutableRawPointer(bitPattern: contextIdentity),
                    result: kIOReturnSuccess,
                    sender: UnsafeMutableRawPointer(bitPattern: senderIdentity),
                    type: kIOHIDReportTypeInput,
                    reportID: 7,
                    report: UnsafeMutablePointer<UInt8>(bitPattern: reportIdentity)!,
                    reportLength: 7
                )
                completed.signal()
            }
            worker.start()
            completed.wait()
            XCTAssertEqual(fixture.receivedReports, 0)
            XCTAssertTrue(fixture.observations.isEmpty)
            XCTAssertTrue(fixture.events.isEmpty)
            fixture.deliver()
            XCTAssertEqual(fixture.events.map(\.kind), [.down])
        }
    }

    func testReceiverCanRetireAndReleaseRegistrationDuringDelivery() {
        onMain {
            let sender = UnsafeMutableRawPointer(bitPattern: 0x1000)!
            var registration: HIDInputReportRegistration?
            weak var observedRegistration: HIDInputReportRegistration?
            var received = 0
            var copiedBytes: [UInt8]?
            registration = HIDInputReportRegistration(sender: sender, length: 7, receive: { _, bytes, _ in
                received += 1
                registration?.invalidate()
                registration = nil
                XCTAssertNotNil(observedRegistration)
                copiedBytes = bytes
            })
            observedRegistration = registration
            let context = registration!.context
            let report = registration!.buffer
            for index in 0..<7 { report[index] = UInt8(index) }

            HIDInputReportRegistration.handleCallback(
                context: context, result: kIOReturnSuccess, sender: sender,
                type: kIOHIDReportTypeInput, reportID: 7, report: report, reportLength: 7
            )
            XCTAssertNil(observedRegistration)
            XCTAssertEqual(copiedBytes, [0, 1, 2, 3, 4, 5, 6])
            XCTAssertEqual(received, 1)

            HIDInputReportRegistration.handleCallback(
                context: context, result: kIOReturnSuccess, sender: sender,
                type: kIOHIDReportTypeInput, reportID: 7, report: report, reportLength: 7
            )
            XCTAssertEqual(received, 1)
        }
    }

    func testSourceParsersAndContactEpochsAreIndependent() {
        onMain {
            let first = InputReportFixture()
            let second = InputReportFixture(sender: UnsafeMutableRawPointer(bitPattern: 0x2000)!)
            first.write(isDown: true)
            first.deliver()
            second.write(isDown: false)
            second.deliver()
            first.deliver()
            second.write(isDown: true, x: 200)
            second.deliver()
            second.write(isDown: false, x: 200)
            second.deliver()
            first.deliver()

            XCTAssertEqual(first.events.map(\.kind), [.down])
            XCTAssertEqual(first.observations.map(\.contactEpoch), [1, 1, 1])
            XCTAssertEqual(second.events.map(\.kind), [.down, .up])
            XCTAssertEqual(second.observations.map(\.contactEpoch), [0, 1, 1])
            XCTAssertNotEqual(first.registration.sourceID, second.registration.sourceID)

            second.registration.invalidate()
            first.deliver()
            XCTAssertNil(first.observations.last?.event)
            XCTAssertEqual(first.observations.last?.contactEpoch, 1)
            XCTAssertFalse(first.registration.retirementFence.isRetired)

            first.write(isDown: false)
            first.deliver()
            first.write(isDown: true)
            first.deliver()
            XCTAssertEqual(first.events.map(\.kind), [.down, .up, .down])
            XCTAssertEqual(first.observations.last?.contactEpoch, 2)
        }
    }

    func testIdleReleaseProducesObservationWithoutCreatingContact() {
        onMain {
            let fixture = InputReportFixture()
            fixture.write(isDown: false)
            let timestamps = [DispatchTime(uptimeNanoseconds: 200), DispatchTime(uptimeNanoseconds: 300)]
            fixture.deliver(timestamp: timestamps[0])
            fixture.deliver(timestamp: timestamps[1])
            XCTAssertEqual(fixture.observations.map(\.contactEpoch), [0, 0])
            XCTAssertEqual(fixture.observations.map(\.isPressed), [false, false])
            // Assert exact transport of the supplied clock values. Darwin may
            // round the constructor's integer nanoseconds to Mach timebase ticks.
            XCTAssertEqual(fixture.observations.map(\.timestamp), timestamps)
            XCTAssertTrue(fixture.events.isEmpty)
            fixture.write(isDown: true)
            fixture.deliver()
            XCTAssertEqual(fixture.observations.last?.contactEpoch, 1)
            XCTAssertEqual(fixture.events.map(\.kind), [.down])
        }
    }

    func testRetirementFenceOutlivesRegistrationWithoutRetainingIt() {
        onMain {
            var registration: HIDInputReportRegistration? = HIDInputReportRegistration(
                sender: UnsafeMutableRawPointer(bitPattern: 0x1000)!, length: 7
            )
            weak var weakRegistration: HIDInputReportRegistration?
            weakRegistration = registration
            let fence = registration!.retirementFence
            let sourceID = registration!.sourceID
            XCTAssertEqual(fence.sourceID, sourceID)
            XCTAssertFalse(fence.isRetired)
            registration = nil
            XCTAssertNil(weakRegistration)
            XCTAssertTrue(fence.isRetired)

            // Only the locked Sendable fence crosses the boundary, never the
            // released registration or parser. The main thread waits for readers.
            let completed = DispatchSemaphore(value: 0)
            Thread {
                XCTAssertTrue(fence.isRetired)
                XCTAssertEqual(fence.sourceID, sourceID)
                completed.signal()
            }.start()
            completed.wait()
        }
    }

    func testObservationReceiverCanRetireDuringDelivery() {
        onMain {
            var registration: HIDInputReportRegistration?
            weak var weakRegistration: HIDInputReportRegistration?
            var delivered: HIDTouchObservation?
            var deliveredFence: HIDSourceRetirementFence?
            registration = HIDInputReportRegistration(
                sender: UnsafeMutableRawPointer(bitPattern: 0x1000)!, length: 7,
                receiveObservation: { observation, fence in
                    delivered = observation
                    deliveredFence = fence
                    registration?.invalidate()
                    registration = nil
                    XCTAssertNotNil(weakRegistration)
                    XCTAssertTrue(fence.isRetired)
                }
            )
            weakRegistration = registration
            let context = registration!.context
            let report = registration!.buffer
            for (index, byte) in [UInt8(7), 1, 10, 0, 20, 0, 0].enumerated() { report[index] = byte }
            HIDInputReportRegistration.handleCallback(
                context: context, result: kIOReturnSuccess,
                sender: UnsafeMutableRawPointer(bitPattern: 0x1000),
                type: kIOHIDReportTypeInput, reportID: 7, report: report, reportLength: 7
            )
            XCTAssertNil(weakRegistration)
            XCTAssertEqual(delivered?.event?.kind, .down)
            XCTAssertEqual(delivered?.contactEpoch, 1)
            XCTAssertEqual(deliveredFence?.isRetired, true)
        }
    }

    private func assertRejectedWithoutParserMutation(
        _ sendInvalid: (InputReportFixture) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        onMain {
            let fixture = InputReportFixture()
            fixture.write(isDown: true)
            sendInvalid(fixture)
            XCTAssertEqual(fixture.receivedReports, 0, file: file, line: line)
            XCTAssertTrue(fixture.observations.isEmpty, file: file, line: line)
            fixture.deliver()
            XCTAssertEqual(fixture.events.map(\.kind), [.down], file: file, line: line)
            XCTAssertEqual(fixture.observations.first?.contactEpoch, 1, file: file, line: line)
            fixture.write(isDown: false)
            sendInvalid(fixture)
            XCTAssertEqual(fixture.receivedReports, 1, file: file, line: line)
            XCTAssertEqual(fixture.observations.count, 1, file: file, line: line)
            XCTAssertEqual(fixture.events.map(\.kind), [.down], file: file, line: line)

            fixture.write(isDown: true, x: 11)
            fixture.deliver()
            // An invalid up report must not end the parser's current touch.
            XCTAssertEqual(fixture.events.map(\.kind), [.down, .move], file: file, line: line)
            XCTAssertEqual(fixture.observations.map(\.contactEpoch), [1, 1], file: file, line: line)
        }
    }

    private func onMain(_ action: () -> Void) {
        if Thread.isMainThread { action() }
        else { DispatchQueue.main.sync(execute: action) }
    }
}

private final class InputReportFixture {
    let sender: UnsafeMutableRawPointer
    private(set) var registration: HIDInputReportRegistration!
    private(set) var receivedReports = 0
    private(set) var lastBytes: [UInt8]?
    private(set) var events: [TouchEvent] = []
    private(set) var observations: [HIDTouchObservation] = []

    init(capacity: Int = 16, sender: UnsafeMutableRawPointer = UnsafeMutableRawPointer(bitPattern: 0x1000)!) {
        self.sender = sender
        registration = HIDInputReportRegistration(
            sender: sender, length: capacity,
            receiveObservation: { [weak self] observation, fence in
                guard let self else { return }
                XCTAssertEqual(observation.sourceID, fence.sourceID)
                XCTAssertFalse(fence.isRetired)
                observations.append(observation)
                if let event = observation.event { events.append(event) }
            },
            receive: { [weak self] _, bytes, _ in
                guard let self else { return }
                receivedReports += 1
                lastBytes = bytes
            }
        )
    }

    func write(isDown: Bool, x: Int = 10, y: Int = 20) {
        let bytes: [UInt8] = [7, isDown ? 1 : 0, UInt8(x & 0xFF), UInt8((x >> 8) & 0xFF),
                              UInt8(y & 0xFF), UInt8((y >> 8) & 0xFF), 0]
        for (index, byte) in bytes.enumerated() {
            registration.buffer[index] = byte
        }
    }

    func deliver(
        result: IOReturn = kIOReturnSuccess,
        type: IOHIDReportType = kIOHIDReportTypeInput,
        reportID: UInt32 = 7,
        report: UnsafeMutablePointer<UInt8>? = nil,
        length: CFIndex = XeneonEdgeDevice.touchReportLength,
        timestamp: DispatchTime = .now(),
        providerTimestamp: UInt64? = nil
    ) {
        deliver(context: registration.context, sender: sender, result: result, type: type,
                reportID: reportID, report: report, length: length, timestamp: timestamp, providerTimestamp: providerTimestamp)
    }

    func deliver(sender: UnsafeMutableRawPointer?) {
        deliver(context: registration.context, sender: sender)
    }

    func deliver(context: UnsafeMutableRawPointer?) {
        deliver(context: context, sender: sender)
    }

    private func deliver(
        context: UnsafeMutableRawPointer?,
        sender: UnsafeMutableRawPointer?,
        result: IOReturn = kIOReturnSuccess,
        type: IOHIDReportType = kIOHIDReportTypeInput,
        reportID: UInt32 = 7,
        report: UnsafeMutablePointer<UInt8>? = nil,
        length: CFIndex = XeneonEdgeDevice.touchReportLength,
        timestamp: DispatchTime = .now(),
        providerTimestamp: UInt64? = nil
    ) {
        HIDInputReportRegistration.handleCallback(
            context: context, result: result, sender: sender, type: type, reportID: reportID,
            report: report ?? registration.buffer, reportLength: length, timestamp: timestamp, providerTimestamp: providerTimestamp
        )
    }
}
