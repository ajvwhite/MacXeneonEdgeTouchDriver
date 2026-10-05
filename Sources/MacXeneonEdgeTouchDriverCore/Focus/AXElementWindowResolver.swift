import ApplicationServices
import Foundation

/// Web controls need not advertise AXWindow. Resolve their window through the
/// advertised top-level element or a bounded, cycle-checked parent chain. Every
/// ancestor must remain owned by the initial process; callers verify the exact
/// returned window against their captured target or mapped point.
enum AXElementWindowResolver {
    static func resolve(_ element: AXFocusElement, operations: AXFocusOperations,
                        timeout: Float = 0.008, permit: () -> Bool) -> AXFocusRead {
        func read(_ element: AXFocusElement, _ attribute: String) -> AXFocusRead {
            guard permit() else { return AXFocusRead(error: .cannotComplete, value: nil) }
            let configured = operations.setTimeout(element, seconds: timeout)
            guard configured == .success, permit() else { return AXFocusRead(error: configured, value: nil) }
            let result = operations.read(element, attribute: attribute)
            return permit() ? result : AXFocusRead(error: .cannotComplete, value: nil)
        }
        let direct = read(element, kAXWindowAttribute)
        if direct.error == .success {
            guard case .element? = direct.value else { return AXFocusRead(error: .illegalArgument, value: nil) }
            return direct
        }
        guard direct.error == .attributeUnsupported || direct.error == .noValue, permit() else { return direct }
        let (ownerError, owner) = operations.ownerPID(element)
        guard ownerError == .success, owner > 0, permit() else { return AXFocusRead(error: ownerError, value: nil) }
        let top = read(element, kAXTopLevelUIElementAttribute)
        if top.error == .success {
            guard case let .element(candidate)? = top.value else { return AXFocusRead(error: .illegalArgument, value: nil) }
            let role = read(candidate, kAXRoleAttribute)
            guard role.error == .success, case let .string(name)? = role.value else { return role }
            if name == kAXWindowRole {
                guard permit() else { return AXFocusRead(error: .cannotComplete, value: nil) }
                let (error, pid) = operations.ownerPID(candidate)
                guard error == .success, pid == owner, permit() else { return AXFocusRead(error: .invalidUIElement, value: nil) }
                return AXFocusRead(error: .success, value: .element(candidate))
            }
        } else if top.error != .attributeUnsupported && top.error != .noValue {
            return top
        }
        var current = element
        var visited: [AXFocusElement] = []
        for _ in 0..<16 {
            guard permit(), !visited.contains(where: { operations.equal($0, current) }) else {
                return AXFocusRead(error: .invalidUIElement, value: nil)
            }
            visited.append(current)
            let (error, pid) = operations.ownerPID(current)
            guard error == .success, pid == owner, permit() else { return AXFocusRead(error: .invalidUIElement, value: nil) }
            let role = read(current, kAXRoleAttribute)
            guard role.error == .success, case let .string(name)? = role.value else { return role }
            if name == kAXWindowRole { return AXFocusRead(error: .success, value: .element(current)) }
            let parent = read(current, kAXParentAttribute)
            guard parent.error == .success, case let .element(next)? = parent.value else { return parent }
            current = next
        }
        return AXFocusRead(error: .invalidUIElement, value: nil)
    }
}
