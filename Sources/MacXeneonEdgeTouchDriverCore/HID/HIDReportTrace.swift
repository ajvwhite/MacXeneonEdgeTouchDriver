import Foundation

/// JSON-lines report format shared by HIDDump recording and offline replay.
public struct HIDReportTraceRecord: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case report, removal }
    public var schemaVersion: Int
    public var kind: Kind
    public var sourceID: UInt64
    public var timestampNanoseconds: UInt64
    public var reportID: UInt32
    public var bytes: [UInt8]
    /// Optional queue-delivery time for offline backlog experiments. Live recordings omit it.
    public var deliveryTimestampNanoseconds: UInt64?
    public var wallClockMilliseconds: UInt64?
    public var controllerLocationID: UInt32?

    public init(kind: Kind = .report, sourceID: UInt64, timestampNanoseconds: UInt64,
                reportID: UInt32 = 7, bytes: [UInt8] = [], deliveryTimestampNanoseconds: UInt64? = nil, wallClockMilliseconds: UInt64? = nil,
                controllerLocationID: UInt32? = nil) {
        self.schemaVersion = 1; self.kind = kind; self.sourceID = sourceID
        self.timestampNanoseconds = timestampNanoseconds; self.reportID = reportID; self.bytes = bytes
        self.deliveryTimestampNanoseconds = deliveryTimestampNanoseconds
        self.wallClockMilliseconds = wallClockMilliseconds; self.controllerLocationID = controllerLocationID
    }
}

public enum TouchPipelineReplay {
    public struct Report: Codable {
        public let measurement: String
        public let reports: Int
        public let mouseDownPosts: Int
        public let mouseUpPosts: Int
        public let dragPosts: Int
        public let scrollPosts: Int
        public let focusRestoreRequests: Int
        public let finalInputBalanced: Bool
        public let processingMilliseconds: Double
        public let metrics: DriverPerformanceMetrics.Snapshot
    }
    public enum ReplayError: Error { case invalidRecord, unorderedTrace, tooManySources, oversizedTrace }

    /// Runs production parsing/filtering/application/cleanup with virtual time and
    /// fake side effects. No HID, Accessibility, cursor or input APIs are invoked.
    public static func run(_ records: [HIDReportTraceRecord], configuration: DriverConfiguration = .defaults) throws -> Report {
        guard records.count <= 1_000_000 else { throw ReplayError.oversizedTrace }
        let origin = records.first?.timestampNanoseconds ?? 0
        var previous = origin
        var previousDelivery = origin
        for record in records {
            guard record.schemaVersion == 1, record.sourceID > 0, record.bytes.count <= 256 else { throw ReplayError.invalidRecord }
            guard record.timestampNanoseconds >= previous,
                  record.timestampNanoseconds - origin < 86_400_000_000_000 else { throw ReplayError.unorderedTrace }
            let delivery = record.deliveryTimestampNanoseconds ?? record.timestampNanoseconds
            guard delivery >= record.timestampNanoseconds, delivery >= previousDelivery,
                  delivery - origin < 86_400_000_000_000 else { throw ReplayError.unorderedTrace }
            previous = record.timestampNanoseconds
            previousDelivery = delivery
        }
        var config = configuration
        config.diagnostics.performanceMetricsEnabled = true
        let clock = ReplayClock()
        let input = ReplayInput()
        let cursor = ReplayCursor()
        let focus = ReplayFocus()
        let display = DisplaySnapshot(displayID: 42, vendorNumber: CapturedXeneonDisplay.vendorNumber,
            modelNumber: CapturedXeneonDisplay.modelNumber, serialNumber: CapturedXeneonDisplay.observedSerialNumber,
            bounds: CGRect(x: 5088, y: 1890, width: 2560, height: 720), pixelsWide: 2560, pixelsHigh: 720)
        let app = MacXeneonEdgeTouchDriverApplication(configuration: config,
            displayResolver: DisplayResolver(activeDisplayProvider: { [display] }, diagnosticLog: nil),
            inputSink: input, cursorController: cursor, focusRestorer: focus, scheduler: clock)
        var sources: [UInt64: (HIDValueParser, HIDSourceRetirementFence)] = [:]
        let started = DispatchTime.now().uptimeNanoseconds
        for record in records {
            clock.advance(to: (record.deliveryTimestampNanoseconds ?? record.timestampNanoseconds) - origin)
            let identity = HIDSourceID(rawValue: UInt(record.sourceID))
            if record.kind == .removal {
                sources.removeValue(forKey: record.sourceID)?.1.retire()
                app.handleSourceRemoval(identity)
                continue
            }
            if sources[record.sourceID] == nil {
                guard sources.count < 7 else { throw ReplayError.tooManySources }
                sources[record.sourceID] = (HIDValueParser(), HIDSourceRetirementFence(sourceID: identity))
            }
            let (parser, fence) = sources[record.sourceID]!
            if let observation = parser.parseObservation(sourceID: identity, reportID: Int(record.reportID),
                bytes: record.bytes, timestamp: DispatchTime(uptimeNanoseconds: record.timestampNanoseconds - origin)) {
                app.handleRawTouchObservation(observation, fence: fence)
            }
        }
        clock.advance(to: previousDelivery - origin + UInt64(config.timing.stuckGestureTimeoutMs + 3000) * 1_000_000)
        app.handleHIDStop()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return Report(measurement: "simulated pipeline; virtual latency; no OS delivery or native AX measurement",
            reports: records.count, mouseDownPosts: input.downs, mouseUpPosts: input.ups,
            dragPosts: input.drags, scrollPosts: input.scrolls, focusRestoreRequests: focus.restores,
            finalInputBalanced: !input.pressed && !cursor.borrowed && input.downs == input.ups,
            processingMilliseconds: elapsed, metrics: app.performanceSnapshot() ?? DriverPerformanceMetrics().snapshot())
    }
}

