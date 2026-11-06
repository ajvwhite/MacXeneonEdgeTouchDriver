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
        var hitElement: AXFocusElement? = nil
    }
    private let operations: AXTouchTargetOperations
    private let timeout: Float
    private let floatingWindow: (pid_t, CGRect, CGPoint) -> Bool
    private let topmostWindow: (pid_t, CGRect, CGPoint) -> Bool
    init(operations: AXTouchTargetOperations = SystemAXFocusOperations(), timeout: Float = 0.008,
         floatingWindow: @escaping (pid_t, CGRect, CGPoint) -> Bool = AXTouchTargetBackend.systemFloatingWindow,
         topmostWindow: @escaping (pid_t, CGRect, CGPoint) -> Bool = AXTouchTargetBackend.systemTopmostWindow) {
        self.operations = operations
        self.floatingWindow = floatingWindow
        self.topmostWindow = topmostWindow
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

    private func trace(_ reason: String) -> Target? {
        DriverLoggers.log(.debug, category: .focus, "Touch target resolve failed: \(reason).")
        return nil
    }

    private func traceFocus(_ reason: String) -> Bool {
        DriverLoggers.log(.debug, category: .focus, "Touch target focus failed: \(reason).")
        return false
    }

    func resolve(at point: CGPoint, permit: () -> Bool) -> Target? {
        guard point.x.isFinite, point.y.isFinite, permit() else { return nil }
        let system = operations.systemWideElement()
        guard permit(), operations.setTimeout(system, seconds: timeout) == .success, permit() else { return nil }
        let (error, hit) = operations.element(at: point, system: system)
        guard error == .success, let hit, permit() else { return trace("hit-test at \(point) failed: AXError \(error.rawValue)") }
        guard case let .string(role)? = read(hit, kAXRoleAttribute, permit: permit) else { return trace("hit element role unreadable") }
        let window: AXFocusElement
        if role == kAXWindowRole { window = hit }
        else {
            let result = AXElementWindowResolver.resolve(hit, operations: operations, timeout: timeout, permit: permit)
            guard result.error == .success, case let .element(value)? = result.value else {
                return trace("no window for hit element role=\(role): AXError \(result.error.rawValue)")
            }
            window = value
        }
        guard case .string(kAXWindowRole)? = read(window, kAXRoleAttribute, permit: permit) else { return trace("resolved window has no AXWindow role (hit role=\(role))") }
        guard contains(window, point: point, permit: permit), permit() else { return trace("window frame does not contain \(point) or is unreadable") }
        let (windowError, pid) = operations.ownerPID(window)
        guard windowError == .success, pid > 0, permit() else { return trace("window owner pid unreadable") }
        let (hitError, hitPID) = operations.ownerPID(hit)
        guard hitError == .success, hitPID == pid, permit() else { return trace("hit pid \(hitPID) != window pid \(pid)") }
        let application = operations.applicationElement(pid: pid)
        guard case .string(kAXApplicationRole)? = read(application, kAXRoleAttribute, permit: permit), permit() else { return trace("application role unreadable for pid \(pid)") }
        let (appError, appPID) = operations.ownerPID(application)
        guard appError == .success, appPID == pid, permit() else { return trace("application pid mismatch") }
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
        return Target(application: application, window: window, pid: pid, requiresActivation: !passive,
                      hitElement: role == kAXWindowRole ? nil : hit)
    }

    func focusWindow(_ target: Target, at point: CGPoint, permit: () -> Bool) -> Bool {
        guard contains(target.window, point: point, permit: permit), permit() else { return traceFocus("window no longer contains point") }
        guard case .bool(false)? = read(target.window, kAXMinimizedAttribute, permit: permit) else { return traceFocus("minimized attribute not false/unreadable") }
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
        guard result == .success, permit() else { return traceFocus("focus mutation returned AXError \(result.rawValue) (settable=\(settable))") }
        guard case let .element(confirmed)? = read(target.application, kAXFocusedWindowAttribute, permit: permit) else {
            return traceFocus("focused window unreadable after mutation")
        }
        if !operations.equal(confirmed, target.window) {
            // Some multi-window apps (seen with an Electron app that keeps a second
            // window on another display) accept the focus request but keep reporting
            // their other window as AXFocusedWindow. Admit the click only when that
            // window belongs to the same process and WindowServer independently shows
            // the target window, with the same frame, as the topmost surface at the
            // touch point.
            let (siblingError, siblingPID) = operations.ownerPID(confirmed)
            guard siblingError == .success, siblingPID == target.pid, permit() else {
                return traceFocus("focused window belongs to pid \(siblingPID), not target pid \(target.pid)")
            }
            guard case let .point(origin)? = read(target.window, kAXPositionAttribute, permit: permit),
                  case let .size(size)? = read(target.window, kAXSizeAttribute, permit: permit),
                  topmostWindow(target.pid, CGRect(origin: origin, size: size), point), permit() else {
                return traceFocus("app reports a sibling window as focused and WindowServer does not confirm the target is topmost at the touch point")
            }
            DriverLoggers.log(.debug, category: .focus,
                "App reports a sibling window as focused; WindowServer confirms the target is topmost at the touch point, admitting the click.")
        }
        return contains(target.window, point: point, permit: permit)
    }
    /// The first visible WindowServer surface at the point must be an ordinary
    /// window owned by the target process with exactly the AX frame. Missing
    /// WindowServer data fails closed.
    private static func systemTopmostWindow(pid: pid_t, bounds: CGRect, point: CGPoint) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        for window in windows {
            guard let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: rawBounds), rect.contains(point) else { continue }
            guard let owner = window[kCGWindowOwnerPID as String] as? Int32,
                  let level = window[kCGWindowLayer as String] as? Int32 else { return false }
            return owner == pid && rect == bounds && level == CGWindowLevelForKey(.normalWindow)
        }
        return false
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
