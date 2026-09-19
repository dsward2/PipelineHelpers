import AVFoundation
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// PCMDelay — adjustable time-delay stage.
//
// Contract:
//   Input  : raw S16LE PCM, interleaved channels, on stdin
//   Output : the same format, delayed by the current delay setting, on stdout
//
// Motivating use: line a radio play-by-play call up with a TV picture that
// lags the radio (streaming TV commonly runs 5–60 s behind the air), by
// delaying the radio audio until the two agree. Delay is adjustable while the
// stream runs, so a UI slider can nudge it until the announcers' words match
// the pictures.
//
// How it works: a circular buffer of `--max-delay` seconds. Every input frame
// is written at the head; the frame read out is the one written `delay`
// frames ago. Output is emitted frame-for-frame with input, so the stage never
// stalls downstream and never needs a clock of its own — but that also means
// the delay is counted in *samples*, so the upstream must already be
// real-time paced (rtl_fm, AudioInputCapture, PCMUDPReceiver all are). Put a
// PCMJitterBuffer ahead of a bursty source (nrsc5) or the delay will be
// measured in whatever burst timing it delivers.
//
// The initial `--delay` is realised as leading silence, so a stream started
// with a delay begins with that much silence and then plays the live audio.
//
// Changing the delay while running never clicks and never repeats audio:
//   • Longer: fade out, hold the read position (silence) while the buffer
//     fills by the extra amount, then fade back in where playback left off.
//     The listener hears a brief pause; nothing is lost or replayed.
//   • Shorter: fade out, skip ahead by the difference, fade back in. The
//     skipped audio is dropped — the stream is being brought closer to live.
// Both use the same `--fade-ms` ramp (default 30 ms). If the setting moves
// again mid-change (a slider drag), the stage simply heads for the latest
// value; intermediate values are coalesced.
//
// Usage: PCMDelay [--rate <Hz>] [--channels <n>] [--delay <seconds>]
//        [--max-delay <seconds>] [--fade-ms <ms>] [--countdown <mode>]
//        [--countdown-voice <id-or-language>] [--control-port <n>]
//        [--exit-with-parent]
//
//   --rate           sample rate in Hz (default 48000)
//   --channels       channel count (default 2)
//   --delay          initial delay in seconds (default 0)
//   --max-delay      largest delay the stage will accept, seconds (default
//                    60, up to 600). Sets the buffer's capacity, at ~188 KiB
//                    per second of 48 kHz stereo S16LE (5 min ≈ 58 MB). The
//                    memory is committed lazily as audio fills the buffer, not
//                    up front, so a stage with a large maximum costs nothing
//                    until the stream has actually run that long.
//   --fade-ms        ramp length used whenever the delay changes (default 30)
//   --countdown      cues mixed into the initial `--delay` silence, counted
//                    down to the moment live audio starts: none (default),
//                    beeps (one per second), speech (spoken countdown), or
//                    both. See Countdown.swift for the schedule. Cancelled if
//                    the delay is changed during the countdown.
//   --countdown-voice  AVSpeechSynthesisVoice identifier or BCP-47 language
//                    for the spoken countdown (default: the system voice)
//   --control-port   UDP port (loopback) for live updates (see below)
//   --exit-with-parent  exit if the parent process dies (same watchdog
//                    pattern as the other pipeline helpers)
//
// Control port (UDP, one-line ASCII, e.g. via `nc -u`):
//   delay <seconds>   set the target delay; clamped to 0…--max-delay
//   delay?            reply to the sender with the target, the delay actually
//                     being applied right now, and the maximum

