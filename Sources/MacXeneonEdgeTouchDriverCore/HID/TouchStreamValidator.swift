import Foundation

/// Validates healthy contacts and extracts coherent finger tracks from a mixed storm stream.
public final class TouchStreamValidator {
    public enum StormTrigger: String, Equatable {
        case severeCoordinateJump = "severe coordinate jump"
        case repeatedFastSegments = "repeated implausibly fast segments"
        case chaoticProbationPath = "chaotic probation path"
        case overlappingContact = "overlapping contact transition"
    }

    public struct Configuration: Equatable {
        public var probationNanoseconds: UInt64
        public var fastNormalizedSpeed: Double
        public var severeNormalizedSpeed: Double
        public var maximumProbationPathSpeed: Double
        public var minimumChaoticPathLength: Double
        public var maximumChaoticNetRatio: Double
        public var stormAcquisitionWindowNanoseconds: UInt64
        public var stormMinimumAcquisitionSpanNanoseconds: UInt64
        public var stormMaximumTrackingGapNanoseconds: UInt64
        public var stormRequiredSamples: Int
        public var stormMaximumRecentSamples: Int
        public var stormBaseNormalizedRadius: Double
        public var stormMaximumNormalizedSpeed: Double
        public var stormMaximumNormalizedGate: Double
        public var stormMinimumPathNetRatio: Double

        public static let defaults = Configuration(
            probationNanoseconds: 40_000_000,
            fastNormalizedSpeed: 10,
            severeNormalizedSpeed: 18,
            maximumProbationPathSpeed: 12,
            minimumChaoticPathLength: 0.20,
            maximumChaoticNetRatio: 0.45,
            stormAcquisitionWindowNanoseconds: 120_000_000,
            stormMinimumAcquisitionSpanNanoseconds: 20_000_000,
            stormMaximumTrackingGapNanoseconds: 120_000_000,
            stormRequiredSamples: 4,
            stormMaximumRecentSamples: 16,
            stormBaseNormalizedRadius: 0.012,
            stormMaximumNormalizedSpeed: 7,
            stormMaximumNormalizedGate: 0.12,
            stormMinimumPathNetRatio: 0.55
        )

        public init(
            probationNanoseconds: UInt64,
            fastNormalizedSpeed: Double,
            severeNormalizedSpeed: Double,
            maximumProbationPathSpeed: Double,
            minimumChaoticPathLength: Double,
            maximumChaoticNetRatio: Double,
            stormAcquisitionWindowNanoseconds: UInt64,
            stormMinimumAcquisitionSpanNanoseconds: UInt64,
            stormMaximumTrackingGapNanoseconds: UInt64,
            stormRequiredSamples: Int,
            stormMaximumRecentSamples: Int,
            stormBaseNormalizedRadius: Double,
            stormMaximumNormalizedSpeed: Double,
            stormMaximumNormalizedGate: Double,
            stormMinimumPathNetRatio: Double
        ) {
            self.probationNanoseconds = probationNanoseconds
            self.fastNormalizedSpeed = fastNormalizedSpeed
            self.severeNormalizedSpeed = severeNormalizedSpeed
            self.maximumProbationPathSpeed = maximumProbationPathSpeed
            self.minimumChaoticPathLength = minimumChaoticPathLength
            self.maximumChaoticNetRatio = maximumChaoticNetRatio
            self.stormAcquisitionWindowNanoseconds = stormAcquisitionWindowNanoseconds
            self.stormMinimumAcquisitionSpanNanoseconds = stormMinimumAcquisitionSpanNanoseconds
            self.stormMaximumTrackingGapNanoseconds = stormMaximumTrackingGapNanoseconds
            self.stormRequiredSamples = stormRequiredSamples
            self.stormMaximumRecentSamples = stormMaximumRecentSamples
            self.stormBaseNormalizedRadius = stormBaseNormalizedRadius
            self.stormMaximumNormalizedSpeed = stormMaximumNormalizedSpeed
            self.stormMaximumNormalizedGate = stormMaximumNormalizedGate
            self.stormMinimumPathNetRatio = stormMinimumPathNetRatio
        }
    }

    public struct Result: Equatable {
        public let events: [TouchEvent]
        public let rejectedStream: Bool
        public let stormStarted: StormTrigger?
        public let cancelActiveGesture: Bool

