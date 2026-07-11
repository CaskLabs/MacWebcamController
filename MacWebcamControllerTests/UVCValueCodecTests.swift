import XCTest
@testable import MacWebcamController

final class UVCValueCodecTests: XCTestCase {
    func testDecodesUnsignedLittleEndianValues() {
        XCTAssertEqual(UVCValueCodec.decode(Data([0xFE]), signed: false), 254)
        XCTAssertEqual(UVCValueCodec.decode(Data([0x34, 0x12]), signed: false), 0x1234)
        XCTAssertEqual(UVCValueCodec.decode(Data([0x78, 0x56, 0x34, 0x12]), signed: false), 0x12345678)
    }

    func testDecodesSignedValues() {
        XCTAssertEqual(UVCValueCodec.decode(Data([0xFE]), signed: true), -2)
        XCTAssertEqual(UVCValueCodec.decode(Data([0x00, 0x80]), signed: true), -32768)
        XCTAssertEqual(UVCValueCodec.decode(Data([0xFE, 0xFF, 0xFF, 0xFF]), signed: true), -2)
    }

    func testEncodesLittleEndianAndNegativeValues() {
        XCTAssertEqual(UVCValueCodec.encode(0x1234, length: 2), Data([0x34, 0x12]))
        XCTAssertEqual(UVCValueCodec.encode(0x12345678, length: 4), Data([0x78, 0x56, 0x34, 0x12]))
        XCTAssertEqual(UVCValueCodec.encode(-2, length: 2), Data([0xFE, 0xFF]))
    }

    func testUnsupportedLengthsAreSafe() {
        XCTAssertEqual(UVCValueCodec.decode(Data([1, 2, 3]), signed: false), 0)
        XCTAssertEqual(UVCValueCodec.encode(42, length: 3), Data(repeating: 0, count: 3))
    }
}
