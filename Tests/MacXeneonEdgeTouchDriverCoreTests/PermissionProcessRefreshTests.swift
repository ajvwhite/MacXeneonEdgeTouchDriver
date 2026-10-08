@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class PermissionProcessRefreshTests: XCTestCase {
    func testRefreshMarkerPrecedesReplacementAndPreventsASecondReplacement() throws {
        var marked = false
        var replacements = 0
        let refresh = PermissionProcessRefresh(wasRefreshed: { marked }, markRefreshed: {
            marked = true
        }, replaceProcess: {
            XCTAssertTrue(marked)
            replacements += 1
        })
        try refresh.perform()
        XCTAssertThrowsError(try refresh.perform())
        XCTAssertEqual(replacements, 1)
    }

    func testMarkerFailureNeverReplacesProcess() {
        let refresh = PermissionProcessRefresh(wasRefreshed: { false }, markRefreshed: {
            throw PermissionProcessRefresh.Failure.systemCall(12)
        }, replaceProcess: { XCTFail("The bound must be recorded before replacement") })
        XCTAssertThrowsError(try refresh.perform())
    }

    func testReplacementFailureKeepsTheRefreshBound() {
        var marked = false
        var attempts = 0
        let refresh = PermissionProcessRefresh(wasRefreshed: { marked }, markRefreshed: { marked = true },
            replaceProcess: {
                attempts += 1
                throw PermissionProcessRefresh.Failure.invalidExecutable
            })
        XCTAssertThrowsError(try refresh.perform())
        XCTAssertThrowsError(try refresh.perform())
        XCTAssertEqual(attempts, 1)
    }
}
