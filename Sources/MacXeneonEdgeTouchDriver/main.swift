import Darwin
import Foundation
import MacXeneonEdgeTouchDriverCore

@main
struct MacXeneonEdgeTouchDriverMain {
    static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--check-permissions"]) {
            let status = DriverPermissionStatus.inspect()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let bytes = try encoder.encode(status)
                FileHandle.standardOutput.write(bytes)
                FileHandle.standardOutput.write(Data([10]))
                exit(status.readyForUnattendedStart ? EXIT_SUCCESS : EX_NOPERM)
            } catch {
                FileHandle.standardError.write(Data("Could not encode permission diagnostics: \(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        let loadResult = DriverConfiguration.load()
        do {
            try DriverFileLog.shared.configure(
                fileLogPath: loadResult.configuration.diagnostics.fileLogPath,
                maxBytes: loadResult.configuration.diagnostics.fileLogMaxBytes,
                minimumLevel: DriverLogLevel(configurationName: loadResult.configuration.logLevel) ?? .notice
            )
        } catch {
            DriverLoggers.log(.error, category: .lifecycle, "Could not configure diagnostics file logging: \(error.localizedDescription)")
        }

        for warning in loadResult.warnings {
            DriverLoggers.log(.warning, category: .lifecycle, warning)
        }

        let application = MacXeneonEdgeTouchDriverApplication(configuration: loadResult.configuration)
        exit(application.run())
    }
}
