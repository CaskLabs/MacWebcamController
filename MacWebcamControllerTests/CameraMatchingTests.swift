import XCTest
@testable import MacWebcamController

final class CameraMatchingTests: XCTestCase {
    func testExtractsLocationIDFromUniqueIDPrefix() {
        XCTAssertEqual(CameraManager.extractLocationID(from: "0x1234ABCD-camera"), 0x1234ABCD)
        XCTAssertEqual(CameraManager.extractLocationID(from: "1234ABCD-camera"), 0x1234ABCD)
        XCTAssertNil(CameraManager.extractLocationID(from: "camera-uuid"))
        XCTAssertNil(CameraManager.extractLocationID(from: "00000000-camera"))
    }

    func testExtractsDecimalVendorAndProductIDs() {
        let ids = CameraManager.extractVendorProduct(
            from: "UVC Camera VendorID_1133 ProductID_2141"
        )
        XCTAssertEqual(ids.0, 1133)
        XCTAssertEqual(ids.1, 2141)
    }

    func testExtractsHexVendorAndProductIDs() {
        let ids = CameraManager.extractVendorProduct(from: "USB VID_046D&PID_085D")
        XCTAssertEqual(ids.0, 0x046D)
        XCTAssertEqual(ids.1, 0x085D)
    }

    func testNameSimilarityIsCaseInsensitiveAndAllowsSuffixes() {
        XCTAssertTrue(CameraManager.nameSimilar("Dell Webcam WB7022", "dell webcam wb7022"))
        XCTAssertTrue(CameraManager.nameSimilar("Dell Webcam WB7022 - RGB", "Dell Webcam WB7022"))
        XCTAssertFalse(CameraManager.nameSimilar("FaceTime Camera", "Dell Webcam WB7022"))
    }
}
