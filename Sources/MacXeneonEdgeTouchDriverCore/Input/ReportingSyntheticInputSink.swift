import CoreGraphics

/// The strongest observable result is invocation of the poster, never delivery.
public enum SyntheticInputResult: Equatable {
    case postInvoked
    case constructionFailed
    case sourceUnavailable
    case busy
    case noPendingMouseDown
}

/// Optional, additive managed capability for sinks which can report construction failure.
/// Callers must use this API exclusively for each press, without interleaving the
/// legacy Void methods. The legacy API does not acquire these guarantees.
/// A successful down owns one release until `tryPostMouseUp` invokes its poster.
/// Implementations must reserve release capacity before posting down, and must not
/// return a failed release after a successful down. Calls are serial, not concurrent.
public protocol ReportingSyntheticInputSink: SyntheticInputSink {
    func tryPostMouseDown(at point: CGPoint) -> SyntheticInputResult
    func tryPostMouseUp(at point: CGPoint) -> SyntheticInputResult
    func tryPostMouseDragged(to point: CGPoint) -> SyntheticInputResult
}


/// Adds click counts without weakening the reserved-release contract.
public protocol ClickCountSyntheticInputSink: ReportingSyntheticInputSink {
    func tryPostMouseDown(at point: CGPoint, clickCount: Int) -> SyntheticInputResult
}
