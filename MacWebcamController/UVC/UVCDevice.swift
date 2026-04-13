import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

// MARK: - UVC Device Errors

enum UVCDeviceError: Error, LocalizedError {
    case deviceNotFound
    case interfaceNotOpened
    case controlNotSupported(UVCControl)
    case requestFailed(UVCRequest, UVCControl, Error)
    case stall

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:            "USB video device not found."
        case .interfaceNotOpened:        "Could not open the USB video control interface."
        case .controlNotSupported(let c): "\(c.displayName) is not supported by this camera."
        case .requestFailed(_, let c, let e): "UVC request for \(c.displayName) failed: \(e.localizedDescription)"
        case .stall:                     "Camera rejected the control request (STALL)."
        }
    }
}

// MARK: - UVC Device

/// Communicates with a UVC camera over USB using IOUSBHost.
final class UVCDevice: @unchecked Sendable {
    let name: String
    let locationID: UInt32
    let vendorID: UInt16
    let productID: UInt16

    // IOUSBHostInterface is kept alive for device lifetime
    private let interface: IOUSBHostInterface
    private let vcInterfaceNumber: UInt8

    private(set) var processingUnitID: UInt8 = 0
    private(set) var cameraTerminalID: UInt8 = 0
    private(set) var supportedPUControls: UInt32 = 0
    private(set) var supportedCTControls: UInt32 = 0

    init(interface: IOUSBHostInterface, vcInterfaceNumber: UInt8, name: String,
         locationID: UInt32, vendorID: UInt16, productID: UInt16) {
        self.interface = interface
        self.vcInterfaceNumber = vcInterfaceNumber
        self.name = name
        self.locationID = locationID
        self.vendorID = vendorID
        self.productID = productID
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

    func isSupported(_ control: UVCControl) -> Bool {
        switch control {
        case .brightness:               return supportedPUControls & (1 << 0) != 0
        case .contrast:                 return supportedPUControls & (1 << 1) != 0
        case .saturation:               return supportedPUControls & (1 << 3) != 0
        case .sharpness:                return supportedPUControls & (1 << 4) != 0
        case .gamma:                    return supportedPUControls & (1 << 6) != 0
        case .whiteBalanceTemperature:  return supportedPUControls & (1 << 7) != 0
        case .gain:                     return supportedPUControls & (1 << 9) != 0
        case .backlightCompensation:    return supportedPUControls & (1 << 8) != 0
        case .powerlineFrequency:       return supportedPUControls & (1 << 5) != 0
        case .exposureAbsolute:         return supportedCTControls & (1 << 1) != 0
        case .focusAbsolute:            return supportedCTControls & (1 << 5) != 0
        }
    }

    // MARK: - Core Control Request

    private func sendRequest(_ request: UVCRequest, control: UVCControl, dataLength: Int? = nil) throws -> Data {
        let length = dataLength ?? control.dataLength
        let unitID = unitID(for: control)
        let wValue = UInt16(control.selector) << 8
        let wIndex = (UInt16(unitID) << 8) | UInt16(vcInterfaceNumber)

        var usbReq = IOUSBDeviceRequest()
        usbReq.bmRequestType = request.bmRequestType
        usbReq.bRequest = request.rawValue
        usbReq.wValue = wValue.littleEndian
        usbReq.wIndex = wIndex.littleEndian
        usbReq.wLength = UInt16(length).littleEndian

        let mutableData = NSMutableData(length: length) ?? NSMutableData()
        var bytesTransferred: UInt = 0

        do {
            // __send is the NS_REFINED_FOR_SWIFT version
            try interface.__send(usbReq, data: mutableData,
                                              bytesTransferred: &bytesTransferred,
                                              completionTimeout: 5.0)
        } catch {
            throw UVCDeviceError.requestFailed(request, control, error)
        }

        return mutableData as Data
    }

    // MARK: - Value Conversion

    private func intValue(from data: Data, signed: Bool) -> Int {
        switch data.count {
        case 1:
            return signed ? Int(Int8(bitPattern: data[0])) : Int(data[0])
        case 2:
            let v = UInt16(data[0]) | (UInt16(data[1]) << 8)
            return signed ? Int(Int16(bitPattern: v)) : Int(v)
        case 4:
            let v = UInt32(data[0]) | (UInt32(data[1]) << 8)
                  | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
            return signed ? Int(Int32(bitPattern: v)) : Int(v)
        default: return 0
        }
    }

    private func dataValue(from value: Int, length: Int) -> Data {
        var data = Data(count: length)
        switch length {
        case 1: data[0] = UInt8(truncatingIfNeeded: value)
        case 2:
            let v = UInt16(truncatingIfNeeded: value)
            data[0] = UInt8(v & 0xFF); data[1] = UInt8(v >> 8)
        case 4:
            let v = UInt32(truncatingIfNeeded: value)
            data[0] = UInt8(v & 0xFF); data[1] = UInt8((v >> 8) & 0xFF)
            data[2] = UInt8((v >> 16) & 0xFF); data[3] = UInt8((v >> 24) & 0xFF)
        default: break
        }
        return data
    }

    // MARK: - Public API

    /// Reads a scalar value for the given UVC request (GET_CUR, GET_MIN, etc.).
    func getValue(for control: UVCControl, request: UVCRequest = .getCurrent) throws -> Int {
        let data = try sendRequest(request, control: control)
        return intValue(from: data, signed: control.isSigned)
    }

    /// Writes a value to a UVC control via SET_CUR.
    func setValue(_ value: Int, for control: UVCControl) throws {
        let payload = dataValue(from: value, length: control.dataLength)
        let unitID = unitID(for: control)
        let wValue = UInt16(control.selector) << 8
        let wIndex = (UInt16(unitID) << 8) | UInt16(vcInterfaceNumber)

        var usbReq = IOUSBDeviceRequest()
        usbReq.bmRequestType = UVCRequest.setCurrent.bmRequestType
        usbReq.bRequest = UVCRequest.setCurrent.rawValue
        usbReq.wValue = wValue.littleEndian
        usbReq.wIndex = wIndex.littleEndian
        usbReq.wLength = UInt16(control.dataLength).littleEndian

        let mutablePayload = NSMutableData(data: payload)
        var bytesTransferred: UInt = 0

        do {
            try interface.__send(usbReq, data: mutablePayload,
                                              bytesTransferred: &bytesTransferred,
                                              completionTimeout: 5.0)
        } catch {
            throw UVCDeviceError.requestFailed(.setCurrent, control, error)
        }
    }

    /// Reads the full range (min, max, resolution, default) for a control.
    func getRange(for control: UVCControl) throws -> UVCControlRange {
        let minimum      = try getValue(for: control, request: .getMinimum)
        let maximum      = try getValue(for: control, request: .getMaximum)
        let resolution   = try getValue(for: control, request: .getResolution)
        let defaultValue = try getValue(for: control, request: .getDefault)
        return UVCControlRange(minimum: minimum, maximum: maximum,
                               resolution: resolution, defaultValue: defaultValue)
    }

    /// Reads the GET_INFO capability byte for a control.
    func getInfo(for control: UVCControl) throws -> UVCInfoCapabilities {
        let data = try sendRequest(.getInfo, control: control, dataLength: 1)
        return UVCInfoCapabilities(rawValue: data[0])
    }
}
