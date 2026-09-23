import AppKit
import Foundation

/// Read-only questions for a running Gqrx's remote control (default
/// `127.0.0.1:7356`) — used only to tell whether Gqrx holds a given dongle.
public enum GqrxRemoteControl {
    public static let defaultHost = "127.0.0.1"
    public static let defaultPort: UInt16 = 7356

    /// Gqrx's configured gr-osmosdr input device string (e.g. `rtl=0`), via
    /// `\get_input_device` (gqrx PR #1446, in Gqrx for AntennaHead). "" when
    /// this Gqrx doesn't support the command; nil when no Gqrx remote control
    /// is listening. Blocks (connect is instant on localhost; the reply times
    /// out after a few seconds), so call it off the main thread. Gqrx's remote
    /// control accepts several connections at once, so this doesn't disturb a
    /// client that is already polling it.
    public static func inputDevice(host: String = defaultHost, port: UInt16 = defaultPort) -> String? {
        guard let connection = Connection(host: host, port: port, timeoutSeconds: 3) else { return nil }
        defer { connection.close() }
        guard let reply = connection.exchange("\\get_input_device") else { return nil }
        return reply.hasPrefix("RPRT") ? "" : reply
    }

    /// One blocking TCP connection that exchanges newline-terminated
    /// commands for single-line replies.
    final class Connection {
        private var fd: Int32
        private var buffer = [UInt8]()

        init?(host: String, port: UInt16, timeoutSeconds: Int) {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { return nil }
            var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr(host)
            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            guard connected else { Darwin.close(s); return nil }
            fd = s
        }

        /// Sends `command` and returns the first reply line, nil on failure.
        func exchange(_ command: String) -> String? {
            guard fd >= 0 else { return nil }
            let payload = Array((command + "\n").utf8)
            guard payload.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == payload.count else {
                close(); return nil
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    return line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                guard n > 0 else { close(); return nil }
                buffer.append(contentsOf: chunk[..<n])
            }
        }

        func close() {
            if fd >= 0 { Darwin.close(fd); fd = -1 }
        }

        deinit { close() }
    }
}

/// Quits and relaunches the Gqrx app — the way to free a dongle Gqrx holds
/// (stopping its DSP doesn't: the osmosdr source keeps the device claimed
/// from launch) and to recover a Gqrx whose audio has turned to noise.
///
/// Quitting is a normal application quit, never a kill: Gqrx marks its
/// config "crashed" at launch and clears that only on a clean exit, so a
/// killed Gqrx greets the next launch with its "Crash Detected!" dialog.
public enum GqrxApp {

    /// Gqrx for AntennaHead, then stock Gqrx.
    public static let bundleIdentifiers = ["com.dsward.gqrx-for-antennahead", "dk.gqrx.gqrx"]

    public enum QuitResult: Sendable, Equatable {
        /// No Gqrx was running.
        case notRunning
        /// Every running Gqrx quit; these are their app bundles, for relaunch.
        case quit(bundleURLs: [URL])
        /// A Gqrx was still running when the wait ran out (it may be showing
        /// a dialog, or the quit request wasn't allowed).
        case failed(String)
    }

    public static func running() -> [NSRunningApplication] {
        bundleIdentifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    public static var isRunning: Bool { !running().isEmpty }

    /// Asks every running Gqrx to quit and waits (up to `timeout`) for them to
    /// exit. Blocks, so call it off the main thread.
    ///
    /// Tries `NSRunningApplication.terminate()` first; if the app is still up
    /// a couple of seconds later (a sandboxed caller may not be allowed to
    /// use it), sends the standard quit Apple Event directly — which needs
    /// the caller's Apple Events entitlement and, the first time, the user's
    /// Automation permission.
    public static func quit(timeout: TimeInterval = 15) -> QuitResult {
        let apps = running()
        guard !apps.isEmpty else { return .notRunning }
        let urls = apps.compactMap(\.bundleURL)
        let pids = apps.map(\.processIdentifier)
        let deadline = Date().addingTimeInterval(timeout)

        for app in apps { _ = app.terminate() }
        _ = waitForExit(pids, until: min(deadline, Date().addingTimeInterval(2)))

        var appleEventError: String?
        for pid in pids where isAlive(pid) {
            let quitEvent = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass),
                eventID: AEEventID(kAEQuitApplication),
                targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID))
            do {
                _ = try quitEvent.sendEvent(options: [.noReply], timeout: 5)
            } catch {
                appleEventError = (error as NSError).localizedDescription + " (\((error as NSError).code))"
            }
        }

        guard waitForExit(pids, until: deadline) else {
            var why = "Gqrx didn't quit"
            if let appleEventError { why += " — the quit request failed: \(appleEventError)" }
            return .failed(why + ".")
        }
        return .quit(bundleURLs: urls)
    }

    /// Opens each app bundle again (the Gqrx builds `quit` returned).
    public static func relaunch(_ bundleURLs: [URL]) async {
        for url in bundleURLs {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Polls until every pid has exited; false if `deadline` passes first.
    private static func waitForExit(_ pids: [pid_t], until deadline: Date) -> Bool {
        while pids.contains(where: isAlive) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }
}
