import CoreFoundation
import Foundation

// Prepare files in the installer's private staging directory. This script never
// writes to the installed paths or interacts with the LaunchAgent.
struct PreparationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw PreparationError(message: message)
    }
}

func readData(at path: String, description: String) throws -> Data {
    do {
        return try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw PreparationError(message: "Could not read \(description) at \(path): \(error.localizedDescription)")
    }
}

func plistDictionary(from data: Data) throws -> [String: Any] {
    let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard let dictionary = value as? [String: Any] else {
        throw PreparationError(message: "LaunchAgent plist must contain a dictionary.")
    }
    return dictionary
}

func jsonDictionary(from data: Data) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = value as? [String: Any] else {
        throw PreparationError(message: "Configuration must contain a JSON object.")
    }
    return dictionary
}

func isBoolean(_ value: Any?, equalTo expected: Bool) -> Bool {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID() else {
        return false
    }
    return number.boolValue == expected
}

func validateXMLCharacters(in value: Any) throws {
    if let string = value as? String {
        // Foundation's plist parser accepts some control characters forbidden by
        // XML 1.0, so a Foundation round-trip alone is insufficient here.
        try require(string.unicodeScalars.allSatisfy { scalar in
            let code = scalar.value
            return code == 0x09 || code == 0x0A || code == 0x0D
                || (0x20...0xD7FF).contains(code)
                || (0xE000...0xFFFD).contains(code)
                || (0x10000...0x10FFFF).contains(code)
        }, "LaunchAgent paths or template contain characters that XML 1.0 cannot represent.")
    } else if let dictionary = value as? [String: Any] {
        for (key, child) in dictionary {
            try validateXMLCharacters(in: key)
            try validateXMLCharacters(in: child)
        }
    } else if let array = value as? [Any] {
        for child in array {
            try validateXMLCharacters(in: child)
        }
    }
}

func preparePlist(templatePath: String, binaryPath: String, logDirectory: String) throws -> Data {
    var plist = try plistDictionary(from: readData(at: templatePath, description: "LaunchAgent template"))
    try require(plist["Label"] as? String == "com.ajvwhite.MacXeneonEdgeTouchDriver",
                "LaunchAgent template has an unexpected Label.")
    try require(plist["ProgramArguments"] as? [String] == ["__BIN_PATH__"] && plist["Program"] == nil,
                "LaunchAgent template must use the __BIN_PATH__ program placeholder.")
    try require(plist["StandardOutPath"] as? String == "__LOG_DIR__/stdout.log"
                && plist["StandardErrorPath"] as? String == "__LOG_DIR__/stderr.log",
                "LaunchAgent template has invalid log path placeholders.")
    try require(isBoolean(plist["RunAtLoad"], equalTo: true),
                "LaunchAgent template must set RunAtLoad to true.")
    guard let keepAlive = plist["KeepAlive"] as? [String: Any],
          isBoolean(keepAlive["SuccessfulExit"], equalTo: false),
          isBoolean(keepAlive["Crashed"], equalTo: true) else {
        throw PreparationError(message: "LaunchAgent template has invalid KeepAlive settings.")
    }
    guard let throttle = plist["ThrottleInterval"] as? NSNumber,
          CFGetTypeID(throttle) == CFNumberGetTypeID(),
          !["f", "d"].contains(String(cString: throttle.objCType)),
          throttle.int64Value > 0 else {
        throw PreparationError(message: "LaunchAgent template must have a positive integer ThrottleInterval.")
    }
    try require(plist["ProcessType"] as? String == "Background",
                "LaunchAgent template must use the Background process type.")

    plist["ProgramArguments"] = [binaryPath]
    plist["StandardOutPath"] = logDirectory + "/stdout.log"
    plist["StandardErrorPath"] = logDirectory + "/stderr.log"
    try validateXMLCharacters(in: plist)
    let serialized = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    guard let xml = String(data: serialized, encoding: .utf8) else {
        throw PreparationError(message: "LaunchAgent serialization did not produce UTF-8 XML.")
    }
    // XML readers normalize literal carriage returns. Foundation leaves these
    // unescaped, so use character references to preserve the original paths.
    let data = Data(xml.replacingOccurrences(of: "\r", with: "&#13;").utf8)
    let decoded = try plistDictionary(from: data)
    try require(NSDictionary(dictionary: decoded).isEqual(to: plist),
                "LaunchAgent plist did not round-trip through XML serialization.")
    return data
}

