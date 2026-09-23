import Foundation

/// Asks a running Gqrx (remote control, default `127.0.0.1:7356`) about its
/// input device and makes it release or reopen that device, via the
/// Gqrx-for-AntennaHead `U INPUT` / `u INPUT` commands (dsward2/gqrx#3).
///
/// Stopping Gqrx's DSP (`U DSP 0`) does **not** free the dongle — the osmosdr
/// source keeps it claimed — which is why this exists.
///
/// Every call opens its own short-lived connection and blocks (connect is
/// instant on localhost; replies time out after a few seconds), so call it off
/// the main thread. Gqrx's remote control accepts several connections at
/// once, so this doesn't disturb a polling client that is already connected.
public enum GqrxInputControl {

    public struct Status: Sendable, Equatable {
        /// This Gqrx understands `U INPUT` (lists INPUT in `u ?`).
        public let hasInputControl: Bool
        /// Gqrx currently has its input device open (`u INPUT` = 1). Always
        /// true on a Gqrx without `hasInputControl`: it never releases it.
        public let inputOpen: Bool
        /// The configured gr-osmosdr device string (`\get_input_device`,
        /// gqrx PR #1446), "" when unsupported.
        public let inputDevice: String

        public init(hasInputControl: Bool, inputOpen: Bool, inputDevice: String) {
            self.hasInputControl = hasInputControl
            self.inputOpen = inputOpen
            self.inputDevice = inputDevice
        }
    }

    public static let defaultHost = "127.0.0.1"
    public static let defaultPort: UInt16 = 7356

    /// Gqrx's input-device state, or nil when no Gqrx is listening.
    public static func status(host: String = defaultHost, port: UInt16 = defaultPort) -> Status? {
        guard let connection = Connection(host: host, port: port, timeoutSeconds: 3) else { return nil }
        defer { connection.close() }
        guard let functions = connection.exchange("u ?") else { return nil }
        let hasInputControl = functions.split(separator: " ")
            .contains { $0.caseInsensitiveCompare("INPUT") == .orderedSame }
        let inputOpen = hasInputControl ? connection.exchange("u INPUT") != "0" : true
        let device = connection.exchange("\\get_input_device") ?? ""
        return Status(hasInputControl: hasInputControl,
                      inputOpen: inputOpen,
                      inputDevice: device.hasPrefix("RPRT") ? "" : device)
    }

    /// Closes (`open == false`) or reopens Gqrx's input device. True when
    /// Gqrx acknowledged with `RPRT 0`; reopening replies `RPRT 1` while
    /// another program still holds the device. Reopening reloads Gqrx's
    /// configuration, so it can take a few seconds.
    @discardableResult
    public static func setInputOpen(_ open: Bool, host: String = defaultHost, port: UInt16 = defaultPort) -> Bool {
        guard let connection = Connection(host: host, port: port, timeoutSeconds: 15) else { return false }
        defer { connection.close() }
        return connection.exchange("U INPUT \(open ? 1 : 0)") == "RPRT 0"
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
