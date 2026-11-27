import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

enum UVCValueCodec {
    static func decode(_ data: Data, signed: Bool) -> Int {
        switch data.count {
        case 1: return signed ? Int(Int8(bitPattern: data[0])) : Int(data[0])
        case 2:
            let value = UInt16(data[0]) | (UInt16(data[1]) << 8)
            return signed ? Int(Int16(bitPattern: value)) : Int(value)
        case 4:
            let value = UInt32(data[0]) | (UInt32(data[1]) << 8)
                | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
            return signed ? Int(Int32(bitPattern: value)) : Int(value)
        default: return 0
        }
    }

    static func encode(_ value: Int, length: Int) -> Data {
        var data = Data(count: length)
        switch length {
        case 1:
            data[0] = UInt8(truncatingIfNeeded: value)
        case 2:
            let encoded = UInt16(truncatingIfNeeded: value)
            data[0] = UInt8(encoded & 0xFF)
            data[1] = UInt8(encoded >> 8)
        case 4:
            let encoded = UInt32(truncatingIfNeeded: value)
            data[0] = UInt8(encoded & 0xFF)
            data[1] = UInt8((encoded >> 8) & 0xFF)
            data[2] = UInt8((encoded >> 16) & 0xFF)
            data[3] = UInt8((encoded >> 24) & 0xFF)
        default:
            break
        }
        return data
    }
}

// MARK: - UVC Device Errors

enum UVCDeviceError: Error, LocalizedError {
    case deviceNotFound
    case deviceNotOpened
    case controlNotSupported(UVCControl)
    case requestFailed(UVCRequest, UVCControl, Error)
    case rawRequestFailed(String, Error)
    case stall
    case invalidResponseLength(expected: Int, actual: Int)
    case invalidRange(UVCControl)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:              "USB video device not found."
        case .deviceNotOpened:             "Could not open the USB host device."
        case .controlNotSupported(let c):  "\(c.displayName) is not supported by this camera."
        case .requestFailed(_, let c, let e): "UVC request for \(c.displayName) failed: \(e.localizedDescription)"
        case .rawRequestFailed(let name, let e): "\(name) failed: \(e.localizedDescription)"
        case .stall:                       "Camera rejected the control request (STALL)."
        case .invalidResponseLength(let expected, let actual):
            "Incomplete USB response: expected \(expected) bytes, received \(actual)."
        case .invalidRange(let control):
            "Invalid range reported for \(control.displayName)."
        }
    }
}

// MARK: - UVC Device

/// Hardware boundary used by the view model and deterministic test devices.
protocol CameraControlling: AnyObject, Sendable {
    var identity: String { get }
    var persistentIdentity: String? { get }
    var processingUnitID: UInt8 { get }
    var cameraTerminalID: UInt8 { get }
    var supportedPUControls: UInt32 { get }
    var supportedCTControls: UInt32 { get }
    var isAutoExposureSupported: Bool { get }
    var isWhiteBalanceAutoSupported: Bool { get }
    var isFocusAutoSupported: Bool { get }
    func isSupported(_ control: UVCControl) -> Bool
    func getRange(for control: UVCControl) throws -> UVCControlRange
    func getValue(for control: UVCControl, request: UVCRequest) throws -> Int
    func setValue(_ value: Int, for control: UVCControl) throws
    func getAutoExposureMode() throws -> Int
    func getWhiteBalanceAuto() throws -> Bool
    func getFocusAuto() throws -> Bool
    func setAutoExposure(enabled: Bool) throws
    func setWhiteBalanceAuto(_ enabled: Bool) throws
    func setFocusAuto(_ enabled: Bool) throws
}

extension CameraControlling {
    func getValue(for control: UVCControl) throws -> Int {
        try getValue(for: control, request: .getCurrent)
    }
}

/// Communicates with a UVC camera over USB using IOUSBHostDevice.
/// Sends UVC class-specific control requests on ep0 (the device's default control endpoint),
/// without claiming any specific interface — matching the approach used by CameraController.
final class UVCDevice: CameraControlling, @unchecked Sendable {
    let name: String
    let locationID: UInt32
    let vendorID: UInt16
    let productID: UInt16
    let serialNumber: String?

    /// Port-independent identity only when the camera supplies a serial number.
    var persistentIdentity: String? {
        guard let serialNumber, !serialNumber.isEmpty else { return nil }
        return "\(vendorID):\(productID):\(serialNumber):\(vcInterfaceNumber)"
    }

