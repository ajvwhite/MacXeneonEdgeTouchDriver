import CoreGraphics
import Foundation
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

/// macOS-only observational comparisons for later execution. These construct real
/// CGEvents but inject a recording poster everywhere. They never post an event,
/// query/request posting permission, or run the driver.
///
/// Construction can expose source-table-dependent metadata. The trace and diffs
/// are review evidence, not an assertion that reserve-first construction is
/// metadata-equivalent to the original fresh-down/fresh-up sequence. A fake post
/// cannot establish delivery, target behavior, or source state after a real post.
final class CGEventInputSinkMetadataComparisonTests: XCTestCase {
    private let downPoint = CGPoint(x: 120, y: 240)
    private let releasePoint = CGPoint(x: 345, y: 678)

    func testObservePrivateSourceBaselineVersusReserveFreshAndFallbackRelease() throws {
        // Isolate construction sequences with separate explicit private sources.
        // Their actual source IDs may differ and are deliberately included in diffs.
        let baselineSource = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let freshSource = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let fallbackSource = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let baseline = try baselineSample(source: baselineSource, label: "baseline.private")
        let fresh = try candidateSample(source: freshSource, fallback: false)
        let fallback = try candidateSample(source: fallbackSource, fallback: true)

        emit(baseline)
        emit(fresh)
        emit(fallback)
        emitDifferences(baseline, fresh)
        emitDifferences(baseline, fallback)
        emitDifferences(fresh, fallback)
    }

