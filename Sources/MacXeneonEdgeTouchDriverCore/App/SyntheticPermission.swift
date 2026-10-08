import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import IOKit.hidsystem

enum HIDInputAccess: String { case unknown, denied, granted }

struct SyntheticPermissionSnapshot: Equatable {
    let postEventAccess: Bool
    let accessibilityTrusted: Bool

    let hidInputAccess: HIDInputAccess
    let requiresAccessibility: Bool

    init(postEventAccess: Bool, accessibilityTrusted: Bool, hidInputAccess: HIDInputAccess = .unknown,
         requiresAccessibility: Bool = false) {
        self.postEventAccess = postEventAccess
        self.accessibilityTrusted = accessibilityTrusted
        self.hidInputAccess = hidInputAccess
        self.requiresAccessibility = requiresAccessibility
    }

    // Preserve the synthetic compatibility rule. Neither fact proves delivery.
    var hasSyntheticAccess: Bool { postEventAccess || accessibilityTrusted }
    var hasRequiredSyntheticAccess: Bool { hasSyntheticAccess && (!requiresAccessibility || accessibilityTrusted) }
    var isReady: Bool { hasRequiredSyntheticAccess && hidInputAccess != .denied }
}

protocol SyntheticPermissionProviding: AnyObject {
    func snapshot() -> SyntheticPermissionSnapshot
    func requestInitialAccess(cancellation: StartupCancellation)
    var supportsFreshSnapshots: Bool { get }
    func freshSnapshot(cancellation: StartupCancellation) -> SyntheticPermissionSnapshot?
}

extension SyntheticPermissionProviding {
    var supportsFreshSnapshots: Bool { false }
    func freshSnapshot(cancellation: StartupCancellation) -> SyntheticPermissionSnapshot? { nil }
}

/// Shared only with the request worker. Cancellation cannot dismiss an OS dialog.
final class StartupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class SystemSyntheticPermissionProvider: SyntheticPermissionProviding {
    private let readSnapshot: () -> SyntheticPermissionSnapshot
    private let requestPostEventAccess: () -> Bool
    private let requestAccessibilityTrust: () -> Void
    private let logIdentity: () -> Void
    private let readFreshSnapshot: ((StartupCancellation) -> SyntheticPermissionSnapshot?)?

    convenience init() {
        let check = FreshPermissionCheck(executableURL: Bundle.main.executableURL)
        self.init(
            readSnapshot: {
                SyntheticPermissionSnapshot(
                    postEventAccess: CGPreflightPostEventAccess(),
                    accessibilityTrusted: AXIsProcessTrusted(),
                    hidInputAccess: {
                        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
                        case kIOHIDAccessTypeGranted: return .granted
                        case kIOHIDAccessTypeDenied: return .denied
                        default: return .unknown
                        }
                    }(),
                    requiresAccessibility: true
                )
            },
            requestPostEventAccess: { CGRequestPostEventAccess() },
            requestAccessibilityTrust: {
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            },
            logIdentity: {
                let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "Unknown executable"
                let launcher = NSRunningApplication(processIdentifier: getppid())?.bundleURL?.path ?? "Unknown launcher"
                DriverLoggers.log(.notice, category: .lifecycle, "Permission identity: executable=\(executable), launcher=\(launcher).")
            },
            readFreshSnapshot: { check.snapshot(cancellation: $0) }
        )
    }

    init(
        readSnapshot: @escaping () -> SyntheticPermissionSnapshot,
        requestPostEventAccess: @escaping () -> Bool,
        requestAccessibilityTrust: @escaping () -> Void,
        logIdentity: @escaping () -> Void = {},
        readFreshSnapshot: ((StartupCancellation) -> SyntheticPermissionSnapshot?)? = nil
    ) {
        self.readSnapshot = readSnapshot
        self.requestPostEventAccess = requestPostEventAccess
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.logIdentity = logIdentity
        self.readFreshSnapshot = readFreshSnapshot
    }

    func snapshot() -> SyntheticPermissionSnapshot { readSnapshot() }
    var supportsFreshSnapshots: Bool { readFreshSnapshot != nil }
    func freshSnapshot(cancellation: StartupCancellation) -> SyntheticPermissionSnapshot? {
        guard !cancellation.isCancelled else { return nil }
        return readFreshSnapshot?(cancellation)
    }

    func requestInitialAccess(cancellation: StartupCancellation) {
        guard !cancellation.isCancelled else { return }
        let before = snapshot()
        guard !before.hasRequiredSyntheticAccess else { return }
        logIdentity()
        // CG does not document AX's asynchronous prompt contract. This entire
        // sequence runs off the lifecycle queue; its return value is not readiness.
        guard !cancellation.isCancelled else { return }
        if !before.postEventAccess, requestPostEventAccess(), !before.requiresAccessibility { return }
        guard !cancellation.isCancelled, !snapshot().hasRequiredSyntheticAccess else { return }
        guard !cancellation.isCancelled else { return }
        requestAccessibilityTrust()
    }
}

protocol PermissionRequestWorking {
    /// Runs request work separately and delivers completion on the lifecycle queue.
    func submit(_ request: @escaping () -> Void, completion: @escaping () -> Void)
}

struct DispatchPermissionRequestWorker: PermissionRequestWorking {
    private let queue: DispatchQueue

    init(label: String = "permission-request") {
        queue = DispatchQueue(label: "\(DriverLoggers.subsystem).\(label)", qos: .utility)
    }

    func submit(_ request: @escaping () -> Void, completion: @escaping () -> Void) {
        // The request owns only its provider and locked cancellation token.
        // Lifecycle state is accessed only by completion, back on the main queue.
        queue.async(execute: DispatchWorkItem {
            request()
            DispatchQueue.main.async(execute: DispatchWorkItem(block: completion))
        })
    }
}

protocol PermissionPollTask: AnyObject {
    func cancel()
}

protocol PermissionPollScheduling {
    /// Delivers callbacks on the lifecycle queue. Cancellation may leave a queued callback.
    func schedule(everySeconds: Int, leewayMilliseconds: Int, _ action: @escaping () -> Void) -> PermissionPollTask
}

struct DispatchPermissionPollScheduler: PermissionPollScheduling {
    func schedule(everySeconds: Int, leewayMilliseconds: Int, _ action: @escaping () -> Void) -> PermissionPollTask {
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .seconds(everySeconds), repeating: .seconds(everySeconds), leeway: .milliseconds(leewayMilliseconds))
        source.setEventHandler(handler: action)
        source.activate()
        return DispatchPermissionPollTask(source)
    }
}

private final class DispatchPermissionPollTask: PermissionPollTask {
    private let source: DispatchSourceTimer

    init(_ source: DispatchSourceTimer) { self.source = source }
    func cancel() {
        source.setEventHandler {}
        source.cancel()
    }
    deinit { cancel() }
}
