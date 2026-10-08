@testable import MacXeneonEdgeTouchDriverCore
import XCTest

final class HIDNeutralStateTests: XCTestCase {
    private var neutral: [HIDCachedInputValue] {
        [(9, 1, 0, 1, 0, 120), (9, 2, 0, 1, 0, 10), (9, 3, 0, 1, 0, 10),
         (1, 48, 0, 16_383, 800, 110), (1, 49, 0, 9_599, 200, 110),
         (1, 56, -127, 127, 0, 10)].map {
            HIDCachedInputValue(usagePage: UInt32($0.0), usage: UInt32($0.1),
                minimum: $0.2, maximum: $0.3, value: $0.4, timestamp: UInt64($0.5))
        }
    }

    private var resetCache: [HIDCachedInputValue] {
        neutral.map { HIDCachedInputValue(usagePage: $0.usagePage, usage: $0.usage,
            minimum: $0.minimum, maximum: $0.maximum, value: 0, timestamp: 0) }
    }

    func testColdCacheMarkerIsNotAReleaseCertificate() {
        XCTAssertTrue(HIDNeutralStateReader.isUninitializedResetCache(first: resetCache, second: resetCache))
        XCTAssertNil(HIDNeutralState.certify(first: resetCache, second: resetCache, after: 0, now: 100))
    }

    func testInitializedOrPressedInputCannotBeAColdCacheMarker() {
        for index in resetCache.indices {
            for change in ["value", "timestamp"] {
                var values = resetCache
                let v = values[index]
                values[index] = HIDCachedInputValue(usagePage: v.usagePage, usage: v.usage,
                    minimum: v.minimum, maximum: v.maximum,
                    value: change == "value" ? 1 : 0, timestamp: change == "timestamp" ? 1 : 0)
                XCTAssertFalse(HIDNeutralStateReader.isUninitializedResetCache(first: values, second: values))
                XCTAssertFalse(HIDNeutralStateReader.isUninitializedResetCache(first: resetCache, second: values))
            }
        }
    }

    func testIncompleteOrWrongDescriptorCannotBeAColdCacheMarker() {
        XCTAssertFalse(HIDNeutralStateReader.isUninitializedResetCache(first: [], second: []))
        var values = resetCache
        values.swapAt(0, 1)
        XCTAssertFalse(HIDNeutralStateReader.isUninitializedResetCache(first: values, second: values))
        XCTAssertFalse(HIDNeutralStateReader.isUninitializedResetCache(first: Array(resetCache.dropLast()), second: Array(resetCache.dropLast())))
    }

    func testUnchangedFieldsCanPrecedeLossButReleaseMustFollowIt() {
        XCTAssertEqual(HIDNeutralState.certify(first: neutral, second: neutral, after: 100, now: 130),
                       HIDNeutralState(reportTimestamp: 120))
        XCTAssertNil(HIDNeutralState.certify(first: neutral, second: neutral, after: 120, now: 130))
        XCTAssertNil(HIDNeutralState.certify(first: neutral, second: neutral, after: 121, now: 130))
    }

    func testIncompleteDefaultAndFutureValuesAreNotReleaseEvidence() {
        XCTAssertNil(HIDNeutralState.certify(first: Array(neutral.dropLast()), second: Array(neutral.dropLast()), after: 0, now: 130))
        for index in neutral.indices {
            for timestamp: UInt64 in [0, 131] {
                var values = neutral
                let value = values[index]
                values[index] = HIDCachedInputValue(usagePage: value.usagePage, usage: value.usage,
                    minimum: value.minimum, maximum: value.maximum, value: value.value, timestamp: timestamp)
                XCTAssertNil(HIDNeutralState.certify(first: values, second: values, after: 0, now: 130))
            }
        }
    }

    func testPressedButtonsAndInvalidCoordinatesFailClosed() {
        for index in neutral.indices {
            var values = neutral
            let value = values[index]
            values[index] = HIDCachedInputValue(usagePage: value.usagePage, usage: value.usage,
                minimum: value.minimum, maximum: value.maximum,
                value: index < 3 ? 1 : value.maximum + 1, timestamp: value.timestamp)
            XCTAssertNil(HIDNeutralState.certify(first: values, second: values, after: 0, now: 130))
        }
    }

    func testMixedAndABAReadsCannotCertify() {
        for index in neutral.indices {
            var second = neutral
            let value = second[index]
            second[index] = HIDCachedInputValue(usagePage: value.usagePage, usage: value.usage,
                minimum: value.minimum, maximum: value.maximum, value: value.value,
                timestamp: value.timestamp + 1)
            XCTAssertNil(HIDNeutralState.certify(first: neutral, second: second, after: 0, now: 130))
        }
        var reordered = neutral
        reordered.swapAt(0, 1)
        XCTAssertNil(HIDNeutralState.certify(first: reordered, second: reordered, after: 0, now: 130))
    }
}
