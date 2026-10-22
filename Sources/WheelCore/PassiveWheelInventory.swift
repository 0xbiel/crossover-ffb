import Foundation
import IOKit.hid

public extension WheelInventory {
    /// Metadata-only enumeration. No IOHIDManagerOpen, IOHIDDeviceOpen, GetReport or SetReport.
    static func snapshot() -> [[WheelCollection]] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046d] as CFDictionary)
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        return groups(devices.map { device in
            func number(_ key: String) -> UInt32 { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.uint32Value ?? 0 }
            let service = IOHIDDeviceGetService(device)
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            var parent = service
            var physicalID: UInt64?
            while parent != 0 {
                if IOObjectConformsTo(parent, "IOUSBHostDevice") != 0 {
                    var id: UInt64 = 0
                    if IORegistryEntryGetRegistryEntryID(parent, &id) == KERN_SUCCESS { physicalID = id }
                    if parent != service { IOObjectRelease(parent) }
                    break
                }
                var next: io_registry_entry_t = 0
                let result = IORegistryEntryGetParentEntry(parent, kIOServicePlane, &next)
                if parent != service { IOObjectRelease(parent) }
                if result != KERN_SUCCESS { break }
                parent = next
            }
            return WheelCollection(registryID: registryID, physicalID: physicalID,
                vendor: UInt16(truncatingIfNeeded: number(kIOHIDVendorIDKey)), product: UInt16(truncatingIfNeeded: number(kIOHIDProductIDKey)),
                name: IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "",
                usagePage: number(kIOHIDPrimaryUsagePageKey), usage: number(kIOHIDPrimaryUsageKey))
        })
    }
}