func prepareConfig(configPath: String, logDirectory: String) throws -> Data {
    let attributes: [FileAttributeKey: Any]?
    do {
        attributes = try FileManager.default.attributesOfItem(atPath: configPath)
    } catch {
        let fileError = error as NSError
        guard fileError.domain == NSCocoaErrorDomain,
              [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(fileError.code) else {
            throw PreparationError(message: "Could not inspect existing configuration: \(error.localizedDescription)")
        }
        attributes = nil
    }

    if let attributes {
        try require(attributes[.type] as? FileAttributeType == .typeRegular,
                    "Existing configuration must be a regular file, not a directory or symbolic link.")
        let data = try readData(at: configPath, description: "existing configuration")
        do {
            _ = try jsonDictionary(from: data)
        } catch {
            throw PreparationError(message: "Existing configuration is invalid: \(error.localizedDescription)")
        }
        // Keep formatting, unknown keys, and user settings exactly as supplied.
        return data
    }

    let configuration: [String: Any] = [
        "logLevel": "info",
        "timing": [
            "warpToClickDelayMs": 10,
            "downToUpDelayMs": 20,
            "clickToWarpBackDelayMs": 10,
            "tapDebounceMs": 50,
            "stuckGestureTimeoutMs": 2_000,
        ],
        "display": [
            "vendorNumber": 3_672,
            "modelNumber": 60_672,
            "serialNumber": NSNull(),
            "expectedWidth": 2_560,
            "expectedHeight": 720,
        ] as [String: Any],
        "focus": ["restorePreviousWindow": true],
        "cursor": ["returnToPreviousPosition": true],
        "gesture": ["multiTouchEnabled": false],
        "diagnostics": [
            "fileLogPath": logDirectory + "/driver.log",
            "fileLogMaxBytes": 5_242_880,
        ] as [String: Any],
    ]
    var data = try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0A)
    let decoded = try jsonDictionary(from: data)
    try require(NSDictionary(dictionary: decoded).isEqual(to: configuration),
                "Default configuration did not round-trip through JSON serialization.")
    return data
}

func writeStaged(_ data: Data, name: String, directory: String) throws {
    let path = directory + "/" + name
    do {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try require(readData(at: path, description: "staged \(name)") == data,
                    "Staged \(name) does not match its prepared contents.")
    } catch {
        throw PreparationError(message: "Could not write and verify staged \(name): \(error.localizedDescription)")
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    try require(arguments.count == 5,
                "Usage: prepare-install.swift PLIST_TEMPLATE STAGE_DIRECTORY INSTALLED_BINARY CONFIG_PATH LOG_DIRECTORY")
    try require(arguments.allSatisfy { ($0 as NSString).isAbsolutePath },
                "All installer preparation paths must be absolute.")
    let templatePath = arguments[0]
    let stageDirectory = arguments[1]
    let binaryPath = arguments[2]
    let configPath = arguments[3]
    let logDirectory = arguments[4]
    let attributes = try FileManager.default.attributesOfItem(atPath: stageDirectory)
    try require(attributes[.type] as? FileAttributeType == .typeDirectory,
                "Staging path must be an existing directory, not a symbolic link.")

    let plist = try preparePlist(templatePath: templatePath, binaryPath: binaryPath, logDirectory: logDirectory)
    let config = try prepareConfig(configPath: configPath, logDirectory: logDirectory)
    try writeStaged(plist, name: "agent.plist", directory: stageDirectory)
    try writeStaged(config, name: "config.json", directory: stageDirectory)
} catch {
    FileHandle.standardError.write(Data("Installer preparation failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
