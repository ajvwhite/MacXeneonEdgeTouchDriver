import CoreGraphics
import Foundation

/// Content-free input counters protect a pending touch transaction from a later
/// physical mouse/keyboard choice. No event tap, key contents or new permission
/// prompt is involved. Private-source driver events have their own state table.
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
            let unchanged = counts() == baseline
            return state.check(unchanged)
        }
    }
}

private final class PhysicalInputPermitState {
    private let lock = NSLock()
    private var valid = true
    func check(_ unchanged: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        valid = valid && unchanged
        return valid
    }
}