        public init(
            events: [TouchEvent] = [],
            rejectedStream: Bool = false,
            stormStarted: StormTrigger? = nil,
            cancelActiveGesture: Bool = false
        ) {
            self.events = events
            self.rejectedStream = rejectedStream
            self.stormStarted = stormStarted
            self.cancelActiveGesture = cancelActiveGesture
        }
    }

    public struct StormSnapshot: Equatable {
        public let startedAtNanoseconds: UInt64
        public let lastReportAtNanoseconds: UInt64
        public let totalReports: Int
        public let acceptedSamples: Int
        public let droppedSamples: Int
        public let recoveredContacts: Int
        public let hasAcquiredTrack: Bool
    }

    public struct StormRecovery: Equatable {
        public let snapshot: StormSnapshot
        public let confirmedAtNanoseconds: UInt64
        public let cancelActiveGesture: Bool
    }

    private struct Candidate {
        let down: TouchEvent
        var last: TouchEvent
        var moves: [TouchEvent] = []
        var pathLength = 0.0
        var fastSegmentCount = 0
    }

    private struct Accepted {
        var last: TouchEvent
        var pendingFastMove: TouchEvent?
    }

    private enum NormalState {
        case idle
        case candidate(Candidate)
        case accepted(Accepted)
    }

    private struct StormTrack {
        var lastInlier: TouchEvent
    }

    private struct StormState {
        let startedAtNanoseconds: UInt64
        var lastReportAtNanoseconds: UInt64
        var totalReports: Int
        var acceptedSamples = 0
        var droppedSamples = 0
        var recoveredContacts = 0
        var recentPressedSamples: [TouchEvent] = []
        var track: StormTrack?
    }

    private enum State {
        case normal(NormalState)
        case storm(StormState)
    }

    private let configuration: Configuration
    private var state: State = .normal(.idle)

    public init(configuration: Configuration = .defaults) {
        self.configuration = configuration
    }

    public var isStormActive: Bool {
        if case .storm = state { return true }
        return false
    }

    public func reset() {
        state = .normal(.idle)
    }

    /// Records a valid raw HID report that did not create a lifecycle event.
    public func recordRawReport(at timestamp: DispatchTime) {
        noteRawReport(at: timestamp)
    }

    public func process(_ event: TouchEvent) -> Result {
        noteRawReport(at: event.timestamp)

        switch state {
        case .normal(let normal):
            return processNormal(event, state: normal)
        case .storm(var storm):
            let result = processStorm(event, state: &storm)
            state = .storm(storm)
            return result
        }
    }

    public func stormSnapshot() -> StormSnapshot? {
        guard case .storm(let storm) = state else { return nil }
        return snapshot(for: storm)
    }

    /// Returns to normal mode only after the complete raw report stream has been quiet.
    public func recoverIfQuiet(
        at timestamp: DispatchTime,
        quietNanoseconds: UInt64 = 1_000_000_000
    ) -> StormRecovery? {
        guard case .storm(let storm) = state else { return nil }
        let now = timestamp.uptimeNanoseconds
        guard elapsedNanoseconds(from: storm.lastReportAtNanoseconds, to: now) >= quietNanoseconds else {
            return nil
        }

        let recovery = StormRecovery(
            snapshot: snapshot(for: storm),
            confirmedAtNanoseconds: now,
            cancelActiveGesture: storm.track != nil
        )
        state = .normal(.idle)
        return recovery
    }

    private func noteRawReport(at timestamp: DispatchTime) {
        guard case .storm(var storm) = state else { return }
        storm.lastReportAtNanoseconds = timestamp.uptimeNanoseconds
        storm.totalReports += 1
        state = .storm(storm)
    }

