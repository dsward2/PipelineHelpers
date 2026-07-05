import Foundation
#if canImport(Darwin)
import Darwin
#endif

// PCMUDPSender — terminal stage of an AntennaHead audio pipeline.
//
// Contract:
//   • Input  : raw signed 16-bit little-endian, mono, 48000 Hz PCM on stdin
//   • Output : the same bytes, sent as UDP datagrams to <host>:<port>
//   • Sits at the END of the TaskPipelineManager chain, feeding a continuously
//     running LiveAudioServer's --udp-input-port.
//
// Usage: PCMUDPSender --port <n> [--host <addr>] [--exit-with-parent]
//   --host defaults to 127.0.0.1 (LiveAudioServer runs on the same machine).
//   --exit-with-parent makes this process exit if the launching app dies (even
//     on a crash/SIGKILL, where the app can't run its own cleanup). Because this
//     is the downstream-most reader in the rtl_fm | sox | PCMUDPSender chain,
//     exiting here collapses the whole pipeline via SIGPIPE upstream.
//
// Datagrams are capped at 2048 bytes, matching LocalRadio's UDPSender; this is
// well under the loopback MTU and within LiveAudioServer's receive buffer.

let log = FileHandle.standardError
func note(_ message: String) {
    log.write(Data("PCMUDPSender: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

// MARK: Argument parsing

func parseArguments() -> (host: String, port: UInt16, exitWithParent: Bool) {
    var host = "127.0.0.1"
    var port: UInt16?
    var exitWithParent = false
    var args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--port", "-p":
            i += 1
            guard i < args.count, let value = UInt16(args[i]) else {
                fail("Missing or invalid value for --port (expected 1–65535)")
            }
            port = value
        case "--host":
            i += 1
            guard i < args.count else { fail("Missing value for --host") }
            host = args[i]
        case "--exit-with-parent":
            exitWithParent = true
        default:
            fail("Unknown argument '\(args[i])'")
        }
        i += 1
    }
    guard let port else { fail("--port is required") }
    return (host, port, exitWithParent)
}

let (host, port, exitWithParent) = parseArguments()

// MARK: Parent-death watchdog
//
// Polls getppid() on a background thread. When the launching app exits (quit or
// crash), this process is reparented to launchd (pid 1), so getppid() changes —
// at which point we exit, collapsing the pipeline upstream via SIGPIPE.
func startParentDeathWatchdog() {
    let originalParent = getppid()
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            if getppid() != originalParent {
                note("parent process \(originalParent) exited; shutting down")
                exit(0)
            }
        }
    }
}

if exitWithParent {
    startParentDeathWatchdog()
}

// MARK: UDP socket setup (connected datagram socket)

let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
guard socketFD >= 0 else {
    fail("socket() failed: \(String(cString: strerror(errno)))")
}

var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
    fail("invalid host address '\(host)'")
}

let connectResult = withUnsafePointer(to: &addr) { rawAddr in
    rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
        connect(socketFD, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard connectResult == 0 else {
    fail("connect() to \(host):\(port) failed: \(String(cString: strerror(errno)))")
}

note("started — forwarding S16LE mono 48000 Hz to \(host):\(port)")

// MARK: stdin → UDP loop

let maxDatagram = 2048
let input = FileHandle.standardInput
var totalBytes = 0

while true {
    let chunk = input.availableData
    if chunk.isEmpty { break } // EOF: upstream closed.

    // Split into datagrams no larger than maxDatagram.
    var offset = 0
    let count = chunk.count
    let sendFailed: Bool = chunk.withUnsafeBytes { rawBuffer -> Bool in
        guard let base = rawBuffer.baseAddress else { return true }
        while offset < count {
            let length = min(maxDatagram, count - offset)
            let sent = send(socketFD, base + offset, length, 0)
            if sent < 0 {
                note("send() failed after \(totalBytes) bytes: \(String(cString: strerror(errno)))")
                return true
            }
            offset += length
            totalBytes += length
        }
        return false
    }
    if sendFailed { exit(1) }
}

note("stdin closed — \(totalBytes) bytes sent; exiting")
close(socketFD)
