import Foundation

/// Measures timer wake lateness without HID, Accessibility or synthetic input.
/// It evaluates queue priority in this process, not launchd ProcessType or delivery.
public enum DriverSchedulingProbe {
    public enum ProbeError: Error { case timeout }
    public static func run(iterations: Int = 100) throws -> DriverPerformanceMetrics.Snapshot {
        let metrics = DriverPerformanceMetrics()
        for (name, qos) in [("background", DispatchQoS.QoSClass.background),
                            ("default", DispatchQoS.QoSClass.default),
                            ("interactive", DispatchQoS.QoSClass.userInteractive)] {
            let queue = DispatchQueue(label: "driver-timer-probe.\(name)", qos: DispatchQoS(qosClass: qos, relativePriority: 0))
            for _ in 0..<min(1000, max(1, iterations)) {
                let completed = DispatchSemaphore(value: 0)
                let deadline = DispatchTime.now() + .milliseconds(10)
                queue.asyncAfter(deadline: deadline) {
                    metrics.record("timerWakeLateness.\(name)", from: deadline.uptimeNanoseconds,
                                   to: DispatchTime.now().uptimeNanoseconds)
                    completed.signal()
                }
                guard completed.wait(timeout: .now() + .seconds(2)) == .success else { throw ProbeError.timeout }
            }
        }
        return metrics.snapshot()
    }
}
