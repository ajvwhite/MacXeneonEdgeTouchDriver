import AppKit
import ApplicationServices
import Foundation

/// Values sampled by the coordinator on the main run loop. PID is only an AX
/// ownership check; the retained application object's equality is process identity.
struct AXFocusWorkspaceApplication {
    let processIdentifier: pid_t
    let identity: NSObject
    let isTerminated: Bool
    let isHidden: Bool

    func isSameApplication(as other: Self) -> Bool {
        identity.isEqual(other.identity)
    }
}

/// Opaque to the coordinator. Tests can use ordinary CF objects as fake handles.
struct AXFocusElement {
    let rawValue: CFTypeRef
}

struct AXFocusTarget {
    let application: AXFocusElement
    let window: AXFocusElement
    let workspaceApplication: AXFocusWorkspaceApplication
    /// Retains the original failure even when Workspace corroboration succeeds.
    let systemWideError: AXError?

    init(application: AXFocusElement, window: AXFocusElement,
         workspaceApplication: AXFocusWorkspaceApplication, systemWideError: AXError? = nil) {
        self.application = application
        self.window = window
        self.workspaceApplication = workspaceApplication
        self.systemWideError = systemWideError
    }
}

struct AXFocusFailure {
    let stage: String
    let error: AXError?
    let systemWideError: AXError?
}

enum AXFocusResolution {
    case known(AXFocusTarget)
    case unknown(AXFocusFailure)
}

enum AXFocusRelationship { case same, different }

enum AXFocusAttemptResult {
    case skipped
    case attempted(AXError)
    case unknown(AXFocusFailure)
}

protocol AXFocusObservationProtocol: AnyObject {
    var source: CFRunLoopSource? { get }
    /// Called on the AX worker, after the coordinator removes the source on main.
    func invalidate()
}

protocol AXFocusBackendProtocol: AnyObject {
    func resolve(workspace: AXFocusWorkspaceApplication?, permit: () -> Bool) -> AXFocusResolution
    func relationship(_ lhs: AXFocusTarget, _ rhs: AXFocusTarget) -> AXFocusRelationship
    func attemptRestore(captured: AXFocusTarget, baseline: AXFocusTarget,
                        workspace: AXFocusWorkspaceApplication?,
                        capturedApplication: AXFocusWorkspaceApplication?,
                        permit: () -> Bool) -> AXFocusAttemptResult
    func prepareObservation(target: AXFocusTarget, permit: () -> Bool,
                            onChange: @escaping (FocusObservationEvent) -> Void) -> AXFocusObservationProtocol?
}

enum AXFocusValue {
    case element(AXFocusElement)
    case string(String)
    case bool(Bool)
    case other
}

struct AXFocusRead {
    let error: AXError
    let value: AXFocusValue?
}

protocol AXFocusOperations {
    func systemWideElement() -> AXFocusElement
    func applicationElement(pid: pid_t) -> AXFocusElement
    func setTimeout(_ element: AXFocusElement, seconds: Float) -> AXError
    func read(_ element: AXFocusElement, attribute: String) -> AXFocusRead
    func ownerPID(_ element: AXFocusElement) -> (AXError, pid_t)
    func equal(_ lhs: AXFocusElement, _ rhs: AXFocusElement) -> Bool
    func isSettable(_ element: AXFocusElement, attribute: String) -> (AXError, Bool)
    func actions(_ element: AXFocusElement) -> (AXError, [String])
    func setFocused(_ element: AXFocusElement) -> AXError
    func raise(_ element: AXFocusElement) -> AXError
    func observe(_ target: AXFocusTarget, permit: () -> Bool,
                 onChange: @escaping (FocusObservationEvent) -> Void) -> AXFocusObservationProtocol?
}

/// Synchronous, worker-only AX work. Every IPC is preceded by the coordinator's
/// deadline/generation permit. The coordinator never waits for this worker.
final class AXFocusBackend: AXFocusBackendProtocol {
    private let operations: AXFocusOperations
    private let timeout: Float

    init(operations: AXFocusOperations = SystemAXFocusOperations(), timeout: Float = 0.008) {
        self.operations = operations
        self.timeout = max(0.001, min(timeout, 0.05))
    }

