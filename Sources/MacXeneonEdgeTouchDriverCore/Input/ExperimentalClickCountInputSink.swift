import CoreGraphics

/// Explicit metadata for an experimental managed press, never inferred by a sink.
public enum ExperimentalMouseClickCount: Int64, Sendable {
    case single = 1
    case double = 2
}

/// Optional additive capability. The caller owns classification and readiness.
/// Both release paths must preserve the accepted down's click count and event
/// number. Existing managed/raw calls retain their original metadata behavior.
/// This protocol does not establish delivery, recipient identity, or eligibility.
public protocol ExperimentalClickCountInputSink: ReportingSyntheticInputSink {
    func tryPostMouseDown(at point: CGPoint, clickCount: ExperimentalMouseClickCount) -> SyntheticInputResult
}
