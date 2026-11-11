// Lists the RTL2832U dongles on the USB bus from the IOKit registry, which holds the descriptor strings without
// opening the device, so a dongle that another process has claimed is still listed.

import Foundation
import IOKit

/// An RTL2832U dongle on the USB bus.
public struct Dongle: Sendable, Hashable, Identifiable {
    /// The device's IOKit registry entry ID, which names it for as long as it stays plugged in.
    public let id: UInt64
    let productID: Int
    let locationID: Int
    /// The vendor string of the USB descriptor, or "unknown vendor" when the device reports none.
    public let vendor: String
    /// The product string of the USB descriptor, or "RTL2832U" when the device reports none.
    public let product: String
    /// The serial string of the USB descriptor, or "none". Dongles often share a factory serial.
    public let serial: String

    /// A name for a list of devices, built from the descriptor strings.
    public var name: String { modelName(vendor: vendor, product: product) }
    /// The vendor and product IDs as `lsusb` prints them, for example `0bda:2838`.
    public var usbID: String { String(format: "%04x:%04x", USBTransport.vendorID, productID) }
    /// The USB location ID, which names the port the dongle is plugged into.
    public var location: String { String(format: "0x%08x", locationID) }

    /// The dongles now on the bus, in order of their USB location, so the order is stable from one call to the next.
    public static var all: [Dongle] { scan() }

    /// The first dongle on the bus.
    public static func first() throws -> Dongle {
        guard let dongle = all.first else { throw RadioError.noDongle }
        return dongle
    }

    /// The one dongle on the bus that reports this serial.
    public static func with(serial: String) throws -> Dongle {
        let matches = all.filter { $0.serial == serial }
        guard let dongle = matches.first else { throw RadioError.noDongle }
        guard matches.count == 1 else { throw RadioError.ambiguous(serial: serial, count: matches.count) }
        return dongle
    }
}

/// The model comes from the USB descriptor strings. A dongle that reports only "Generic" and "RTL2832U" says nothing
/// about its tuner or board, so it keeps the chip name; naming the board would need the device opened, which fails
/// or interferes while another app holds it.
func modelName(vendor: String, product: String) -> String {
    switch vendor {
    case "RTLSDRBlog": "RTL-SDR \(product)"
    case "Nooelec": "Nooelec \(product)"
    case "Generic", "Realtek", "unknown vendor": "\(product) dongle"
    default: "\(vendor) \(product)"
    }
}

/// A property of a registry entry, or nil when it is absent or of another type.
func property<T>(_ service: io_service_t, _ key: String) -> T? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
}

/// An `idVendor` key in the matching dictionary matches nothing, so the vendor is filtered here.
func scan() -> [Dongle] {
    var iterator: io_iterator_t = 0
    let matching = IOServiceMatching("IOUSBHostDevice")
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }

    var found: [Dongle] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        if let dongle = Dongle(service: service) { found.append(dongle) }
    }
    return found.sorted { $0.locationID < $1.locationID }
}

extension Dongle {
    /// The dongle described by a USB device registry entry, or nil when the entry is another device.
    init?(service: io_service_t) {
        let vendor: Int = property(service, "idVendor") ?? 0
        let product: Int = property(service, "idProduct") ?? 0
        guard vendor == USBTransport.vendorID, USBTransport.productIDs.contains(product) else { return nil }

        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        self.init(
            id: entryID,
            productID: product,
            locationID: property(service, "locationID") ?? 0,
            vendor: property(service, "USB Vendor Name") ?? "unknown vendor",
            product: property(service, "USB Product Name") ?? "RTL2832U",
            serial: property(service, "USB Serial Number") ?? "none"
        )
    }
}
