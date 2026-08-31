import Foundation
#if canImport(Darwin)
import Darwin
#endif

// PCMJitterBuffer — real-time pacing stage for an audio pipeline.
//
// Contract:
//   • Input  : raw signed 16-bit little-endian interleaved PCM on stdin, at
//     --channels channels and --rate Hz. Upstream may deliver it in bursts
//     (e.g. nrsc5 hands off decoded audio in ~186ms blocks, matching HD
//     Radio's own logical-frame structure, instead of a steady trickle).
//   • Output : the same bytes on stdout, released at a steady real-time pace
//     instead of in whatever burst pattern they arrived in. Sits between a
//     bursty source (nrsc5, or anything else with block-based decode) and
//     the terminal PCMUDPSender stage, so LiveAudioServer's UDP input and
//     everything downstream of it sees a smooth stream.
//
// Trades a fixed --buffer-ms of added latency for absorbing that burstiness.
// If real data ever runs out for longer than the buffer holds, output falls
// behind in real time and catches up once more data arrives — no silence is
// injected here (LiveAudioServer already has its own idle/filler handling
// for genuine upstream stalls).
//
// Usage: PCMJitterBuffer --rate <hz> [--channels <n>] [--buffer-ms <ms>]

let log = FileHandle.standardError
func note(_ message: String) {
    log.write(Data("PCMJitterBuffer: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

// MARK: Argument parsing

func parseArguments() -> (rate: Int, channels: Int, bufferMs: Int) {
    var rate: Int?
    var channels = 2
    var bufferMs = 400
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--rate", "-r":
            i += 1
            guard i < args.count, let value = Int(args[i]), value > 0 else {
                fail("Missing or invalid value for --rate")
            }
            rate = value
        case "--channels", "-c":
            i += 1
            guard i < args.count, let value = Int(args[i]), value > 0 else {
                fail("Missing or invalid value for --channels")
            }
            channels = value
        case "--buffer-ms":
            i += 1
            guard i < args.count, let value = Int(args[i]), value > 0 else {
                fail("Missing or invalid value for --buffer-ms")
            }
            bufferMs = value
        default:
            fail("Unknown argument '\(args[i])'")
        }
        i += 1
    }
    guard let rate else { fail("--rate is required") }
    return (rate, channels, bufferMs)
}

let (rate, channels, bufferMs) = parseArguments()
let bytesPerFrame = channels * 2
let bytesPerSecond = rate * bytesPerFrame
let targetBufferBytes = (bytesPerSecond * bufferMs) / 1000
// Hard ceiling on the queue. The design absorbs bursts by letting output fall
// behind and catch up, so under normal use the queue drains to ~targetBufferBytes.
// But if the average input rate genuinely exceeds --rate (wrong --rate, or a
// source that overproduces), nothing would ever bound it. Past this many bytes
// the oldest audio is dropped rather than grown without limit.
let maxQueuedBytes = max(targetBufferBytes * 4, bytesPerSecond * 3)

note("started — rate=\(rate)Hz channels=\(channels) buffer=\(bufferMs)ms (\(targetBufferBytes) bytes, cap \(maxQueuedBytes))")

// Ignore SIGPIPE at the process level. FileHandle.write(_:) — used below only
// for reading stdin's availableData, not for the stdout writes — is fine, but
// the raw write(2) calls this tool makes to stdout need EPIPE to come back as
// an ordinary errno, not as a signal, so a downstream reader going away (e.g.
// PCMUDPSender exiting) is something we can notice and shut down on cleanly
// instead of being killed outright.
signal(SIGPIPE, SIG_IGN)

// MARK: Shared byte queue between the stdin reader thread and the pacing loop

final class PCMQueue {
    private let condition = NSCondition()
    private var bytes = [UInt8]()
    private var eof = false
    private(set) var droppedBytes = 0

    func append(_ chunk: Data) {
        condition.lock()
        bytes.append(contentsOf: chunk)
        if bytes.count > maxQueuedBytes {
            let overflow = bytes.count - maxQueuedBytes
            bytes.removeFirst(overflow)
            droppedBytes += overflow
        }
        condition.signal()
        condition.unlock()
    }

    func markEOF() {
        condition.lock()
        eof = true
        condition.signal()
        condition.unlock()
    }

    /// Blocks until at least `minBytes` are queued, or EOF is reached.
    func waitUntilBuffered(_ minBytes: Int) {
        condition.lock()
        while bytes.count < minBytes && !eof {
            condition.wait()
        }
        condition.unlock()
    }

    /// Removes and returns up to `maxBytes` currently queued (may be fewer,
    /// including zero).
    func take(upTo maxBytes: Int) -> [UInt8] {
        condition.lock()
        let n = min(maxBytes, bytes.count)
        let result = Array(bytes.prefix(n))
        if n > 0 { bytes.removeFirst(n) }
        condition.unlock()
        return result
    }

    var isEmptyAndEOF: Bool {
        condition.lock()
        defer { condition.unlock() }
        return eof && bytes.isEmpty
    }
}

let queue = PCMQueue()

// MARK: Reader thread — drains stdin exactly as fast as it's available.
// Bursty arrival here is the whole reason this tool exists; the pacing loop
// below is what smooths it out.

let readerThread = Thread {
    let input = FileHandle.standardInput
    var sawEOF = false
    while !sawEOF {
        // availableData returns an autoreleased NSData and this thread runs no
        // run loop; without a pool per iteration every chunk read stays alive.
        autoreleasepool {
            let chunk = input.availableData
            if chunk.isEmpty { sawEOF = true; return }
            queue.append(chunk)
        }
    }
    queue.markEOF()
}
readerThread.start()

// Pre-buffer before releasing any output, so playback doesn't immediately
// underrun while the first burst is still arriving.
queue.waitUntilBuffered(targetBufferBytes)

// MARK: Steady-pace output loop
//
// Every tick, compute how many frame-aligned bytes real elapsed time says
// should have gone out by now, and write that many from the queue. Bursts
// that arrived early just sit in the queue until their scheduled moment;
// a queue that's run dry means we fall behind schedule and catch up as soon
// as more data lands — self-correcting, no drift as long as the average
// input rate matches --rate.

let stdoutFD: Int32 = 1
let tickInterval: TimeInterval = 0.02  // 20ms ticks
let startTime = DispatchTime.now()
var bytesWritten = 0

func elapsedSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
}

