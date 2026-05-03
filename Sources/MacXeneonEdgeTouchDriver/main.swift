import Darwin
import Foundation
import MacXeneonEdgeTouchDriverCore

@main
struct MacXeneonEdgeTouchDriverMain {
    static func main() {
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
