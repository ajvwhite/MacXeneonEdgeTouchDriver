import CoreGraphics

/// Posts pixel scroll events at the prepared touch target without a mouse press.
public protocol ScrollInputSink: SyntheticInputSink {
    func tryPostScroll(deltaX: Double, deltaY: Double, at point: CGPoint) -> SyntheticInputResult
}