    func relationship(_ lhs: AXFocusTarget, _ rhs: AXFocusTarget) -> AXFocusRelationship {
        lhs.workspaceApplication.isSameApplication(as: rhs.workspaceApplication)
            && operations.equal(lhs.application, rhs.application)
            && operations.equal(lhs.window, rhs.window) ? .same : .different
    }

    func resolve(workspace: AXFocusWorkspaceApplication?, permit: () -> Bool) -> AXFocusResolution {
        let first = resolveOnce(workspace: workspace, permit: permit)
        guard case let .known(firstTarget) = first else { return first }
        let second = resolveOnce(workspace: workspace, permit: permit)
        guard case let .known(secondTarget) = second else { return second }
        guard permit(), relationship(firstTarget, secondTarget) == .same else {
            return .unknown(failure("changed observation"))
        }
        return .known(AXFocusTarget(application: secondTarget.application, window: secondTarget.window,
            workspaceApplication: secondTarget.workspaceApplication,
            systemWideError: secondTarget.systemWideError ?? firstTarget.systemWideError))
    }

    private func resolveOnce(workspace: AXFocusWorkspaceApplication?, permit: () -> Bool) -> AXFocusResolution {
        guard permit(), let workspace, workspace.processIdentifier > 0,
              !workspace.isTerminated, !workspace.isHidden else {
            return .unknown(failure("workspace unavailable"))
        }
        let system = operations.systemWideElement()
        guard permit() else { return .unknown(failure("cancelled")) }
        // AX specifies this particular setting is global to our process. All
        // acquired application/window handles also get their own finite timeout.
        let timeoutResult = operations.setTimeout(system, seconds: timeout)
        guard timeoutResult == .success else { return .unknown(failure("system timeout", timeoutResult)) }
        guard permit() else { return .unknown(failure("cancelled")) }
        let read = operations.read(system, attribute: kAXFocusedApplicationAttribute)
        let application: AXFocusElement
        switch read.error {
        case .success:
            guard case let .element(value)? = read.value else {
                return .unknown(failure("focused application type", nil, read.error))
            }
            application = value
        case .cannotComplete:
            guard permit() else { return .unknown(failure("cancelled", nil, read.error)) }
            application = operations.applicationElement(pid: workspace.processIdentifier)
        default:
            return .unknown(failure("focused application", read.error, read.error))
        }
        if let problem = validate(application, role: kAXApplicationRole,
                                  pid: workspace.processIdentifier, permit: permit) {
            return .unknown(failure(problem.stage, problem.error, read.error))
        }
        if read.error == .cannotComplete {
            guard permit() else { return .unknown(failure("cancelled", nil, read.error)) }
            let frontmost = operations.read(application, attribute: kAXFrontmostAttribute)
            guard frontmost.error == .success, case .bool(true)? = frontmost.value else {
                return .unknown(failure("fallback application not frontmost", frontmost.error, read.error))
            }
        }
        guard permit() else { return .unknown(failure("cancelled", nil, read.error)) }
        let windowRead = operations.read(application, attribute: kAXFocusedWindowAttribute)
        guard windowRead.error == .success, case let .element(window)? = windowRead.value else {
            return .unknown(failure("focused window", windowRead.error, read.error))
        }
        if let problem = validate(window, role: kAXWindowRole,
                                  pid: workspace.processIdentifier, permit: permit) {
            return .unknown(failure(problem.stage, problem.error, read.error))
        }
        guard permit() else { return .unknown(failure("cancelled", nil, read.error)) }
        return .known(AXFocusTarget(application: application, window: window, workspaceApplication: workspace,
                                   systemWideError: read.error == .success ? nil : read.error))
    }

    private func validate(_ element: AXFocusElement, role: String, pid: pid_t,
                          permit: () -> Bool) -> AXFocusFailure? {
        guard permit() else { return failure("cancelled") }
        let timeoutResult = operations.setTimeout(element, seconds: timeout)
        guard timeoutResult == .success else { return failure("element timeout", timeoutResult) }
        guard permit() else { return failure("cancelled") }
        let roleRead = operations.read(element, attribute: kAXRoleAttribute)
        guard roleRead.error == .success, case let .string(actualRole)? = roleRead.value,
              actualRole == role else { return failure("element role", roleRead.error) }
        guard permit() else { return failure("cancelled") }
        let (ownerError, owner) = operations.ownerPID(element)
        guard ownerError == .success, owner > 0, owner == pid else { return failure("element owner", ownerError) }
        return nil
    }

