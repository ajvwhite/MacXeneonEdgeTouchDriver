import Foundation
import HIDDumpSupport
import IOKit
import XCTest

final class HIDDumpCallbackContextTests: XCTestCase {
    func testOnlySuccessfulLiveTypedContextsResolve() {
        onMain {
            let owner = Owner()
            let context = HIDDumpCallbackContext(owner: owner)
            XCTAssertTrue(resolve(context.context) === owner)
            XCTAssertNil(resolve(context.context, result: kIOReturnError))
            XCTAssertNil(resolve(context.context, result: kIOReturnAborted))
            XCTAssertNil(resolve(nil))
            XCTAssertNil(resolve(UnsafeMutableRawPointer(bitPattern: UInt.max)))
            XCTAssertNil(HIDDumpCallbackContext.owner(
                for: context.context, result: kIOReturnSuccess, as: OtherOwner.self
            ))
        }
    }

    func testInvalidationIsIdempotentAndNewSessionCannotReuseToken() {
        onMain {
            let owner = Owner()
            let retired = HIDDumpCallbackContext(owner: owner)
            retired.invalidate()
            retired.invalidate()
            XCTAssertNil(resolve(retired.context))
            let replacement = HIDDumpCallbackContext(owner: owner)
            XCTAssertNotEqual(retired.context, replacement.context)
            XCTAssertNil(resolve(retired.context))
            XCTAssertTrue(resolve(replacement.context) === owner)
        }
    }

    func testContextDoesNotKeepApplicationOwnerAlive() {
        onMain {
            var owner: Owner? = Owner()
            let context = HIDDumpCallbackContext(owner: owner!)
            weak var observed: Owner?
            observed = owner
            owner = nil
            XCTAssertNil(observed)
            XCTAssertNil(resolve(context.context))
        }
    }

    func testReleasedContextCannotResolveEvenWhenOwnerRemainsAlive() {
        onMain {
            let owner = Owner()
            var context: HIDDumpCallbackContext? = HIDDumpCallbackContext(owner: owner)
            let token = context!.context
            context = nil
            XCTAssertNil(resolve(token))
            withExtendedLifetime(owner) {}
        }
    }

    func testPromotedOwnerRemainsAliveUntilCallbackReleasesIt() {
        onMain {
            var owner: Owner? = Owner()
            weak var observed: Owner?
            observed = owner
            let context = HIDDumpCallbackContext(owner: owner!)
            var promoted = resolve(context.context)
            owner = nil
            context.invalidate()
            XCTAssertNotNil(observed)
            XCTAssertNotNil(promoted)
            promoted = nil
            XCTAssertNil(observed)
        }
    }

    func testOffMainContextCannotResolve() {
        onMain {
            let owner = Owner()
            let context = HIDDumpCallbackContext(owner: owner)
            let identity = UInt(bitPattern: context.context)
            let completed = DispatchSemaphore(value: 0)
            let worker = Thread {
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertNil(HIDDumpCallbackContext.owner(
                    for: UnsafeMutableRawPointer(bitPattern: identity),
                    result: kIOReturnSuccess, as: Owner.self
                ))
                completed.signal()
            }
            worker.start()
            completed.wait()
            XCTAssertTrue(resolve(context.context) === owner)
        }
    }

    private func resolve(_ context: UnsafeMutableRawPointer?, result: IOReturn = kIOReturnSuccess) -> Owner? {
        HIDDumpCallbackContext.owner(for: context, result: result, as: Owner.self)
    }
}

private final class Owner {}
private final class OtherOwner {}
