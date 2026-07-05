import Foundation
#if canImport(Darwin)
import Darwin
#endif

// PCMUDPReceiver — source stage of an AntennaHead audio pipeline.
//
// Contract:
//   • Input  : UDP datagrams on <port> (typically raw S16LE PCM from an
//     external tool such as nrsc5 running outside the app)
//   • Output : the datagram payloads, written to stdout in arrival order
//   • Sits at the START of a TaskPipelineManager chain; a downstream sox
//     stage normalizes rate/channels to the 48 kHz / 2 ch LAS contract.
//
// Usage: PCMUDPReceiver --port <n> [--bind <addr>] [--exit-with-parent]
//   --bind defaults to 127.0.0.1 (loopback only); use 0.0.0.0 to accept
//     datagrams from other machines on the LAN.
//   --exit-with-parent makes this process exit if the launching app dies (even
//     on a crash/SIGKILL, where the app can't run its own cleanup). Because
//     this is the upstream-most stage, downstream stages then see EOF and the
//     pipeline collapses cleanly.
//
// If stdout closes (the downstream stage exited), this process exits — the
// mirror image of PCMUDPSender's SIGPIPE-driven collapse.

let log = FileHandle.standardError
func note(_ message: String) {
    log.write(Data("PCMUDPReceiver: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

// MARK: Argument parsing

func parseArguments() -> (bind: String, port: UInt16, exitWithParent: Bool) {
    var bind = "127.0.0.1"
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
        case "--bind":
            i += 1
            guard i < args.count else { fail("Missing value for --bind") }
            bind = args[i]
        case "--exit-with-parent":
            exitWithParent = true
        default:
            fail("Unknown argument '\(args[i])'")
        }
        i += 1
    }
    guard let port else { fail("--port is required") }
    return (bind, port, exitWithParent)
}

let (bind, port, exitWithParent) = parseArguments()

// MARK: Parent-death watchdog
//
// Polls getppid() on a background thread. When the launching app exits (quit or
// crash), this process is reparented to launchd (pid 1), so getppid() changes —
// at which point we exit, and downstream stages see EOF.
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

// MARK: UDP socket setup (bound listening socket)

let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
guard socketFD >= 0 else {
    fail("socket() failed: \(String(cString: strerror(errno)))")
}

// Allow quick restarts of the pipeline on the same port.
var reuse: Int32 = 1
_ = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
guard inet_pton(AF_INET, bind, &addr.sin_addr) == 1 else {
    fail("invalid bind address '\(bind)'")
}

let bindResult = withUnsafePointer(to: &addr) { rawAddr in
    rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
        Darwin.bind(socketFD, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bindResult == 0 else {
    fail("bind() to \(bind):\(port) failed: \(String(cString: strerror(errno)))")
}

// Exiting on a dead downstream reader is our job (see write loop); don't let
// the default SIGPIPE disposition kill us before we can log it.
signal(SIGPIPE, SIG_IGN)

note("started — listening on \(bind):\(port), writing payloads to stdout")

// MARK: UDP → stdout loop

let bufferSize = 65_536
let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
var totalBytes = 0

while true {
    let received = recv(socketFD, buffer, bufferSize, 0)
    if received < 0 {
        if errno == EINTR { continue }
        fail("recv() failed after \(totalBytes) bytes: \(String(cString: strerror(errno)))")
    }
    if received == 0 { continue } // zero-length datagram; nothing to forward

    // Write the whole payload to stdout, handling short writes.
    var offset = 0
    while offset < received {
        let written = write(1, buffer + offset, received - offset)
        if written < 0 {
            if errno == EINTR { continue }
            note("stdout closed after \(totalBytes) bytes (\(String(cString: strerror(errno)))); exiting")
            close(socketFD)
            exit(0)
        }
        offset += written
        totalBytes += written
    }
}
