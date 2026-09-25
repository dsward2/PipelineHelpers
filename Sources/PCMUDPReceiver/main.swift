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
//                       [--fill-silence --rate <hz> [--channels <n>]
//                        [--prebuffer-ms <ms>] [--max-buffer-ms <ms>]]
//   --bind accepts IPv4 (e.g. 127.0.0.1, 0.0.0.0) or IPv6 (e.g. ::1, ::)
//     addresses. Defaults to 127.0.0.1. The socket family (AF_INET vs
//     AF_INET6) is inferred automatically from the address format.
//   --exit-with-parent makes this process exit if the launching app dies (even
//     on a crash/SIGKILL, where the app can't run its own cleanup). Because
//     this is the upstream-most stage, downstream stages then see EOF and the
//     pipeline collapses cleanly.
//
//   --fill-silence turns a bursty source into a continuous, real-time paced
//     stream: output is written in 20 ms blocks, and whenever no audio has
//     arrived the block is silence. For sources that only send while there is
//     something to hear (dsd-neo's decoded voice, between radio calls), so the
//     rest of the pipeline and LiveAudioServer see an unbroken stream.
//     Requires --rate (the incoming sample rate) and takes --channels
//     (default 2); payloads are S16LE. Each burst is held for --prebuffer-ms
//     (default 100) before it starts playing, to ride out network jitter,
//     and a backlog beyond --max-buffer-ms (default 1000) drops its oldest
//     audio so latency can't grow without bound.
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

struct FillSilenceOptions {
    var rate: Int
    var channels: Int
    var prebufferMs: Int
    var maxBufferMs: Int
}

func parseArguments() -> (bind: String, port: UInt16, exitWithParent: Bool, fill: FillSilenceOptions?) {
    var bind = "127.0.0.1"
    var port: UInt16?
    var exitWithParent = false
    var fillSilence = false
    var rate: Int?
    var channels = 2
    var prebufferMs = 100
    var maxBufferMs = 1000
    func intValue(_ flag: String, _ i: inout Int, _ args: [String], range: ClosedRange<Int>) -> Int {
        i += 1
        guard i < args.count, let value = Int(args[i]), range.contains(value) else {
            fail("Missing or invalid value for \(flag) (expected \(range.lowerBound)–\(range.upperBound))")
        }
        return value
    }
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
        case "--fill-silence":
            fillSilence = true
        case "--rate", "-r":
            rate = intValue("--rate", &i, args, range: 1_000...384_000)
        case "--channels", "-c":
            channels = intValue("--channels", &i, args, range: 1...8)
        case "--prebuffer-ms":
            prebufferMs = intValue("--prebuffer-ms", &i, args, range: 0...5_000)
        case "--max-buffer-ms":
            maxBufferMs = intValue("--max-buffer-ms", &i, args, range: 100...60_000)
        default:
            fail("Unknown argument '\(args[i])'")
        }
        i += 1
    }
    guard let port else { fail("--port is required") }
    var fill: FillSilenceOptions?
    if fillSilence {
        guard let rate else { fail("--fill-silence requires --rate") }
        fill = FillSilenceOptions(rate: rate, channels: channels,
                                  prebufferMs: prebufferMs, maxBufferMs: max(maxBufferMs, prebufferMs + 100))
    }
    return (bind, port, exitWithParent, fill)
}

let (bind, port, exitWithParent, fillSilence) = parseArguments()

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

// Infer socket family from the bind address: try IPv6 first, fall back to IPv4.
var in6Addr = in6_addr()
let isIPv6 = inet_pton(AF_INET6, bind, &in6Addr) == 1

let socketFD: Int32
let bindResult: Int32

