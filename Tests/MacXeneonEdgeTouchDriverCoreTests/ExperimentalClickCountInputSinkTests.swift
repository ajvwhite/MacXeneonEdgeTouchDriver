import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

/// Fake events only: these tests never construct or post a CoreGraphics event.
final class ExperimentalClickCountInputSinkTests: XCTestCase {
    private let down = CGPoint(x: 100, y: 200)
    private let up = CGPoint(x: 110, y: 210)

    func testDoubleCountFreezesDownMetadataAcrossFreshRelease() {
        let fake = ClickMetadataEnvironment()
        let sink = fake.sink()
        XCTAssertEqual(sink.tryPostMouseDown(at: down, clickCount: .double), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseUp(at: up), .postInvoked)
        XCTAssertEqual(fake.posted.map(\.clickCount), [2, 2])
        XCTAssertEqual(fake.posted.map(\.eventNumber), [102, 102])
        XCTAssertEqual(fake.posted.map(\.id), [2, 3])
        XCTAssertEqual(fake.posted[1].timestamp, 30)
        XCTAssertEqual(fake.posted[1].flags, [.maskCommand])
        XCTAssertEqual(fake.clockReads, 0)
        XCTAssertEqual(fake.flagsReads, 0)
    }

    func testDoubleCountSurvivesPermanentFactoryFailureUsingReserveExactlyOnce() {
        let fake = ClickMetadataEnvironment()
        fake.failFrom = 3
        let sink = fake.sink()
        XCTAssertEqual(sink.tryPostMouseDown(at: down, clickCount: .double), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseUp(at: up), .postInvoked)
        XCTAssertEqual(fake.posted.map(\.id), [2, 1])
        XCTAssertEqual(fake.posted.map(\.clickCount), [2, 2])
        XCTAssertEqual(fake.posted.map(\.eventNumber), [102, 102])
        XCTAssertEqual(fake.posted[1].location, up)
        XCTAssertEqual(fake.posted[1].timestamp, 987_654_321)
        XCTAssertEqual(fake.posted[1].flags, [.maskShift])
        XCTAssertEqual(fake.clockReads, 1)
        XCTAssertEqual(fake.flagsReads, 1)
        XCTAssertEqual(sink.tryPostMouseUp(at: up), .noPendingMouseDown)
        XCTAssertEqual(fake.factoryCalls, 3)
        XCTAssertEqual(fake.posted.count, 2)
    }

    func testExplicitSingleCountFallbackPairsReservedReleaseMetadata() {
        let fake = ClickMetadataEnvironment()
        fake.failFrom = 3
        let sink = fake.sink()
        XCTAssertEqual(sink.tryPostMouseDown(at: down, clickCount: .single), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseUp(at: up), .postInvoked)
        XCTAssertEqual(fake.posted.map(\.id), [2, 1])
        XCTAssertEqual(fake.posted.map(\.clickCount), [1, 1])
        XCTAssertEqual(fake.posted.map(\.eventNumber), [102, 102])
        XCTAssertEqual(fake.posted[1].location, up)
        XCTAssertEqual(fake.posted[1].timestamp, 987_654_321)
        XCTAssertEqual(fake.posted[1].flags, [.maskShift])
        XCTAssertEqual(sink.tryPostMouseUp(at: up), .noPendingMouseDown)
        XCTAssertEqual(fake.factoryCalls, 3)
    }

    func testControllerCancellationAfterExplicitDoubleDownPreservesFreshAndFallbackMetadata() {
        for fallback in [false, true] {
            let fake = ClickMetadataEnvironment()
            if fallback { fake.failFrom = 3 }
            let cursor = ClickCancellationCursor()
            let scheduler = TestGestureScheduler(executeCancelledActions: true)
            let mapper = CoordinateMapper(displayBounds: CGRect(x: 10, y: 20, width: 100, height: 100))
            let sink = FixedDoubleCountSink(sink: fake.sink())
            let controller = GestureController(mapperProvider: { mapper }, inputSink: sink,
                                               cursorController: cursor, timing: .immediate,
                                               scheduler: scheduler)
            cursor.onRelease = {
                XCTAssertEqual(fake.posted.map(\.type), [.leftMouseDown, .leftMouseUp],
                               "The owned release must be invoked before cursor cleanup.")
            }
            controller.handle(TouchEvent(kind: .down, contactID: 0, rawX: 0, rawY: 0,
                                         timestamp: scheduler.now))
            XCTAssertEqual(fake.posted.map(\.clickCount), [2])
            controller.forceCancel()
            controller.forceCancel()
            scheduler.advance(byMilliseconds: 1_000)
            XCTAssertEqual(fake.posted.map(\.type), [.leftMouseDown, .leftMouseUp])
            XCTAssertEqual(fake.posted.map(\.clickCount), [2, 2])
            XCTAssertEqual(fake.posted.map(\.eventNumber), [102, 102])
            XCTAssertEqual(fake.posted.map(\.id), fallback ? [2, 1] : [2, 3])
            XCTAssertEqual(cursor.releases, 1)
            XCTAssertEqual(controller.state, .idle)
            XCTAssertEqual(fake.factoryCalls, 3)
        }
    }

