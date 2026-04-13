import Foundation

/// Probes a UVC device to determine which controls are actually supported,
/// going beyond descriptor bitmasks by sending GET_INFO requests.
///
/// Some cameras claim controls in bmControls that they don't actually support,
/// and vice versa. GET_INFO is the authoritative source.
enum UVCControlProber {

    /// Result of probing a single control.
    struct ProbeResult: Sendable {
        let control: UVCControl
        let isReadable: Bool
        let isWritable: Bool
        let isAutoSupported: Bool   // auto mode available
        let isAutoEnabled: Bool     // currently in auto mode
    }

    /// Probes all controls on the device and returns results.
    /// Should be called on a background queue.
    static func probeAll(device: UVCDevice) -> [UVCControl: ProbeResult] {
        var results: [UVCControl: ProbeResult] = [:]

        for control in UVCControl.allCases {
            // Skip controls the descriptor says are not supported
            guard device.isSupported(control) else {
                results[control] = ProbeResult(
                    control: control,
                    isReadable: false, isWritable: false,
                    isAutoSupported: false, isAutoEnabled: false
                )
                continue
            }

            // GET_INFO returns a capability bitmask
            let caps: UVCInfoCapabilities
            do {
                caps = try device.getInfo(for: control)
            } catch {
                // STALL means the control is not actually supported despite descriptor
                results[control] = ProbeResult(
                    control: control,
                    isReadable: false, isWritable: false,
                    isAutoSupported: false, isAutoEnabled: false
                )
                continue
            }

            let isReadable = caps.contains(.supportsGet)
            let isWritable = caps.contains(.supportsSet)

            // Check for corresponding auto-mode controls
            let (autoSupported, autoEnabled) = checkAutoMode(device: device, for: control)

            results[control] = ProbeResult(
                control: control,
                isReadable: isReadable,
                isWritable: isWritable,
                isAutoSupported: autoSupported,
                isAutoEnabled: autoEnabled
            )
        }

        return results
    }

    /// Checks if a control has a corresponding auto-mode control, and whether
    /// auto mode is currently enabled.
    private static func checkAutoMode(device: UVCDevice, for control: UVCControl) -> (Bool, Bool) {
        switch control {
        case .whiteBalanceTemperature:
            return readAutoControl(device: device, selector: 0x0B, unitType: .processingUnit,
                                   vcInterfaceNumber: device)
        case .exposureAbsolute:
            // Exposure auto: 1=manual, 2=auto, 4=shutter priority, 8=aperture priority
            let (supported, rawValue) = readAutoRawControl(device: device, selector: 0x02,
                                                           unitType: .cameraTerminal, device: device)
            return (supported, rawValue != 1) // not manual = some auto mode
        case .focusAbsolute:
            return readAutoControl(device: device, selector: 0x08, unitType: .cameraTerminal,
                                   vcInterfaceNumber: device)
        default:
            return (false, false)
        }
    }

    private static func readAutoControl(
        device: UVCDevice,
        selector: UInt8,
        unitType: UVCUnitType,
        vcInterfaceNumber: UVCDevice
    ) -> (Bool, Bool) {
        let (supported, value) = readAutoRawControl(
            device: device, selector: selector, unitType: unitType, device: device
        )
        return (supported, value != 0)
    }

    private static func readAutoRawControl(
        device: UVCDevice,
        selector: UInt8,
        unitType: UVCUnitType,
        device uvcDevice: UVCDevice
    ) -> (Bool, Int) {
        // We use a temporary synthetic control to read the auto value.
        // The auto-mode controls are not in the main UVCControl enum,
        // so we build a raw request manually via a helper.
        // For now, return unsupported — this will be wired up when
        // UVCDevice exposes a raw request API.
        return (false, 0)
    }
}

/// Applies probe results to ControlState, overriding descriptor-based isSupported.
extension ControlState {
    mutating func applyProbeResult(_ result: UVCControlProber.ProbeResult) {
        isSupported = result.isReadable
        isAutoSupported = result.isAutoSupported
        isAutoEnabled = result.isAutoEnabled
        if !result.isReadable {
            error = "Not supported by this camera"
        }
    }
}
