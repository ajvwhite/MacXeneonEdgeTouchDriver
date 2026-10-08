import XCTest
@testable import MacXeneonEdgeTouchDriverCore

final class PhysicalInputGuardTests: XCTestCase {
    func testUnchangedCountersKeepPermitWithoutReadingInputContents() {
        let guardValue = PhysicalInputGuard(counts: { [3, 7, 0, 8, 12] })
        let permit = guardValue.capture()
        for _ in 0..<100 { XCTAssertTrue(permit()) }
    }

    func testEveryObservedInputKindRevokesPermit() {
        for index in 0..<5 {
            var counts: [UInt32] = [3, 7, 0, 8, 12]
            let permit = PhysicalInputGuard(counts: { counts }).capture()
            counts[index] &+= 1
            XCTAssertFalse(permit())
            counts = [3, 7, 0, 8, 12]
            XCTAssertFalse(permit(), "A revoked physical choice cannot become eligible again")
        }
    }

    func testCounterWrapRevokesInsteadOfComparingSignedOrder() {
        var counts: [UInt32] = [.max]
        let permit = PhysicalInputGuard(counts: { counts }).capture()
        counts[0] = 0
        XCTAssertFalse(permit())
    }

    func testSeparateTransactionsCaptureTheirOwnBaseline() {
        var counts: [UInt32] = [0]
        let guardValue = PhysicalInputGuard(counts: { counts })
        let first = guardValue.capture()
        counts[0] = 1
        let second = guardValue.capture()
        XCTAssertFalse(first())
        XCTAssertTrue(second())
    }
}