    func testExplicitSingleCountPairsEventNumberButDefaultManagedCallDoesNot() {
        let explicit = ClickMetadataEnvironment()
        let explicitSink = explicit.sink()
        XCTAssertEqual(explicitSink.tryPostMouseDown(at: down, clickCount: .single), .postInvoked)
        XCTAssertEqual(explicitSink.tryPostMouseUp(at: up), .postInvoked)
        XCTAssertEqual(explicit.posted.map(\.clickCount), [1, 1])
        XCTAssertEqual(explicit.posted.map(\.eventNumber), [102, 102])

        let legacy = ClickMetadataEnvironment()
        let legacySink = legacy.sink()
        XCTAssertEqual(legacySink.tryPostMouseDown(at: down), .postInvoked)
        XCTAssertEqual(legacySink.tryPostMouseUp(at: up), .postInvoked)
        XCTAssertEqual(legacy.posted.map(\.clickCount), [1, 1])
        XCTAssertEqual(legacy.posted.map(\.eventNumber), [102, 103])
        XCTAssertEqual(legacy.transcript, [
            "make:1", "make:2", "set:2:button=0", "set:2:click=1", "post:2",
            "make:3", "set:3:button=0", "set:3:click=1", "post:3"
        ])
    }

    func testDefaultManagedFallbackKeepsOriginalEffectTranscript() {
        let fake = ClickMetadataEnvironment()
        fake.failFrom = 3
        let sink = fake.sink()
        XCTAssertEqual(sink.tryPostMouseDown(at: down), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseUp(at: up), .postInvoked)
        XCTAssertEqual(fake.transcript, [
            "make:1", "make:2", "set:2:button=0", "set:2:click=1", "post:2", "make:3",
            "clock", "flags", "set:1:number=102", "set:1:button=0", "set:1:click=1", "post:1"
        ])
        XCTAssertEqual(fake.posted.map(\.clickCount), [1, 1])
    }

    func testRawCallsRetainSingleEventConstructionAndMetadata() {
        let fake = ClickMetadataEnvironment()
        fake.source = nil
        let sink = fake.sink()
        sink.postMouseUp(at: up)
        sink.postMouseDown(at: down)
        sink.postMouseDown(at: down)
        sink.postMouseDragged(to: up)
        XCTAssertEqual(fake.factoryCalls, 4)
        XCTAssertEqual(fake.posted.map(\.eventNumber), [101, 102, 103, 104])
        XCTAssertEqual(fake.posted.map(\.clickCount), [1, 1, 1, 0])
        XCTAssertEqual(fake.clockReads, 0)
        XCTAssertEqual(fake.flagsReads, 0)
    }

    func testExperimentalConstructionFailuresCannotAcquireOrLeakMetadata() {
        for failure in [1, 2] {
            let fake = ClickMetadataEnvironment()
            fake.failedCalls = [failure]
            let sink = fake.sink()
            XCTAssertEqual(sink.tryPostMouseDown(at: down, clickCount: .double), .constructionFailed)
            XCTAssertTrue(fake.posted.isEmpty)
            XCTAssertEqual(sink.tryPostMouseUp(at: up), .noPendingMouseDown)
            XCTAssertEqual(sink.tryPostMouseDown(at: down), .postInvoked)
            XCTAssertEqual(sink.tryPostMouseUp(at: up), .postInvoked)
            XCTAssertEqual(fake.posted.map(\.clickCount), [1, 1])
        }
    }

