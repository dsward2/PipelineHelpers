import Foundation

/// The three librtlsdr calls the preflight needs, supplied by the host app.
///
/// `SDRDeviceAccess` deliberately doesn't link librtlsdr itself: AntennaHead
/// gets it as a Swift package and ControlBooth embeds its own framework copy,
/// so each app conforms a tiny type over its own `import librtlsdr`. That also
/// lets the tests drive the preflight with a fake backend.
public protocol RTLSDRBackend {
    /// `rtlsdr_get_device_count()`.
    func deviceCount() -> UInt32
    /// The device's EEPROM serial (`rtlsdr_get_device_usb_strings`), or nil
    /// when the strings can't be read.
    func serial(at index: UInt32) -> String?
    /// `rtlsdr_open` immediately followed by `rtlsdr_close`. Returns 0 when
    /// the device could be opened, otherwise librtlsdr's negative error
    /// (-3, libusb's ACCESS error, when another process has it claimed).
    func tryOpen(at index: UInt32) -> Int32
}

/// Maps a device argument to a USB index the same way the tools that will
/// actually open the device do, so the preflight tests the same dongle.
public enum RTLSDRDeviceResolver {

    /// The index `rtl_fm_localradio -d <value>` (and the other rtl_* tools,
    /// via librtlsdr's `verbose_device_search`) would open, or nil when no
    /// device matches. In order:
    ///
    /// 1. `strtol(value, &end, 0)` parses the whole string and is a valid
    ///    index. Base 0, so "0x1" is hex and a leading "0" means octal: the
    ///    8-digit serial "00000360" parses as octal 240 (not a valid index)
    ///    and falls through, while "00000090" isn't octal at all. An empty
    ///    value parses as 0.
    /// 2. An exact serial match, then a prefix match, then a suffix match.
    ///
    /// `serials[i]` is device i's serial, nil when unreadable.
    public static func rtlToolIndex(for value: String, serials: [String?]) -> UInt32? {
        let count = serials.count
        guard count > 0 else { return nil }

        var parsedWhole = false
        let number: Int = value.withCString { start in
            var end: UnsafeMutablePointer<CChar>?
            let n = strtol(start, &end, 0)
            parsedWhole = end?.pointee == 0
            return n
        }
        if parsedWhole, number >= 0, number < count {
            return UInt32(number)
        }

        let matchers: [(String) -> Bool] = [
            { $0 == value },
            { $0.hasPrefix(value) },
            { $0.hasSuffix(value) },
        ]
        for matches in matchers {
            if let i = serials.firstIndex(where: { $0.map(matches) ?? false }) {
                return UInt32(i)
            }
        }
        return nil
    }

    /// The RTL-SDR index a gr-osmosdr device string (Gqrx's input device,
    /// e.g. `rtl=0`, `rtl=00000090,bias=1`) opens, or nil when it isn't a
    /// local RTL-SDR (`rtl_tcp=`, `airspy`, `file=`, …) or matches nothing.
    /// gr-osmosdr treats the `rtl=` value as a serial first, then as a
    /// decimal index; an empty value means index 0.
    public static func osmosdrIndex(for deviceString: String, serials: [String?]) -> UInt32? {
        let args = deviceString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let rtlArg = args.first(where: { $0 == "rtl" || $0.hasPrefix("rtl=") }) else { return nil }
        let value = rtlArg == "rtl" ? "" : String(rtlArg.dropFirst("rtl=".count))
        if value.isEmpty { return serials.isEmpty ? nil : 0 }
        if let i = serials.firstIndex(where: { $0 == value }) { return UInt32(i) }
        if let n = UInt32(value), Int(n) < serials.count { return n }
        return nil
    }
}
