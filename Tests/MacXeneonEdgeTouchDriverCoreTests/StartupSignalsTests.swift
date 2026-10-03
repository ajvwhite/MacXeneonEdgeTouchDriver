import Darwin
@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class StartupSignalsTests: XCTestCase {
    func testInstallationSuppressesDefaultActionsBeforeActivatingSources() throws {
        let platform = FakeStartupSignalPlatform()
        let signals = DispatchStartupSignals(platform: platform)
        var receivedSignals: [Int32] = []

        try signals.install { receivedSignals.append($0) }

        XCTAssertEqual(platform.calls, [
            .ignore(SIGINT), .makeSource(SIGINT), .activate(SIGINT),
            .ignore(SIGTERM), .makeSource(SIGTERM), .activate(SIGTERM)
        ])
        platform.sources[0].deliver()
        platform.sources[1].deliver()
        XCTAssertEqual(receivedSignals, [SIGINT, SIGTERM])
        signals.cancel()
    }

    func testCancelRestoresCompleteOriginalActionsAndIsIdempotent() throws {
        let platform = FakeStartupSignalPlatform()
        let signals = DispatchStartupSignals(platform: platform)
        try signals.install { _ in }

        signals.cancel()
        signals.cancel()

        XCTAssertEqual(Array(platform.calls.suffix(4)), [
            .cancel(SIGINT), .cancel(SIGTERM), .restore(SIGTERM), .restore(SIGINT)
        ])
        XCTAssertEqual(platform.restoredActions.count, 2)
        for (signalNumber, action) in platform.restoredActions {
            XCTAssertEqual(action.sa_flags, platform.originalActions[signalNumber]?.sa_flags)
            XCTAssertEqual(action.sa_mask, platform.originalActions[signalNumber]?.sa_mask)
            XCTAssertEqual(
                unsafeBitCast(action.__sigaction_u.__sa_handler, to: UInt.self),
                unsafeBitCast(platform.originalActions[signalNumber]!.__sigaction_u.__sa_handler, to: UInt.self)
            )
        }
    }

    func testPartialInstallationFailureCancelsAndRestoresEarlierSignal() {
        let platform = FakeStartupSignalPlatform()
        platform.failureSignal = SIGTERM
        let signals = DispatchStartupSignals(platform: platform)
        var delivered = false

        XCTAssertThrowsError(try signals.install { _ in delivered = true }) { error in
            XCTAssertEqual(error as? FakeSignalError, .installation)
        }

        XCTAssertEqual(platform.calls, [
            .ignore(SIGINT), .makeSource(SIGINT), .activate(SIGINT),
            .ignore(SIGTERM), .cancel(SIGINT), .restore(SIGINT)
        ])
        XCTAssertEqual(platform.restoredActions.map(\.0), [SIGINT])
        platform.sources[0].deliver()
        XCTAssertFalse(delivered)
    }

    func testFirstInstallationFailureDoesNotRestoreAnActionItDidNotReplace() {
        let platform = FakeStartupSignalPlatform()
        platform.failureSignal = SIGINT
        let signals = DispatchStartupSignals(platform: platform)

        XCTAssertThrowsError(try signals.install { _ in })

        XCTAssertEqual(platform.calls, [.ignore(SIGINT)])
        XCTAssertTrue(platform.sources.isEmpty)
        XCTAssertTrue(platform.restoredActions.isEmpty)
    }

    func testCallbacksDuringCancellationAndFromOldInstallationAreIgnored() throws {
        let platform = FakeStartupSignalPlatform()
        platform.deliverOnCancel = true
        let signals = DispatchStartupSignals(platform: platform)
        var receivedSignals: [Int32] = []
        try signals.install { receivedSignals.append($0) }
        let oldSources = platform.sources

        signals.cancel()
        try signals.install { receivedSignals.append($0) }
        oldSources.forEach { $0.deliver() }

        XCTAssertTrue(receivedSignals.isEmpty)
        platform.sources.last?.deliver()
        XCTAssertEqual(receivedSignals, [SIGTERM])
        signals.cancel()
        XCTAssertEqual(receivedSignals, [SIGTERM])
    }

    func testStopFromActivationDoesNotContinueInstallingSignals() throws {
        let platform = FakeStartupSignalPlatform()
        platform.deliverOnActivate = true
        let signals = DispatchStartupSignals(platform: platform)

        try signals.install { [weak signals] _ in signals?.cancel() }

        XCTAssertEqual(platform.calls, [
            .ignore(SIGINT), .makeSource(SIGINT), .activate(SIGINT), .cancel(SIGINT), .restore(SIGINT)
        ])
    }

    func testCleanupFailureDoesNotPreventRestoringOtherSignals() throws {
        let platform = FakeStartupSignalPlatform()
        platform.restoreFailureSignal = SIGTERM
        var errors: [Error] = []
        let signals = DispatchStartupSignals(platform: platform, reportCleanupError: { errors.append($0) })
        try signals.install { _ in }

        signals.cancel()

        XCTAssertEqual(platform.restoredActions.map(\.0), [SIGTERM, SIGINT])
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first as? FakeSignalError, .restoration)
    }

    func testRepeatedInstallFailsWithoutChangingExistingHandlers() throws {
        let platform = FakeStartupSignalPlatform()
        let signals = DispatchStartupSignals(platform: platform)
        var originalHandlerCalls = 0
        try signals.install { _ in originalHandlerCalls += 1 }
        let installationCalls = platform.calls

        XCTAssertThrowsError(try signals.install { _ in XCTFail("Replaced original handler") })

        XCTAssertEqual(platform.calls, installationCalls)
        platform.sources[0].deliver()
        XCTAssertEqual(originalHandlerCalls, 1)
        signals.cancel()
    }

    func testDeinitializationCancelsSourcesAndRestoresActions() throws {
        let platform = FakeStartupSignalPlatform()
        var signals: DispatchStartupSignals? = DispatchStartupSignals(platform: platform)
        var delivered = false
        try signals?.install { _ in delivered = true }

        signals = nil
        platform.sources.forEach { $0.deliver() }

        XCTAssertEqual(platform.restoredActions.map(\.0), [SIGTERM, SIGINT])
        XCTAssertFalse(delivered)
    }
}

