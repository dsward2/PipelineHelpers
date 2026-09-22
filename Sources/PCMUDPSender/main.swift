import Foundation
#if canImport(Darwin)
import Darwin
#endif

// PCMUDPSender — terminal stage of an AntennaHead audio pipeline.
//
// Contract:
//   • Input  : raw signed 16-bit little-endian, mono, 48000 Hz PCM on stdin
//   • Output : the same bytes, self-paced in real time (see --rate below) and
//     sent as UDP datagrams to <host>:<port>
//   • Sits at the END of the TaskPipelineManager chain, feeding a continuously
//     running LiveAudioServer's --udp-input-port.
//
// Usage: PCMUDPSender --port <n> [--host <addr>] [--frame-bytes <n>]
//        [--rate <hz>] [--exit-with-parent] [--control-port <n>] [--relay <on|off>]
//   --host defaults to 127.0.0.1 (LiveAudioServer runs on the same machine).
//   --frame-bytes  datagram-boundary alignment in bytes (default 4 = one S16LE
//     stereo frame). A datagram never splits a frame: the trailing 1…N−1 bytes
//     of a stdin read are carried into the next datagram. Without this a stdin
//     chunk whose size is not a multiple of the frame (e.g. sox writing in an
//     odd `--buffer` size) produced odd-length datagrams, and any UDP
//     reordering/loss on the hop then shifted every later sample by a byte —
//     full-scale broadband static downstream (cf. the mixer filler bug). Pass
//     `--frame-bytes 1` for the pre-existing unaligned behaviour.
//   --rate  stream sample rate in Hz, used only to pace output (default 48000,
//     the LiveAudioServer contract every caller in AntennaHead resamples or
//     bridges to before reaching this stage). Upstream stages like sox emit in
//     bursts sized for their own buffering (e.g. ~50ms chunks at narrowband
//     rates — see SDRController's makeResampleTaskItem), not steadily; without
//     pacing, this stage forwarded each burst as a flurry of back-to-back UDP
//     datagrams with silence in between rather than a smooth stream, which
//     downstream playback could hear as choppy audio even though the
//     long-run byte rate was correct. Self-pacing here (same technique as
//     PCMPrefix's clip playback) smooths that back out. Has no effect on
//     correctness if the rate is wrong — only on how evenly output is spread.
//   --exit-with-parent makes this process exit if the launching app dies (even
//     on a crash/SIGKILL, where the app can't run its own cleanup). Because this
//     is the downstream-most reader in the rtl_fm | sox | PCMUDPSender chain,
//     exiting here collapses the whole pipeline via SIGPIPE upstream.
//   --control-port  UDP port for live "relay on"/"relay off"/"relay?" commands
//     (same control-socket convention as PCMDistanceGain/PCMMixer). Lets a host
//     app mute/unmute the outgoing stream without restarting this process or
//     anything upstream of it — e.g. ControlBooth's AirPlay receiver keeps
//     shairport-sync connected to its AirPlay source while toggling whether the
//     decoded audio actually reaches AntennaHead.
//   --relay  initial relay state, "on" (default) or "off". With --control-port,
//     this is just the starting value; "relay on"/"relay off" datagrams change
//     it at runtime.
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

func parseArguments() -> (host: String, port: UInt16, frameBytes: Int, rate: Int, exitWithParent: Bool,
                          controlPort: UInt16?, relayEnabled: Bool) {
    var host = "127.0.0.1"
    var port: UInt16?
    var frameBytes = 4
    var rate = 48_000
    var exitWithParent = false
    var controlPort: UInt16?
    var relayEnabled = true
    let args = Array(CommandLine.arguments.dropFirst())
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
        case "--frame-bytes":
            i += 1
            guard i < args.count, let value = Int(args[i]), value >= 1, value <= 2048 else {
                fail("Missing or invalid value for --frame-bytes (expected 1–2048)")
            }
            frameBytes = value
        case "--rate":
            i += 1
            guard i < args.count, let value = Int(args[i]), value >= 8_000, value <= 192_000 else {
                fail("Missing or invalid value for --rate")
            }
            rate = value
        case "--exit-with-parent":
            exitWithParent = true
        case "--control-port":
            i += 1
            guard i < args.count, let value = UInt16(args[i]) else {
                fail("Missing or invalid value for --control-port (expected 1–65535)")
            }
            controlPort = value
        case "--relay":
            i += 1
            guard i < args.count, ["on", "off"].contains(args[i]) else {
                fail("Missing or invalid value for --relay (expected 'on' or 'off')")
            }
            relayEnabled = (args[i] == "on")
        default:
            fail("Unknown argument '\(args[i])'")
        }
        i += 1
    }
    guard let port else { fail("--port is required") }
    return (host, port, frameBytes, rate, exitWithParent, controlPort, relayEnabled)
}

