import Foundation

/// Filters one USB report stream before it can acquire a gesture.
/// A coherent stream is evidence of a touch, not proof of a physical finger.
struct TouchStreamFilter {
    struct Result {
        var observations: [HIDTouchObservation] = []
        var cancelContact = false
        var enteredStorm = false
        var recoveredFromStorm = false
    }

    private struct Sample {
        let source: HIDSourceID
        let pressed: Bool
        let x: Int
        let y: Int
        let time: UInt64
        let rawEpoch: UInt64
    }
    private enum Mode { case normal, storm }
    private var mode: Mode = .normal
    private var candidate: [Sample] = []
    private var lastAccepted: Sample?
    private var lastReport: UInt64?
    private var source: HIDSourceID?
    private var epoch: UInt64 = 0
    private(set) var isStorming = false

    // Initial values require replay and physical qualification before release.
    private let candidateLimit = 16
    private let candidateWindow: UInt64 = 120_000_000
    private let trackingGap: UInt64 = 120_000_000
    private let quietInterval: UInt64 = 1_000_000_000

    var nextDeadline: UInt64? {
        if mode == .normal { return candidate.first.map { $0.time + candidateWindow } }
        guard let lastReport else { return nil }
        return min(lastReport + quietInterval, lastAccepted.map { $0.time + trackingGap } ?? UInt64.max)
    }

    mutating func process(_ observation: HIDTouchObservation) -> Result {
        guard let x = observation.rawX, let y = observation.rawY,
              XeneonEdgeDevice.rawXRange.contains(x), XeneonEdgeDevice.rawYRange.contains(y),
              source == nil || source == observation.sourceID else { return Result() }
        let time = observation.timestamp.uptimeNanoseconds
        guard lastReport == nil || time > lastReport! else { return Result() }
        var result = advance(to: time)
        source = observation.sourceID
        lastReport = time
        let sample = Sample(source: observation.sourceID, pressed: observation.isPressed,
                            x: x, y: y, time: time, rawEpoch: observation.contactEpoch)
        if mode == .storm {
            let accepted = processStorm(sample, result: &result)
            result.observations += accepted
            return result
        }
        if let previous = lastAccepted {
            guard sample.rawEpoch == previous.rawEpoch, plausible(previous, sample, speed: 12) else {
                enterStorm(result: &result)
                if sample.pressed { candidate = [sample] }
                return result
            }
            if sample.pressed {
                lastAccepted = sample
                result.observations.append(output(sample, kind: moved(previous, sample) ? .move : nil))
            } else {
                lastAccepted = nil
                result.observations.append(output(sample, kind: .up))
            }
            return result
        }
        guard let first = candidate.first else {
            if sample.pressed { candidate = [sample] }
            else { result.observations.append(output(sample, kind: nil)) }
            return result
        }
        guard sample.rawEpoch == first.rawEpoch, plausible(first, sample, speed: 12) else {
            candidate.removeAll(keepingCapacity: true)
            enterStorm(result: &result)
            if sample.pressed { candidate = [sample] }
            return result
        }
        // Two healthy reports confirm the initial touch. Short taps can use their
        // release as the second report; they do not need a movement sample.
        epoch += 1
        candidate.removeAll(keepingCapacity: true)
        result.observations.append(output(first, kind: .down))
        if sample.pressed {
            lastAccepted = sample
            result.observations.append(output(sample, kind: moved(first, sample) ? .move : nil))
        } else {
            result.observations.append(output(sample, kind: .up))
        }
        return result
    }

    /// Must also run from a timer. Noise, silence and idle reports cannot extend
    /// an acquired storm contact beyond its last accepted sample's deadline.
    mutating func advance(to now: UInt64) -> Result {
        var result = Result()
        if mode == .normal {
            if let first = candidate.first, now >= first.time + candidateWindow {
                candidate.removeAll(keepingCapacity: true)
            }
            return result
        }
        if let accepted = lastAccepted, now >= accepted.time + trackingGap {
            lastAccepted = nil
            candidate.removeAll(keepingCapacity: true)
            result.cancelContact = true
        }
        if let lastReport, now >= lastReport + quietInterval {
            if lastAccepted != nil { result.cancelContact = true }
            lastAccepted = nil
            candidate.removeAll(keepingCapacity: true)
            mode = .normal
            isStorming = false
            result.recoveredFromStorm = true
        }
        return result
    }

    private mutating func enterStorm(result: inout Result) {
        result.cancelContact = lastAccepted != nil
        lastAccepted = nil
        candidate.removeAll(keepingCapacity: true)
        mode = .storm
        isStorming = true
        result.enteredStorm = true
    }

