import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

/// Discovers UVC-compliant USB cameras using IOKit matching and IOUSBHost.
enum UVCDeviceDiscovery {

    /// Finds all USB Video Control interfaces and returns UVCDevice instances.
    static func discoverDevices() -> [UVCDevice] {
        var devices: [UVCDevice] = []

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
            print("[UVC Discovery] IOServiceGetMatchingServices failed: \(kr)")
            return devices
        }

        defer { IOObjectRelease(iterator) }

        var count = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            count += 1
            print("[UVC Discovery] Processing matched service #\(count) (id=\(service))")
            if let device = createDevice(from: service) {
                devices.append(device)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        print("[UVC Discovery] Found \(count) VC interface(s), created \(devices.count) UVCDevice(s)")
        return devices
    }

    // MARK: - Device Creation

    private static func createDevice(from interfaceService: io_service_t) -> UVCDevice? {
        let vcInterfaceNumber = interfaceNumber(from: interfaceService)
        print("[UVC Discovery]   vcInterfaceNumber = \(vcInterfaceNumber)")

        // Walk up to find the USB device IOKit service
        guard let deviceService = findDeviceService(from: interfaceService) else {
            print("[UVC Discovery]   Could not find parent device service")
            return nil
        }
        defer { IOObjectRelease(deviceService) }

        let devClass = ioClassName(deviceService)
        print("[UVC Discovery]   Device service class: \(devClass)")

        let name = registryString(deviceService, key: "USB Product Name")
            ?? registryString(deviceService, key: kUSBProductString)
            ?? "Unknown Camera"
        let locationID = UInt32(registryInt(deviceService, key: kUSBDevicePropertyLocationID) ?? 0)
        let vendorID   = UInt16(registryInt(deviceService, key: kUSBVendorID) ?? 0)
        let productID  = UInt16(registryInt(deviceService, key: kUSBProductID) ?? 0)

        print("[UVC Discovery]   \(name) VID:0x\(String(vendorID, radix: 16)) PID:0x\(String(productID, radix: 16)) LOC:0x\(String(locationID, radix: 16))")

        // Open without capturing the physical USB device. `.deviceCapture` would
        // terminate the camera's AVFoundation/USB drivers and can trigger a
        // disconnect/reconnect loop while the live preview is running.
        let hostDevice: IOUSBHostDevice
        do {
            hostDevice = try IOUSBHostDevice(
                __ioService: deviceService,
                options: [],
                queue: nil,
                interestHandler: nil
            )
            print("[UVC Discovery]   Opened IOUSBHostDevice (no capture)")
        } catch {
            print("[UVC Discovery]   IOUSBHostDevice (no capture) failed: \(error)")
            return nil
        }

        // Read configuration descriptor
        var configData: Data?
        if let ptr = hostDevice.configurationDescriptor {
            let totalLength = Int(ptr.pointee.wTotalLength.littleEndian)
            if totalLength > 0 {
                configData = Data(bytes: ptr, count: totalLength)
                print("[UVC Discovery]   Config descriptor: \(totalLength) bytes")
            }
        }

        // Fallback: try to get config descriptor via IORegistryEntry
        if configData == nil {
            print("[UVC Discovery]   configurationDescriptor nil on device, trying registry fallback")
            configData = configDescriptorFromRegistry(interfaceService)
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
            let info = UVCDescriptorParser.parse(configurationDescriptor: data, targetVCInterface: vcInterfaceNumber)
            device.configure(
                processingUnitID: info.processingUnitID,
                cameraTerminalID: info.cameraTerminalID,
                supportedPUControls: info.puControlsBitmask,
                supportedCTControls: info.ctControlsBitmask
            )
            print("[UVC Discovery]   PU:\(info.processingUnitID) CT:\(info.cameraTerminalID) PU-bmControls:0x\(String(info.puControlsBitmask, radix: 16)) CT-bmControls:0x\(String(info.ctControlsBitmask, radix: 16))")
        } else {
            print("[UVC Discovery]   WARNING: No config descriptor available — controls will not work")
        }

        return device
    }

    // MARK: - Device Service Lookup

    /// Walks up the IOKit service tree from an interface service to find the USB device node.
    ///
    /// Rather than matching specific class names (which vary across macOS versions and USB
    /// controller types such as Thunderbolt-attached hubs), this checks for the presence of
    /// USB device properties (VendorID + ProductID). The first ancestor that has both is the
    /// camera's USB device node regardless of what the IOKit class is called.
    private static func findDeviceService(from service: io_service_t) -> io_service_t? {
        var current: io_object_t = service
        IOObjectRetain(current)

        // Walk up to 8 levels. Devices behind a monitor hub sit 1–2 levels above the interface.
        for level in 0..<8 {
            var parent: io_object_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                IOObjectRelease(current)
                return nil
            }
            IOObjectRelease(current)
            current = parent

            let cls = ioClassName(current)
            print("[UVC Discovery]   parent[\(level)] class = \(cls)")

            // Accept any node that exposes VendorID + ProductID — that identifies the USB device
            // node independent of the exact IOKit class name used by this macOS version.
            if registryInt(current, key: kUSBVendorID) != nil &&
               registryInt(current, key: kUSBProductID) != nil {
                print("[UVC Discovery]   Found USB device node at level \(level) (class=\(cls))")
                return current  // caller takes ownership
            }
        }

        IOObjectRelease(current)
        return nil
    }

    // MARK: - Config Descriptor Fallback

    /// Try to read configuration descriptor from IOKit registry properties.
    /// Walks up several levels because the property may live on the device node,
    /// which could be one or two hops above the interface node.
    private static func configDescriptorFromRegistry(_ interfaceService: io_service_t) -> Data? {
        let keys = ["USB Configuration Descriptor", "ConfigurationDescriptor", "Device Descriptor"]

        var current: io_object_t = interfaceService
        IOObjectRetain(current)

        defer { IOObjectRelease(current) }

        for _ in 0..<4 {
            for key in keys {
                if let prop = IORegistryEntryCreateCFProperty(current, key as CFString, kCFAllocatorDefault, 0) {
                    let val = prop.takeRetainedValue()
                    if let data = val as? Data, data.count > 4 {
                        print("[UVC Discovery]   Found config descriptor in registry key '\(key)' (\(data.count) bytes)")
                        return data
                    }
                }
            }

            var parent: io_object_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
        }

        return nil
    }

    // MARK: - IOKit Registry Helpers

    private static func interfaceNumber(from service: io_service_t) -> UInt8 {
        guard let prop = IORegistryEntryCreateCFProperty(
            service, kUSBInterfaceNumber as CFString, kCFAllocatorDefault, 0
        ) else { return 0 }
        return UInt8((prop.takeRetainedValue() as? NSNumber)?.intValue ?? 0)
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
        return buf.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return "" }
            return String(cString: base)
        }
    }
}
