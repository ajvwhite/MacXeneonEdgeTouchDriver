import Darwin
import Foundation

/// A single startup refresh clears macOS permission caches without another PID
/// or a launchd restart. The environment marker survives the executable change.
struct PermissionProcessRefresh {
    enum Failure: LocalizedError {
        case alreadyRefreshed, invalidExecutable, systemCall(Int32)
        var errorDescription: String? {
            switch self {
            case .alreadyRefreshed: return "The automatic permission refresh was already used"
            case .invalidExecutable: return "The driver executable could not be located"
            case .systemCall(let code): return String(cString: strerror(code))
            }
        }
    }

    let wasRefreshed: () -> Bool
    let markRefreshed: () throws -> Void
    let replaceProcess: () throws -> Void

    func perform() throws {
        guard !wasRefreshed() else { throw Failure.alreadyRefreshed }
        try markRefreshed()
        try replaceProcess()
    }

    static var live: Self {
        Self(wasRefreshed: { getenv("MAC_XENEON_PERMISSION_REFRESHED") != nil },
             markRefreshed: {
                guard setenv("MAC_XENEON_PERMISSION_REFRESHED", "1", 1) == 0 else {
                    throw Failure.systemCall(errno)
                }
             }, replaceProcess: {
                guard let executable = Bundle.main.executableURL?.path else {
                    throw Failure.invalidExecutable
                }
                var arguments = CommandLine.arguments.map { strdup($0) }
                guard arguments.allSatisfy({ $0 != nil }) else {
                    arguments.forEach { free($0) }
                    throw Failure.systemCall(ENOMEM)
                }
                arguments.append(nil)
                defer { arguments.forEach { free($0) } }
                executable.withCString { path in
                    arguments.withUnsafeMutableBufferPointer { buffer in
                        _ = execv(path, buffer.baseAddress!)
                    }
                }
                throw Failure.systemCall(errno)
             })
    }
}
