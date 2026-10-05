import CoreGraphics
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

/// Sink-only tests. Neither the factory nor the poster uses a real CGEvent.
final class CGEventInputSinkFailureTests: XCTestCase {
    private let downPoint = CGPoint(x: 120, y: 240)
    private let releasePoint = CGPoint(x: 345, y: 678)

    func testDefaultPostingKeepsDownDragAndEmergencyReleaseAfterHardwareState() {
        let effects = MockMouseEnvironment()
        let sink = effects.makeSink()
        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseDragged(to: releasePoint), .postInvoked)
        effects.failFactoryFromCall = effects.requests.count + 1
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .postInvoked)
        XCTAssertEqual(effects.posts.map(\.tap),
                       [.cgSessionEventTap, .cgSessionEventTap, .cgSessionEventTap])
        XCTAssertEqual(effects.posts.map { $0.event.type },
                       [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
    }

    func testReserveCreationFailureDoesNotConstructOrPostDown() {
        let effects = MockMouseEnvironment()
        effects.failedFactoryCalls = [1]
        let sink = effects.makeSink()

        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .constructionFailed)
        XCTAssertEqual(effects.requests.map(\.type), [.leftMouseUp])
        XCTAssertTrue(effects.posts.isEmpty)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .noPendingMouseDown)
        XCTAssertEqual(effects.requests.count, 1)

        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .postInvoked,
                       "A failed reservation must not leave the sink busy.")
    }

    func testDownCreationFailureDiscardsUnpostedReserveAndAllowsNextPress() {
        let effects = MockMouseEnvironment()
        effects.failedFactoryCalls = [2]
        let sink = effects.makeSink()

        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .constructionFailed)
        XCTAssertEqual(effects.requests.map(\.type), [.leftMouseUp, .leftMouseDown])
        XCTAssertTrue(effects.posts.isEmpty)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .noPendingMouseDown)
        XCTAssertEqual(sink.tryPostMouseDragged(to: releasePoint), .noPendingMouseDown)
        XCTAssertEqual(effects.requests.count, 2)

        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .postInvoked)
        XCTAssertEqual(effects.posts.map { $0.event.type }, [.leftMouseDown, .leftMouseUp])
        XCTAssertFalse(effects.posts.contains { $0.event === effects.createdEvents[0] })
    }

    func testMissingExplicitSourceFailsClosedWithoutCallingAnyEffect() {
        let effects = MockMouseEnvironment()
        effects.sourceStateID = nil
        let sink = effects.makeSink()

        // This records the candidate policy, pending a separate nil-source review.
        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .sourceUnavailable)
        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .sourceUnavailable)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .noPendingMouseDown)
        XCTAssertEqual(sink.tryPostMouseDragged(to: releasePoint), .noPendingMouseDown)
        XCTAssertTrue(effects.requests.isEmpty)
        XCTAssertTrue(effects.posts.isEmpty)
        XCTAssertEqual(effects.clockReads, 0)
        XCTAssertEqual(effects.flagReads, 0)
    }

    func testAliasedReserveAndDownAreRejectedWithoutPosting() {
        let effects = MockMouseEnvironment()
        let shared = MockMouseEvent(type: .leftMouseUp, point: downPoint,
                                    sourceStateID: effects.sourceStateID!)
        effects.factoryOverrides = [1: shared, 2: shared]
        let sink = effects.makeSink()

        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .sourceUnavailable)
        XCTAssertTrue(effects.posts.isEmpty)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .noPendingMouseDown)
    }

    func testReserveOrDownFromWrongSourceCannotBeginPress() {
        for wrongSourceCall in [1, 2] {
            let effects = MockMouseEnvironment()
            effects.factoryOverrides[wrongSourceCall] = MockMouseEvent(
                type: wrongSourceCall == 1 ? .leftMouseUp : .leftMouseDown,
                point: downPoint, sourceStateID: 999
            )
            let sink = effects.makeSink()

            XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .sourceUnavailable)
            XCTAssertTrue(effects.posts.isEmpty)
            XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .noPendingMouseDown)
        }
    }

    func testNormalReleasePostsDistinctFreshUpWithoutReplacingItsTimestampOrFlags() {
        let effects = MockMouseEnvironment()
        let freshUp = MockMouseEvent(type: .leftMouseUp, point: releasePoint,
                                    sourceStateID: effects.sourceStateID!)
        freshUp.timestamp = 83_000_000_019
        freshUp.flags = [.maskCommand, .maskAlternate]
        freshUp.setIntegerValueField(.mouseEventNumber, value: 900)
        effects.factoryOverrides[3] = freshUp
        effects.nowNanoseconds = 99_000_000_071
        effects.currentFlags = [.maskShift]
        let sink = effects.makeSink(eventTap: .cgSessionEventTap)

        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .postInvoked)
        XCTAssertEqual(effects.requests.map(\.type), [.leftMouseUp, .leftMouseDown, .leftMouseUp])
        XCTAssertEqual(effects.requests.map(\.point), [downPoint, downPoint, releasePoint])
        XCTAssertEqual(effects.posts.count, 2)
        guard effects.posts.count == 2 else { return }
        let reserve = effects.createdEvents[0]
        let down = effects.posts[0].event
        let up = effects.posts[1].event
        XCTAssertFalse(reserve === down)
        XCTAssertFalse(reserve === up)
        XCTAssertFalse(down === up)
        XCTAssertTrue(up === freshUp)
        XCTAssertEqual(up.timestamp, 83_000_000_019)
        XCTAssertEqual(up.flags, [.maskCommand, .maskAlternate])
        XCTAssertEqual(up.location, releasePoint)
        XCTAssertEqual(up.getIntegerValueField(.mouseEventNumber), 900,
                       "Keep the normal fresh constructor's metadata; pair explicitly only on fallback.")
        assertLeftSingleClick(down)
        assertLeftSingleClick(up)
        XCTAssertEqual(effects.posts.map(\.tap), [.cgSessionEventTap, .cgSessionEventTap])
        XCTAssertEqual(effects.clockReads, 0)
        XCTAssertEqual(effects.flagReads, 0)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .noPendingMouseDown)
        XCTAssertEqual(effects.requests.count, 3)
        XCTAssertEqual(effects.posts.count, 2)
    }

    func testPermanentFactoryFailureAfterDownPostsReserveExactlyOnceWithReleaseMetadata() {
        let effects = MockMouseEnvironment()
        // A deliberately non-sentinel source ID represents the actual source table.
        effects.sourceStateID = -24_681
        effects.failFactoryFromCall = 3
        let sink = effects.makeSink()

        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .postInvoked)
        let reserve = effects.createdEvents[0]
        let down = effects.createdEvents[1]
        XCTAssertNotEqual(reserve.getIntegerValueField(.mouseEventNumber),
                          down.getIntegerValueField(.mouseEventNumber))
        // The clock contract is uptime nanoseconds, not a mach tick counter.
        effects.nowNanoseconds = 12_345_678_901_234
        effects.currentFlags = [.maskControl, .maskSecondaryFn]

        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .postInvoked)
        XCTAssertEqual(effects.posts.count, 2)
        guard effects.posts.count == 2 else { return }
        XCTAssertTrue(effects.posts[1].event === reserve)
        XCTAssertFalse(effects.posts[0].event === reserve)
        XCTAssertEqual(reserve.type, .leftMouseUp)
        XCTAssertEqual(reserve.location, releasePoint)
        XCTAssertEqual(reserve.timestamp, 12_345_678_901_234)
        XCTAssertEqual(reserve.flags, [.maskControl, .maskSecondaryFn])
        XCTAssertEqual(reserve.getIntegerValueField(.eventSourceStateID), -24_681)
        XCTAssertEqual(reserve.getIntegerValueField(.mouseEventNumber),
                       down.getIntegerValueField(.mouseEventNumber))
        assertLeftSingleClick(reserve)
        XCTAssertEqual(effects.clockReads, 1)
        XCTAssertEqual(effects.flagReads, 1)
        XCTAssertEqual(effects.flagSourceIDs, [-24_681])
        XCTAssertEqual(effects.createdEvents.count, 2)
        XCTAssertEqual(sink.tryPostMouseUp(at: downPoint), .noPendingMouseDown)
        XCTAssertEqual(sink.tryPostMouseDragged(to: downPoint), .noPendingMouseDown)
        XCTAssertEqual(effects.posts.count, 2)
        XCTAssertEqual(effects.requests.count, 3, "Release must not retry construction or copy an event.")
        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .constructionFailed)
        XCTAssertEqual(effects.posts.count, 2)
    }

    func testSecondDownIsBusyAndCannotReplacePendingRelease() {
        let effects = MockMouseEnvironment()
        let sink = effects.makeSink()
        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .postInvoked)

        XCTAssertEqual(sink.tryPostMouseDown(at: releasePoint), .busy)
        XCTAssertEqual(effects.requests.count, 2)
        XCTAssertEqual(effects.posts.count, 1)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .postInvoked)
        XCTAssertEqual(effects.posts.count, 2)
    }

    func testReentrantCallsAreBusyDuringReserveDownConstructionAndDownPosting() {
        for phase in ["make:1", "make:2", "post:1"] {
            let effects = MockMouseEnvironment()
            let sink = effects.makeSink()
            var probes = 0
            effects.onEffect = { observedPhase in
                guard observedPhase == phase else { return }
                probes += 1
                self.assertAllCallsBusy(sink)
            }

            XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .postInvoked, phase)
            XCTAssertEqual(probes, 1, phase)
            XCTAssertEqual(effects.requests.count, 2, phase)
            XCTAssertEqual(effects.posts.count, 1, phase)
            effects.onEffect = nil
            XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .postInvoked, phase)
            XCTAssertEqual(effects.posts.count, 2, phase)
        }
    }

    func testReentrantCallsAreBusyThroughoutFreshAndFallbackRelease() {
        let scenarios: [(fallback: Bool, phase: String)] = [
            (false, "make:3"), (false, "post:2"),
            (true, "make:3"), (true, "clock"), (true, "flags"), (true, "post:2")
        ]
        for scenario in scenarios {
            let effects = MockMouseEnvironment()
            if scenario.fallback { effects.failedFactoryCalls = [3] }
            let sink = effects.makeSink()
            XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .postInvoked)
            var probes = 0
            effects.onEffect = { observedPhase in
                guard observedPhase == scenario.phase else { return }
                probes += 1
                self.assertAllCallsBusy(sink)
            }

            XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .postInvoked, scenario.phase)
            XCTAssertEqual(probes, 1, scenario.phase)
            XCTAssertEqual(effects.requests.count, 3, scenario.phase)
            XCTAssertEqual(effects.posts.count, 2, scenario.phase)
            effects.onEffect = nil
            XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .noPendingMouseDown)
            XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .postInvoked,
                           "A later press becomes available only after release returns.")
        }
    }

    func testFailedDragRetainsReserveForLaterReleaseDespiteContinuingFactoryFailure() {
        let effects = MockMouseEnvironment()
        effects.failFactoryFromCall = 3
        let sink = effects.makeSink()
        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .postInvoked)

        XCTAssertEqual(sink.tryPostMouseDragged(to: CGPoint(x: 222, y: 333)), .constructionFailed)
        XCTAssertEqual(effects.posts.count, 1)
        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .busy)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .postInvoked)
        XCTAssertEqual(effects.posts.count, 2)
        guard effects.posts.count == 2 else { return }
        XCTAssertTrue(effects.posts[1].event === effects.createdEvents[0])
        XCTAssertEqual(effects.posts[1].event.location, releasePoint)
        XCTAssertEqual(effects.requests.map(\.type),
                       [.leftMouseUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp])
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .noPendingMouseDown)
    }

    func testDiscardingPosterReportsOnlyInvocationAndConsumesRelease() {
        let effects = MockMouseEnvironment()
        effects.discardPosts = true
        let sink = effects.makeSink()

        // The fake poster deliberately provides no delivery acknowledgement.
        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseDragged(to: releasePoint), .postInvoked)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .postInvoked)
        XCTAssertEqual(effects.postInvocations, 3)
        XCTAssertTrue(effects.posts.isEmpty)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .noPendingMouseDown)
        XCTAssertEqual(effects.postInvocations, 3)
    }

    func testLegacyVoidMethodsPreserveNilSourceUnpairedAndRepeatedSingleEventCalls() {
        let effects = MockMouseEnvironment()
        effects.sourceStateID = nil
        let sink = effects.makeSink()
        sink.postMouseUp(at: releasePoint)
        sink.postMouseDragged(to: releasePoint)
        sink.postMouseDown(at: downPoint)
        sink.postMouseDown(at: downPoint)
        sink.postMouseUp(at: releasePoint)
        XCTAssertEqual(effects.requests.map(\.type),
                       [.leftMouseUp, .leftMouseDragged, .leftMouseDown, .leftMouseDown, .leftMouseUp])
        XCTAssertEqual(effects.posts.map { $0.event.type }, effects.requests.map(\.type))
        XCTAssertEqual(effects.posts.map { $0.event.getIntegerValueField(.mouseEventNumber) },
                       [4_001, 4_002, 4_003, 4_004, 4_005])
        XCTAssertEqual(effects.posts.map { $0.event.timestamp }, [100, 100, 100, 100, 100])
        XCTAssertEqual(effects.clockReads, 0)
        XCTAssertEqual(effects.flagReads, 0)
        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .sourceUnavailable,
                       "Nil is supported by raw calls, not the managed release guarantee")
    }

    func testLegacyConstructionFailurePostsNothingAndDoesNotReserveOrRetry() {
        let effects = MockMouseEnvironment()
        effects.failedFactoryCalls = [1]
        let sink = effects.makeSink()
        sink.postMouseDown(at: downPoint)
        XCTAssertEqual(effects.requests.map(\.type), [.leftMouseDown])
        XCTAssertTrue(effects.posts.isEmpty)
        sink.postMouseUp(at: releasePoint)
        XCTAssertEqual(effects.requests.map(\.type), [.leftMouseDown, .leftMouseUp])
        XCTAssertEqual(effects.posts.map { $0.event.type }, [.leftMouseUp])
    }

    func testLegacyCallsCannotInterleaveWithAnOwnedManagedPress() {
        let effects = MockMouseEnvironment()
        let sink = effects.makeSink()
        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .postInvoked)
        sink.postMouseDown(at: releasePoint)
        sink.postMouseUp(at: releasePoint)
        sink.postMouseDragged(to: releasePoint)
        XCTAssertEqual(effects.posts.count, 1)
        XCTAssertEqual(effects.requests.count, 2)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .postInvoked)
        XCTAssertEqual(effects.posts.map { $0.event.type }, [.leftMouseDown, .leftMouseUp])
    }

    private func assertAllCallsBusy(_ sink: CGEventInputSink,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(sink.tryPostMouseDown(at: downPoint), .busy, file: file, line: line)
        XCTAssertEqual(sink.tryPostMouseUp(at: releasePoint), .busy, file: file, line: line)
        XCTAssertEqual(sink.tryPostMouseDragged(to: releasePoint), .busy, file: file, line: line)
    }

    private func assertLeftSingleClick(_ event: MouseInputEvent,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber),
                       Int64(CGMouseButton.left.rawValue), file: file, line: line)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 1, file: file, line: line)
    }
}