    func attemptRestore(captured: AXFocusTarget, baseline: AXFocusTarget,
                        workspace: AXFocusWorkspaceApplication?,
                        capturedApplication: AXFocusWorkspaceApplication?,
                        permit: () -> Bool) -> AXFocusAttemptResult {
        guard permit() else { return .skipped }
        guard let capturedApplication, !capturedApplication.isTerminated,
              !capturedApplication.isHidden, capturedApplication.processIdentifier > 0,
              capturedApplication.processIdentifier == captured.workspaceApplication.processIdentifier,
              capturedApplication.isSameApplication(as: captured.workspaceApplication) else {
            return .unknown(failure("captured process changed"))
        }
        switch resolve(workspace: workspace, permit: permit) {
        case let .unknown(problem): return .unknown(problem)
        case let .known(current):
            guard relationship(current, baseline) == .same else { return .unknown(failure("baseline changed")) }
            if relationship(current, captured) == .same { return .skipped }
        }
        if let problem = validate(captured.application, role: kAXApplicationRole,
                                  pid: capturedApplication.processIdentifier, permit: permit) { return .unknown(problem) }
        if let problem = validate(captured.window, role: kAXWindowRole,
                                  pid: capturedApplication.processIdentifier, permit: permit) { return .unknown(problem) }
        guard permit() else { return .skipped }
        let minimized = operations.read(captured.window, attribute: kAXMinimizedAttribute)
        guard minimized.error == .success, case .bool(false)? = minimized.value else {
            return .unknown(failure("target minimized or unavailable", minimized.error))
        }
        guard permit() else { return .skipped }
        let targetFocus = operations.read(captured.application, attribute: kAXFocusedWindowAttribute)
        guard targetFocus.error == .success, case let .element(targetWindow)? = targetFocus.value else {
            return .unknown(failure("target focused window unavailable", targetFocus.error))
        }
        let expectedWindow = captured.workspaceApplication.isSameApplication(as: baseline.workspaceApplication)
            ? baseline.window : captured.window
        guard operations.equal(targetWindow, expectedWindow) else {
            return .unknown(failure("target sibling changed"))
        }
        if !operations.equal(targetWindow, captured.window) {
            guard permit() else { return .skipped }
            let modal = operations.read(targetWindow, attribute: kAXModalAttribute)
            guard modal.error == .success, case .bool(false)? = modal.value else {
                return .unknown(failure("new focused window modal or unknown", modal.error))
            }
        }
        // The public AX window attributes do not expose a universal attached-sheet
        // relationship. The focused-window modal check and observation invalidation
        // are conservative guards, not proof that every application has no sheet.
        guard permit() else { return .skipped }
        let (settableError, settable) = operations.isSettable(captured.window, attribute: kAXFocusedAttribute)
        guard settableError == .success else { return .unknown(failure("focused capability", settableError)) }
        if settable {
            guard permit() else { return .skipped }
            return .attempted(operations.setFocused(captured.window))
        }
        guard permit() else { return .skipped }
        let (actionsError, actions) = operations.actions(captured.window)
        guard actionsError == .success else { return .unknown(failure("raise capability", actionsError)) }
        guard actions.contains(kAXRaiseAction) else { return .skipped }
        guard permit() else { return .skipped }
        // A timeout can still mean the action occurred. Never retry a mutation.
        return .attempted(operations.raise(captured.window))
    }

    func prepareObservation(target: AXFocusTarget, permit: () -> Bool,
                            onChange: @escaping (FocusObservationEvent) -> Void) -> AXFocusObservationProtocol? {
        guard permit() else { return nil }
        return operations.observe(target, permit: permit, onChange: onChange)
    }

    private func failure(_ stage: String, _ error: AXError? = nil,
                         _ systemWideError: AXError? = nil) -> AXFocusFailure {
        AXFocusFailure(stage: stage, error: error, systemWideError: systemWideError)
    }
}

