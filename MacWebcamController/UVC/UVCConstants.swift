import Foundation

// MARK: - USB Video Class Constants (UVC 1.5 Spec)

/// USB interface class for Video.
let CC_VIDEO: UInt8 = 0x0E

/// USB interface subclass for Video Control.
let SC_VIDEOCONTROL: UInt8 = 0x01

/// USB interface subclass for Video Streaming.
let SC_VIDEOSTREAMING: UInt8 = 0x02

/// Class-specific descriptor type.
let CS_INTERFACE: UInt8 = 0x24

// MARK: - VC Interface Descriptor Subtypes

/// Video Control header descriptor subtype.
let VC_HEADER: UInt8 = 0x01

/// Input terminal descriptor subtype.
let VC_INPUT_TERMINAL: UInt8 = 0x02

/// Output terminal descriptor subtype.
let VC_OUTPUT_TERMINAL: UInt8 = 0x03

/// Processing unit descriptor subtype.
let VC_PROCESSING_UNIT: UInt8 = 0x05

/// Extension unit descriptor subtype.
let VC_EXTENSION_UNIT: UInt8 = 0x06

// MARK: - Terminal Types

/// Camera terminal type (ITT_CAMERA).
let ITT_CAMERA: UInt16 = 0x0201

// MARK: - UVC Request Codes

enum UVCRequest: UInt8, Sendable {
    case setCurrent = 0x01
    case getCurrent = 0x81
    case getMinimum = 0x82
    case getMaximum = 0x83
    case getResolution = 0x84
    case getLength = 0x85
    case getInfo = 0x86
    case getDefault = 0x87

    /// bmRequestType for this request direction.
    var bmRequestType: UInt8 {
        switch self {
        case .setCurrent:
            0x21  // Host-to-device, Class, Interface
        default:
            0xA1  // Device-to-host, Class, Interface
        }
    }
}

// MARK: - GET_INFO Bitmask

/// Bitmask values returned by GET_INFO requests.
struct UVCInfoCapabilities: OptionSet, Sendable {
    let rawValue: UInt8

    static let supportsGet        = UVCInfoCapabilities(rawValue: 1 << 0)
    static let supportsSet        = UVCInfoCapabilities(rawValue: 1 << 1)
    static let disabled           = UVCInfoCapabilities(rawValue: 1 << 2)
    static let autoUpdateControl  = UVCInfoCapabilities(rawValue: 1 << 3)
    static let asynchronousControl = UVCInfoCapabilities(rawValue: 1 << 4)
}

// MARK: - Control Range

/// Describes the min/max/resolution/default range for a UVC control.
struct UVCControlRange: Sendable {
    let minimum: Int
    let maximum: Int
    let resolution: Int
    let defaultValue: Int

    static func read(for control: UVCControl, value: (UVCRequest) throws -> Int) throws -> UVCControlRange {
        let minimum = try value(.getMinimum)
        let maximum = try value(.getMaximum)
        guard maximum > minimum else { throw UVCDeviceError.invalidRange(control) }
        // Optional metadata must not hide an otherwise usable control.
        let resolution = max(1, (try? value(.getResolution)) ?? 1)
        let defaultValue = (try? value(.getDefault)) ?? (try? value(.getCurrent)) ?? minimum
        let range = UVCControlRange(minimum: minimum, maximum: maximum,
                                    resolution: resolution, defaultValue: defaultValue)
        return UVCControlRange(minimum: minimum, maximum: maximum,
                               resolution: resolution, defaultValue: range.normalized(defaultValue))
    }

    /// UVC values are at most 32 bits, so the bounded offset fits in Int on macOS.
    func normalized(_ value: Int) -> Int {
        guard maximum >= minimum else { return minimum }
        let step = max(1, resolution)
        let bounded = max(minimum, min(maximum, value))
        let offset = bounded - minimum
        let lower = offset / step
        let steps = offset % step >= (step + 1) / 2 ? lower + 1 : lower
        let highestStep = (maximum - minimum) / step
        return minimum + min(steps, highestStep) * step
    }
}