let (host, port, frameBytes, rate, exitWithParent, controlPort, initialRelayEnabled) = parseArguments()

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

// MARK: Relay mute/unmute (--control-port)

/// Read from the pacing loop on every packet and written from the control
/// thread; an NSLock around a plain Bool is cheap enough at this rate (same
/// reasoning as PCMDistanceGain's DistanceBox).
final class RelayBox {
    private let lock = NSLock()
    private var value: Bool
    init(_ initial: Bool) { value = initial }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

let relayEnabled = RelayBox(initialRelayEnabled)

/// UDP control listener accepting "relay on" / "relay off" / "relay?" —
/// same accept-loop shape as PCMDistanceGain's startControlListener.
func startControlListener(port: UInt16) {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { fail("socket() for control failed: \(String(cString: strerror(errno)))") }
    var reuse: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = INADDR_ANY
    let result = withUnsafePointer(to: &addr) { rawAddr in
        rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
            bind(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else { fail("bind() control to port \(port) failed: \(String(cString: strerror(errno)))") }

    Thread.detachNewThread {
        let bufferSize = 512
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
        var sender = sockaddr_in()
        while true {
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &sender) { rawSender in
                rawSender.withMemoryRebound(to: sockaddr.self, capacity: 1) { senderAddr in
                    recvfrom(fd, buffer, bufferSize, 0, senderAddr, &senderLen)
                }
            }
            guard received > 0 else { continue }
            let text = String(decoding: UnsafeRawBufferPointer(start: buffer, count: received), as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) {
                let words = line.split(separator: " ")
                switch words.first {
                case "relay" where words.count == 2 && words[1] == "on":
                    relayEnabled.set(true)
                    note("control: relay on")
                case "relay" where words.count == 2 && words[1] == "off":
                    relayEnabled.set(false)
                    note("control: relay off")
                case "relay?":
                    let reply = "relay=\(relayEnabled.get() ? "on" : "off")\n"
                    _ = reply.withCString { cString in
                        withUnsafePointer(to: &sender) { rawSender in
                            rawSender.withMemoryRebound(to: sockaddr.self, capacity: 1) { senderAddr in
                                sendto(fd, cString, strlen(cString), 0, senderAddr, senderLen)
                            }
                        }
                    }
                default:
                    note("control: ignoring '\(line)'")
                }
            }
        }
    }
}

if let controlPort {
    startControlListener(port: controlPort)
}

note("started — forwarding S16LE PCM to \(host):\(port) (\(frameBytes)-byte frame alignment, paced at \(rate) Hz"
     + (controlPort.map { ", control port \($0), relay \(initialRelayEnabled ? "on" : "off")" } ?? "") + ")")

// MARK: stdin → UDP loop

// Largest ≤2048 datagram that is still a whole number of frames.
let maxDatagram = max(frameBytes, 2048 - (2048 % frameBytes))
let input = FileHandle.standardInput
var totalBytes = 0
var sawEOF = false
/// Trailing 1…frameBytes−1 bytes held back from a stdin read so a datagram
/// never splits a frame; prepended to the next read.
var carry = [UInt8]()

// Self-pacing state (see --rate in the header comment). `deadline` starts now
// so pre-loop setup time isn't counted as a pacing debt.
let bytesPerSecond = Double(rate) * Double(frameBytes)
var deadline = Date()

// TEMP DIAGNOSTIC — remove after the choppy-audio investigation. Reports,
// every ~2s, how bursty stdin reads are (readGap = time between successive
// availableData calls) and how evenly packets actually departed post-pacing
// (sendGap = time between successive send() calls). Gated so it's inert
// unless explicitly requested.
let debugTiming = ProcessInfo.processInfo.environment["PCMUDPSENDER_DEBUG_TIMING"] == "1"
var lastReadAt: Date?
var readGapMinMs = Double.greatestFiniteMagnitude, readGapMaxMs = 0.0, readGapSumMs = 0.0, readGapCount = 0
var lastSendAt: Date?
var sendGapMinMs = Double.greatestFiniteMagnitude, sendGapMaxMs = 0.0, sendGapSumMs = 0.0, sendGapCount = 0
var lastReportAt = Date()

func reportTimingIfDue() {
    guard debugTiming, Date().timeIntervalSince(lastReportAt) >= 2.0 else { return }
    if readGapCount > 0 {
        note(String(format: "TIMING readGap(ms) n=%d min=%.1f avg=%.1f max=%.1f | sendGap(ms) n=%d min=%.1f avg=%.1f max=%.1f",
                    readGapCount, readGapMinMs, readGapSumMs / Double(readGapCount), readGapMaxMs,
                    sendGapCount, sendGapCount > 0 ? sendGapMinMs : 0, sendGapCount > 0 ? sendGapSumMs / Double(max(sendGapCount, 1)) : 0, sendGapMaxMs))
    }
    readGapMinMs = .greatestFiniteMagnitude; readGapMaxMs = 0; readGapSumMs = 0; readGapCount = 0
    sendGapMinMs = .greatestFiniteMagnitude; sendGapMaxMs = 0; sendGapSumMs = 0; sendGapCount = 0
    lastReportAt = Date()
}

func sendAll(_ bytes: [UInt8]) -> Bool {
    guard !bytes.isEmpty else { return false }
    return bytes.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var offset = 0
        while offset < bytes.count {
            let length = min(maxDatagram, bytes.count - offset)
            // Muted: still walk through every packet's pacing/bookkeeping below
            // (so stdin keeps draining at the real-time rate and sox/shairport-sync
            // upstream never blocks), just skip the actual network send.
            if relayEnabled.get(), send(socketFD, base + offset, length, 0) < 0 {
                note("send() failed after \(totalBytes) bytes: \(String(cString: strerror(errno)))")
                return true
            }
            if debugTiming {
                let now = Date()
                if let last = lastSendAt {
                    let gapMs = now.timeIntervalSince(last) * 1000
                    sendGapMinMs = min(sendGapMinMs, gapMs); sendGapMaxMs = max(sendGapMaxMs, gapMs)
                    sendGapSumMs += gapMs; sendGapCount += 1
                }
                lastSendAt = now
            }
            offset += length
            totalBytes += length
            // Pace this packet's departure to its real-time duration rather
            // than sending it back-to-back with the rest of a burst — the
            // same self-clocking technique PCMPrefix uses for clip playback.
            // If we're already behind schedule (upstream briefly stalled),
            // `delay` is ≤0 and we send the next packet immediately instead
            // of adding artificial latency on top of a real gap.
            deadline.addTimeInterval(Double(length) / bytesPerSecond)
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
        return false
    }
}

while !sawEOF {
    // Each availableData call hands back an autoreleased NSData. This loop runs
    // no run loop, so the thread's pool is never drained — without an explicit
    // autoreleasepool every chunk read since startup stays alive, which leaked
    // many GB over an overnight run. Scope each iteration's temporaries.
    let failed: Bool = autoreleasepool {
        let chunk = input.availableData
        if chunk.isEmpty { sawEOF = true; return false } // EOF: upstream closed.

        if debugTiming {
            let now = Date()
            if let last = lastReadAt {
                let gapMs = now.timeIntervalSince(last) * 1000
                readGapMinMs = min(readGapMinMs, gapMs); readGapMaxMs = max(readGapMaxMs, gapMs)
                readGapSumMs += gapMs; readGapCount += 1
            }
            lastReadAt = now
        }

        var buffer = carry
        buffer.append(contentsOf: chunk)
        let whole = buffer.count - (buffer.count % frameBytes)
        carry = Array(buffer[whole...])          // 0…frameBytes−1 leftover bytes
        return sendAll(Array(buffer[..<whole]))
    }
    if failed { exit(1) }
    reportTimingIfDue()
}

// Flush any straggler bytes so the byte stream stays complete (a genuinely
// frame-misaligned total means the source dropped bytes, not us).
if sendAll(carry) { exit(1) }

note("stdin closed — \(totalBytes) bytes sent; exiting")
close(socketFD)
