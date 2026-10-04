import Foundation

/// A fail-closed entry gate for explicitly requested touch experiments.
/// Without an experimental option, the original startup closure runs unchanged.
public enum ExperimentalStartupGate {
    public static func run(arguments: [String], startLegacy: () -> Int32) -> Int32 {
        run(
            arguments: arguments,
            readConfiguration: readConfigurationFile,
            reportRejection: { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            },
            startLegacy: startLegacy
        )
    }

    static let maximumConfigurationBytes = 65_536
    static let rejectedConfigurationExitCode: Int32 = 78

    static func run(
        arguments: [String],
        readConfiguration: (String) throws -> Data,
        reportRejection: (String) -> Void,
        startLegacy: () -> Int32
    ) -> Int32 {
        switch evaluate(arguments: arguments, readConfiguration: readConfiguration) {
        case .legacy:
            return startLegacy()
        case .rejected(let diagnostic):
            reportRejection("Experimental configuration rejected: " + diagnostic)
            return rejectedConfigurationExitCode
        }
    }

    static func evaluate(
        arguments: [String],
        readConfiguration: (String) throws -> Data
    ) -> Decision {
        // Prior releases did not interpret arguments. Preserve that behavior for
        // unrelated arguments, but never treat a misspelled experiment as absent.
        guard arguments.contains(where: { $0.hasPrefix("--experimental") }) else {
            return .legacy
        }
        guard arguments.count == 2, arguments[0] == "--experimental-config",
              !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !arguments[1].hasPrefix("--") else {
            return .rejected("use exactly --experimental-config <path>; duplicate or unknown experimental options are not supported.")
        }

        let data: Data
        do {
            data = try readConfiguration(arguments[1])
        } catch {
            return .rejected("the explicitly selected file could not be read; no driver dependencies were initialized.")
        }
        guard !data.isEmpty, data.count <= maximumConfigurationBytes else {
            return .rejected("the file must contain 1...\(maximumConfigurationBytes) bytes of JSON.")
        }

        let configuration: ExperimentalConfiguration
        do {
            configuration = try ExperimentalConfiguration.decode(data)
        } catch {
            return .rejected("invalid versioned request (unknown or duplicate keys/features, unsupported values, and empty requests are rejected).")
        }

        // Enablement is only intent. Readiness is owned by reviewed code and
        // evidence, never by a user-editable verified:true field or feature flag.
        let reasons = configuration.features.map { feature in
            feature.rawValue + ": " + readiness(for: feature).reason
        }
        return .rejected("live dispatch is unavailable. " + reasons.joined(separator: "; ") + ". Pure models are for deterministic tests only.")
    }

    static func readiness(for feature: ExperimentalFeature) -> Readiness {
        switch feature {
        case .spatialDoubleClick:
            return .unavailable("requires a verified source lifecycle and bounded target-context contract")
        case .twoFingerScroll:
            return .unavailable("current hardware evidence is single-touch; complete contact frames are unverified")
        case .explicitRouting:
            return .unavailable("requires an attributed exclusive endpoint and verified display binding")
        }
    }

    private static func readConfigurationFile(_ path: String) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        return try handle.read(upToCount: maximumConfigurationBytes + 1) ?? Data()
    }

    enum Decision: Equatable {
        case legacy
        case rejected(String)
    }

    enum Readiness: Equatable {
        case unavailable(String)

        var reason: String {
            switch self {
            case .unavailable(let reason): return reason
            }
        }
    }
}

/// A request vocabulary, not a promise that any live feature can start.
/// Runtime selectors and tuning are deliberately absent until their contracts
/// are verified. Unknown fields must not silently become inactive settings.
struct ExperimentalConfiguration: Decodable, Equatable {
    let schemaVersion: Int
    let features: [ExperimentalFeature]

    static func decode(_ data: Data) throws -> ExperimentalConfiguration {
        // JSONDecoder accepts duplicate object keys. Reject them explicitly so
        // different parsers cannot interpret the same activation differently.
        _ = try JSONSerialization.jsonObject(with: data)
        var validator = UniqueJSONKeysValidator(data: data)
        try validator.validate()
        return try JSONDecoder().decode(Self.self, from: data)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: AnyKey.self)
        guard Set(values.allKeys.map(\.stringValue)) == ["schemaVersion", "features"] else {
            throw ValidationError.invalidRequest
        }
        schemaVersion = try values.decode(Int.self, forKey: AnyKey("schemaVersion"))
        features = try values.decode([ExperimentalFeature].self, forKey: AnyKey("features"))
        guard schemaVersion == 1, !features.isEmpty,
              Set(features).count == features.count else {
            throw ValidationError.invalidRequest
        }
    }

    enum ValidationError: Error { case invalidRequest }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
}

enum ExperimentalFeature: String, Decodable, Hashable {
    case spatialDoubleClick
    case twoFingerScroll
    case explicitRouting
}

/// Checks object-key uniqueness after Foundation has validated JSON syntax.
/// Bounded recursion and input size prevent unbounded activation parsing work.
private struct UniqueJSONKeysValidator {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) { bytes = Array(data) }

    mutating func validate() throws {
        try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw invalid() }
    }

    private mutating func value(depth: Int) throws {
        guard depth < 32 else { throw invalid() }
        whitespace()
        guard index < bytes.count else { throw invalid() }
        switch bytes[index] {
        case 123: // {
            index += 1
            whitespace()
            if consume(125) { return }
            var keys: Set<String> = []
            while true {
                whitespace()
                let key = try string()
                guard keys.insert(key).inserted else { throw invalid() }
                whitespace()
                guard consume(58) else { throw invalid() }
                try value(depth: depth + 1)
                whitespace()
                if consume(125) { return }
                guard consume(44) else { throw invalid() }
            }
        case 91: // [
            index += 1
            whitespace()
            if consume(93) { return }
            while true {
                try value(depth: depth + 1)
                whitespace()
                if consume(93) { return }
                guard consume(44) else { throw invalid() }
            }
        case 34:
            _ = try string()
        default:
            let start = index
            while index < bytes.count && ![UInt8(32), 9, 10, 13, 44, 93, 125].contains(bytes[index]) {
                index += 1
            }
            guard index > start else { throw invalid() }
        }
    }

    private mutating func string() throws -> String {
        let start = index
        guard consume(34) else { throw invalid() }
        while index < bytes.count {
            if bytes[index] == 92 { // escape; Foundation already checked its syntax
                index += 2
            } else if bytes[index] == 34 {
                index += 1
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            } else {
                index += 1
            }
        }
        throw invalid()
    }

    private mutating func whitespace() {
        while index < bytes.count && [UInt8(32), 9, 10, 13].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ expected: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == expected else { return false }
        index += 1
        return true
    }

    private func invalid() -> ExperimentalConfiguration.ValidationError { .invalidRequest }
}