    func testExperimentalNilSourceRejectsBeforeFactory() {
        let fake = ClickMetadataEnvironment()
        fake.source = nil
        let sink = fake.sink()
        XCTAssertEqual(sink.tryPostMouseDown(at: down, clickCount: .double), .sourceUnavailable)
        XCTAssertEqual(fake.factoryCalls, 0)
        XCTAssertTrue(fake.posted.isEmpty)
    }

    func testExperimentalWrongSourceOrAliasedReserveRejectsBeforePosting() {
        for scenario in ["reserve", "down", "alias"] {
            let fake = ClickMetadataEnvironment()
            fake.wrongSourceCall = scenario == "reserve" ? 1 : (scenario == "down" ? 2 : nil)
            fake.aliasReserve = scenario == "alias"
            let sink = fake.sink()
            XCTAssertEqual(sink.tryPostMouseDown(at: down, clickCount: .double), .sourceUnavailable, scenario)
            XCTAssertTrue(fake.posted.isEmpty)
            XCTAssertEqual(sink.tryPostMouseUp(at: up), .noPendingMouseDown)
        }
    }

    func testBusyDownAndRawCallsCannotReplaceFrozenDoubleCount() {
        let fake = ClickMetadataEnvironment()
        let sink = fake.sink()
        XCTAssertEqual(sink.tryPostMouseDown(at: down, clickCount: .double), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseDown(at: down, clickCount: .single), .busy)
        XCTAssertEqual(sink.tryPostMouseDown(at: down), .busy)
        sink.postMouseDown(at: down)
        sink.postMouseUp(at: up)
        sink.postMouseDragged(to: up)
        XCTAssertEqual(fake.factoryCalls, 2)
        XCTAssertEqual(sink.tryPostMouseUp(at: up), .postInvoked)
        XCTAssertEqual(fake.posted.map(\.clickCount), [2, 2])
    }

    func testDragDoesNotRewriteFrozenDoubleReleaseEvenAfterFailedDrag() {
        for fails in [false, true] {
            let fake = ClickMetadataEnvironment()
            if fails { fake.failFrom = 3 }
            let sink = fake.sink()
            XCTAssertEqual(sink.tryPostMouseDown(at: down, clickCount: .double), .postInvoked)
            XCTAssertEqual(sink.tryPostMouseDragged(to: up), fails ? .constructionFailed : .postInvoked)
            XCTAssertEqual(sink.tryPostMouseUp(at: up), .postInvoked)
            XCTAssertEqual(fake.posted.first?.clickCount, 2)
            XCTAssertEqual(fake.posted.last?.clickCount, 2)
            XCTAssertEqual(fake.posted.last?.eventNumber, 102)
        }
    }

    func testReentryCannotMutateMetadataOrDuplicateRelease() {
        for fallback in [false, true] {
            let phases = ["make:1", "make:2", "set:2:click=2", "post:2", "make:3"]
                + (fallback ? ["clock", "flags", "set:1:click=2", "post:1"] : ["set:3:click=2", "post:3"])
            for phase in phases {
                let fake = ClickMetadataEnvironment()
                if fallback { fake.failFrom = 3 }
                let sink = fake.sink()
                var probes = 0
                fake.onEffect = { effect in
                    guard effect == phase else { return }
                    probes += 1
                    XCTAssertEqual(sink.tryPostMouseDown(at: self.down, clickCount: .single), .busy)
                    XCTAssertEqual(sink.tryPostMouseDown(at: self.down), .busy)
                    XCTAssertEqual(sink.tryPostMouseUp(at: self.up), .busy)
                    XCTAssertEqual(sink.tryPostMouseDragged(to: self.up), .busy)
                }
                XCTAssertEqual(sink.tryPostMouseDown(at: down, clickCount: .double), .postInvoked)
                XCTAssertEqual(sink.tryPostMouseUp(at: up), .postInvoked)
                XCTAssertEqual(probes, 1, phase)
                XCTAssertEqual(fake.posted.map(\.clickCount), [2, 2], phase)
                XCTAssertEqual(fake.factoryCalls, 3)
            }
        }
    }

    func testLaterDefaultPressDoesNotInheritExperimentalMetadata() {
        let fake = ClickMetadataEnvironment()
        let sink = fake.sink()
        XCTAssertEqual(sink.tryPostMouseDown(at: down, clickCount: .double), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseUp(at: up), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseDown(at: down), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseUp(at: up), .postInvoked)
        XCTAssertEqual(fake.posted.map(\.clickCount), [2, 2, 1, 1])
        XCTAssertEqual(fake.posted.map(\.eventNumber), [102, 102, 105, 106])
    }
}

