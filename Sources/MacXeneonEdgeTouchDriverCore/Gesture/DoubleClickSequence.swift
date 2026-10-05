import CoreGraphics
import Foundation

/// Retained AX handles prevent a PID or hash from standing in for window identity.
struct TouchTargetIdentity: Equatable {
    let pid: pid_t
    let application: CFTypeRef
    let window: CFTypeRef

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && CFEqual(lhs.application, rhs.application) && CFEqual(lhs.window, rhs.window)
    }
}

/// Counts only completed, unmoved clicks to the same verified target.
struct DoubleClickSequence {
    private struct Tap {
        let point: CGPoint
        let timestamp: UInt64
        let target: TouchTargetIdentity
        let mapper: CoordinateMapper
        let inputPermit: PhysicalInputGuard.Permit
    }
    private var previous: Tap?
    private var active: Tap?
    private var count = 1

    mutating func begin(at point: CGPoint, timestamp: UInt64, target: TouchTargetIdentity?,
                        mapper: CoordinateMapper, interval: UInt64,
                        inputPermit: @escaping PhysicalInputGuard.Permit) -> Int {
        count = 1
        guard let target, point.x.isFinite, point.y.isFinite, interval > 0 else {
            reset()
            return 1
        }
        if let previous, previous.inputPermit(), timestamp >= previous.timestamp,
           timestamp - previous.timestamp < interval, previous.mapper == mapper,
           previous.target == target, hypot(point.x - previous.point.x, point.y - previous.point.y) <= 4 {
            count = 2
        }
        previous = nil
        active = Tap(point: point, timestamp: timestamp, target: target,
                     mapper: mapper, inputPermit: inputPermit)
        return count
    }

    func mayContinue(at point: CGPoint, timestamp: UInt64, mapper: CoordinateMapper,
                     interval: UInt64) -> Bool {
        guard let previous, previous.inputPermit(), timestamp >= previous.timestamp else { return false }
        return timestamp - previous.timestamp < interval && previous.mapper == mapper &&
            hypot(point.x - previous.point.x, point.y - previous.point.y) <= 4
    }

    mutating func completed(at point: CGPoint, timestamp: UInt64, interval: UInt64,
                            dragged: Bool, posted: Bool) {
        defer { active = nil; count = 1 }
        guard count == 1, let active, !dragged, posted, active.inputPermit(),
              timestamp >= active.timestamp, timestamp - active.timestamp < interval,
              hypot(point.x - active.point.x, point.y - active.point.y) <= 4 else {
            previous = nil
            return
        }
        previous = active
    }

    mutating func reset() { previous = nil; active = nil; count = 1 }
}