    private mutating func processStorm(_ sample: Sample, result: inout Result) -> [HIDTouchObservation] {
        if let previous = lastAccepted {
            if plausible(previous, sample, speed: 7) {
                if sample.pressed {
                    lastAccepted = sample
                    return [output(sample, kind: moved(previous, sample) ? .move : nil)]
                }
                lastAccepted = nil
                candidate.removeAll(keepingCapacity: true)
                // A plausible lift releases at the last trustworthy position.
                let release = Sample(source: sample.source, pressed: false, x: previous.x,
                                     y: previous.y, time: sample.time, rawEpoch: sample.rawEpoch)
                return [output(release, kind: .up)]
            }
            return []
        }
        guard sample.pressed else { return [] }
        candidate.removeAll { sample.time - $0.time >= candidateWindow }
        candidate.append(sample)
        if candidate.count > candidateLimit { candidate.removeFirst(candidate.count - candidateLimit) }
        let chain = coherentChain()
        guard chain.count >= 4, chain.count * 2 >= candidate.count,
              let first = chain.first, let last = chain.last,
              last.time - first.time >= 20_000_000 else { return [] }
        epoch += 1
        lastAccepted = last
        candidate.removeAll(keepingCapacity: true)
        var observations = [output(first, kind: .down)]
        var previous = first
        for sample in chain.dropFirst() {
            observations.append(output(sample, kind: moved(previous, sample) ? .move : nil))
            previous = sample
        }
        return observations
    }

    private func coherentChain() -> [Sample] {
        // Prefer a consistent velocity as well as proximity. A chain cannot be
        // assembled by selecting arbitrary zigzags from the noisy window.
        var chains: [[Sample]] = []
        for start in candidate.indices {
            var chain = [candidate[start]]
            for index in candidate.indices where index > start {
                let next = candidate[index]
                guard let last = chain.last, plausible(last, next, speed: 7) else { continue }
                if chain.count >= 2 {
                    let before = chain[chain.count - 2]
                    let dx = Double(last.x - before.x) / 16_383
                    let dy = Double(last.y - before.y) / 9_599
                    let nx = Double(next.x - last.x) / 16_383
                    let ny = Double(next.y - last.y) / 9_599
                    // Allow stationary contacts and gentle changes of direction.
                    if hypot(dx, dy) > 0.012, hypot(nx, ny) > 0.012,
                       dx * nx + dy * ny < 0 { continue }
                }
                chain.append(next)
            }
            chains.append(chain)
        }
        guard let best = chains.max(by: { $0.count < $1.count }),
              let first = best.first, let last = best.last else { return [] }
        // Repeated noise can form more than one plausible track. Never choose
        // one merely because it has one extra report or was enumerated first.
        for other in chains where other.count >= 3 {
            guard let start = other.first, let end = other.last,
                  end.time - start.time >= 16_000_000 else { continue }
            let startDistance = hypot(Double(start.x - first.x) / 16_383,
                                      Double(start.y - first.y) / 9_599)
            let endDistance = hypot(Double(end.x - last.x) / 16_383,
                                    Double(end.y - last.y) / 9_599)
            if startDistance > 0.025 && endDistance > 0.025 { return [] }
        }
        var length = 0.0
        for (a, b) in zip(best, best.dropFirst()) {
            length += hypot(Double(b.x - a.x) / 16_383, Double(b.y - a.y) / 9_599)
        }
        let net = hypot(Double(last.x - first.x) / 16_383, Double(last.y - first.y) / 9_599)
        // Acquiring a moving finger requires a directed initial segment, not a
        // looping chain selected from unrelated points. Once acquired, a finger
        // can turn normally; proximity and the independent expiry guard it.
        guard length <= 0.025 || net / length >= 0.85 else { return [] }
        return best
    }

    private func plausible(_ a: Sample, _ b: Sample, speed: Double) -> Bool {
        guard b.time > a.time else { return false }
        let seconds = Double(b.time - a.time) / 1_000_000_000
        let distance = hypot(Double(b.x - a.x) / 16_383, Double(b.y - a.y) / 9_599)
        return distance <= min(0.12, 0.012 + speed * seconds)
    }

    private func moved(_ a: Sample, _ b: Sample) -> Bool { a.x != b.x || a.y != b.y }

    private func output(_ sample: Sample, kind: TouchEvent.Kind?) -> HIDTouchObservation {
        HIDTouchObservation(sourceID: sample.source, contactEpoch: epoch, isPressed: sample.pressed,
            timestamp: DispatchTime(uptimeNanoseconds: sample.time),
            event: kind.map { TouchEvent(kind: $0, contactID: 0, rawX: sample.x, rawY: sample.y,
                                        timestamp: DispatchTime(uptimeNanoseconds: sample.time)) },
            rawX: sample.x, rawY: sample.y)
    }
}
