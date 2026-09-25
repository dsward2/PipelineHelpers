import Foundation

/// A running program that commonly holds an RTL-SDR dongle open.
public struct SDRDeviceHolder: Sendable, Equatable {
    public let pid: pid_t
    /// Program name, e.g. "Gqrx", "rtl_fm_localradio".
    public let name: String
    /// The app bundle the executable lives in ("ControlBooth" for its
    /// `Contents/Helpers/rtl_fm_localradio`), or nil for a standalone tool
    /// or when the path can't be read (e.g. under the App Sandbox).
    public let app: String?

    public init(pid: pid_t, name: String, app: String?) {
        self.pid = pid
        self.name = name
        self.app = app
    }

    /// "rtl_fm_localradio (ControlBooth)", "Gqrx", "rtl_tcp".
    public var label: String {
        guard let app, app.caseInsensitiveCompare(name) != .orderedSame,
              !app.lowercased().hasPrefix(name.lowercased()) else { return name }
        return "\(name) (\(app))"
    }
}

/// Finds running programs that may be holding an RTL-SDR open.
///
/// librtlsdr can't say which process has a device claimed, so this is a
/// best-effort list of known SDR programs, not an exact attribution — except
/// for Gqrx, whose input device `RTLSDRPreflight` asks for directly.
public enum SDRDeviceHolders {

    /// Executable names (matched case-insensitively against the start of the
    /// kernel's 16-character `p_comm`, which truncates longer names) mapped to
    /// the name to show.
    static let knownPrograms: [(prefix: String, display: String)] = [
        ("gqrx", "Gqrx"),
        ("rtl_fm_localradi", "rtl_fm_localradio"),
        ("rtl_fm", "rtl_fm"),
        ("rtl_sdr", "rtl_sdr"),
        ("rtl_tcp", "rtl_tcp"),
        ("rtl_power", "rtl_power"),
        ("rtl_test", "rtl_test"),
        ("rtl_adsb", "rtl_adsb"),
        ("rtl_433", "rtl_433"),
        ("rtl_eeprom", "rtl_eeprom"),
        ("nrsc5", "nrsc5"),
        ("dump1090", "dump1090"),
        ("dsd-neo", "dsd-neo"),
        ("sdrpp", "SDR++"),
        ("sdr++", "SDR++"),
        ("cubicsdr", "CubicSDR"),
        ("sdrangel", "SDRangel"),
        ("sdrconsole", "SDR Console"),
    ]

    /// Running programs that may hold an RTL-SDR, excluding `excludingPIDs`.
    public static func running(excludingPIDs: Set<pid_t> = []) -> [SDRDeviceHolder] {
        processes().compactMap { pid, comm in
            guard !excludingPIDs.contains(pid), let name = displayName(forCommand: comm) else { return nil }
            return SDRDeviceHolder(pid: pid, name: name, app: appName(forPID: pid))
        }
    }

    static func displayName(forCommand comm: String) -> String? {
        let lower = comm.lowercased()
        return knownPrograms.first { lower.hasPrefix($0.prefix) }?.display
    }

    /// The `.app` bundle an executable path lives in ("…/ControlBooth.app/
    /// Contents/Helpers/rtl_fm_localradio" → "ControlBooth"), or nil.
    static func appName(fromExecutablePath path: String) -> String? {
        let components = path.split(separator: "/")
        guard let bundle = components.last(where: { $0.hasSuffix(".app") }) else { return nil }
        return String(bundle.dropLast(".app".count))
    }

    private static func appName(forPID pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro isn't imported into Swift.
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return appName(fromExecutablePath: String(cString: buffer))
    }

    /// (pid, p_comm) for every process, via `sysctl(KERN_PROC_ALL)`.
    private static func processes() -> [(pid_t, String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).map { proc in
            var p = proc
            let comm = withUnsafeBytes(of: &p.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return (p.kp_proc.p_pid, comm)
        }
    }
}