    private func processNormal(_ event: TouchEvent, state normal: NormalState) -> Result {
        switch normal {
        case .idle:
            guard event.kind != .up else { return Result() }
            // The HID parser may still consider the raw contact pressed when a
            // storm ends. Treat its next pressed sample as a fresh candidate.
            let down = eventWithKind(event, .down)
            state = .normal(.candidate(Candidate(down: down, last: down)))
            return Result()

        case .candidate(var candidate):
            switch event.kind {
            case .down:
                return beginStorm(trigger: .overlappingContact, at: event, cancelActiveGesture: false)

            case .move:
                let speed = normalizedSpeed(from: candidate.last, to: event)
                candidate.pathLength += normalizedDistance(from: candidate.last, to: event)
                candidate.last = event
                candidate.moves.append(event)
                if speed >= configuration.fastNormalizedSpeed {
                    candidate.fastSegmentCount += 1
                }
                if speed >= configuration.severeNormalizedSpeed {
                    return beginStorm(trigger: .severeCoordinateJump, at: event, cancelActiveGesture: false)
                }
                if candidate.fastSegmentCount >= 2 {
                    return beginStorm(trigger: .repeatedFastSegments, at: event, cancelActiveGesture: false)
                }

                let elapsed = elapsedNanoseconds(from: candidate.down, to: event)
                guard elapsed >= configuration.probationNanoseconds else {
                    state = .normal(.candidate(candidate))
                    return Result()
                }
                guard probationIsPlausible(candidate, elapsedNanoseconds: elapsed) else {
                    return beginStorm(trigger: .chaoticProbationPath, at: event, cancelActiveGesture: false)
                }

                state = .normal(.accepted(Accepted(last: event)))
                return Result(events: [candidate.down] + meaningfulMoves(candidate.moves, after: candidate.down))

            case .up:
                let releaseSpeed = normalizedSpeed(from: candidate.last, to: event)
                if releaseSpeed >= configuration.severeNormalizedSpeed {
                    return beginStorm(trigger: .severeCoordinateJump, at: event, cancelActiveGesture: false)
                }
                let elapsed = elapsedNanoseconds(from: candidate.down, to: event)
                guard candidate.fastSegmentCount == 0,
                      probationIsPlausible(candidate, elapsedNanoseconds: elapsed) else {
                    return beginStorm(trigger: .chaoticProbationPath, at: event, cancelActiveGesture: false)
                }
                state = .normal(.idle)
                let up = eventAtCoordinates(event, of: candidate.last, kind: .up)
                return Result(events: [candidate.down] + meaningfulMoves(candidate.moves, after: candidate.down) + [up])
            }

        case .accepted(var accepted):
            switch event.kind {
            case .down:
                return beginStorm(trigger: .overlappingContact, at: event, cancelActiveGesture: true)

            case .move:
                let speed = normalizedSpeed(from: accepted.last, to: event)
                if speed >= configuration.severeNormalizedSpeed ||
                    (speed >= configuration.fastNormalizedSpeed && accepted.pendingFastMove != nil) {
                    let trigger: StormTrigger = speed >= configuration.severeNormalizedSpeed
                        ? .severeCoordinateJump
                        : .repeatedFastSegments
                    return beginStorm(trigger: trigger, at: event, cancelActiveGesture: true)
                }
                if speed >= configuration.fastNormalizedSpeed {
                    accepted.pendingFastMove = event
                    state = .normal(.accepted(accepted))
                    return Result()
                }

                accepted.pendingFastMove = nil
                let moved = event.rawX != accepted.last.rawX || event.rawY != accepted.last.rawY
                accepted.last = event
                state = .normal(.accepted(accepted))
                return Result(events: moved ? [event] : [])

            case .up:
                let speed = normalizedSpeed(from: accepted.last, to: event)
                if speed >= configuration.severeNormalizedSpeed {
                    return beginStorm(trigger: .severeCoordinateJump, at: event, cancelActiveGesture: true)
                }
                let last = accepted.last
                state = .normal(.idle)
                return Result(events: [eventAtCoordinates(event, of: last, kind: .up)])
            }
        }
    }

    private func beginStorm(
        trigger: StormTrigger,
        at event: TouchEvent,
        cancelActiveGesture: Bool
    ) -> Result {
        let timestamp = event.timestamp.uptimeNanoseconds
        state = .storm(StormState(
            startedAtNanoseconds: timestamp,
            lastReportAtNanoseconds: timestamp,
            totalReports: 1
        ))
        return Result(
            rejectedStream: true,
            stormStarted: trigger,
            cancelActiveGesture: cancelActiveGesture
        )
    }