    func testObserveNilVersusPrivateBaselineAndCandidateNilSourcePolicy() throws {
        let privateSource = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let nilBaseline = try baselineSample(source: nil, label: "baseline.nil")
        let privateBaseline = try baselineSample(source: privateSource, label: "baseline.private")
        emit(nilBaseline)
        emit(privateBaseline)
        emitDifferences(nilBaseline, privateBaseline)

        var factoryCalls = 0
        var postCalls = 0
        var clockCalls = 0
        var flagsCalls = 0
        let sink = CGEventInputSink(environment: MouseInputEnvironment(
            makeEvent: { type, point in
                factoryCalls += 1
                return CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: point, mouseButton: .left)
            },
            post: { _, _ in postCalls += 1 }, // Discard only. Never a CGEvent post.
            timestamp: { clockCalls += 1; return DispatchTime.now().uptimeNanoseconds },
            sourceStateID: nil,
            flags: { flagsCalls += 1; return [] }
        ))

        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .sourceUnavailable)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .noPendingMouseDown)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(postCalls, 0)
        XCTAssertEqual(clockCalls, 0)
        XCTAssertEqual(flagsCalls, 0)
        print("candidate.nil: fail-closed before construction; nil-source compatibility remains a policy review item")
    }

    private func baselineSample(source: CGEventSource?, label: String) throws -> MetadataSample {
        var trace = [sourceObservation(source, stage: "before construction")]
        var fakePosts: [EventMetadata] = []
        let fakePoster: (CGEvent) -> Void = { event in
            fakePosts.append(EventMetadata(event: event))
            trace.append("fake post only: \(EventMetadata(event: event).description)")
        }
        for (type, point) in [(CGEventType.leftMouseDown, downPoint), (.leftMouseUp, releasePoint)] {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: source, mouseType: type,
                                             mouseCursorPosition: point, mouseButton: .left))
            trace.append("factory: \(EventMetadata(event: event).description)")
            trace.append(sourceObservation(source, stage: "after factory \(type.rawValue)"))
            // Match the original implementation: set button and click, retaining
            // the constructor's timestamp, flags, and event number unchanged.
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.left.rawValue))
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            fakePoster(event)
            trace.append(sourceObservation(source, stage: "after fake post \(type.rawValue)"))
        }
        return MetadataSample(label: label, down: fakePosts[0], up: fakePosts[1], trace: trace)
    }

    private func candidateSample(source: CGEventSource, fallback: Bool) throws -> MetadataSample {
        let label = fallback ? "candidate.private.reserve-fallback" : "candidate.private.reserve-fresh"
        var trace = [sourceObservation(source, stage: "before construction")]
        var created: [CGEvent] = []
        var posted: [CGEvent] = []
        var snapshots: [EventMetadata] = []
        var factoryCalls = 0
        var clockCalls = 0
        var flagCalls = 0
        let actualSourceID = source.sourceStateID
        let sink = CGEventInputSink(environment: MouseInputEnvironment(
            makeEvent: { type, point in
                factoryCalls += 1
                if fallback && factoryCalls >= 3 {
                    trace.append("factory \(factoryCalls): forced permanent failure for \(type.rawValue)")
                    return nil
                }
                guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                          mouseCursorPosition: point, mouseButton: .left) else {
                    trace.append("factory \(factoryCalls): real constructor returned nil")
                    return nil
                }
                created.append(event)
                trace.append("factory \(factoryCalls): \(EventMetadata(event: event).description)")
                trace.append(self.sourceObservation(source, stage: "after factory \(factoryCalls)"))
                return event
            },
            post: { event, tap in
                // This environment's factory above only creates CGEvent instances.
                // CoreFoundation casts cannot conditionally test this type.
                let event = event as! CGEvent
                // No real poster is reachable from this test environment.
                posted.append(event)
                snapshots.append(EventMetadata(event: event))
                trace.append("fake post \(posted.count), tap=\(tap.rawValue): \(EventMetadata(event: event).description)")
                trace.append(self.sourceObservation(source, stage: "after fake post \(posted.count)"))
            },
            timestamp: {
                clockCalls += 1
                let nanoseconds = DispatchTime.now().uptimeNanoseconds
                trace.append("fallback timestamp uptimeNanoseconds=\(nanoseconds)")
                return nanoseconds
            },
            sourceStateID: Int64(actualSourceID.rawValue),
            flags: {
                flagCalls += 1
                let flags = CGEventSource.flagsState(actualSourceID)
                trace.append("fallback flags actualSourceID=\(actualSourceID.rawValue), flags=\(flags.rawValue)")
                return flags
            }
        ))

        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .postInvoked)
        XCTAssertEqual(factoryCalls, 3)
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(created.count, fallback ? 2 : 3)
        XCTAssertEqual(clockCalls, fallback ? 1 : 0)
        XCTAssertEqual(flagCalls, fallback ? 1 : 0)
        if posted.count != 2 {
            print("Incomplete CGEvent metadata observation: \(label)")
            for line in trace { print("  \(line)") }
        }
        // Unwrap before indexing so unavailable real constructors fail clearly.
        let down = try XCTUnwrap(posted.first)
        let up = try XCTUnwrap(posted.dropFirst().first)
        let reserve = try XCTUnwrap(created.first)
        XCTAssertFalse(down === reserve)
        XCTAssertFalse(down === up)
        XCTAssertEqual(up === reserve, fallback)
        XCTAssertEqual(down.type, .leftMouseDown)
        XCTAssertEqual(up.type, .leftMouseUp)
        XCTAssertEqual(up.location, releasePoint)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .noPendingMouseDown)
        XCTAssertEqual(posted.count, 2)
        return MetadataSample(label: label, down: snapshots[0], up: snapshots[1], trace: trace)
    }

    private func sourceObservation(_ source: CGEventSource?, stage: String) -> String {
        if let source {
            let actualID = source.sourceStateID
            return "\(stage): explicit sourceStateID=\(actualID.rawValue), " +
                "sourceLeftButton=\(CGEventSource.buttonState(actualID, button: .left)), " +
                "sourceFlags=\(CGEventSource.flagsState(actualID).rawValue)"
        }
        // Observe both named global tables without claiming either is nil's table.
        return "\(stage): explicit source=nil, actual source table unresolved; " +
            "combinedSession.left=\(CGEventSource.buttonState(.combinedSessionState, button: .left)), " +
            "combinedSession.flags=\(CGEventSource.flagsState(.combinedSessionState).rawValue), " +
            "hidSystem.left=\(CGEventSource.buttonState(.hidSystemState, button: .left)), " +
            "hidSystem.flags=\(CGEventSource.flagsState(.hidSystemState).rawValue)"
    }

    private func emit(_ sample: MetadataSample) {
        print("CGEvent metadata observation: \(sample.label)")
        for line in sample.trace { print("  \(line)") }
    }

    private func emitDifferences(_ baseline: MetadataSample, _ candidate: MetadataSample) {
        print("Observed differences: \(baseline.label) -> \(candidate.label)")
        for (phase, before, after) in [("down", baseline.down, candidate.down),
                                       ("up", baseline.up, candidate.up)] {
            let changed = before.values.keys.sorted().compactMap { key -> String? in
                guard before.values[key] != after.values[key] else { return nil }
                return "\(key): \(before.values[key] ?? "missing") -> \(after.values[key] ?? "missing")"
            }
            print("  \(phase): \(changed.isEmpty ? "no differences observed in sampled fields" : changed.joined(separator: "; "))")
        }
        print("  Observational only: no metadata equivalence or real-delivery claim.")
    }
}

private struct MetadataSample {
    let label: String
    let down: EventMetadata
    let up: EventMetadata
    let trace: [String]
}

private struct EventMetadata {
    let values: [String: String]

    init(event: CGEvent) {
        values = [
            "type": String(event.type.rawValue),
            "x": String(describing: event.location.x),
            "y": String(describing: event.location.y),
            "eventSourceStateID": String(event.getIntegerValueField(.eventSourceStateID)),
            "button": String(event.getIntegerValueField(.mouseEventButtonNumber)),
            "clickState": String(event.getIntegerValueField(.mouseEventClickState)),
            "flags": String(event.flags.rawValue),
            "eventNumber": String(event.getIntegerValueField(.mouseEventNumber)),
            "timestampNanoseconds": String(event.timestamp),
            "deltaX": String(event.getIntegerValueField(.mouseEventDeltaX)),
            "deltaY": String(event.getIntegerValueField(.mouseEventDeltaY)),
            "pressure": String(event.getDoubleValueField(.mouseEventPressure))
        ]
    }

    var description: String {
        values.keys.sorted().map { "\($0)=\(values[$0] ?? "missing")" }.joined(separator: ", ")
    }
}
