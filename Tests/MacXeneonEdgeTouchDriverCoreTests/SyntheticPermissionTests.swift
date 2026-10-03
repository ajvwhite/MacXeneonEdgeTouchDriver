@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class SyntheticPermissionTests: XCTestCase {
    func testSnapshotsReadBothFactsWithoutRequests() {
        var reads = 0
        var requests = 0
        let provider = SystemSyntheticPermissionProvider(
            readSnapshot: {
                reads += 1
                return SyntheticPermissionSnapshot(postEventAccess: true, accessibilityTrusted: false)
            },
            requestPostEventAccess: { requests += 1; return false },
            requestAccessibilityTrust: { requests += 1 }
        )
        XCTAssertTrue(provider.snapshot().isReady)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(requests, 0)
    }

    func testUnreadySequenceRequestsCGThenAXOnce() {
        var calls: [String] = []
        let provider = SystemSyntheticPermissionProvider(
            readSnapshot: { SyntheticPermissionSnapshot(postEventAccess: false, accessibilityTrusted: false) },
            requestPostEventAccess: { calls.append("CG"); return false },
            requestAccessibilityTrust: { calls.append("AX") }
        )
        provider.requestInitialAccess(cancellation: StartupCancellation())
        XCTAssertEqual(calls, ["CG", "AX"])
        XCTAssertFalse(provider.snapshot().isReady, "An AX prompt returning does not establish readiness.")
    }

    func testReadyBeforeWorkerRunsSkipsBothRequests() {
        for snapshot in [
            SyntheticPermissionSnapshot(postEventAccess: true, accessibilityTrusted: false),
            SyntheticPermissionSnapshot(postEventAccess: false, accessibilityTrusted: true)
        ] {
            let provider = SystemSyntheticPermissionProvider(
                readSnapshot: { snapshot },
                requestPostEventAccess: { XCTFail("Unexpected CG request"); return false },
                requestAccessibilityTrust: { XCTFail("Unexpected AX request") }
            )
            provider.requestInitialAccess(cancellation: StartupCancellation())
        }
    }

    func testSuccessfulCGRequestSkipsAXButDoesNotReplaceSnapshot() {
        let provider = SystemSyntheticPermissionProvider(
            readSnapshot: { SyntheticPermissionSnapshot(postEventAccess: false, accessibilityTrusted: false) },
            requestPostEventAccess: { true },
            requestAccessibilityTrust: { XCTFail("Unexpected AX request") }
        )
        provider.requestInitialAccess(cancellation: StartupCancellation())
        XCTAssertFalse(provider.snapshot().isReady)
    }

    func testGrantDuringCGRequestSkipsAX() {
        var granted = false
        let provider = SystemSyntheticPermissionProvider(
            readSnapshot: { SyntheticPermissionSnapshot(postEventAccess: granted, accessibilityTrusted: false) },
            requestPostEventAccess: { granted = true; return false },
            requestAccessibilityTrust: { XCTFail("Readiness was granted before AX request") }
        )
        provider.requestInitialAccess(cancellation: StartupCancellation())
        XCTAssertTrue(provider.snapshot().isReady)
    }

    func testCanceledBeforeRequestSkipsEvenSnapshot() {
        let cancellation = StartupCancellation()
        cancellation.cancel()
        let provider = SystemSyntheticPermissionProvider(
            readSnapshot: { XCTFail("Unexpected read"); return SyntheticPermissionSnapshot(postEventAccess: false, accessibilityTrusted: false) },
            requestPostEventAccess: { XCTFail("Unexpected CG request"); return false },
            requestAccessibilityTrust: { XCTFail("Unexpected AX request") }
        )
        provider.requestInitialAccess(cancellation: cancellation)
    }

    func testCancellationDuringPostRequestSnapshotPreventsAXRequest() {
        let cancellation = StartupCancellation()
        var reads = 0
        let provider = SystemSyntheticPermissionProvider(
            readSnapshot: {
                reads += 1
                if reads == 2 { cancellation.cancel() }
                return SyntheticPermissionSnapshot(postEventAccess: false, accessibilityTrusted: false)
            },
            requestPostEventAccess: { false },
            requestAccessibilityTrust: { XCTFail("Canceled snapshot continued to AX") }
        )
        provider.requestInitialAccess(cancellation: cancellation)
        XCTAssertEqual(reads, 2)
    }

    func testCancellationDuringBlockedCGRequestPreventsLaterAXRequest() {
        let cancellation = StartupCancellation()
        var cgRequests = 0
        let provider = SystemSyntheticPermissionProvider(
            readSnapshot: { SyntheticPermissionSnapshot(postEventAccess: false, accessibilityTrusted: false) },
            requestPostEventAccess: {
                cgRequests += 1
                // Model stop arriving while CG is blocked, before it returns.
                cancellation.cancel()
                return false
            },
            requestAccessibilityTrust: { XCTFail("Canceled request continued to AX") }
        )
        provider.requestInitialAccess(cancellation: cancellation)
        XCTAssertEqual(cgRequests, 1)
    }
}
