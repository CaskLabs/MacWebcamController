import XCTest
@testable import MacWebcamController

final class UVCControlRangeTests: XCTestCase {
    func testStateAdoptsCompleteRangeAndNormalizesZeroResolution() {
        var state = ControlState()
        state.range = UVCControlRange(minimum: -10, maximum: 90, resolution: 0, defaultValue: 20)
        XCTAssertEqual(state.minimum, -10)
        XCTAssertEqual(state.maximum, 90)
        XCTAssertEqual(state.resolution, 1)
        XCTAssertEqual(state.defaultValue, 20)
    }

    func testSnapsRelativeToMinimumAndNeverExceedsLastValidStep() {
        let range = UVCControlRange(minimum: 3, maximum: 24, resolution: 5, defaultValue: 8)
        XCTAssertEqual(range.normalized(17), 18)
        XCTAssertEqual(range.normalized(Int.min), 3)
        XCTAssertEqual(range.normalized(Int.max), 23)
        XCTAssertEqual(range.normalized(24), 23)
    }

    func testSignedRangesAndInvalidResolutionRemainSafe() {
        let signed = UVCControlRange(minimum: -13, maximum: 12, resolution: 5, defaultValue: -3)
        XCTAssertEqual(signed.normalized(-5), -3)
        let zero = UVCControlRange(minimum: 0, maximum: 10, resolution: 0, defaultValue: 0)
        XCTAssertEqual(zero.normalized(7), 7)
    }
    func testMissingOptionalMetadataFallsBackToCurrentValueAndUnitStep() throws {
        let range = try UVCControlRange.read(for: .brightness) { request in
            switch request {
            case .getMinimum: return -10
            case .getMaximum: return 90
            case .getCurrent: return 17
            default: throw UVCDeviceError.stall
            }
        }
        XCTAssertEqual(range.minimum, -10)
        XCTAssertEqual(range.maximum, 90)
        XCTAssertEqual(range.resolution, 1)
        XCTAssertEqual(range.defaultValue, 17)
    }

    func testMandatoryBoundsAndDegenerateRangesAreRejected() {
        XCTAssertThrowsError(try UVCControlRange.read(for: .brightness) { _ in
            throw UVCDeviceError.stall
        })
        XCTAssertThrowsError(try UVCControlRange.read(for: .brightness) { _ in 6 })
    }

}
