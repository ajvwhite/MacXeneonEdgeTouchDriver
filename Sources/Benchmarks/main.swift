import Foundation
import MacXeneonEdgeTouchDriverCore

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments.first == "--timers" {
        let samples: Int
        if arguments.count == 1 { samples = 100 }
        else if arguments.count == 3, arguments[1] == "--samples",
                let value = Int(arguments[2]), (1...1000).contains(value) { samples = value }
        else {
            FileHandle.standardError.write(Data("Usage: Benchmarks --timers [--samples 1..1000]\n".utf8))
            exit(64)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(DriverSchedulingProbe.run(iterations: samples)))
        FileHandle.standardOutput.write(Data([10]))
        exit(0)
    }
    let records: [HIDReportTraceRecord]
    if arguments.count == 2, arguments[0] == "--trace" {
        let url = URL(fileURLWithPath: arguments[1])
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024 else { throw TouchPipelineReplay.ReplayError.oversizedTrace }
        let data = try Data(contentsOf: url)
        guard data.count <= 16 * 1024 * 1024 else { throw TouchPipelineReplay.ReplayError.oversizedTrace }
        records = try data.split(separator: 10).map { try JSONDecoder().decode(HIDReportTraceRecord.self, from: Data($0)) }
    } else if arguments == ["--backlog"] {
        var generated: [HIDReportTraceRecord] = []
        for contact in 0..<1000 {
            let base = UInt64(contact) * 150_000_000
            for index in 0..<24 {
                let offset = index == 0 ? 0 : index == 1 ? 8 : 20 + (index - 2) * 2
                let x = UInt16(5000 + max(0, index - 1) * 20)
                generated.append(HIDReportTraceRecord(sourceID: 1,
                    timestampNanoseconds: base + UInt64(offset) * 1_000_000,
                    bytes: [7, index == 23 ? 0 : 1, UInt8(x & 255), UInt8(x >> 8), 184, 11, 0],
                    deliveryTimestampNanoseconds: base + 100_000_000))
            }
        }
        records = generated
    } else if arguments.isEmpty {
        // Repeatable healthy taps.
        var generated: [HIDReportTraceRecord] = []
        for tap in 0..<1000 {
            let base = UInt64(tap) * 150_000_000
            for (offset, pressed) in [(UInt64(0), true), (8_000_000, true), (16_000_000, false)] {
                generated.append(HIDReportTraceRecord(sourceID: 1, timestampNanoseconds: base + offset,
                    bytes: [7, pressed ? 1 : 0, 9, 33, 13, 23, 0]))
            }
        }
        records = generated
    } else {
        FileHandle.standardError.write(Data("Usage: Benchmarks [--trace recording.jsonl | --backlog | --timers [--samples 1..1000]]\n".utf8))
        exit(64)
    }
    let report = try TouchPipelineReplay.run(records)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data([10]))
    if !report.finalInputBalanced { exit(1) }
} catch {
    FileHandle.standardError.write(Data("Benchmark failed: \(error)\n".utf8))
    exit(1)
}
