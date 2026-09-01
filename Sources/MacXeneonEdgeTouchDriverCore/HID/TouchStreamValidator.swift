import Foundation

/// Rejects physically implausible single-touch motion before it reaches gesture synthesis.
///
/// The controller reports at roughly 120 Hz. Real taps remain stationary and real drags
/// form a continuous path; the observed failure mode instead jumped across large portions
/// of the coordinate range between adjacent reports. Initial motion is held briefly so an
/// incoherent burst cannot begin scrolling before it is classified.
public final class TouchStreamValidator {
    public struct Configuration: Equatable {
        public var probationNanoseconds: UInt64
        public var suppressionQuietNanoseconds: UInt64
        public var fastNormalizedSpeed: Double
        public var severeNormalizedSpeed: Double
        public var maximumProbationPathSpeed: Double
        public var minimumChaoticPathLength: Double
        public var maximumChaoticNetRatio: Double

        public static let defaults = Configuration(
            probationNanoseconds: 40_000_000,
            suppressionQuietNanoseconds: 250_000_000,
            fastNormalizedSpeed: 10,
            severeNormalizedSpeed: 18,
            maximumProbationPathSpeed: 12,
            minimumChaoticPathLength: 0.20,
            maximumChaoticNetRatio: 0.45
        )

        public init(
            probationNanoseconds: UInt64,
            suppressionQuietNanoseconds: UInt64,
            fastNormalizedSpeed: Double,
            severeNormalizedSpeed: Double,
            maximumProbationPathSpeed: Double,
            minimumChaoticPathLength: Double,
            maximumChaoticNetRatio: Double
        ) {
            self.probationNanoseconds = probationNanoseconds
            self.suppressionQuietNanoseconds = suppressionQuietNanoseconds
            self.fastNormalizedSpeed = fastNormalizedSpeed
            self.severeNormalizedSpeed = severeNormalizedSpeed
            self.maximumProbationPathSpeed = maximumProbationPathSpeed
            self.minimumChaoticPathLength = minimumChaoticPathLength
            self.maximumChaoticNetRatio = maximumChaoticNetRatio
        }
    }

    public struct Result: Equatable {
        public let events: [TouchEvent]
        public let rejectedStream: Bool

        public init(events: [TouchEvent] = [], rejectedStream: Bool = false) {
            self.events = events
            self.rejectedStream = rejectedStream
        }
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

    private enum State {
        case idle
        case candidate(Candidate)
        case accepted(Accepted)
        case suppressing(until: UInt64)
    }

    private let configuration: Configuration
    private var state: State = .idle

    public init(configuration: Configuration = .defaults) {
        self.configuration = configuration
    }

    public func reset() {
        state = .idle
    }

    public func process(_ event: TouchEvent) -> Result {
        switch state {
        case .idle:
            guard event.kind == .down else { return Result() }
            state = .candidate(Candidate(down: event, last: event))
            return Result(events: [event])

        case .candidate(var candidate):
            switch event.kind {
            case .down:
                return reject(at: event.timestamp)
            case .move:
                let speed = normalizedSpeed(from: candidate.last, to: event)
                candidate.pathLength += normalizedDistance(from: candidate.last, to: event)
                candidate.last = event
                candidate.moves.append(event)
                if speed >= configuration.fastNormalizedSpeed {
                    candidate.fastSegmentCount += 1
                }

                if speed >= configuration.severeNormalizedSpeed || candidate.fastSegmentCount >= 2 {
                    return reject(at: event.timestamp)
                }

                let elapsed = elapsedNanoseconds(from: candidate.down, to: event)
                guard elapsed >= configuration.probationNanoseconds else {
                    state = .candidate(candidate)
                    return Result()
                }
                guard probationIsPlausible(candidate, elapsedNanoseconds: elapsed) else {
                    return reject(at: event.timestamp)
                }

                state = .accepted(Accepted(last: event))
                return Result(events: candidate.moves)

            case .up:
                let elapsed = elapsedNanoseconds(from: candidate.down, to: event)
                if candidate.fastSegmentCount > 0 || !probationIsPlausible(candidate, elapsedNanoseconds: elapsed) {
                    return reject(at: event.timestamp)
                }
                state = .idle
                return Result(events: candidate.moves + [event])
            }

        case .accepted(var accepted):
            switch event.kind {
            case .down:
                return reject(at: event.timestamp)
            case .move:
                let speed = normalizedSpeed(from: accepted.last, to: event)
                if speed >= configuration.severeNormalizedSpeed ||
                    (speed >= configuration.fastNormalizedSpeed && accepted.pendingFastMove != nil) {
                    return reject(at: event.timestamp)
                }
                if speed >= configuration.fastNormalizedSpeed {
                    accepted.pendingFastMove = event
                    state = .accepted(accepted)
                    return Result()
                }

                accepted.pendingFastMove = nil
                accepted.last = event
                state = .accepted(accepted)
                return Result(events: [event])

            case .up:
                let sanitized = accepted.pendingFastMove == nil
                    ? event
                    : TouchEvent(
                        kind: .up,
                        contactID: event.contactID,
                        rawX: accepted.last.rawX,
                        rawY: accepted.last.rawY,
                        timestamp: event.timestamp
                    )
                state = .idle
                return Result(events: [sanitized])
            }

        case .suppressing(let until):
            let timestamp = event.timestamp.uptimeNanoseconds
            guard timestamp >= until, event.kind == .down else {
                state = .suppressing(until: adding(configuration.suppressionQuietNanoseconds, to: timestamp))
                return Result()
            }
            state = .candidate(Candidate(down: event, last: event))
            return Result(events: [event])
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

    private func reject(at timestamp: DispatchTime) -> Result {
        state = .suppressing(until: adding(
            configuration.suppressionQuietNanoseconds,
            to: timestamp.uptimeNanoseconds
        ))
        return Result(rejectedStream: true)
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
        let startValue = start.timestamp.uptimeNanoseconds
        let endValue = end.timestamp.uptimeNanoseconds
        return endValue >= startValue ? endValue - startValue : 0
    }

    private func adding(_ delta: UInt64, to value: UInt64) -> UInt64 {
        let (result, overflow) = value.addingReportingOverflow(delta)
        return overflow ? UInt64.max : result
    }
}
