import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

/// Discovers UVC-compliant USB cameras using IOKit matching and IOUSBHost.
enum UVCDeviceDiscovery {

    /// Finds all USB Video Control interfaces and returns UVCDevice instances.
    static func discoverDevices() -> [UVCDevice] {
        var devices: [UVCDevice] = []

        // Match on VC interfaces to find the vcInterfaceNumber and config descriptor,
        // then open the parent IOUSBHostDevice for control requests (avoids claiming
        // the interface which conflicts with the system camera driver).
        let matching = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: nil,
            productID: nil,
            bcdDevice: nil,
            interfaceNumber: nil,
            configurationValue: nil,
            interfaceClass: NSNumber(value: CC_VIDEO),
            interfaceSubclass: NSNumber(value: SC_VIDEOCONTROL),
            interfaceProtocol: nil,
            speed: nil,
            productIDArray: nil
        )

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching.takeRetainedValue(), &iterator)

        guard kr == KERN_SUCCESS else {
            print("[UVC] IOServiceGetMatchingServices failed: \(kr)")
            return devices
        }

        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let device = createDevice(from: service) {
                devices.append(device)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return devices
    }

    /// Opens a UVCDevice from a matched IOKit VC interface service.
    private static func createDevice(from interfaceService: io_service_t) -> UVCDevice? {
        // Read interface number and device properties from the IOKit registry
        let vcInterfaceNumber = interfaceNumber(from: interfaceService)
        let (deviceService, name, locationID, vendorID, productID) = deviceProperties(from: interfaceService)
        guard deviceService != 0 else { return nil }
        defer { IOObjectRelease(deviceService) }

        // Open the parent IOUSBHostDevice — sends control requests on ep0 without
        // claiming the VC interface, which avoids conflicts with IOUSBVideoSupport.kext.
        let hostDevice: IOUSBHostDevice
        do {
            hostDevice = try IOUSBHostDevice(
                __ioService: deviceService,
                options: [],
                queue: nil,
                interestHandler: nil
            )
        } catch {
            print("[UVC] Cannot open IOUSBHostDevice for \(name): \(error.localizedDescription)")
            return nil
        }

        // Read configuration descriptor directly from the device (not the interface).
        // IOUSBHostInterface cannot be opened while the system camera driver holds it,
        // but IOUSBHostDevice.configurationDescriptor is always accessible.
        var configData: Data?
        if let ptr = hostDevice.configurationDescriptor {
            let totalLength = Int(ptr.pointee.wTotalLength.littleEndian)
            if totalLength > 0 {
                configData = Data(bytes: ptr, count: totalLength)
                print("[UVC] Config descriptor: \(totalLength) bytes")
            }
        } else {
            print("[UVC] configurationDescriptor is nil for \(name)")
        }

        let device = UVCDevice(
            hostDevice: hostDevice,
            vcInterfaceNumber: vcInterfaceNumber,
            name: name,
            locationID: locationID,
            vendorID: vendorID,
            productID: productID
        )

        if let data = configData {
            let info = UVCDescriptorParser.parse(configurationDescriptor: data)
            device.configure(
                processingUnitID: info.processingUnitID,
                cameraTerminalID: info.cameraTerminalID,
                supportedPUControls: info.puControlsBitmask,
                supportedCTControls: info.ctControlsBitmask
            )
            print("[UVC] Found: \(name) VID:0x\(String(vendorID, radix: 16)) PID:0x\(String(productID, radix: 16)) PU:\(info.processingUnitID) CT:\(info.cameraTerminalID) PU-bmControls:0x\(String(info.puControlsBitmask, radix: 16)) CT-bmControls:0x\(String(info.ctControlsBitmask, radix: 16))")
        } else {
            print("[UVC] No config descriptor for \(name)")
        }

        return device
    }

    // MARK: - IOKit Registry Helpers

    private static func interfaceNumber(from service: io_service_t) -> UInt8 {
        guard let prop = IORegistryEntryCreateCFProperty(
            service, kUSBInterfaceNumber as CFString, kCFAllocatorDefault, 0
        ) else { return 0 }
        return UInt8((prop.takeRetainedValue() as? NSNumber)?.intValue ?? 0)
    }

    /// Returns (deviceService, name, locationID, vendorID, productID).
    /// Caller is responsible for releasing the returned io_object_t.
    private static func deviceProperties(from service: io_service_t) -> (io_object_t, String, UInt32, UInt16, UInt16) {
        var parent: io_object_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return (0, "Unknown Camera", 0, 0, 0)
        }

        let className = ioClassName(parent)
        let deviceEntry: io_object_t

        if className == "IOUSBHostDevice" || className == "AppleUSBDevice" {
            deviceEntry = parent
        } else {
            var grandParent: io_object_t = 0
            guard IORegistryEntryGetParentEntry(parent, kIOServicePlane, &grandParent) == KERN_SUCCESS else {
                IOObjectRelease(parent)
                return (0, "Unknown Camera", 0, 0, 0)
            }
            IOObjectRelease(parent)
            deviceEntry = grandParent
        }

        // Retain so the caller can release it after use
        IOObjectRetain(deviceEntry)

        let name = registryString(deviceEntry, key: "USB Product Name")
            ?? registryString(deviceEntry, key: kUSBProductString)
            ?? "Unknown Camera"
        let locationID = UInt32(registryInt(deviceEntry, key: kUSBDevicePropertyLocationID) ?? 0)
        let vendorID   = UInt16(registryInt(deviceEntry, key: kUSBVendorID) ?? 0)
        let productID  = UInt16(registryInt(deviceEntry, key: kUSBProductID) ?? 0)

        return (deviceEntry, name, locationID, vendorID, productID)
    }

    private static func registryInt(_ entry: io_object_t, key: String) -> Int? {
        guard let prop = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (prop.takeRetainedValue() as? NSNumber)?.intValue
    }

    private static func registryString(_ entry: io_object_t, key: String) -> String? {
        guard let prop = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return prop.takeRetainedValue() as? String
    }

    private static func ioClassName(_ entry: io_object_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        IOObjectGetClass(entry, &buf)
        return String(cString: buf)
    }
}
