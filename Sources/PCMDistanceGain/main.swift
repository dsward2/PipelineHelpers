import Foundation
#if canImport(Darwin)
import Darwin
#endif

// PCMDistanceGain — distance-based loudness falloff stage.
//
// Contract:
//   Input  : raw S16LE PCM, interleaved channels, on stdin
//   Output : the same format with distance attenuation applied, on stdout
//
// Sits upstream of PCMBinauralPanner in the same pipeline — distance and
// direction are independent cues, and most spatial-audio SDKs' binaural
// effects only handle direction, leaving loudness falloff to whatever sits
// next to them. This stage is that neighbor.
//
// Air absorption (the high-frequency rolloff that's part of what makes
// something sound "far" beyond just "quiet") lives in PCMBinauralPanner,
// not here — it briefly lived in this stage, but running the same
// distance-driven lowpass in both chained stages would double-apply it
// rather than compute two distinct things from the same input. This stage
// stays purely a gain curve; send the same `dist` value to both stages'
// control ports to keep loudness and air absorption in sync.
//
// Usage: PCMDistanceGain [--rate <Hz>] [--channels <n>]
//        [--distance <d>] [--reference-distance <d>] [--rolloff <r>]
//        [--min-gain <g>] [--control-port <n>] [--exit-with-parent]
//
//   --rate                sample rate in Hz (default 48000)
//   --channels            channel count (default 2)
//   --distance            initial distance, pad units (default 1.0 — the
//                         pad's outer ring, i.e. unity gain)
//   --reference-distance  distance at/inside which gain is unity (default 1.0)
//   --rolloff             falloff exponent; 1.0 = physical inverse-distance,
//                         lower is gentler (default 0.8)
//   --min-gain            floor so a far source fades, never vanishes
//                         (default 0.05)
//   --control-port        UDP port for live updates (see below)
//   --exit-with-parent    exit if the parent process dies (same watchdog
//                         pattern as the other pipeline helpers)
//
// Control port (UDP, one-line ASCII, e.g. via `nc -u`):
//   dist <value>   set distance (pad units); ramped in over the next
//                  block, same convention as a fader's ramp time
//   dist?          reply to the sender with the current distance and gain

let log = FileHandle.standardError
func note(_ message: String) {
    log.write(Data("PCMDistanceGain: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

// MARK: Argument parsing

struct Options {
    var sampleRate = 48_000.0
    var channels = 2
    var distance = 1.0
    var referenceDistance = 1.0
    var rolloff = 0.8
    var minGain = 0.05
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
        case "--distance":
            i += 1
            guard i < args.count, let d = Double(args[i]), d >= 0 else {
                fail("Missing or invalid value for --distance (expected >= 0)")
            }
            o.distance = d
        case "--reference-distance":
            i += 1
            guard i < args.count, let d = Double(args[i]), d > 0 else {
                fail("Missing or invalid value for --reference-distance (expected > 0)")
            }
            o.referenceDistance = d
        case "--rolloff":
            i += 1
            guard i < args.count, let r = Double(args[i]), r >= 0 else {
                fail("Missing or invalid value for --rolloff (expected >= 0)")
            }
            o.rolloff = r
        case "--min-gain":
            i += 1
            guard i < args.count, let g = Double(args[i]), (0...1).contains(g) else {
                fail("Missing or invalid value for --min-gain (expected 0–1)")
            }
            o.minGain = g
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

// MARK: Distance-attenuation curve
//
// gain = (referenceDistance / max(distance, referenceDistance)) ^ rolloff,
// floored at minGain. Distance at or inside referenceDistance plays at full
// level — the "min distance" convention game-audio middleware (FMOD, Wwise)
// uses so an approaching source doesn't blow up toward infinite gain.

func gain(forDistance distance: Double) -> Double {
    let d = max(distance, options.referenceDistance)
    let raw = pow(options.referenceDistance / d, options.rolloff)
    return max(raw, options.minGain)
}

// `targetDistance` is read from the control thread and the main loop reads
// it back each block; a lock around a plain Double is cheap enough to take
// once per block (not once per sample).
final class DistanceBox {
    private let lock = NSLock()
    private var value: Double
    init(_ initial: Double) { value = initial }
    func set(_ newValue: Double) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Double { lock.lock(); defer { lock.unlock() }; return value }
}

let targetDistance = DistanceBox(options.distance)
var currentGain = gain(forDistance: options.distance)

// MARK: Control port (dist / dist? commands)

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
                case "dist" where words.count == 2:
                    if let value = Double(words[1]), value >= 0 {
                        targetDistance.set(value)
                    } else {
                        note("control: bad value in '\(line)'")
                    }
                case "dist?":
                    let reply = "dist=\(targetDistance.get()) gain=\(currentGain)\n"
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

// MARK: Streaming gain loop
//
// Same shape as FMDeemphasis: read a chunk, mutate its Int16 samples in
// place, write it back out. Gain is ramped linearly across each chunk in
// the frame domain (not the raw sample domain) so a stereo pair never gets
// split across two different gain values mid-frame.

let channels = options.channels
let bytesPerFrame = channels * MemoryLayout<Int16>.size

note("started — \(Int(options.sampleRate)) Hz \(channels) ch, "
     + "distance \(options.distance) (ref \(options.referenceDistance), rolloff \(options.rolloff), floor \(options.minGain)), "
     + "stdin → stdout"
     + (options.controlPort.map { ", control port \($0)" } ?? ""))

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
var totalFrames = 0

var sawEOF = false
while !sawEOF {
    // availableData returns an autoreleased NSData; this loop runs no run
    // loop, so wrap each iteration or every chunk read since startup stays alive.
    autoreleasepool {
        let chunk = input.availableData
        if chunk.isEmpty { sawEOF = true; return }   // EOF: upstream closed.

        var processed = chunk
        let frameCount = processed.count / bytesPerFrame
        guard frameCount > 0 else { return }

        let target = gain(forDistance: targetDistance.get())
        let step = (target - currentGain) / Double(frameCount)

        processed.withUnsafeMutableBytes { rawPtr in
            let samples = rawPtr.bindMemory(to: Int16.self)
            var g = currentGain
            for frame in 0..<frameCount {
                for ch in 0..<channels {
                    let index = frame * channels + ch
                    let scaled = (Double(samples[index]) * g).rounded()
                    samples[index] = Int16(min(max(scaled, -32_768.0), 32_767.0))
                }
                g += step
            }
        }
        currentGain = target
        totalFrames += frameCount

        output.write(processed)
    }
}

note("stdin closed — \(totalFrames) frames processed; exiting")