    private func processStorm(_ event: TouchEvent, state storm: inout StormState) -> Result {
        if var track = storm.track {
            if event.kind == .up, trackingStepIsPlausible(from: track.lastInlier, to: event) {
                storm.acceptedSamples += 1
                storm.recoveredContacts += 1
                storm.track = nil
                storm.recentPressedSamples.removeAll(keepingCapacity: true)
                return Result(events: [eventAtCoordinates(event, of: track.lastInlier, kind: .up)])
            }

            if event.kind != .up, trackingStepIsPlausible(from: track.lastInlier, to: event) {
                let moved = event.rawX != track.lastInlier.rawX || event.rawY != track.lastInlier.rawY
                track.lastInlier = event
                storm.track = track
                storm.acceptedSamples += 1
                return Result(events: moved ? [eventWithKind(event, .move)] : [])
            }

            storm.droppedSamples += 1
            let gap = elapsedNanoseconds(from: track.lastInlier, to: event)
            guard gap >= configuration.stormMaximumTrackingGapNanoseconds else {
                return Result()
            }

            storm.track = nil
            storm.recentPressedSamples.removeAll(keepingCapacity: true)
            let acquisition = event.kind == .up ? Result() : considerStormCandidate(event, state: &storm)
            return Result(events: acquisition.events, cancelActiveGesture: true)
        }

        guard event.kind != .up else {
            storm.droppedSamples += 1
            return Result()
        }
        return considerStormCandidate(event, state: &storm)
    }

    private func considerStormCandidate(_ event: TouchEvent, state storm: inout StormState) -> Result {
        storm.recentPressedSamples.append(event)
        trimRecentSamples(state: &storm, now: event.timestamp.uptimeNanoseconds)

        guard let chain = bestPlausibleChain(in: storm.recentPressedSamples),
              chain.count >= configuration.stormRequiredSamples else {
            return Result()
        }

        let span = elapsedNanoseconds(from: chain[0], to: chain[chain.count - 1])
        guard span >= configuration.stormMinimumAcquisitionSpanNanoseconds,
              chainIsCoherent(chain) else {
            return Result()
        }

        storm.droppedSamples += max(0, storm.recentPressedSamples.count - chain.count)
        storm.acceptedSamples += chain.count
        storm.recentPressedSamples.removeAll(keepingCapacity: true)
        storm.track = StormTrack(lastInlier: chain[chain.count - 1])

        var output: [TouchEvent] = [eventWithKind(chain[0], .down)]
        var last = chain[0]
        for sample in chain.dropFirst() {
            guard sample.rawX != last.rawX || sample.rawY != last.rawY else {
                last = sample
                continue
            }
            output.append(eventWithKind(sample, .move))
            last = sample
        }
        return Result(events: output)
    }

    private func trimRecentSamples(state storm: inout StormState, now: UInt64) {
        let cutoff = now >= configuration.stormAcquisitionWindowNanoseconds
            ? now - configuration.stormAcquisitionWindowNanoseconds
            : 0
        let initialCount = storm.recentPressedSamples.count
        storm.recentPressedSamples.removeAll {
            $0.timestamp.uptimeNanoseconds < cutoff
        }
        if storm.recentPressedSamples.count > configuration.stormMaximumRecentSamples {
            storm.recentPressedSamples.removeFirst(
                storm.recentPressedSamples.count - configuration.stormMaximumRecentSamples
            )
        }
        storm.droppedSamples += initialCount - storm.recentPressedSamples.count
    }

    private func bestPlausibleChain(in samples: [TouchEvent]) -> [TouchEvent]? {
        guard !samples.isEmpty else { return nil }
        var lengths = Array(repeating: 1, count: samples.count)
        var predecessors = Array(repeating: -1, count: samples.count)

        for end in samples.indices {
            for start in samples.indices where start < end {
                guard trackingStepIsPlausible(from: samples[start], to: samples[end]) else { continue }
                if lengths[start] + 1 > lengths[end] {
                    lengths[end] = lengths[start] + 1
                    predecessors[end] = start
                }
            }
        }

        guard let bestEnd = lengths.indices.max(by: { lengths[$0] < lengths[$1] }) else { return nil }
        var indices: [Int] = []
        var cursor = bestEnd
        while cursor >= 0 {
            indices.append(cursor)
            cursor = predecessors[cursor]
        }
        return indices.reversed().map { samples[$0] }
    }

