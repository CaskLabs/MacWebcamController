import XCTest
@testable import MacWebcamController

final class UVCDescriptorParserTests: XCTestCase {
    func testParsesCameraTerminalAndProcessingUnit() {
        let data = descriptorSet(interface: 2, terminalID: 4, unitID: 7,
                                 ctControls: [0x0A, 0x01, 0x80],
                                 puControls: [0x41, 0x12, 0x01])

        let info = UVCDescriptorParser.parse(configurationDescriptor: data, targetVCInterface: 2)

        XCTAssertEqual(info.vcInterfaceNumber, 2)
        XCTAssertEqual(info.cameraTerminalID, 4)
        XCTAssertEqual(info.processingUnitID, 7)
        XCTAssertEqual(info.ctControlsBitmask, 0x0080_010A)
        XCTAssertEqual(info.puControlsBitmask, 0x0001_1241)
    }

    func testOnlyParsesRequestedVideoControlInterface() {
        var data = descriptorSet(interface: 1, terminalID: 2, unitID: 3,
                                 ctControls: [0x01], puControls: [0x02])
        data.append(descriptorSet(interface: 4, terminalID: 5, unitID: 6,
                                  ctControls: [0x10], puControls: [0x20]))

        let info = UVCDescriptorParser.parse(configurationDescriptor: data, targetVCInterface: 4)

        XCTAssertEqual(info.vcInterfaceNumber, 4)
        XCTAssertEqual(info.cameraTerminalID, 5)
        XCTAssertEqual(info.processingUnitID, 6)
        XCTAssertEqual(info.ctControlsBitmask, 0x10)
        XCTAssertEqual(info.puControlsBitmask, 0x20)
    }

    func testStopsSafelyAtMalformedDescriptor() {
        let malformed = Data([9, 4, 1, 0, 0, 0x0E, 1, 0, 0, 20, 0x24, 0x05])

        let info = UVCDescriptorParser.parse(configurationDescriptor: malformed)

        XCTAssertEqual(info.vcInterfaceNumber, 1)
        XCTAssertEqual(info.processingUnitID, 0)
    }

    private func descriptorSet(
        interface: UInt8,
        terminalID: UInt8,
        unitID: UInt8,
        ctControls: [UInt8],
        puControls: [UInt8]
    ) -> Data {
        var bytes: [UInt8] = [9, 0x04, interface, 0, 0, 0x0E, 0x01, 0, 0]

        let ctLength = UInt8(15 + ctControls.count)
        bytes += [ctLength, 0x24, 0x02, terminalID, 0x01, 0x02, 0, 0,
                  0, 0, 0, 0, 0, 0, UInt8(ctControls.count)]
        bytes += ctControls

        let puLength = UInt8(8 + puControls.count)
        bytes += [puLength, 0x24, 0x05, unitID, terminalID, 0, 0, UInt8(puControls.count)]
        bytes += puControls
        return Data(bytes)
    }
}