private final class ReplayClock: GestureScheduler {
    private final class Task: GestureScheduledTask {
        let deadline: UInt64
        let action: () -> Void
        var cancelled = false
        init(_ deadline: UInt64, _ action: @escaping () -> Void) { self.deadline = deadline; self.action = action }
        func cancel() { cancelled = true }
    }
    var now = DispatchTime(uptimeNanoseconds: 0)
    private var tasks: [Task] = []
    func schedule(at deadline: DispatchTime, action: @escaping () -> Void) -> GestureScheduledTask {
        let task = Task(deadline.uptimeNanoseconds, action)
        if deadline <= now { action() } else { tasks.append(task) }
        return task
    }
    func schedule(afterMilliseconds milliseconds: Int, action: @escaping () -> Void) -> GestureScheduledTask {
        schedule(at: DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + UInt64(max(0, milliseconds)) * 1_000_000), action: action)
    }
    func advance(to time: UInt64) {
        while let index = tasks.indices.filter({ tasks[$0].deadline <= time }).min(by: { tasks[$0].deadline < tasks[$1].deadline }) {
            let task = tasks.remove(at: index)
            now = DispatchTime(uptimeNanoseconds: task.deadline)
            if !task.cancelled { task.action() }
        }
        now = DispatchTime(uptimeNanoseconds: time)
    }
}
private final class ReplayInput: ClickCountSyntheticInputSink, ScrollInputSink {
    var downs = 0, ups = 0, drags = 0, scrolls = 0
    var pressed = false
    func tryPostMouseDown(at point: CGPoint, clickCount: Int) -> SyntheticInputResult {
        guard !pressed else { return .busy }; pressed = true; downs += 1; return .postInvoked
    }
    func tryPostMouseDown(at point: CGPoint) -> SyntheticInputResult { tryPostMouseDown(at: point, clickCount: 1) }
    func tryPostMouseUp(at point: CGPoint) -> SyntheticInputResult {
        guard pressed else { return .noPendingMouseDown }; pressed = false; ups += 1; return .postInvoked
    }
    func tryPostMouseDragged(to point: CGPoint) -> SyntheticInputResult { drags += 1; return .postInvoked }
    func tryPostScroll(deltaX: Double, deltaY: Double, at point: CGPoint) -> SyntheticInputResult { scrolls += 1; return .postInvoked }
    func postMouseDown(at point: CGPoint) { _ = tryPostMouseDown(at: point) }
    func postMouseUp(at point: CGPoint) { _ = tryPostMouseUp(at: point) }
    func postMouseDragged(to point: CGPoint) { _ = tryPostMouseDragged(to: point) }
}
private final class ReplayCursor: CursorController {
    var borrowed = false
    func borrow(warpingTo point: CGPoint) -> Bool { borrowed = true; return true }
    func updatePosition(_ point: CGPoint) {}
    func returnToOrigin() { borrowed = false }
    func forceShow() { borrowed = false }
}
private final class ReplayFocus: FocusRestorer {
    var restores = 0
    func captureFocusedWindow() {}
    func restoreCapturedWindow() { restores += 1 }
    func discardCapturedWindow() {}
}