if isIPv6 {
    socketFD = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
    guard socketFD >= 0 else {
        fail("socket(AF_INET6) failed: \(String(cString: strerror(errno)))")
    }
    var reuse: Int32 = 1
    _ = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var addr6 = sockaddr_in6()
    addr6.sin6_family = sa_family_t(AF_INET6)
    addr6.sin6_port = port.bigEndian
    addr6.sin6_addr = in6Addr
    bindResult = withUnsafePointer(to: &addr6) { rawAddr in
        rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
    }
} else {
    var in4Addr = in_addr()
    guard inet_pton(AF_INET, bind, &in4Addr) == 1 else {
        fail("invalid bind address '\(bind)' (not a valid IPv4 or IPv6 address)")
    }
    socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard socketFD >= 0 else {
        fail("socket(AF_INET) failed: \(String(cString: strerror(errno)))")
    }
    var reuse: Int32 = 1
    _ = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var addr4 = sockaddr_in()
    addr4.sin_family = sa_family_t(AF_INET)
    addr4.sin_port = port.bigEndian
    addr4.sin_addr = in4Addr
    bindResult = withUnsafePointer(to: &addr4) { rawAddr in
        rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}
guard bindResult == 0 else {
    fail("bind() to \(bind):\(port) failed: \(String(cString: strerror(errno)))")
}

// Exiting on a dead downstream reader is our job (see write loop); don't let
// the default SIGPIPE disposition kill us before we can log it.
signal(SIGPIPE, SIG_IGN)

// MARK: Output

let bufferSize = 65_536
let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
var totalBytes = 0

/// Writes all of `bytes` to stdout, handling short writes; exits when the
/// downstream reader has gone away.
func writeAll(_ bytes: UnsafeRawPointer, _ count: Int) {
    var offset = 0
    while offset < count {
        let written = write(1, bytes + offset, count - offset)
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

// MARK: Paced UDP → stdout loop (--fill-silence)

/// Emits one `chunk` every `chunkMs`, from buffered audio when a burst is
/// playing and silence otherwise. The socket is drained between ticks.
func runFillSilence(_ options: FillSilenceOptions) -> Never {
    let frameBytes = 2 * options.channels
    let bytesPerMs = Double(options.rate * frameBytes) / 1000.0
    func alignedBytes(ms: Int) -> Int {
        let raw = Int(bytesPerMs * Double(ms))
        return max(frameBytes, raw - raw % frameBytes)
    }
    let chunkMs = 20
    let chunk = alignedBytes(ms: chunkMs)
    let prebuffer = options.prebufferMs == 0 ? 0 : alignedBytes(ms: options.prebufferMs)
    let maxBuffer = alignedBytes(ms: options.maxBufferMs)
    let silence = [UInt8](repeating: 0, count: chunk)
    var pending = [UInt8]()
    pending.reserveCapacity(maxBuffer + bufferSize)
    var playing = false
    var carry = [UInt8]()   // partial frame from a datagram that split one

    let interval = UInt64(chunkMs) * 1_000_000
    var nextTick = DispatchTime.now().uptimeNanoseconds

    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        if now < nextTick {
            var pfd = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32(max(1, (nextTick - now) / 1_000_000))
            let ready = poll(&pfd, 1, waitMs)
            if ready < 0 && errno != EINTR {
                fail("poll() failed: \(String(cString: strerror(errno)))")
            }
            if ready > 0 {
                while true {
                    let received = recv(socketFD, buffer, bufferSize, MSG_DONTWAIT)
                    if received <= 0 { break }
                    carry.append(contentsOf: UnsafeRawBufferPointer(start: buffer, count: received))
                    let whole = carry.count - carry.count % frameBytes
                    pending.append(contentsOf: carry[0..<whole])
                    carry.removeFirst(whole)
                }
                if pending.count > maxBuffer {
                    pending.removeFirst(pending.count - maxBuffer)   // frame-aligned: both are
                }
            }
            continue
        }

        if !playing && pending.count >= max(prebuffer, 1) {
            playing = true
        }
        if playing && pending.count >= chunk {
            pending.withUnsafeBytes { writeAll($0.baseAddress!, chunk) }
            pending.removeFirst(chunk)
        } else {
            // End of a burst (or nothing yet): flush any tail padded with
            // silence, then idle on silence until the next burst prebuffers.
            if playing && !pending.isEmpty {
                var block = pending
                block.append(contentsOf: silence[0..<(chunk - pending.count)])
                block.withUnsafeBytes { writeAll($0.baseAddress!, chunk) }
                pending.removeAll(keepingCapacity: true)
            } else {
                silence.withUnsafeBytes { writeAll($0.baseAddress!, chunk) }
            }
            playing = false
        }

        nextTick += interval
        // Fell far behind (system sleep, a stalled reader): resync to now
        // rather than bursting the missed blocks out all at once.
        let after = DispatchTime.now().uptimeNanoseconds
        if after > nextTick + 1_000_000_000 {
            nextTick = after
        }
    }
}

if let fillSilence {
    note("started — listening on \(bind):\(port), writing a continuous \(fillSilence.rate) Hz " +
         "\(fillSilence.channels)-channel stream to stdout (silence between bursts)")
    runFillSilence(fillSilence)
}

note("started — listening on \(bind):\(port), writing payloads to stdout")

// MARK: UDP → stdout loop

while true {
    let received = recv(socketFD, buffer, bufferSize, 0)
    if received < 0 {
        if errno == EINTR { continue }
        fail("recv() failed after \(totalBytes) bytes: \(String(cString: strerror(errno)))")
    }
    if received == 0 { continue } // zero-length datagram; nothing to forward

    writeAll(buffer, received)
}
