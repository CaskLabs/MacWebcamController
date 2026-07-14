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

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:              "USB video device not found."
        case .deviceNotOpened:             "Could not open the USB host device."
        case .controlNotSupported(let c):  "\(c.displayName) is not supported by this camera."
        case .requestFailed(_, let c, let e): "UVC request for \(c.displayName) failed: \(e.localizedDescription)"
        case .rawRequestFailed(let name, let e): "\(name) failed: \(e.localizedDescription)"
        case .stall:                       "Camera rejected the control request (STALL)."
        }
    }
}

// MARK: - UVC Device

/// Communicates with a UVC camera over USB using IOUSBHostDevice.
/// Sends UVC class-specific control requests on ep0 (the device's default control endpoint),
/// without claiming any specific interface — matching the approach used by CameraController.
final class UVCDevice: @unchecked Sendable {
    let name: String
    let locationID: UInt32
    let vendorID: UInt16
    let productID: UInt16

    private let hostDevice: IOUSBHostDevice
    let vcInterfaceNumber: UInt8

    private(set) var processingUnitID: UInt8 = 0
    private(set) var cameraTerminalID: UInt8 = 0
    private(set) var supportedPUControls: UInt32 = 0
    private(set) var supportedCTControls: UInt32 = 0

    init(hostDevice: IOUSBHostDevice, vcInterfaceNumber: UInt8, name: String,
         locationID: UInt32, vendorID: UInt16, productID: UInt16) {
        self.hostDevice = hostDevice
        self.vcInterfaceNumber = vcInterfaceNumber
        self.name = name
        self.locationID = locationID
        self.vendorID = vendorID
        self.productID = productID
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
        let minimum      = try getValue(for: control, request: .getMinimum)
        let maximum      = try getValue(for: control, request: .getMaximum)
        let resolution   = try getValue(for: control, request: .getResolution)
        let defaultValue = try getValue(for: control, request: .getDefault)
        return UVCControlRange(minimum: minimum, maximum: maximum,
                               resolution: resolution, defaultValue: defaultValue)
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
        return Int((data.bytes.bindMemory(to: UInt8.self, capacity: 1).pointee))
    }

    func setAutoExposureMode(_ mode: Int) throws {
        let wValue = UInt16(0x02) << 8
        let wIndex = (UInt16(cameraTerminalID) << 8) | UInt16(vcInterfaceNumber)
        let data = NSMutableData(length: 1) ?? NSMutableData()
        data.mutableBytes.initializeMemory(as: UInt8.self, repeating: UInt8(mode & 0xFF), count: 1)
        do {
            try sendRaw(bmRequestType: UVCRequest.setCurrent.bmRequestType,
                        bRequest: UVCRequest.setCurrent.rawValue,
                        wValue: wValue, wIndex: wIndex, data: data)
        } catch {
            throw UVCDeviceError.rawRequestFailed("SET_CUR Auto Exposure Mode", error)
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
        return data.bytes.bindMemory(to: UInt8.self, capacity: 1).pointee != 0
    }

    func setFocusAuto(_ enabled: Bool) throws {
        let wValue = UInt16(0x08) << 8
        let wIndex = (UInt16(cameraTerminalID) << 8) | UInt16(vcInterfaceNumber)
        let data = NSMutableData(length: 1) ?? NSMutableData()
        data.mutableBytes.initializeMemory(as: UInt8.self, repeating: enabled ? 1 : 0, count: 1)
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
        return data.bytes.bindMemory(to: UInt8.self, capacity: 1).pointee != 0
    }

    func setWhiteBalanceAuto(_ enabled: Bool) throws {
        let wValue = UInt16(0x0B) << 8
        let wIndex = (UInt16(processingUnitID) << 8) | UInt16(vcInterfaceNumber)
        let data = NSMutableData(length: 1) ?? NSMutableData()
        data.mutableBytes.initializeMemory(as: UInt8.self, repeating: enabled ? 1 : 0, count: 1)
        do {
            try sendRaw(bmRequestType: UVCRequest.setCurrent.bmRequestType,
                        bRequest: UVCRequest.setCurrent.rawValue,
                        wValue: wValue, wIndex: wIndex, data: data)
        } catch {
            throw UVCDeviceError.rawRequestFailed("SET_CUR WB Auto", error)
        }
    }
}