private final class MockMouseEvent: MouseInputEvent {
    var type: CGEventType
    var location: CGPoint
    var timestamp: CGEventTimestamp = 100
    var flags: CGEventFlags = [.maskAlphaShift]
    private var fields: [CGEventField: Int64] = [:]

    init(type: CGEventType, point: CGPoint, sourceStateID: Int64) {
        self.type = type
        location = point
        fields[.eventSourceStateID] = sourceStateID
        fields[.mouseEventNumber] = 77
        fields[.mouseEventButtonNumber] = Int64(CGMouseButton.right.rawValue)
        fields[.mouseEventClickState] = 0
    }

    func getIntegerValueField(_ field: CGEventField) -> Int64 { fields[field, default: 0] }
    func setIntegerValueField(_ field: CGEventField, value: Int64) { fields[field] = value }
}

private final class MockMouseEnvironment {
    struct Request {
        let type: CGEventType
        let point: CGPoint
    }

    struct Post {
        let event: MouseInputEvent
        let tap: CGEventTapLocation
    }

    var sourceStateID: Int64? = -42
    var failedFactoryCalls: Set<Int> = []
    var failFactoryFromCall: Int?
    var factoryOverrides: [Int: MockMouseEvent] = [:]
    var nowNanoseconds: CGEventTimestamp = 5_000_000_001
    var currentFlags: CGEventFlags = []
    var discardPosts = false
    var onEffect: ((String) -> Void)?
    private(set) var requests: [Request] = []
    private(set) var createdEvents: [MockMouseEvent] = []
    private(set) var posts: [Post] = []
    private(set) var postInvocations = 0
    private(set) var clockReads = 0
    private(set) var flagReads = 0
    private(set) var flagSourceIDs: [Int64?] = []

