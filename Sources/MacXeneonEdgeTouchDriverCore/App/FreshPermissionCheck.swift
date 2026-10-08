import Darwin
import Foundation

protocol PermissionProbeProcess: AnyObject {
    func launch() throws
    func wait(seconds: TimeInterval) -> Bool
    func terminate()
    var normalExit: Bool { get }
    var exitStatus: Int32 { get }
    var output: Data { get }
}

/// macOS can cache a permission answer for the lifetime of a process. The
/// existing read-only CLI check gives us a current answer without restarting
/// the driver or requesting access again. Only startup waiting uses this check.
final class FreshPermissionCheck {
    private let executableURL: URL?
    private let timeout: TimeInterval
    private let stopTimeout: TimeInterval
    private let makeProcess: (URL) -> PermissionProbeProcess
    private var blockedProcess: PermissionProbeProcess?

    init(executableURL: URL?, timeout: TimeInterval = 3, stopTimeout: TimeInterval = 3,
         makeProcess: @escaping (URL) -> PermissionProbeProcess = { SystemPermissionProbeProcess(executableURL: $0) }) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.stopTimeout = stopTimeout
        self.makeProcess = makeProcess
    }

    // Called on one serial worker queue, never the lifecycle queue.
    func snapshot(cancellation: StartupCancellation) -> SyntheticPermissionSnapshot? {
        guard !cancellation.isCancelled, let executableURL else { return nil }
        if let blockedProcess {
            guard blockedProcess.wait(seconds: 0) else { return nil }
            self.blockedProcess = nil
        }
        let process = makeProcess(executableURL)
        do { try process.launch() } catch { return nil }
        var remaining = timeout
        var exited = false
        while remaining > 0, !cancellation.isCancelled {
            let slice = min(remaining, 0.05)
            if process.wait(seconds: slice) { exited = true; break }
            remaining -= slice
        }
        if !exited {
            process.terminate()
            guard process.wait(seconds: stopTimeout) else {
                blockedProcess = process
                DriverLoggers.log(.error, category: .lifecycle,
                    "A permission check did not stop; further checks will wait for its exit.")
                return nil
            }
            return nil
        }
        guard !cancellation.isCancelled, process.normalExit else { return nil }
        let data = process.output
        guard data.count <= 4096,
              let status = try? JSONDecoder().decode(DriverPermissionStatus.self, from: data),
              let hid = HIDInputAccess(rawValue: status.hidInputAccess) else { return nil }
        let snapshot = SyntheticPermissionSnapshot(postEventAccess: status.postEventAccess,
            accessibilityTrusted: status.accessibilityTrusted, hidInputAccess: hid, requiresAccessibility: true)
        let ready = snapshot.hasRequiredSyntheticAccess && hid == .granted
        guard status.readyForUnattendedStart == ready,
              process.exitStatus == (ready ? EXIT_SUCCESS : EX_NOPERM) else { return nil }
        return snapshot
    }
}

private final class SystemPermissionProbeProcess: PermissionProbeProcess {
    private let process = Process()
    private let pipe = Pipe()
    private let exited = DispatchSemaphore(value: 0)
    private var observedExit = false

    init(executableURL: URL) {
        process.executableURL = executableURL
        process.arguments = ["--check-permissions"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = self.exited
        process.terminationHandler = { _ in exited.signal() }
    }

    func launch() throws { try process.run() }
    func wait(seconds: TimeInterval) -> Bool {
        if observedExit { return true }
        guard exited.wait(timeout: .now() + seconds) == .success else { return false }
        process.waitUntilExit()
        observedExit = true
        return true
    }
    func terminate() { if process.isRunning { process.terminate() } }
    var normalExit: Bool { process.terminationReason == .exit }
    var exitStatus: Int32 { process.terminationStatus }
    // The CLI branch writes a small JSON record and exits without starting any
    // other process. Bound the read and reject oversized or incomplete output.
    var output: Data { pipe.fileHandleForReading.readData(ofLength: 4097) }
}

final class PermissionSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SyntheticPermissionSnapshot?
    func store(_ value: SyntheticPermissionSnapshot?) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }
    func read() -> SyntheticPermissionSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
