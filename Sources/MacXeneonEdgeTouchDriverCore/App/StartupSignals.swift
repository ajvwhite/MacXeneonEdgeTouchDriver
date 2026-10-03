import Darwin
import Dispatch
import Foundation

/// Install, cancel, and deliver callbacks on the application's main lifecycle thread.
protocol StartupSignalHandling: AnyObject {
    func install(_ onSignal: @escaping (Int32) -> Void) throws
    func cancel()
}

protocol StartupSignalSource: AnyObject {
    func activate()
    func cancel()
}

protocol StartupSignalPlatform {
    func ignoreDefaultAction(for signalNumber: Int32) throws -> sigaction
    func restoreAction(_ action: sigaction, for signalNumber: Int32) throws
    func makeSource(for signalNumber: Int32, handler: @escaping () -> Void) -> StartupSignalSource
}

enum StartupSignalError: Error, LocalizedError {
    case alreadyInstalled
    case sigactionFailed(signalNumber: Int32, errorCode: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyInstalled:
            return "Startup signal handlers are already installed."
        case let .sigactionFailed(signalNumber, errorCode):
            return "sigaction failed for signal \(signalNumber) (errno \(errorCode))."
        }
    }
}

final class DispatchStartupSignals: StartupSignalHandling {
    private struct Registration {
        let signalNumber: Int32
        let originalAction: sigaction
        let source: StartupSignalSource
    }

    private let platform: StartupSignalPlatform
    private let reportCleanupError: (Error) -> Void
    private var registrations: [Registration] = []
    private var generation: UInt64 = 0
    private var isInstalled = false

    init(
        platform: StartupSignalPlatform = DarwinStartupSignalPlatform(),
        reportCleanupError: @escaping (Error) -> Void = { error in
            DriverLoggers.log(.error, category: .lifecycle, "Could not restore signal action: \(error.localizedDescription)")
        }
    ) {
        self.platform = platform
        self.reportCleanupError = reportCleanupError
    }

    deinit {
        cancel()
    }

    func install(_ onSignal: @escaping (Int32) -> Void) throws {
        guard !isInstalled else {
            throw StartupSignalError.alreadyInstalled
        }

        generation &+= 1
        let installationGeneration = generation
        isInstalled = true

        do {
            for signalNumber in [SIGINT, SIGTERM] {
                // A callback may cancel setup; do not install the remaining signals.
                guard isInstalled, generation == installationGeneration else { return }
                let originalAction = try platform.ignoreDefaultAction(for: signalNumber)
                let source = platform.makeSource(for: signalNumber) { [weak self] in
                    guard let self, self.isInstalled, self.generation == installationGeneration else { return }
                    onSignal(signalNumber)
                }
                registrations.append(Registration(
                    signalNumber: signalNumber,
                    originalAction: originalAction,
                    source: source
                ))
                source.activate()
            }
        } catch {
            cancel()
            throw error
        }
    }

    func cancel() {
        // Dispatch cancellation does not interrupt an event handler already in progress.
        // Invalidate first, including before platform cleanup can deliver a stale callback.
        generation &+= 1
        isInstalled = false
        let previousRegistrations = registrations
        registrations.removeAll()

        previousRegistrations.forEach { $0.source.cancel() }
        for registration in previousRegistrations.reversed() {
            do {
                try platform.restoreAction(registration.originalAction, for: registration.signalNumber)
            } catch {
                reportCleanupError(error)
            }
        }
    }
}

struct DarwinStartupSignalPlatform: StartupSignalPlatform {
    func ignoreDefaultAction(for signalNumber: Int32) throws -> sigaction {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_IGN
        action.sa_flags = 0
        sigemptyset(&action.sa_mask)
        var originalAction = sigaction()
        // A dispatch signal source observes delivery; it does not prevent default termination.
        guard sigaction(signalNumber, &action, &originalAction) == 0 else {
            throw StartupSignalError.sigactionFailed(signalNumber: signalNumber, errorCode: errno)
        }
        return originalAction
    }

    func restoreAction(_ action: sigaction, for signalNumber: Int32) throws {
        var action = action
        guard sigaction(signalNumber, &action, nil) == 0 else {
            throw StartupSignalError.sigactionFailed(signalNumber: signalNumber, errorCode: errno)
        }
    }

    func makeSource(for signalNumber: Int32, handler: @escaping () -> Void) -> StartupSignalSource {
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler(handler: handler)
        return DispatchStartupSignalSource(source: source)
    }
}

private final class DispatchStartupSignalSource: StartupSignalSource {
    private let source: DispatchSourceSignal

    init(source: DispatchSourceSignal) {
        self.source = source
    }

    func activate() {
        source.activate()
    }

    func cancel() {
        source.cancel()
    }
}