/// Writes `bytes` to stdout via the raw write(2) syscall. Unlike
/// FileHandle.write(_:), which raises an uncatchable NSException on I/O
/// failure, this returns false on error so the caller can shut down cleanly
/// instead of crashing — the expected case being EPIPE once the downstream
/// reader (PCMUDPSender) is gone.
func writeToStdout(_ bytes: [UInt8]) -> Bool {
    var offset = 0
    let count = bytes.count
    return bytes.withUnsafeBytes { rawBuffer -> Bool in
        guard let base = rawBuffer.baseAddress else { return true }
        while offset < count {
            let n = write(stdoutFD, base + offset, count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                note("stdout write failed (\(String(cString: strerror(errno)))) — downstream reader is gone, exiting")
                return false
            }
            offset += n
        }
        return true
    }
}

while true {
    let targetBytes = Int(elapsedSeconds() * Double(bytesPerSecond))
    let targetFrameAligned = (targetBytes / bytesPerFrame) * bytesPerFrame
    if targetFrameAligned > bytesWritten {
        let chunk = queue.take(upTo: targetFrameAligned - bytesWritten)
        if !chunk.isEmpty {
            guard writeToStdout(chunk) else { exit(0) }
            bytesWritten += chunk.count
        }
    }
    if queue.isEmptyAndEOF { break }
    Thread.sleep(forTimeInterval: tickInterval)
}

let droppedNote = queue.droppedBytes > 0 ? " (\(queue.droppedBytes) bytes dropped — input outran --rate)" : ""
note("stdin closed — \(bytesWritten) bytes paced through\(droppedNote); exiting")
