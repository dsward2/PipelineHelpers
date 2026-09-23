import Foundation

/// The result of checking whether an RTL-SDR can be opened right now.
public struct RTLSDRPreflightReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// The device opened (and was closed again) — safe to launch.
        case available
        /// Another process has the device claimed (librtlsdr error `code`).
        case busy(code: Int32)
        /// No connected device matches the requested value.
        case notFound
        /// No RTL-SDR devices are connected at all.
        case noDevices
    }

    /// The device argument as given (`-d` value, "" = index 0).
    public let requested: String
    public let outcome: Outcome
    /// The resolved USB index, nil for `.notFound` / `.noDevices`.
    public let index: UInt32?
    /// The resolved device's EEPROM serial, "" when unknown.
    public let serial: String
    /// Known SDR programs running at check time (busy only).
    public let holders: [SDRDeviceHolder]
    /// True when Gqrx is the holder: its configured input device is this
    /// dongle, or (with its remote control off) it is the only SDR program
    /// running. Quitting Gqrx frees the dongle — what drives a "Quit Gqrx and
    /// Retry" button. (Stopping Gqrx's DSP doesn't: the device stays open.)
    public let gqrxIsHolder: Bool

    public var isAvailable: Bool { outcome == .available }

    /// "USB device 00000360" / "USB device 1" / "USB device 0".
    public var deviceLabel: String {
        if !serial.isEmpty { return "USB device \(serial)" }
        if let index { return "USB device \(index)" }
        return requested.isEmpty ? "USB device 0" : "USB device \(requested)"
    }

    /// One user-facing sentence (or two) explaining the outcome.
    public var message: String {
        switch outcome {
        case .available:
            return "\(deviceLabel) is available."
        case .noDevices:
            return "No RTL-SDR devices are connected."
        case .notFound:
            return "No connected RTL-SDR matches USB device \u{201C}\(requested)\u{201D}."
        case .busy:
            var text = "\(deviceLabel) is in use by another program"
            if gqrxIsHolder {
                text += " (Gqrx)."
            } else if holders.isEmpty {
                text += "."
            } else {
                var labels: [String] = []   // two rtl_sdr instances read as one "rtl_sdr"
                for label in holders.map(\.label) where !labels.contains(label) { labels.append(label) }
                text += ". Running now: " + labels.joined(separator: ", ") + "."
            }
            return text
        }
    }

    public init(requested: String, outcome: Outcome, index: UInt32?, serial: String,
                holders: [SDRDeviceHolder] = [], gqrxIsHolder: Bool = false) {
        self.requested = requested
        self.outcome = outcome
        self.index = index
        self.serial = serial
        self.holders = holders
        self.gqrxIsHolder = gqrxIsHolder
    }
}

/// Checks that an RTL-SDR is free before a tool is launched on it, so a
/// contention failure is reported up front (naming the likely holder) instead
/// of surfacing as a pipeline that silently dies, and says when quitting Gqrx
/// would free it.
///
/// All calls block — the trial open takes ~0.4 s on a free device — so run
/// them off the main thread, *after* any previous pipeline on the device has
/// exited (or it will report the app's own old process as the holder).
///
/// The check is a trial `rtlsdr_open` / `rtlsdr_close`, so there is a
/// millisecond-scale window between it and the real open in which another
/// program could still take the device; the launch path must still handle a
/// failed open.
public enum RTLSDRPreflight {

    /// Checks `device` (an `rtl_fm -d` value). `gqrxInputDevice` defaults to
    /// asking a local Gqrx's remote control (nil = not reachable); tests pass
    /// a fixed value.
    public static func check(device: String,
                             backend: RTLSDRBackend,
                             excludingPIDs: Set<pid_t> = [],
                             holders: () -> [SDRDeviceHolder]? = { nil },
                             gqrxInputDevice: () -> String? = { GqrxRemoteControl.inputDevice() })
        -> RTLSDRPreflightReport
    {
        let requested = device.trimmingCharacters(in: .whitespaces)
        let count = backend.deviceCount()
        guard count > 0 else {
            return RTLSDRPreflightReport(requested: requested, outcome: .noDevices, index: nil, serial: "")
        }
        let serials = (0..<count).map { backend.serial(at: $0) }
        guard let index = RTLSDRDeviceResolver.rtlToolIndex(for: requested, serials: serials) else {
            return RTLSDRPreflightReport(requested: requested, outcome: .notFound, index: nil, serial: "")
        }
        let serial = serials[Int(index)] ?? ""

        let code = backend.tryOpen(at: index)
        guard code != 0 else {
            return RTLSDRPreflightReport(requested: requested, outcome: .available, index: index, serial: serial)
        }

        // Busy: find out who has it. Gqrx can say exactly which device it
        // holds; everything else is a list of likely candidates.
        var running = holders() ?? SDRDeviceHolders.running(excludingPIDs: excludingPIDs)
        var gqrxIsHolder = false
        if running.contains(where: { $0.name == "Gqrx" }) {
            if let gqrxDevice = gqrxInputDevice() {
                // Gqrx holds its configured device from launch (DSP running or
                // not). It's the holder when that device is this one — or can't
                // be resolved (a Gqrx without \get_input_device) — so a Gqrx on
                // a different dongle is never quit for nothing.
                let gqrxIndex = RTLSDRDeviceResolver.osmosdrIndex(for: gqrxDevice, serials: serials)
                let isLocalRTL = gqrxDevice.isEmpty || gqrxIndex != nil
                gqrxIsHolder = isLocalRTL && (gqrxIndex == nil || gqrxIndex == index)
                if !gqrxIsHolder { running.removeAll { $0.name == "Gqrx" } }   // provably not it
            } else {
                // Remote control off, so Gqrx can't say which dongle it has:
                // blame it only when it's the only SDR program running.
                gqrxIsHolder = running.map(\.name) == ["Gqrx"]
            }
        }

        return RTLSDRPreflightReport(requested: requested, outcome: .busy(code: code), index: index,
                                     serial: serial, holders: running, gqrxIsHolder: gqrxIsHolder)
    }

    /// Quits Gqrx (a normal quit — see `GqrxApp`), then re-checks `device`,
    /// allowing the USB release up to `settleSeconds` to land. Returns the
    /// quit result (its bundle URLs let a caller relaunch Gqrx later) and the
    /// fresh report (still `.busy` if something else holds the dongle).
    /// Blocks for as long as Gqrx takes to quit.
    public static func quitGqrxAndRecheck(device: String,
                                          backend: RTLSDRBackend,
                                          excludingPIDs: Set<pid_t> = [],
                                          settleSeconds: Double = 3.0)
        -> (quit: GqrxApp.QuitResult, report: RTLSDRPreflightReport)
    {
        let quit = GqrxApp.quit()
        let deadline = Date().addingTimeInterval(settleSeconds)
        var report = check(device: device, backend: backend, excludingPIDs: excludingPIDs)
        while case .busy = report.outcome, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            report = check(device: device, backend: backend, excludingPIDs: excludingPIDs)
        }
        return (quit, report)
    }
}