struct SystemAXFocusOperations: AXFocusOperations {
    private func ax(_ element: AXFocusElement) -> AXUIElement { element.rawValue as! AXUIElement }
    func systemWideElement() -> AXFocusElement { AXFocusElement(rawValue: AXUIElementCreateSystemWide()) }
    func applicationElement(pid: pid_t) -> AXFocusElement { AXFocusElement(rawValue: AXUIElementCreateApplication(pid)) }
    func setTimeout(_ element: AXFocusElement, seconds: Float) -> AXError { AXUIElementSetMessagingTimeout(ax(element), seconds) }
    func equal(_ lhs: AXFocusElement, _ rhs: AXFocusElement) -> Bool { CFEqual(lhs.rawValue, rhs.rawValue) }
    func ownerPID(_ element: AXFocusElement) -> (AXError, pid_t) {
        var pid: pid_t = 0
        let error = AXUIElementGetPid(ax(element), &pid)
        return (error, pid)
    }
    func read(_ element: AXFocusElement, attribute: String) -> AXFocusRead {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(ax(element), attribute as CFString, &raw)
        guard error == .success, let raw else { return AXFocusRead(error: error, value: nil) }
        let value: AXFocusValue
        switch CFGetTypeID(raw) {
        case AXUIElementGetTypeID(): value = .element(AXFocusElement(rawValue: raw))
        case CFStringGetTypeID(): value = .string(raw as! String)
        case CFBooleanGetTypeID(): value = .bool(CFBooleanGetValue((raw as! CFBoolean)))
        default: value = .other
        }
        return AXFocusRead(error: error, value: value)
    }
    func isSettable(_ element: AXFocusElement, attribute: String) -> (AXError, Bool) {
        var result = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(ax(element), attribute as CFString, &result)
        return (error, result.boolValue)
    }
    func actions(_ element: AXFocusElement) -> (AXError, [String]) {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(ax(element), &names)
        return (error, names as? [String] ?? [])
    }
    func setFocused(_ element: AXFocusElement) -> AXError {
        AXUIElementSetAttributeValue(ax(element), kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
    func raise(_ element: AXFocusElement) -> AXError { AXUIElementPerformAction(ax(element), kAXRaiseAction as CFString) }
    func observe(_ target: AXFocusTarget, permit: () -> Bool,
                 onChange: @escaping (FocusObservationEvent) -> Void) -> AXFocusObservationProtocol? {
        SystemAXFocusObservation.make(target: target, permit: permit, onChange: onChange)
    }
}

private final class SystemAXFocusObservation: AXFocusObservationProtocol {
    private var observer: AXObserver?
    private var registrations: [(AXUIElement, CFString)] = []
    private let onChange: (FocusObservationEvent) -> Void
    private(set) var source: CFRunLoopSource?

    private init(onChange: @escaping (FocusObservationEvent) -> Void) { self.onChange = onChange }

    static func make(target: AXFocusTarget, permit: () -> Bool,
                     onChange: @escaping (FocusObservationEvent) -> Void) -> SystemAXFocusObservation? {
        let result = SystemAXFocusObservation(onChange: onChange)
        var observer: AXObserver?
        guard permit(), AXObserverCreate(target.workspaceApplication.processIdentifier, { _, _, notification, context in
            guard let context else { return }
            let event: FocusObservationEvent = (notification as String) == kAXFocusedWindowChangedNotification ? .focusChanged : .lifecycleChanged
            Unmanaged<SystemAXFocusObservation>.fromOpaque(context).takeUnretainedValue().onChange(event)
        }, &observer) == .success, let observer else { return nil }
        result.observer = observer
        result.source = AXObserverGetRunLoopSource(observer)
        let registrations: [(AXUIElement, String)] = [
            (target.application.rawValue as! AXUIElement, kAXFocusedWindowChangedNotification),
            (target.application.rawValue as! AXUIElement, kAXApplicationHiddenNotification),
            (target.window.rawValue as! AXUIElement, kAXUIElementDestroyedNotification),
            (target.window.rawValue as! AXUIElement, kAXWindowMiniaturizedNotification)
        ]
        for (element, name) in registrations {
            guard permit(), AXObserverAddNotification(observer, element, name as CFString,
                Unmanaged.passUnretained(result).toOpaque()) == .success else {
                result.invalidate()
                return nil
            }
            result.registrations.append((element, name as CFString))
        }
        guard permit() else { result.invalidate(); return nil }
        return result
    }

    func invalidate() {
        guard let observer else { return }
        for (element, notification) in registrations { AXObserverRemoveNotification(observer, element, notification) }
        registrations.removeAll()
        source = nil
        self.observer = nil
    }
}
