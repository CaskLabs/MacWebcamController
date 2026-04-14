import Foundation
import IOKit
import IOKit.usb

/// Result of parsing UVC class-specific descriptors from a USB device.
struct UVCDescriptorInfo: Sendable {
    var processingUnitID: UInt8 = 0
    var cameraTerminalID: UInt8 = 0
    var vcInterfaceNumber: UInt8 = 0
    /// Bitmask of supported processing unit controls from bmControls field.
    var puControlsBitmask: UInt32 = 0
    /// Bitmask of supported camera terminal controls from bmControls field.
    var ctControlsBitmask: UInt32 = 0
}

/// Parses UVC class-specific Video Control descriptors from the USB
/// configuration descriptor to discover unit IDs and supported controls.
enum UVCDescriptorParser {

    /// Parses the configuration descriptor data to extract UVC unit IDs
    /// and supported control bitmasks.
    ///
    /// The configuration descriptor contains class-specific VC interface
    /// descriptors that describe the video function's topology:
    /// - VC_INPUT_TERMINAL (subtype 0x02) with type ITT_CAMERA (0x0201)
    ///   gives the camera terminal ID and its bmControls
    /// - VC_PROCESSING_UNIT (subtype 0x05) gives the processing unit ID
    ///   and its bmControls
    static func parse(configurationDescriptor data: Data) -> UVCDescriptorInfo {
        var info = UVCDescriptorInfo()
        var offset = 0
        var inVCInterface = false  // Only parse CS descriptors inside the VC interface

        while offset + 2 <= data.count {
            let bLength = Int(data[offset])
            let bDescriptorType = data[offset + 1]

            // Avoid infinite loop on zero-length descriptors
            guard bLength >= 2 else { break }
            guard offset + bLength <= data.count else { break }

            // Track standard interface descriptors to know which interface we're in
            if bDescriptorType == 0x04 && bLength >= 9 {
                let bInterfaceClass    = data[offset + 5]
                let bInterfaceSubClass = data[offset + 6]
                if bInterfaceClass == CC_VIDEO && bInterfaceSubClass == SC_VIDEOCONTROL {
                    info.vcInterfaceNumber = data[offset + 2]
                    inVCInterface = true
                } else {
                    // Any non-VC interface — stop parsing for UVC units.
                    // VS descriptors share the 0x24 type but have different subtypes;
                    // parsing them after the VC section produces wrong unit IDs.
                    inVCInterface = false
                }
            }

            // Only parse class-specific descriptors while inside the VC interface
            if inVCInterface && bDescriptorType == CS_INTERFACE && bLength >= 3 {
                let bDescriptorSubtype = data[offset + 2]
                parseClassSpecificDescriptor(
                    subtype: bDescriptorSubtype,
                    data: data,
                    offset: offset,
                    length: bLength,
                    info: &info
                )
            }

            offset += bLength
        }

        if info.processingUnitID == 0 {
            // PU not found — dump first 120 bytes for diagnosis
            let hexDump = data.prefix(120).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("[UVC Descriptor] PU not found. Descriptor hex: \(hexDump)")
        }

        return info
    }

    private static func parseClassSpecificDescriptor(
        subtype: UInt8, data: Data, offset: Int, length: Int,
        info: inout UVCDescriptorInfo
    ) {
        switch subtype {
        case VC_INPUT_TERMINAL:
            parseInputTerminal(data: data, offset: offset, length: length, info: &info)
        case VC_PROCESSING_UNIT:
            parseProcessingUnit(data: data, offset: offset, length: length, info: &info)
        default:
            break
        }
    }

    /// Parses a VC_INPUT_TERMINAL descriptor.
    /// Layout (UVC 1.5, Table 4-6):
    ///   [0] bLength
    ///   [1] bDescriptorType (0x24)
    ///   [2] bDescriptorSubtype (0x02)
    ///   [3] bTerminalID
    ///   [4-5] wTerminalType (little-endian)
    ///   [6] bAssocTerminal
    ///   [7] iTerminal
    ///   For Camera Terminal (wTerminalType == 0x0201):
    ///     [8-9] wObjectiveFocalLengthMin
    ///     [10-11] wObjectiveFocalLengthMax
    ///     [12-13] wOcularFocalLength
    ///     [14] bControlSize (number of bytes in bmControls)
    ///     [15..] bmControls
    private static func parseInputTerminal(
        data: Data, offset: Int, length: Int, info: inout UVCDescriptorInfo
    ) {
        guard length >= 8 else { return }

        let terminalType = UInt16(data[offset + 4]) | (UInt16(data[offset + 5]) << 8)

        // Only interested in Camera Terminal (ITT_CAMERA = 0x0201)
        guard terminalType == ITT_CAMERA else { return }

        info.cameraTerminalID = data[offset + 3]

        // Parse bmControls if present
        guard length >= 15 else { return }
        let controlSize = Int(data[offset + 14])
        guard length >= 15 + controlSize else { return }

        var bitmask: UInt32 = 0
        for i in 0..<min(controlSize, 4) {
            bitmask |= UInt32(data[offset + 15 + i]) << (i * 8)
        }
        info.ctControlsBitmask = bitmask
    }

    /// Parses a VC_PROCESSING_UNIT descriptor.
    /// Layout (UVC 1.5, Table 4-8):
    ///   [0] bLength
    ///   [1] bDescriptorType (0x24)
    ///   [2] bDescriptorSubtype (0x05)
    ///   [3] bUnitID
    ///   [4] bSourceID
    ///   [5-6] wMaxMultiplier
    ///   [7] bControlSize (number of bytes in bmControls)
    ///   [8..] bmControls
    private static func parseProcessingUnit(
        data: Data, offset: Int, length: Int, info: inout UVCDescriptorInfo
    ) {
        guard length >= 8 else { return }

        info.processingUnitID = data[offset + 3]

        let controlSize = Int(data[offset + 7])
        guard length >= 8 + controlSize else { return }

        var bitmask: UInt32 = 0
        for i in 0..<min(controlSize, 4) {
            bitmask |= UInt32(data[offset + 8 + i]) << (i * 8)
        }
        info.puControlsBitmask = bitmask
    }
}
