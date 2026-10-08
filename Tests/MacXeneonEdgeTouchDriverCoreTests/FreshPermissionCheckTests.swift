@testable import MacXeneonEdgeTouchDriverCore
import Darwin
import Foundation
import XCTest

final class FreshPermissionCheckTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/test/driver")
    private let granted = Data(#"{"postEventAccess":true,"accessibilityTrusted":true,"hidInputAccess":"granted","readyForUnattendedStart":true}"#.utf8)
    private let denied = Data(#"{"postEventAccess":true,"accessibilityTrusted":true,"hidInputAccess":"denied","readyForUnattendedStart":false}"#.utf8)

    func testGrantedAndDeniedResultsAreBothAcceptedAsPermissionFacts() {
        for (data, code, ready) in [(granted, Int32(EXIT_SUCCESS), true), (denied, Int32(EX_NOPERM), false)] {
            let process = ProbeProcessFake(output: data, status: code)
            let check = FreshPermissionCheck(executableURL: url, makeProcess: { _ in process })
            XCTAssertEqual(check.snapshot(cancellation: StartupCancellation())?.isReady, ready)
            XCTAssertEqual(process.launches, 1)
            XCTAssertEqual(process.terminations, 0)
        }
    }

    func testBadOutputOrExitCannotEstablishPermission() {
        let cases: [(Data, Int32, Bool)] = [
            (Data(), 0, true), (Data("not JSON".utf8), 0, true),
            (Data(repeating: 32, count: 4097), 0, true),
            (granted, EX_NOPERM, true), (denied, 0, true),
            (granted, 0, false),
            (Data(#"{"postEventAccess":true,"accessibilityTrusted":false,"hidInputAccess":"granted","readyForUnattendedStart":true}"#.utf8), 0, true),
            (Data(#"{"postEventAccess":true,"accessibilityTrusted":true,"hidInputAccess":"unrecognised","readyForUnattendedStart":true}"#.utf8), 0, true)
        ]
        for (data, code, normal) in cases {
            let process = ProbeProcessFake(output: data, status: code)
            process.normalExit = normal
            let check = FreshPermissionCheck(executableURL: url, makeProcess: { _ in process })
            XCTAssertNil(check.snapshot(cancellation: StartupCancellation()))
        }
    }

    func testCancelledBeforeLaunchDoesNotCreateAProcess() {
        let cancellation = StartupCancellation(); cancellation.cancel()
        let check = FreshPermissionCheck(executableURL: url, makeProcess: { _ in
            XCTFail("Cancelled check launched a child"); return ProbeProcessFake(output: self.granted)
        })
        XCTAssertNil(check.snapshot(cancellation: cancellation))
    }

    func testCancellationWhileWaitingStopsOwnedChildAndRejectsItsLateGrant() {
        let cancellation = StartupCancellation()
        let process = ProbeProcessFake(output: granted)
        process.exited = false
        process.onWait = { _ in cancellation.cancel(); return false }
        process.onTerminate = { process.exited = true; process.onWait = nil }
        let check = FreshPermissionCheck(executableURL: url, makeProcess: { _ in process })
        XCTAssertNil(check.snapshot(cancellation: cancellation))
        XCTAssertEqual(process.terminations, 1)
    }

    func testTimeoutStopsChildAndRejectsItsLateGrant() {
        let process = ProbeProcessFake(output: granted)
        process.exited = false
        process.onTerminate = { process.exited = true }
        let check = FreshPermissionCheck(executableURL: url, timeout: 0.1, makeProcess: { _ in process })
        XCTAssertNil(check.snapshot(cancellation: StartupCancellation()))
        XCTAssertEqual(process.terminations, 1)
        XCTAssertTrue(process.exited)
    }

    func testUnprovedClosureBlocksAnotherChildUntilTheOldOneExits() {
        let blocked = ProbeProcessFake(output: granted); blocked.exited = false
        let next = ProbeProcessFake(output: granted)
        var launches = 0
        let check = FreshPermissionCheck(executableURL: url, timeout: 0.1, stopTimeout: 0.1, makeProcess: { _ in
            launches += 1; return launches == 1 ? blocked : next
        })
        XCTAssertNil(check.snapshot(cancellation: StartupCancellation()))
        XCTAssertNil(check.snapshot(cancellation: StartupCancellation()))
        XCTAssertEqual(launches, 1)
        blocked.exited = true
        XCTAssertTrue(check.snapshot(cancellation: StartupCancellation())?.isReady == true)
        XCTAssertEqual(launches, 2)
    }

    func testMissingExecutableAndLaunchFailureRemainUnknown() {
        let missing = FreshPermissionCheck(executableURL: nil)
        XCTAssertNil(missing.snapshot(cancellation: StartupCancellation()))
        let process = ProbeProcessFake(output: granted); process.launchError = CocoaError(.fileNoSuchFile)
        let check = FreshPermissionCheck(executableURL: url, makeProcess: { _ in process })
        XCTAssertNil(check.snapshot(cancellation: StartupCancellation()))
        XCTAssertEqual(process.terminations, 0)
    }

    func testRealChildReceivesOnlyTheReadOnlyFlagAndItsOutputIsDecoded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("permission-fixture")
        let script = "#!/bin/sh\n[ \"$#\" -eq 1 ] && [ \"$1\" = '--check-permissions' ] || exit 1\nprintf '%s\\n' '\(String(decoding: granted, as: UTF8.self))'\n"
        try script.write(to: executable, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let check = FreshPermissionCheck(executableURL: executable)
        XCTAssertTrue(check.snapshot(cancellation: StartupCancellation())?.isReady == true)
    }
}

private final class ProbeProcessFake: PermissionProbeProcess {
    let output: Data
    let exitStatus: Int32
    var normalExit = true
    var exited = true
    var launchError: Error?
    var onWait: ((TimeInterval) -> Bool)?
    var onTerminate: (() -> Void)?
    private(set) var launches = 0
    private(set) var terminations = 0
    init(output: Data, status: Int32 = 0) { self.output = output; exitStatus = status }
    func launch() throws { launches += 1; if let launchError { throw launchError } }
    func wait(seconds: TimeInterval) -> Bool { onWait?(seconds) ?? exited }
    func terminate() { terminations += 1; onTerminate?() }
}
