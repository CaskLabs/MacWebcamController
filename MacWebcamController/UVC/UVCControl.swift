import Foundation

/// Unit type for a UVC control — either Processing Unit or Camera Terminal.
enum UVCUnitType {
    case processingUnit
    case cameraTerminal
}

/// All supported UVC controls with their selector codes and metadata.
enum UVCControl: String, CaseIterable, Identifiable, Sendable {
    case brightness
    case contrast
    case saturation
    case sharpness
    case gamma
    case whiteBalanceTemperature
    case gain
    case backlightCompensation
    case powerlineFrequency
    case exposureAbsolute
    case focusAbsolute

    var id: String { rawValue }

    /// UVC selector code (CS) for this control.
    var selector: UInt8 {
        switch self {
        case .brightness: 0x02
        case .contrast: 0x03
        case .saturation: 0x07
        case .sharpness: 0x08
        case .gamma: 0x09
        case .whiteBalanceTemperature: 0x0A
        case .gain: 0x04
        case .backlightCompensation: 0x01
        case .powerlineFrequency: 0x05
        case .exposureAbsolute: 0x04
        case .focusAbsolute: 0x06
        }
    }

    /// Which UVC unit this control belongs to.
    var unitType: UVCUnitType {
        switch self {
        case .exposureAbsolute, .focusAbsolute:
            .cameraTerminal
        default:
            .processingUnit
        }
    }

    /// Size of the control data in bytes.
    var dataLength: Int {
        switch self {
        case .powerlineFrequency: 1
        case .exposureAbsolute: 4
        default: 2
        }
    }

    /// Whether the control value is a signed integer.
    var isSigned: Bool {
        switch self {
        case .brightness: true
        default: false
        }
    }

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .saturation: "Saturation"
        case .sharpness: "Sharpness"
        case .gamma: "Gamma"
        case .whiteBalanceTemperature: "White Balance"
        case .gain: "Gain"
        case .backlightCompensation: "Backlight Compensation"
        case .powerlineFrequency: "Anti-Flicker"
        case .exposureAbsolute: "Exposure"
        case .focusAbsolute: "Focus"
        }
    }
}