/// Test-only opt-in. No production GestureController calls the new overload.
private final class FixedDoubleCountSink: ReportingSyntheticInputSink {
    let sink: CGEventInputSink
    init(sink: CGEventInputSink) { self.sink = sink }
    func tryPostMouseDown(at point: CGPoint) -> SyntheticInputResult { sink.tryPostMouseDown(at: point, clickCount: .double) }
    func tryPostMouseUp(at point: CGPoint) -> SyntheticInputResult { sink.tryPostMouseUp(at: point) }
    func tryPostMouseDragged(to point: CGPoint) -> SyntheticInputResult { sink.tryPostMouseDragged(to: point) }
    func postMouseDown(at point: CGPoint) { XCTFail("Expected managed input") }
    func postMouseUp(at point: CGPoint) { XCTFail("Expected managed input") }
    func postMouseDragged(to point: CGPoint) { XCTFail("Expected managed input") }
}

private final class ClickCancellationCursor: CursorController {
    var releases = 0
    var onRelease: (() -> Void)?
    func borrow(warpingTo point: CGPoint) -> Bool { true }
    func updatePosition(_ point: CGPoint) {}
    func returnToOrigin() { releases += 1; onRelease?() }
    func forceShow() {}
}

private final class ClickMetadataEvent: MouseInputEvent {
    let id: Int
    var type: CGEventType
    var location: CGPoint
    var timestamp: CGEventTimestamp
    var flags: CGEventFlags = [.maskCommand]
    private var fields: [CGEventField: Int64]
    private let effect: (String) -> Void

    init(id: Int, type: CGEventType, point: CGPoint, source: Int64, effect: @escaping (String) -> Void) {
        self.id = id
        self.type = type
        location = point
        timestamp = UInt64(id * 10)
        self.effect = effect
        fields = [.eventSourceStateID: source, .mouseEventNumber: Int64(100 + id), .mouseEventClickState: 0]
    }

    var clickCount: Int64 { fields[.mouseEventClickState, default: 0] }
    var eventNumber: Int64 { fields[.mouseEventNumber, default: 0] }
    func getIntegerValueField(_ field: CGEventField) -> Int64 { fields[field, default: 0] }
    func setIntegerValueField(_ field: CGEventField, value: Int64) {
        fields[field] = value
        let name = field == .mouseEventButtonNumber ? "button" : (field == .mouseEventClickState ? "click" : "number")
        effect("set:\(id):\(name)=\(value)")
    }
}

private final class ClickMetadataEnvironment {
    var source: Int64? = -42
    var failedCalls: Set<Int> = []
    var failFrom: Int?
    var wrongSourceCall: Int?
    var aliasReserve = false
    var onEffect: ((String) -> Void)?
    private(set) var factoryCalls = 0
    private(set) var clockReads = 0
    private(set) var flagsReads = 0
    private(set) var transcript: [String] = []
    private(set) var posted: [ClickMetadataEvent] = []
    private var reserve: ClickMetadataEvent?

    func sink() -> CGEventInputSink {
        let source = self.source
        return CGEventInputSink(environment: MouseInputEnvironment(
            makeEvent: { [self] type, point in
                self.factoryCalls += 1
                let id = self.factoryCalls
                self.record("make:\(id)")
                if self.failedCalls.contains(id) || self.failFrom.map({ id >= $0 }) == true { return nil }
                if id == 2, self.aliasReserve { return self.reserve }
                let event = ClickMetadataEvent(
                    id: id, type: type, point: point,
                    source: self.wrongSourceCall == id ? 999 : (source ?? 0),
                    effect: { [weak self] in self?.record($0) }
                )
                if id == 1 { self.reserve = event }
                return event
            },
            post: { event, _ in
                let event = event as! ClickMetadataEvent
                self.posted.append(event)
                self.record("post:\(event.id)")
            },
            timestamp: {
                self.clockReads += 1
                self.record("clock")
                return 987_654_321
            },
            sourceStateID: source,
            flags: {
                self.flagsReads += 1
                self.record("flags")
                return [.maskShift]
            }
        ))
    }

    private func record(_ effect: String) {
        transcript.append(effect)
        onEffect?(effect)
    }
}
