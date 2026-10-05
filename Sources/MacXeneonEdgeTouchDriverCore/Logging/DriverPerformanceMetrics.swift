import Foundation

/// Opt-in timing samples contain durations and counts, never text or coordinates.
/// Percentiles describe the retained recent window; total counts cover the run.
public final class DriverPerformanceMetrics: @unchecked Sendable {
    public struct Distribution: Codable, Equatable {
        public let count: UInt64
        public let retainedSamples: Int
        public let p50Milliseconds: Double
        public let p95Milliseconds: Double
        public let p99Milliseconds: Double
    }
    public struct Snapshot: Codable {
        public let timings: [String: Distribution]
        public let counters: [String: UInt64]
    }
    private struct Samples {
        var total: UInt64 = 0
        var next = 0
        var values: [UInt64] = []
    }
    private let lock = NSLock()
    private let capacity: Int
    private var timings: [String: Samples] = [:]
    private var counters: [String: UInt64] = [:]

    public init(capacity: Int = 1024) { self.capacity = min(16384, max(1, capacity)) }

    func record(_ name: String, from start: UInt64, to end: UInt64) {
        guard end >= start else { return }
        lock.lock(); defer { lock.unlock() }
        var samples = timings[name] ?? Samples()
        samples.total += 1
        if samples.values.count < capacity { samples.values.append(end - start) }
        else { samples.values[samples.next] = end - start }
        samples.next = (samples.next + 1) % capacity
        timings[name] = samples
    }

    func increment(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        counters[name, default: 0] += 1
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        let copiedTimings = timings
        let copiedCounters = counters
        lock.unlock()
        let result: [String: Distribution] = copiedTimings.mapValues { (samples: Samples) -> Distribution in
            let ordered = samples.values.sorted()
            func percentile(_ p: Double) -> Double {
                guard !ordered.isEmpty else { return 0 }
                let index = min(ordered.count - 1, max(0, Int(ceil(Double(ordered.count) * p)) - 1))
                return Double(ordered[index]) / 1_000_000
            }
            return Distribution(count: samples.total, retainedSamples: ordered.count,
                p50Milliseconds: percentile(0.50), p95Milliseconds: percentile(0.95),
                p99Milliseconds: percentile(0.99))
        }
        return Snapshot(timings: result, counters: copiedCounters)
    }

    func logSummary() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(snapshot()), let text = String(data: data, encoding: .utf8) {
            DriverLoggers.log(.notice, category: .lifecycle, "Performance samples (posting is not delivery): \(text)")
        }
    }
}
