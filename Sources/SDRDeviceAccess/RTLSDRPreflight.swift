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
    /// True when Gqrx has this very device open and can be asked to release
    /// it (`U INPUT 0`) — what drives a "Release from Gqrx" button.
    public let gqrxCanRelease: Bool
    /// True when Gqrx is (or may be) the holder but predates `U INPUT`, so
    /// the only way to free the device is to quit it.
    public let gqrxHoldsWithoutRelease: Bool

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
            if gqrxCanRelease || gqrxHoldsWithoutRelease {
                text += " (Gqrx)."
                if gqrxHoldsWithoutRelease {
                    text += " Gqrx can't be asked to release it (remote control is off, or this Gqrx predates U INPUT), so quit Gqrx to free it."
                }
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
                holders: [SDRDeviceHolder] = [], gqrxCanRelease: Bool = false,
                gqrxHoldsWithoutRelease: Bool = false) {
        self.requested = requested
        self.outcome = outcome
        self.index = index
        self.serial = serial
        self.holders = holders
        self.gqrxCanRelease = gqrxCanRelease
        self.gqrxHoldsWithoutRelease = gqrxHoldsWithoutRelease
    }
}

/// Checks that an RTL-SDR is free before a tool is launched on it, so a
/// contention failure is reported up front (naming the likely holder) instead
/// of surfacing as a pipeline that silently dies, and offers to take the
/// device back from Gqrx.
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

    /// Checks `device` (an `rtl_fm -d` value). `gqrxStatus` defaults to
    /// asking a local Gqrx; tests pass a fixed value.
    public static func check(device: String,
                             backend: RTLSDRBackend,
                             excludingPIDs: Set<pid_t> = [],
                             holders: () -> [SDRDeviceHolder]? = { nil },
                             gqrxStatus: () -> GqrxInputControl.Status? = { GqrxInputControl.status() })
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
        var gqrxCanRelease = false
        var gqrxHoldsWithoutRelease = false
        if let gqrx = gqrxStatus() {
            // Offer release only when Gqrx's device is this one — or can't be
            // resolved (an older Gqrx without \get_input_device) — so a Gqrx
            // using a different dongle is never disturbed.
            let gqrxIndex = RTLSDRDeviceResolver.osmosdrIndex(for: gqrx.inputDevice, serials: serials)
            let isLocalRTL = gqrx.inputDevice.isEmpty || gqrxIndex != nil
            let holdsThis = gqrx.inputOpen && isLocalRTL && (gqrxIndex == nil || gqrxIndex == index)
            if holdsThis {
                if gqrx.hasInputControl { gqrxCanRelease = true } else { gqrxHoldsWithoutRelease = true }
            } else {
                running.removeAll { $0.name == "Gqrx" }   // it provably isn't the holder
            }
        } else if running.map(\.name) == ["Gqrx"] {
            // Gqrx is the only SDR program running, with remote control off:
            // almost certainly the holder, and it can't be asked to release.
            gqrxHoldsWithoutRelease = true
        }

        return RTLSDRPreflightReport(requested: requested, outcome: .busy(code: code), index: index,
                                     serial: serial, holders: running,
                                     gqrxCanRelease: gqrxCanRelease,
                                     gqrxHoldsWithoutRelease: gqrxHoldsWithoutRelease)
    }

    /// Asks Gqrx to release its input device (`U INPUT 0`), then re-checks
    /// `device`, allowing the USB release up to `settleSeconds` to land.
    /// Returns the fresh report (still `.busy` if something else holds it).
    public static func releaseFromGqrxAndRecheck(device: String,
                                                 backend: RTLSDRBackend,
                                                 excludingPIDs: Set<pid_t> = [],
                                                 settleSeconds: Double = 2.0) -> RTLSDRPreflightReport {
        GqrxInputControl.setInputOpen(false)
        let deadline = Date().addingTimeInterval(settleSeconds)
        var report = check(device: device, backend: backend, excludingPIDs: excludingPIDs)
        while case .busy = report.outcome, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            report = check(device: device, backend: backend, excludingPIDs: excludingPIDs)
        }
        return report
    }
}