    var identity: String {
        "\(serialNumber ?? ""):\(vendorID):\(productID):\(locationID):\(vcInterfaceNumber):\(processingUnitID):\(cameraTerminalID):\(supportedPUControls):\(supportedCTControls)"
    }

    private let hostDevice: IOUSBHostDevice
    let vcInterfaceNumber: UInt8

    private(set) var processingUnitID: UInt8 = 0
    private(set) var cameraTerminalID: UInt8 = 0
    private(set) var supportedPUControls: UInt32 = 0
    private(set) var supportedCTControls: UInt32 = 0

    init(hostDevice: IOUSBHostDevice, vcInterfaceNumber: UInt8, name: String,
         locationID: UInt32, vendorID: UInt16, productID: UInt16, serialNumber: String? = nil) {
        self.hostDevice = hostDevice
        self.vcInterfaceNumber = vcInterfaceNumber
        self.name = name
        self.locationID = locationID
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit {
        // Release the user client and its notification port deterministically
        // instead of waiting for IOUSBHostObject's automatic cleanup.
        hostDevice.destroy()
    }

    // MARK: - Configuration

    func configure(processingUnitID: UInt8, cameraTerminalID: UInt8,
                   supportedPUControls: UInt32, supportedCTControls: UInt32) {
        self.processingUnitID = processingUnitID
        self.cameraTerminalID = cameraTerminalID
        self.supportedPUControls = supportedPUControls
        self.supportedCTControls = supportedCTControls
    }

    // MARK: - Unit ID

    private func unitID(for control: UVCControl) -> UInt8 {
        control.unitType == .processingUnit ? processingUnitID : cameraTerminalID
    }

    // MARK: - Supported Controls
    // Bit positions from UVC 1.5 spec Table 4-11 (PU) and Table 4-9 (CT).

    func isSupported(_ control: UVCControl) -> Bool {
        // If the camera didn't advertise any capabilities in bmControls
        // (both masks are zero), assume all controls may be supported and
        // let the actual USB request succeed or fail.
        if supportedPUControls == 0 && supportedCTControls == 0 { return true }

        switch control {
        // Processing Unit bmControls (Table 4-11)
        case .brightness:               return supportedPUControls & (1 << 0)  != 0  // D0
        case .contrast:                 return supportedPUControls & (1 << 1)  != 0  // D1
        case .saturation:               return supportedPUControls & (1 << 3)  != 0  // D3
        case .sharpness:                return supportedPUControls & (1 << 4)  != 0  // D4
        case .gamma:                    return supportedPUControls & (1 << 5)  != 0  // D5
        case .whiteBalanceTemperature:  return supportedPUControls & (1 << 6)  != 0  // D6
        case .backlightCompensation:    return supportedPUControls & (1 << 8)  != 0  // D8
        case .gain:                     return supportedPUControls & (1 << 9)  != 0  // D9
        case .powerlineFrequency:       return supportedPUControls & (1 << 10) != 0  // D10
        // Camera Terminal bmControls (Table 4-9)
        case .exposureAbsolute:         return supportedCTControls & (1 << 3)  != 0  // D3
        case .focusAbsolute:            return supportedCTControls & (1 << 5)  != 0  // D5
        }
    }

    // MARK: - Auto-Mode Support Checks

    /// Whether the camera supports Auto-Exposure Mode (CT bmControls D1).
    var isAutoExposureSupported: Bool { supportedCTControls & (1 << 1) != 0 }

    /// Whether the camera supports White Balance Temperature Auto (PU bmControls D12).
    var isWhiteBalanceAutoSupported: Bool { supportedPUControls & (1 << 12) != 0 }

    /// Whether the camera supports Focus Auto (CT bmControls D17).
    var isFocusAutoSupported: Bool { supportedCTControls & (1 << 17) != 0 }

    // MARK: - Core Control Request

    /// Sends a raw UVC class-specific control request on the device's default control endpoint.
    private func sendRaw(
        bmRequestType: UInt8, bRequest: UInt8,
        wValue: UInt16, wIndex: UInt16,
        data: NSMutableData
    ) throws {
        var req = IOUSBDeviceRequest()
        req.bmRequestType = bmRequestType
        req.bRequest = bRequest
        req.wValue = wValue
        req.wIndex = wIndex
        req.wLength = UInt16(data.length)

        var bytesTransferred: UInt = 0
        try hostDevice.__send(req, data: data, bytesTransferred: &bytesTransferred, completionTimeout: 5.0)
        if bmRequestType & 0x80 != 0, bytesTransferred != UInt(data.length) {
            throw UVCDeviceError.invalidResponseLength(expected: data.length, actual: Int(bytesTransferred))
        }
    }

    private func sendRequest(_ request: UVCRequest, control: UVCControl, dataLength: Int? = nil) throws -> Data {
        let length = dataLength ?? control.dataLength
        let unitID = unitID(for: control)
        let wValue = UInt16(control.selector) << 8
        let wIndex = (UInt16(unitID) << 8) | UInt16(vcInterfaceNumber)

        let mutableData = NSMutableData(length: length) ?? NSMutableData()
        do {
            try sendRaw(bmRequestType: request.bmRequestType, bRequest: request.rawValue,
                        wValue: wValue, wIndex: wIndex, data: mutableData)
        } catch {
            throw UVCDeviceError.requestFailed(request, control, error)
        }
        return mutableData as Data
    }

    // MARK: - Value Conversion

    // MARK: - Public Slider Controls

    func getValue(for control: UVCControl, request: UVCRequest = .getCurrent) throws -> Int {
        let data = try sendRequest(request, control: control)
        return UVCValueCodec.decode(data, signed: control.isSigned)
    }

    func setValue(_ value: Int, for control: UVCControl) throws {
        let payload = UVCValueCodec.encode(value, length: control.dataLength)
        let unitID = unitID(for: control)
        let wValue = UInt16(control.selector) << 8
        let wIndex = (UInt16(unitID) << 8) | UInt16(vcInterfaceNumber)

        let mutableData = NSMutableData(data: payload)
        do {
            try sendRaw(bmRequestType: UVCRequest.setCurrent.bmRequestType,
                        bRequest: UVCRequest.setCurrent.rawValue,
                        wValue: wValue, wIndex: wIndex, data: mutableData)
        } catch {
            throw UVCDeviceError.requestFailed(.setCurrent, control, error)
        }
    }

    func getRange(for control: UVCControl) throws -> UVCControlRange {
        try UVCControlRange.read(for: control) { request in
            try getValue(for: control, request: request)
        }
    }

    func getInfo(for control: UVCControl) throws -> UVCInfoCapabilities {
        let data = try sendRequest(.getInfo, control: control, dataLength: 1)
        return UVCInfoCapabilities(rawValue: data[0])
    }

    // MARK: - Auto Exposure Mode (CT selector 0x02)
    // UVC values: 1 = Manual, 2 = Auto, 4 = Shutter Priority, 8 = Aperture Priority

    func getAutoExposureMode() throws -> Int {
        let wValue = UInt16(0x02) << 8  // CT_AE_MODE_CONTROL selector
        let wIndex = (UInt16(cameraTerminalID) << 8) | UInt16(vcInterfaceNumber)
        let data = NSMutableData(length: 1) ?? NSMutableData()
        do {
            try sendRaw(bmRequestType: UVCRequest.getCurrent.bmRequestType,
                        bRequest: UVCRequest.getCurrent.rawValue,
                        wValue: wValue, wIndex: wIndex, data: data)
        } catch {
            throw UVCDeviceError.rawRequestFailed("GET_CUR Auto Exposure Mode", error)
        }
        var byte: UInt8 = 0
        data.getBytes(&byte, length: 1)
        return Int(byte)
    }

    func setAutoExposureMode(_ mode: Int) throws {
        let wValue = UInt16(0x02) << 8
        let wIndex = (UInt16(cameraTerminalID) << 8) | UInt16(vcInterfaceNumber)
        var byte = UInt8(mode & 0xFF)
        let data = NSMutableData(bytes: &byte, length: 1)
        do {
            try sendRaw(bmRequestType: UVCRequest.setCurrent.bmRequestType,
                        bRequest: UVCRequest.setCurrent.rawValue,
                        wValue: wValue, wIndex: wIndex, data: data)
        } catch {
            throw UVCDeviceError.rawRequestFailed("SET_CUR Auto Exposure Mode", error)
        }
    }

    /// Queries the bitmask of supported Auto-Exposure modes via GET_RES on CT selector 0x02.
    /// Bit 0: Manual (1), Bit 1: Auto (2), Bit 2: Shutter Priority (4), Bit 3: Aperture Priority (8).
    func getAutoExposureSupportedModes() -> UInt8 {
        let wValue = UInt16(0x02) << 8
        let wIndex = (UInt16(cameraTerminalID) << 8) | UInt16(vcInterfaceNumber)
        let data = NSMutableData(length: 1) ?? NSMutableData()
        do {
            try sendRaw(bmRequestType: UVCRequest.getResolution.bmRequestType,
                        bRequest: UVCRequest.getResolution.rawValue,
                        wValue: wValue, wIndex: wIndex, data: data)
            var byte: UInt8 = 0
            data.getBytes(&byte, length: 1)
            return byte
        } catch {
            return 0
        }
    }

    /// Sets Auto Exposure on or off using the best supported mode.
    /// When enabling: prefers Full Auto (2), then Aperture Priority (8), then Shutter Priority (4).
    /// When disabling: sets Manual mode (1).
    func setAutoExposure(enabled: Bool) throws {
        if !enabled {
            try setAutoExposureMode(1)
            return
        }

        let supportedModes = getAutoExposureSupportedModes()
        if supportedModes != 0 {
            if (supportedModes & 2) != 0 {
                try setAutoExposureMode(2)
                return
            } else if (supportedModes & 8) != 0 {
                try setAutoExposureMode(8)
                return
            } else if (supportedModes & 4) != 0 {
                try setAutoExposureMode(4)
                return
            }
        }

        // Fallback if GET_RES returned 0 or wasn't supported: try Auto (2), then Aperture Priority (8)
        do {
            try setAutoExposureMode(2)
        } catch {
            try setAutoExposureMode(8)
        }
    }

    // MARK: - Focus Auto (CT selector 0x08)

    func getFocusAuto() throws -> Bool {
        let wValue = UInt16(0x08) << 8  // CT_FOCUS_AUTO_CONTROL
        let wIndex = (UInt16(cameraTerminalID) << 8) | UInt16(vcInterfaceNumber)
        let data = NSMutableData(length: 1) ?? NSMutableData()
        do {
            try sendRaw(bmRequestType: UVCRequest.getCurrent.bmRequestType,
                        bRequest: UVCRequest.getCurrent.rawValue,
                        wValue: wValue, wIndex: wIndex, data: data)
        } catch {
            throw UVCDeviceError.rawRequestFailed("GET_CUR Focus Auto", error)
        }
        var byte: UInt8 = 0
        data.getBytes(&byte, length: 1)
        return byte != 0
    }

    func setFocusAuto(_ enabled: Bool) throws {
        let wValue = UInt16(0x08) << 8
        let wIndex = (UInt16(cameraTerminalID) << 8) | UInt16(vcInterfaceNumber)
        var byte: UInt8 = enabled ? 1 : 0
        let data = NSMutableData(bytes: &byte, length: 1)
        do {
            try sendRaw(bmRequestType: UVCRequest.setCurrent.bmRequestType,
                        bRequest: UVCRequest.setCurrent.rawValue,
                        wValue: wValue, wIndex: wIndex, data: data)
        } catch {
            throw UVCDeviceError.rawRequestFailed("SET_CUR Focus Auto", error)
        }
    }

    // MARK: - White Balance Temperature Auto (PU selector 0x0B)

    func getWhiteBalanceAuto() throws -> Bool {
        let wValue = UInt16(0x0B) << 8  // PU_WHITE_BALANCE_TEMPERATURE_AUTO_CONTROL
        let wIndex = (UInt16(processingUnitID) << 8) | UInt16(vcInterfaceNumber)
        let data = NSMutableData(length: 1) ?? NSMutableData()
        do {
            try sendRaw(bmRequestType: UVCRequest.getCurrent.bmRequestType,
                        bRequest: UVCRequest.getCurrent.rawValue,
                        wValue: wValue, wIndex: wIndex, data: data)
        } catch {
            throw UVCDeviceError.rawRequestFailed("GET_CUR WB Auto", error)
        }
        var byte: UInt8 = 0
        data.getBytes(&byte, length: 1)
        return byte != 0
    }

    func setWhiteBalanceAuto(_ enabled: Bool) throws {
        let wValue = UInt16(0x0B) << 8
        let wIndex = (UInt16(processingUnitID) << 8) | UInt16(vcInterfaceNumber)
        var byte: UInt8 = enabled ? 1 : 0
        let data = NSMutableData(bytes: &byte, length: 1)
        do {
            try sendRaw(bmRequestType: UVCRequest.setCurrent.bmRequestType,
                        bRequest: UVCRequest.setCurrent.rawValue,
                        wValue: wValue, wIndex: wIndex, data: data)
        } catch {
            throw UVCDeviceError.rawRequestFailed("SET_CUR WB Auto", error)
        }
    }
}