let log = FileHandle.standardError
func note(_ message: String) {
    log.write(Data("PCMDelay: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

// MARK: Argument parsing

struct Options {
    var sampleRate = 48_000.0
    var channels = 2
    var delay = 0.0
    var maxDelay = 60.0
    var fadeMs = 30.0
    var countdown = CountdownMode.none
    var countdownVoice: String?
    var controlPort: UInt16?
    var exitWithParent = false
}

func parseArguments() -> Options {
    var o = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--rate":
            i += 1
            guard i < args.count, let rate = Double(args[i]), rate >= 8_000, rate <= 192_000 else {
                fail("Missing or invalid value for --rate (expected 8000–192000)")
            }
            o.sampleRate = rate
        case "--channels":
            i += 1
            guard i < args.count, let channels = Int(args[i]), (1...8).contains(channels) else {
                fail("Missing or invalid value for --channels (expected 1–8)")
            }
            o.channels = channels
        case "--delay":
            i += 1
            guard i < args.count, let d = Double(args[i]), d >= 0 else {
                fail("Missing or invalid value for --delay (expected >= 0 seconds)")
            }
            o.delay = d
        case "--max-delay":
            i += 1
            guard i < args.count, let d = Double(args[i]), d > 0, d <= 600 else {
                fail("Missing or invalid value for --max-delay (expected 0–600 seconds)")
            }
            o.maxDelay = d
        case "--fade-ms":
            i += 1
            guard i < args.count, let ms = Double(args[i]), ms >= 1, ms <= 1_000 else {
                fail("Missing or invalid value for --fade-ms (expected 1–1000)")
            }
            o.fadeMs = ms
        case "--countdown":
            i += 1
            guard i < args.count, let mode = CountdownMode(rawValue: args[i]) else {
                fail("Missing or invalid value for --countdown (expected none, beeps, speech or both)")
            }
            o.countdown = mode
        case "--countdown-voice":
            i += 1
            guard i < args.count else { fail("Missing value for --countdown-voice") }
            o.countdownVoice = args[i]
        case "--control-port":
            i += 1
            guard i < args.count, let port = UInt16(args[i]), port > 0 else {
                fail("Missing or invalid value for --control-port")
            }
            o.controlPort = port
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
    if o.delay > o.maxDelay {
        fail("--delay \(o.delay) exceeds --max-delay \(o.maxDelay)")
    }
    return o
}

let options = parseArguments()

// MARK: Parent-death watchdog (same pattern as the other pipeline helpers)

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

if options.exitWithParent {
    startParentDeathWatchdog()
}

// MARK: Shared state between the control thread and the audio loop
//
// Both values are read/written across threads once per block, so a lock
// around a plain Double is cheap enough (not taken per sample).

final class SecondsBox {
    private let lock = NSLock()
    private var value: Double
    init(_ initial: Double) { value = initial }
    func set(_ newValue: Double) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Double { lock.lock(); defer { lock.unlock() }; return value }
}

let channels = options.channels
let bytesPerFrame = channels * MemoryLayout<Int16>.size
let sampleRate = options.sampleRate
let maxDelayFrames = Int((options.maxDelay * sampleRate).rounded())

func clampedDelaySeconds(_ seconds: Double) -> Double {
    min(max(seconds, 0), options.maxDelay)
}

let targetDelaySeconds = SecondsBox(clampedDelaySeconds(options.delay))
let appliedDelaySeconds = SecondsBox(clampedDelaySeconds(options.delay))

// MARK: Control port (delay / delay? commands)

func startControlListener(port: UInt16) {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { fail("socket() for control failed: \(String(cString: strerror(errno)))") }
    var reuse: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
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
                case "delay" where words.count == 2:
                    if let value = Double(words[1]), value.isFinite, value >= 0 {
                        targetDelaySeconds.set(clampedDelaySeconds(value))
                    } else {
                        note("control: bad value in '\(line)'")
                    }
                case "delay?":
                    let reply = "delay=\(targetDelaySeconds.get()) applied=\(appliedDelaySeconds.get()) max=\(options.maxDelay)\n"
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

if let controlPort = options.controlPort {
    startControlListener(port: controlPort)
}

// MARK: Delay line
//
// `written` and `read` are absolute frame counters; a frame lives at
// `counter % capacity`. The delay in force is `written - read` measured
// before the current frame is written, so delay 0 reads back the frame just
// written. Capacity is maxDelayFrames + 2 so that a full-length delay never
// lets the write head overwrite the frame the read head is about to return.

let capacity = maxDelayFrames + 2
// calloc, not allocate + initialize: a large calloc comes back as untouched
// zero-fill-on-demand pages, so resident memory grows with the audio actually
// written (up to the full capacity) rather than being committed at launch —
// and reading a never-written slot (the initial-delay silence) still yields 0.
guard let rawRing = calloc(capacity * channels, MemoryLayout<Int16>.size) else {
    fail("could not allocate \(capacity * bytesPerFrame / 1024) KB delay buffer")
}
let ring = rawRing.bindMemory(to: Int16.self, capacity: capacity * channels)

// Start `initialDelayFrames` frames "ahead" of the read head: the buffer is
// already zero, so those frames play as leading silence.
var written = Int((clampedDelaySeconds(options.delay) * sampleRate).rounded())
var read = 0

// MARK: Countdown over the initial silence
//
// `silentUntil` is the read index at which the prefilled silence ends (live
// audio starts); 0 means there is no countdown (or it was cancelled).

var silentUntil = 0
var countdownMixer: CountdownMixer?
var renderCountdownSpeech: (() -> Void)?
let rateInt = Int(sampleRate.rounded())
if options.countdown != .none, written >= rateInt {
    let totalSeconds = written / rateInt
    var bank: CountdownSpeechBank?
    if options.countdown.speech {
        var voice: AVSpeechSynthesisVoice?
        if let spec = options.countdownVoice {
            voice = AVSpeechSynthesisVoice(identifier: spec) ?? AVSpeechSynthesisVoice(language: spec)
            if voice == nil { note("countdown: unknown voice '\(spec)'; using the system voice") }
        }
        let newBank = CountdownSpeechBank()
        bank = newBank
        // Rendered on the main thread once the audio thread is running (below).
        renderCountdownSpeech = {
            newBank.renderAll(phrases: CountdownPhrases.all(total: totalSeconds), voice: voice,
                              sampleRate: sampleRate, log: { note($0) })
        }
    }
    countdownMixer = CountdownMixer(rate: rateInt, totalSeconds: totalSeconds,
                                    mode: options.countdown, bank: bank)
    silentUntil = written
}

// Envelope on the read side. `muted` means fully faded out and adjusting the
// delay (holding the read head to lengthen it, or skipping it to shorten).
let fadeFrames = max(1, Int((options.fadeMs / 1_000 * sampleRate).rounded()))
let fadeStep = 1.0 / Double(fadeFrames)
var gain = 1.0
var muted = false

func targetDelayFrames() -> Int {
    min(max(Int((targetDelaySeconds.get() * sampleRate).rounded()), 0), maxDelayFrames)
}

note("started — \(Int(sampleRate)) Hz \(channels) ch, delay \(clampedDelaySeconds(options.delay)) s "
     + "(countdown \(options.countdown.rawValue), max \(options.maxDelay) s, up to \(capacity * bytesPerFrame / 1024) KB buffer, fade \(options.fadeMs) ms), "
     + "stdin → stdout"
     + (options.controlPort.map { ", control port \($0)" } ?? ""))

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
var totalFrames = 0

// Same partial-frame carry as the other stdin-loop helpers: a PCMUDPReceiver
// upstream writes datagram payloads verbatim, so a read routinely ends 1–3
// bytes into a frame. Rebuilt from a fresh copy each pass — never
// `removeFirst` on a long-lived Data (see the unbounded-growth note in
// PCMDistanceGain).
var carry = Data()

// The stdin loop runs on its own thread so the main thread stays free to run
// its event loop: AVSpeechSynthesizer delivers its callbacks on the main
// thread, so the countdown's speech can't be rendered while main is blocked
// reading stdin (see Countdown.swift). Every top-level variable the loop uses
// is touched only from this thread once it starts.
let audioThread = Thread {
    var sawEOF = false
    while !sawEOF {
        autoreleasepool {
            let chunk = input.availableData
            if chunk.isEmpty { sawEOF = true; return }   // EOF: upstream closed.
            carry.append(chunk)

            let frameCount = carry.count / bytesPerFrame
            guard frameCount > 0 else { return }
            var processed = Data(carry.prefix(frameCount * bytesPerFrame))

            let target = targetDelayFrames()

            processed.withUnsafeMutableBytes { rawPtr in
                let samples = rawPtr.bindMemory(to: Int16.self)
                for frame in 0..<frameCount {
                    let base = frame * channels
                    let delayNow = written - read

                    // Write this frame at the head.
                    let writeBase = (written % capacity) * channels
                    for ch in 0..<channels { ring[writeBase + ch] = samples[base + ch] }
                    written += 1

                    if muted {
                        if delayNow < target {
                            // Lengthening: hold the read head so the buffer fills.
                            for ch in 0..<channels { samples[base + ch] = 0 }
                            continue
                        }
                        if delayNow > target {
                            // Shortening: skip ahead by the excess, once.
                            read += delayNow - target
                        }
                        // Delay now matches: start ramping back in from silence.
                        muted = false
                        gain = fadeStep
                    } else if delayNow != target {
                        // Delay needs to change: fade out first. Any countdown to
                        // the end of the initial silence no longer means anything.
                        if silentUntil != 0 { silentUntil = 0; countdownMixer?.cancel() }
                        gain -= fadeStep
                        if gain <= 0 {
                            gain = 0
                            muted = true
                        }
                    } else if gain < 1 {
                        gain = min(1, gain + fadeStep)
                    }

                    if muted {
                        for ch in 0..<channels { samples[base + ch] = 0 }
                        continue
                    }

                    let readBase = (read % capacity) * channels
                    let cue = countdownMixer?.overlay(remainingFrames: silentUntil - read) ?? 0
                    for ch in 0..<channels {
                        let scaled = (Double(ring[readBase + ch]) * gain).rounded() + Double(cue)
                        samples[base + ch] = Int16(min(max(scaled, -32_768.0), 32_767.0))
                    }
                    read += 1
                }
            }
            appliedDelaySeconds.set(Double(written - read) / sampleRate)
            totalFrames += frameCount

            output.write(processed)

            carry = Data(Array(carry.dropFirst(frameCount * bytesPerFrame)))
        }
    }

    note("stdin closed — \(totalFrames) frames processed; exiting")
    exit(0)
}
audioThread.name = "PCMDelay audio"
audioThread.qualityOfService = .userInteractive
audioThread.start()
// Main thread: render the spoken countdown (which needs main to be free — see
// CountdownSpeechBank.renderAll), then idle; the audio thread exits the process.
renderCountdownSpeech?()
dispatchMain()