private enum FakeSignalError: Error {
    case installation
    case restoration
}

/// Records only in-memory actions; no real signal dispositions or dispatch sources are used.
private final class FakeStartupSignalPlatform: StartupSignalPlatform {
    enum Call: Equatable {
        case ignore(Int32)
        case makeSource(Int32)
        case activate(Int32)
        case cancel(Int32)
        case restore(Int32)
    }

    var calls: [Call] = []
    var failureSignal: Int32?
    var restoreFailureSignal: Int32?
    var deliverOnCancel = false
    var deliverOnActivate = false
    var sources: [FakeStartupSignalSource] = []
    var restoredActions: [(Int32, sigaction)] = []
    let originalActions: [Int32: sigaction] = [SIGINT, SIGTERM].reduce(into: [:]) { actions, signalNumber in
        var action = sigaction()
        action.sa_flags = signalNumber
        action.sa_mask = UInt32(signalNumber)
        action.__sigaction_u.__sa_handler = signalNumber == SIGINT ? SIG_IGN : SIG_DFL
        actions[signalNumber] = action
    }

    func ignoreDefaultAction(for signalNumber: Int32) throws -> sigaction {
        calls.append(.ignore(signalNumber))
        if failureSignal == signalNumber { throw FakeSignalError.installation }
        return originalActions[signalNumber]!
    }

    func restoreAction(_ action: sigaction, for signalNumber: Int32) throws {
        calls.append(.restore(signalNumber))
        restoredActions.append((signalNumber, action))
        if restoreFailureSignal == signalNumber { throw FakeSignalError.restoration }
    }

    func makeSource(for signalNumber: Int32, handler: @escaping () -> Void) -> StartupSignalSource {
        calls.append(.makeSource(signalNumber))
        let source = FakeStartupSignalSource(
            handler: handler,
            onActivate: { [weak self] in
                self?.calls.append(.activate(signalNumber))
                if self?.deliverOnActivate == true { handler() }
            },
            onCancel: { [weak self] in
                self?.calls.append(.cancel(signalNumber))
                if self?.deliverOnCancel == true { handler() }
            }
        )
        sources.append(source)
        return source
    }
}

private final class FakeStartupSignalSource: StartupSignalSource {
    let handler: () -> Void
    let onActivate: () -> Void
    let onCancel: () -> Void

    init(handler: @escaping () -> Void, onActivate: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.handler = handler
        self.onActivate = onActivate
        self.onCancel = onCancel
    }

    func activate() { onActivate() }
    func cancel() { onCancel() }
    func deliver() { handler() }
}