    func makeSink(eventTap: CGEventTapLocation? = nil) -> CGEventInputSink {
        let explicitSourceID = sourceStateID
        let environment = MouseInputEnvironment(
            makeEvent: { type, point in
                self.requests.append(Request(type: type, point: point))
                let call = self.requests.count
                self.onEffect?("make:\(call)")
                if self.failedFactoryCalls.contains(call) { return nil }
                if let firstFailure = self.failFactoryFromCall, call >= firstFailure { return nil }
                let event: MockMouseEvent
                if let override = self.factoryOverrides[call] {
                    event = override
                } else {
                    event = MockMouseEvent(type: type, point: point, sourceStateID: explicitSourceID ?? 0)
                    event.setIntegerValueField(.mouseEventNumber, value: Int64(4_000 + call))
                }
                self.createdEvents.append(event)
                return event
            },
            post: { event, tap in
                self.postInvocations += 1
                if !self.discardPosts { self.posts.append(Post(event: event, tap: tap)) }
                self.onEffect?("post:\(self.postInvocations)")
            },
            timestamp: {
                self.clockReads += 1
                self.onEffect?("clock")
                return self.nowNanoseconds
            },
            sourceStateID: explicitSourceID,
            flags: {
                self.flagReads += 1
                self.flagSourceIDs.append(explicitSourceID)
                self.onEffect?("flags")
                return self.currentFlags
            }
        )
        if let eventTap { return CGEventInputSink(environment: environment, eventTap: eventTap) }
        return CGEventInputSink(environment: environment)
    }
}
