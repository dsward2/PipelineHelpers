import Foundation
import IOKit
import IOUSBHost

/// Resets an RTL-SDR at the USB level — the software stand-in for unplugging
/// and replugging it. The device drops off the bus and re-enumerates (about a
/// second), so any open handle to it is dead afterwards.
///
/// This resets the dongle's USB side only. A tuner or demodulator that is hung
/// behind a healthy USB interface can come back just as stuck; only cutting
/// the port's power clears that.
///
/// Done through IOUSBHost rather than libusb so `SDRDeviceAccess` stays free
/// of any libusb dependency (each app bundles its own copy). Needs the
/// `com.apple.security.device.usb` entitlement in a sandboxed app, which the
/// apps already have for librtlsdr.
public enum RTLSDRUSBReset {
    /// Realtek's vendor ID; every RTL2832U dongle reports it.
    private static let realtekVendorID = 0x0bda

    public enum Outcome: Sendable, Equatable {
        /// The reset was issued and the dongle came back (when `waitForReturn`).
        case reset
        /// No USB device with that serial is on the bus.
        case notFound
        /// The reset call failed (`message` is the system's description).
        case failed(message: String)
    }

    /// Resets the Realtek device whose USB serial is `serial` (empty = the
    /// only Realtek device, when there is exactly one). Blocks until the
    /// dongle shows up on the bus again, up to `waitSeconds`.
    @discardableResult
    public static func reset(serial: String, waitSeconds: Double = 5.0) -> Outcome {
        let services = realtekServices()
        defer { services.forEach { IOObjectRelease($0.service) } }

        let matches = serial.isEmpty ? (services.count == 1 ? services : []) : services.filter { $0.serial == serial }
        guard let target = matches.first else { return .notFound }

        do {
            // Seizing takes the device from any driver or process holding it;
            // callers only get here once nothing known is using the dongle.
            let device = try IOUSBHostDevice(__ioService: target.service, options: .deviceSeize,
                                             queue: nil, interestHandler: nil)
            try device.reset()
            device.destroy()
        } catch {
            return .failed(message: error.localizedDescription)
        }

        // It re-enumerates, so wait for it to reappear (new registry entry).
        let deadline = Date().addingTimeInterval(waitSeconds)
        Thread.sleep(forTimeInterval: 0.5)
        while Date() < deadline {
            let again = realtekServices()
            let found = again.contains { serial.isEmpty || $0.serial == serial }
            again.forEach { IOObjectRelease($0.service) }
            if found { return .reset }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return .reset
    }

    /// Every Realtek USB device on the bus, with its serial. The caller
    /// releases the services.
    private static func realtekServices() -> [(service: io_service_t, serial: String)] {
        let matching = IOServiceMatching("IOUSBHostDevice")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [(io_service_t, String)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            // Filtered here: a vendor ID in the matching dictionary matched nothing.
            let vendor = IORegistryEntryCreateCFProperty(service, "idVendor" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            guard vendor == realtekVendorID else {
                IOObjectRelease(service)
                continue
            }
            let serial = IORegistryEntryCreateCFProperty(service, "kUSBSerialNumberString" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            found.append((service, serial ?? ""))
        }
        return found
    }
}
