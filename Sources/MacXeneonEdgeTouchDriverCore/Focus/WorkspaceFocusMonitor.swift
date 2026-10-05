import AppKit
import CoreGraphics
import Foundation

struct WorkspaceFocusSnapshot {
    let application: AXFocusWorkspaceApplication?
    let revision: UInt64
    let sessionActive: Bool
}

/// Methods and observation delivery belong to main. Observations are synchronous
/// invalidation hints; moving them to a later queue turn changes focus eligibility.
protocol WorkspaceFocusMonitoring: AnyObject {
    func start(observation: @escaping (FocusObservationEvent) -> Void)
    func snapshot() -> WorkspaceFocusSnapshot
    func application(processIdentifier: pid_t) -> AXFocusWorkspaceApplication?
    func stop()
}

/// All NSWorkspace/NSRunningApplication access and observer lifetime live on main.
/// Revisions are invalidation hints, not substitutes for fresh AX focus resolution.
final class WorkspaceFocusMonitor: WorkspaceFocusMonitoring {
    enum Event: Sendable {
        case focusChanged
        case lifecycleChanged
        case sessionActive(Bool)
        case sleeping(Bool)
    }

    struct Operations {
        var frontmostApplication: () -> AXFocusWorkspaceApplication?
        var application: (pid_t) -> AXFocusWorkspaceApplication?
        var sessionIsActive: () -> Bool?
        // Register on main and deliver every handler invocation on main. The
        // returned removal closure is also invoked on main, once per registration.
        // It must retain its registration resources until removal and must not
        // require the monitor to remain alive. Already queued notifications may
        // still arrive after removal; the weak/generation guards reject them.
        var observe: (@escaping (Event) -> Void) -> (() -> Void)

        // Construct per monitor; workspace access and observer callbacks remain main-thread confined.
        static var live: Operations {
            Operations(
                frontmostApplication: { snapshot(NSWorkspace.shared.frontmostApplication) },
                application: { snapshot(NSRunningApplication(processIdentifier: $0)) },
                sessionIsActive: {
                    guard let values = CGSessionCopyCurrentDictionary() as? [String: Any],
                          let onConsole = values[kCGSessionOnConsoleKey as String] as? Bool,
                          let loggedIn = values[kCGSessionLoginDoneKey as String] as? Bool else { return nil }
                    return onConsole && loggedIn
                },
                observe: { handler in
                    let center = NSWorkspace.shared.notificationCenter
                    let names: [(Notification.Name, Event)] = [
                        (NSWorkspace.didActivateApplicationNotification, .focusChanged),
                        (NSWorkspace.didDeactivateApplicationNotification, .focusChanged),
                        (NSWorkspace.didTerminateApplicationNotification, .lifecycleChanged),
                        (NSWorkspace.activeSpaceDidChangeNotification, .lifecycleChanged),
                        (NSWorkspace.sessionDidResignActiveNotification, .sessionActive(false)),
                        (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive(true)),
                        (NSWorkspace.willSleepNotification, .sleeping(true)),
                        (NSWorkspace.didWakeNotification, .sleeping(false))
                    ]
                    let observers = names.map { name, event in
                        center.addObserver(forName: name, object: nil, queue: .main) { _ in handler(event) }
                    }
                    return { observers.forEach(center.removeObserver) }
                }
            )
        }

        private static func snapshot(_ application: NSRunningApplication?) -> AXFocusWorkspaceApplication? {
            guard let application else { return nil }
            return AXFocusWorkspaceApplication(
                processIdentifier: application.processIdentifier,
                identity: application,
                isTerminated: application.isTerminated,
                isHidden: application.isHidden
            )
        }
    }

    private let operations: Operations
    private var stopObserving: (() -> Void)?
    private var observation: ((FocusObservationEvent) -> Void)?
    private var revision: UInt64 = 0
    private var observationGeneration: UInt64 = 0
    private var sessionActive: Bool?
    private var sleeping = false

    init(operations: Operations = .live) {
        self.operations = operations
    }

    deinit {
        // No callback can concurrently own this instance at final release: observer
        // delivery promotes weak self for its duration. Transfer only the removal
        // closure, which retains the registration resources independently, to main.
        // The closure must never capture this monitor strongly.
        let stop = stopObserving
        if Thread.isMainThread { stop?() }
        else { DispatchQueue.main.async { stop?() } }
    }

    func start(observation: @escaping (FocusObservationEvent) -> Void) {
        precondition(Thread.isMainThread)
        self.observation = observation
        guard stopObserving == nil else { return }
        observationGeneration &+= 1
        let generation = observationGeneration
        stopObserving = operations.observe { [weak self] event in
            precondition(Thread.isMainThread)
            guard let self, self.stopObserving != nil, self.observationGeneration == generation else { return }
            self.revision &+= 1
            switch event {
            case .focusChanged:
                self.observation?(.focusChanged)
            case .lifecycleChanged:
                self.observation?(.lifecycleChanged)
            case .sessionActive(let active):
                self.sessionActive = active
                self.observation?(.lifecycleChanged)
            case .sleeping(let sleeping):
                self.sleeping = sleeping
                self.observation?(.lifecycleChanged)
            }
        }
    }

    func snapshot() -> WorkspaceFocusSnapshot {
        precondition(Thread.isMainThread)
        return WorkspaceFocusSnapshot(application: operations.frontmostApplication(), revision: revision,
                                      sessionActive: !sleeping && sessionActive != false && operations.sessionIsActive() == true)
    }

    func application(processIdentifier: pid_t) -> AXFocusWorkspaceApplication? {
        precondition(Thread.isMainThread)
        return operations.application(processIdentifier)
    }

    func stop() {
        precondition(Thread.isMainThread)
        observation = nil
        observationGeneration &+= 1
        let stop = stopObserving
        stopObserving = nil
        stop?()
        revision &+= 1
    }
}
