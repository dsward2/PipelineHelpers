import Foundation
#if canImport(Darwin)
import Darwin
#endif

// PCMPrefix — plays a short pre-rendered clip, then passes its input straight
// through for the rest of the session.
//
// Contract:
//   • Input  : raw S16LE PCM on stdin at --rate / --channels (default
//              48000 / 2 — the LiveAudioServer contract).
//   • Output : the clip's PCM first, self-paced in real time (a downstream
//              PCMUDPSender has no back-pressure, so this stage meters its own
//              output — same technique as PCMSpeechSynth), then stdin copied
//              through unchanged.
//   • Sits just before PCMUDPSender in a TaskPipelineManager chain, so the
//     listener hears the announcement and then the live audio with no gap.
//
// Usage: PCMPrefix --prefix-file <path> [--during-prefix drop|hold]
//        [--prefix-channels 1|2] [--rate <hz>] [--channels <n>]
//        [--exit-with-parent]
//
//   --prefix-file      raw S16LE clip to play first, at --rate. Missing, empty
//                      or unreadable → this stage is a plain passthrough
//                      (logged, not fatal), so a failed render never breaks
//                      the pipeline.
//   --during-prefix    what to do with stdin while the clip plays:
//                        drop  discard it (default) — for a live source
//                              (rtl_fm, device capture) that must not block.
//                        hold  leave it alone — upstream back-pressure pauses
//                              a self-pacing file player, which then resumes
//                              from where it stopped once passthrough begins.
//   --prefix-channels  channel count of --prefix-file (default 2). 1 is
//                      up-mixed to --channels by sample duplication. No
//                      resampling is done: --prefix-file must already be at
//                      --rate.
//   --rate/--channels  stream format, used for pacing math (default 48000 / 2).
//   --exit-with-parent terminate if the parent process goes away.

let log = FileHandle.standardError
func note(_ message: String) {
    log.write(Data("PCMPrefix: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

// MARK: Argument parsing

enum DuringPrefix: String {
    case drop
    case hold
}

struct Options {
    var prefixFile: String?
    var during: DuringPrefix = .drop
    var prefixChannels = 2
    var rate = 48_000
    var channels = 2
    var exitWithParent = false
}

func parseArguments() -> Options {
    var o = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--prefix-file":
            i += 1
            guard i < args.count else { fail("Missing value for --prefix-file") }
            o.prefixFile = args[i]
        case "--during-prefix":
            i += 1
            guard i < args.count, let mode = DuringPrefix(rawValue: args[i]) else {
                fail("Missing or invalid value for --during-prefix (expected 'drop' or 'hold')")
            }
            o.during = mode
        case "--prefix-channels":
            i += 1
            guard i < args.count, let c = Int(args[i]), c == 1 || c == 2 else {
                fail("Missing or invalid value for --prefix-channels (expected 1 or 2)")
            }
            o.prefixChannels = c
        case "--rate":
            i += 1
            guard i < args.count, let r = Int(args[i]), r >= 8_000, r <= 192_000 else {
                fail("Missing or invalid value for --rate")
            }
            o.rate = r
        case "--channels":
            i += 1
            guard i < args.count, let c = Int(args[i]), c >= 1, c <= 8 else {
                fail("Missing or invalid value for --channels")
            }
            o.channels = c
        case "--exit-with-parent":
            o.exitWithParent = true
        default:
            if args[i].hasPrefix("—") || args[i].hasPrefix("–") {
                fail("Unknown argument '\(args[i])' — this starts with an em/en dash, not '--'. "
                     + "Re-type the option with two hyphens (disable smart dashes).")
            }
            fail("Unknown argument '\(args[i])'")
        }
        i += 1
    }
    return o
}

let options = parseArguments()

// MARK: Parent-death watchdog (same pattern as the other pipeline helpers)

if options.exitWithParent {
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

signal(SIGPIPE, SIG_IGN)

// MARK: Load the clip

/// Duplicates every Int16 sample so a mono clip plays on a stereo stream.
func upmixMonoToStereo(_ mono: Data) -> Data {
    let sampleCount = mono.count / MemoryLayout<Int16>.size
    var out = Data(count: sampleCount * 2 * MemoryLayout<Int16>.size)
    mono.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            let s = src.bindMemory(to: Int16.self)
            let d = dst.bindMemory(to: Int16.self)
            for k in 0..<sampleCount {
                d[2 * k] = s[k]
                d[2 * k + 1] = s[k]
            }
        }
    }
    return out
}