    private func chainIsCoherent(_ chain: [TouchEvent]) -> Bool {
        guard chain.count > 1 else { return false }
        var pathLength = 0.0
        for index in 1..<chain.count {
            pathLength += normalizedDistance(from: chain[index - 1], to: chain[index])
        }
        guard pathLength > configuration.stormBaseNormalizedRadius else { return true }
        let netDistance = normalizedDistance(from: chain[0], to: chain[chain.count - 1])
        return netDistance / pathLength >= configuration.stormMinimumPathNetRatio
    }

    private func trackingStepIsPlausible(from start: TouchEvent, to end: TouchEvent) -> Bool {
        let elapsed = elapsedNanoseconds(from: start, to: end)
        guard elapsed > 0, elapsed <= configuration.stormMaximumTrackingGapNanoseconds else { return false }
        let seconds = Double(elapsed) / 1_000_000_000
        let gate = min(
            configuration.stormMaximumNormalizedGate,
            configuration.stormBaseNormalizedRadius + configuration.stormMaximumNormalizedSpeed * seconds
        )
        return normalizedDistance(from: start, to: end) <= gate
    }

    private func meaningfulMoves(_ moves: [TouchEvent], after initial: TouchEvent) -> [TouchEvent] {
        var last = initial
        return moves.compactMap { move in
            defer { last = move }
            guard move.rawX != last.rawX || move.rawY != last.rawY else { return nil }
            return eventWithKind(move, .move)
        }
    }

    private func probationIsPlausible(_ candidate: Candidate, elapsedNanoseconds: UInt64) -> Bool {
        guard candidate.moves.isEmpty == false else { return true }
        let elapsedSeconds = max(Double(elapsedNanoseconds) / 1_000_000_000, 0.000_001)
        if candidate.pathLength / elapsedSeconds > configuration.maximumProbationPathSpeed {
            return false
        }
        let netDistance = normalizedDistance(from: candidate.down, to: candidate.last)
        if candidate.pathLength >= configuration.minimumChaoticPathLength,
           netDistance / candidate.pathLength < configuration.maximumChaoticNetRatio {
            return false
        }
        return true
    }

    private func snapshot(for storm: StormState) -> StormSnapshot {
        StormSnapshot(
            startedAtNanoseconds: storm.startedAtNanoseconds,
            lastReportAtNanoseconds: storm.lastReportAtNanoseconds,
            totalReports: storm.totalReports,
            acceptedSamples: storm.acceptedSamples,
            droppedSamples: storm.droppedSamples,
            recoveredContacts: storm.recoveredContacts,
            hasAcquiredTrack: storm.track != nil
        )
    }

    private func eventWithKind(_ event: TouchEvent, _ kind: TouchEvent.Kind) -> TouchEvent {
        TouchEvent(
            kind: kind,
            contactID: event.contactID,
            rawX: event.rawX,
            rawY: event.rawY,
            timestamp: event.timestamp
        )
    }

    private func eventAtCoordinates(
        _ event: TouchEvent,
        of coordinates: TouchEvent,
        kind: TouchEvent.Kind
    ) -> TouchEvent {
        TouchEvent(
            kind: kind,
            contactID: event.contactID,
            rawX: coordinates.rawX,
            rawY: coordinates.rawY,
            timestamp: event.timestamp
        )
    }

    private func normalizedSpeed(from start: TouchEvent, to end: TouchEvent) -> Double {
        let elapsed = elapsedNanoseconds(from: start, to: end)
        guard elapsed > 0 else {
            return normalizedDistance(from: start, to: end) == 0 ? 0 : .infinity
        }
        return normalizedDistance(from: start, to: end) / (Double(elapsed) / 1_000_000_000)
    }

    private func normalizedDistance(from start: TouchEvent, to end: TouchEvent) -> Double {
        let width = Double(XeneonEdgeDevice.rawXRange.upperBound - XeneonEdgeDevice.rawXRange.lowerBound)
        let height = Double(XeneonEdgeDevice.rawYRange.upperBound - XeneonEdgeDevice.rawYRange.lowerBound)
        let deltaX = Double(end.rawX - start.rawX) / width
        let deltaY = Double(end.rawY - start.rawY) / height
        return hypot(deltaX, deltaY)
    }

    private func elapsedNanoseconds(from start: TouchEvent, to end: TouchEvent) -> UInt64 {
        elapsedNanoseconds(from: start.timestamp.uptimeNanoseconds, to: end.timestamp.uptimeNanoseconds)
    }

    private func elapsedNanoseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}
