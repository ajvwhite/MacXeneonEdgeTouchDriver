import ApplicationServices
import CoreGraphics

protocol AXTouchTargetOperations: AXFocusOperations {
    func element(at point: CGPoint, system: AXFocusElement) -> (AXError, AXFocusElement?)
    func setFocusedWindow(_ window: AXFocusElement, application: AXFocusElement) -> AXError
}

extension SystemAXFocusOperations: AXTouchTargetOperations {
    func element(at point: CGPoint, system: AXFocusElement) -> (AXError, AXFocusElement?) {
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(system.rawValue as! AXUIElement,
                                                    Float(point.x), Float(point.y), &hit)
        return (error, hit.map { AXFocusElement(rawValue: $0) })
    }

    func setFocusedWindow(_ window: AXFocusElement, application: AXFocusElement) -> AXError {
        AXUIElementSetAttributeValue(application.rawValue as! AXUIElement,
                                    kAXFocusedWindowAttribute as CFString, window.rawValue)
    }
}

/// Worker-only operations. Every IPC has a finite timeout and a fresh permit;
/// no uncertain mutation is retried or replaced with an activation click.
protocol AXTouchTargetResolving: AnyObject {
    func resolve(at point: CGPoint, permit: () -> Bool) -> AXTouchTargetBackend.Target?
    func focusWindow(_ target: AXTouchTargetBackend.Target, at point: CGPoint, permit: () -> Bool) -> Bool
}

final class AXTouchTargetBackend: AXTouchTargetResolving {
    struct Target {
        let application: AXFocusElement
        let window: AXFocusElement
        let pid: pid_t
        var requiresActivation = true
    }
    private let operations: AXTouchTargetOperations
    private let timeout: Float
    private let floatingWindow: (pid_t, CGRect, CGPoint) -> Bool
    init(operations: AXTouchTargetOperations = SystemAXFocusOperations(), timeout: Float = 0.008,
         floatingWindow: @escaping (pid_t, CGRect, CGPoint) -> Bool = AXTouchTargetBackend.systemFloatingWindow) {
        self.operations = operations
        self.floatingWindow = floatingWindow
        self.timeout = max(0.001, min(timeout, 0.05))
    }

    private func read(_ element: AXFocusElement, _ attribute: String, permit: () -> Bool) -> AXFocusValue? {
        guard permit(), operations.setTimeout(element, seconds: timeout) == .success, permit() else { return nil }
        let result = operations.read(element, attribute: attribute)
        guard result.error == .success, permit() else { return nil }
        return result.value
    }