var clip = Data()
if let path = options.prefixFile {
    if let data = FileManager.default.contents(atPath: path), !data.isEmpty {
        clip = data
        if options.prefixChannels == 1 && options.channels == 2 {
            clip = upmixMonoToStereo(clip)
        }
    } else {
        note("prefix file '\(path)' is missing or empty — starting passthrough with no announcement")
    }
} else {
    note("no --prefix-file — acting as a plain passthrough")
}

// MARK: Byte I/O helpers

func writeAll(_ base: UnsafeRawPointer, _ count: Int) {
    var offset = 0
    while offset < count {
        let n = write(1, base + offset, count - offset)
        if n < 0 {
            if errno == EINTR { continue }
            note("stdout closed (\(String(cString: strerror(errno)))); exiting")
            exit(0)
        }
        offset += n
    }
}

func setNonBlocking(_ on: Bool) {
    let flags = fcntl(0, F_GETFL, 0)
    guard flags >= 0 else { return }
    _ = fcntl(0, F_SETFL, on ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK))
}

let drainSize = 65_536
let drainBuf = UnsafeMutableRawPointer.allocate(byteCount: drainSize, alignment: 1)

/// Reads and discards whatever is currently readable on stdin (stdin must be
/// non-blocking). Keeps a live source from stalling while the clip plays.
func drainAndDiscard() {
    while true {
        let n = read(0, drainBuf, drainSize)
        if n <= 0 { break }   // 0 = EOF, -1 = EAGAIN/EWOULDBLOCK
    }
}

// MARK: Phase 1 — play the clip, self-paced

if !clip.isEmpty {
    let bytesPerSecond = Double(options.rate * options.channels * MemoryLayout<Int16>.size)
    let chunkSize = 8_192
    var deadline = Date()

    if options.during == .drop { setNonBlocking(true) }

    clip.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < clip.count {
            let length = min(chunkSize, clip.count - offset)
            writeAll(base + offset, length)
            offset += length
            if options.during == .drop { drainAndDiscard() }
            deadline.addTimeInterval(Double(length) / bytesPerSecond)
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
    }

    if options.during == .drop { setNonBlocking(false) }
    note("clip finished (\(clip.count) bytes); switching to passthrough")
}

// MARK: Phase 2 — passthrough until stdin closes

// Belt-and-suspenders: guarantee blocking reads before the passthrough loop.
// Phase 1's drop mode makes stdin non-blocking and restores it, but if that
// restore is ever a no-op the first read here would return EAGAIN — and with
// a short clip the live source (rtl_fm) often hasn't produced a sample yet,
// so that race is real. The loop also treats EAGAIN as "retry", never EOF.
setNonBlocking(false)

let ptSize = 65_536
let ptBuf = UnsafeMutableRawPointer.allocate(byteCount: ptSize, alignment: 1)
var total = 0
while true {
    let n = read(0, ptBuf, ptSize)
    if n < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            // stdin is still non-blocking and upstream has nothing yet
            // (e.g. rtl_fm warming up). Force blocking mode and wait —
            // this is not end-of-stream.
            setNonBlocking(false)
            Thread.sleep(forTimeInterval: 0.005)
            continue
        }
        note("stdin read error (\(String(cString: strerror(errno)))); exiting")
        break
    }
    if n == 0 { break }   // upstream closed
    writeAll(ptBuf, n)
    total += n
}
note("stdin closed — \(total) bytes passed through; exiting")
