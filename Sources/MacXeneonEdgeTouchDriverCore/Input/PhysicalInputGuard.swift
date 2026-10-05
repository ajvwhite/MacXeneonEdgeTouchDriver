import CoreGraphics
import Foundation

/// Content-free input counters protect a pending touch transaction from a later
/// physical mouse/keyboard choice. No event tap, key contents or new permission
/// prompt is involved. Driver events must enter at cgSessionEventTap; a private
/// source alone does not exclude events posted at cghidEventTap from HID counters.
struct PhysicalInputGuard {
    typealias Permit = () -> Bool
    private let counts: () -> [UInt32]

    init(counts: @escaping () -> [UInt32]) { self.counts = counts }

    static var system: Self {
        Self {
            [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel].map {
                CGEventSource.counterForEventType(.hidSystemState, eventType: $0)
            }
        }
    }

    /// A change or wrap revokes this permit permanently, even if a later sample
    /// happens to equal the original counters. The short lock covers values only.
    func capture() -> Permit {
        let baseline = counts()
        let state = PhysicalInputPermitState()
        return {
            let observed = counts()
            let result = state.check(observed == baseline)
            if result.revoked {
                DriverLoggers.log(.debug, category: .focus,
                    "Physical-input permit revoked; baseline counters=\(baseline), observed counters=\(observed).")
            }
            return result.valid
        }
    }
}

private final class PhysicalInputPermitState {
    private let lock = NSLock()
    private var valid = true
    func check(_ unchanged: Bool) -> (valid: Bool, revoked: Bool) {
        lock.lock(); defer { lock.unlock() }
        let revoked = valid && !unchanged
        valid = valid && unchanged
        return (valid, revoked)
    }
}