    private func contains(_ window: AXFocusElement, point: CGPoint, permit: () -> Bool) -> Bool {
        guard case let .point(origin)? = read(window, kAXPositionAttribute, permit: permit),
              case let .size(size)? = read(window, kAXSizeAttribute, permit: permit),
              origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return false }
        return CGRect(origin: origin, size: size).contains(point)
    }

    func resolve(at point: CGPoint, permit: () -> Bool) -> Target? {
        guard point.x.isFinite, point.y.isFinite, permit() else { return nil }
        let system = operations.systemWideElement()
        guard permit(), operations.setTimeout(system, seconds: timeout) == .success, permit() else { return nil }
        let (error, hit) = operations.element(at: point, system: system)
        guard error == .success, let hit, permit(),
              case let .string(role)? = read(hit, kAXRoleAttribute, permit: permit) else { return nil }
        let window: AXFocusElement
        if role == kAXWindowRole { window = hit }
        else {
            let result = AXElementWindowResolver.resolve(hit, operations: operations, timeout: timeout, permit: permit)
            guard result.error == .success, case let .element(value)? = result.value else { return nil }
            window = value
        }
        guard case .string(kAXWindowRole)? = read(window, kAXRoleAttribute, permit: permit),
              contains(window, point: point, permit: permit), permit() else { return nil }
        let (windowError, pid) = operations.ownerPID(window)
        guard windowError == .success, pid > 0, permit() else { return nil }
        let (hitError, hitPID) = operations.ownerPID(hit)
        guard hitError == .success, hitPID == pid, permit() else { return nil }
        let application = operations.applicationElement(pid: pid)
        guard case .string(kAXApplicationRole)? = read(application, kAXRoleAttribute, permit: permit), permit() else { return nil }
        let (appError, appPID) = operations.ownerPID(application)
        guard appError == .success, appPID == pid, permit() else { return nil }
        // A floating dialog with no focus setter can receive mouse input while
        // leaving the source application's keyboard recipient intact. Do not
        // activate its app merely to manufacture a focused-window certificate.
        var passive = false
        if case .string(kAXDialogSubrole)? = read(window, kAXSubroleAttribute, permit: permit),
           case .bool(false)? = read(window, kAXFocusedAttribute, permit: permit), permit() {
            let (capabilityError, settable) = operations.isSettable(window, attribute: kAXFocusedAttribute)
            if capabilityError == .success, !settable, permit(),
               case let .point(origin)? = read(window, kAXPositionAttribute, permit: permit),
               case let .size(size)? = read(window, kAXSizeAttribute, permit: permit) {
                passive = floatingWindow(pid, CGRect(origin: origin, size: size), point) && permit()
            }
        }
        return Target(application: application, window: window, pid: pid, requiresActivation: !passive)
    }

    func focusWindow(_ target: Target, at point: CGPoint, permit: () -> Bool) -> Bool {
        guard contains(target.window, point: point, permit: permit), permit(),
              case .bool(false)? = read(target.window, kAXMinimizedAttribute, permit: permit) else { return false }
        let (ownerError, owner) = operations.ownerPID(target.window)
        guard ownerError == .success, owner == target.pid, permit() else { return false }
        if !target.requiresActivation {
            // Hit-test again immediately before admitting the click. A moved,
            // obscured or replaced panel cannot borrow the earlier proof.
            guard let fresh = resolve(at: point, permit: permit), !fresh.requiresActivation,
                  fresh.pid == target.pid, operations.equal(fresh.window, target.window) else { return false }
            return permit()
        }
        if case let .element(focused)? = read(target.application, kAXFocusedWindowAttribute, permit: permit),
           operations.equal(focused, target.window) { return permit() }
        guard permit() else { return false }
        let (error, settable) = operations.isSettable(target.application, attribute: kAXFocusedWindowAttribute)
        guard error == .success, permit() else { return false }
        let result: AXError
        if settable {
            result = operations.setFocusedWindow(target.window, application: target.application)
        } else {
            let (windowError, windowSettable) = operations.isSettable(target.window, attribute: kAXFocusedAttribute)
            guard windowError == .success, permit() else { return false }
            if windowSettable { result = operations.setFocused(target.window) }
            else {
                let (actionsError, actions) = operations.actions(target.window)
                guard actionsError == .success, actions.contains(kAXRaiseAction), permit() else { return false }
                result = operations.raise(target.window)
            }
        }
        guard result == .success, permit(),
              case let .element(confirmed)? = read(target.application, kAXFocusedWindowAttribute, permit: permit),
              operations.equal(confirmed, target.window) else { return false }
        return contains(target.window, point: point, permit: permit)
    }
    /// Corroborate AX ownership and geometry against the first visible desktop
    /// surface at this point. Missing WindowServer data fails closed. No title,
    /// window contents or application-specific allowlist is used.
    private static func systemFloatingWindow(pid: pid_t, bounds: CGRect, point: CGPoint) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        for window in windows {
            guard let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: rawBounds), rect.contains(point) else { continue }
            guard let owner = window[kCGWindowOwnerPID as String] as? Int32,
                  let level = window[kCGWindowLayer as String] as? Int32 else { return false }
            return owner == pid && rect == bounds
                && level > CGWindowLevelForKey(.normalWindow)
                && level <= CGWindowLevelForKey(.modalPanelWindow)
        }
        return false
    }

}
