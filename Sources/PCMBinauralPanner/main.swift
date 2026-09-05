import Foundation
#if canImport(Darwin)
import Darwin
#endif

// PCMBinauralPanner — ITD/ILD-based direction stage.
//
// Contract:
//   Input  : raw S16LE PCM, interleaved channels, on stdin (any --channels;
//            channels beyond the first two are ignored, and a stereo input
//            is downmixed to mono before spatializing — same "operates on
//            the normalized stream" contract PCMDistanceGain and
//            PCMTranscriber use)
//   Output : 2-channel (true binaural) S16LE PCM on stdout, always —
//            regardless of input channel count
//
// This is NOT measured-HRTF binaural rendering (that's a real upgrade path —
// see the Steam Audio TODO in SteamAudioSpatializer.swift on the app side).
// It's the older, cheaper technique: interaural time difference (ITD) via a
// fractional delay line, interaural level difference (ILD) via a pan gain,
// and a head-shadow lowpass on the far ear. That trio is what actually
// carries left/right localization for most listeners; a real HRTF's main
// advantage is elevation and front/back cues via pinna spectral notches,
// which this stage does NOT attempt to reproduce — see the elevation note
// below. Sits downstream of PCMDistanceGain in the pipeline: distance and
// direction are independent cues handled by independent stages.
//
// Usage: PCMBinauralPanner [--rate <Hz>] [--channels <n>]
//        [--azimuth <deg>] [--elevation <deg>] [--head-radius <m>]
//        [--ild-depth <0-1>] [--shadow-min-cutoff <Hz>] [--shadow-max-cutoff <Hz>]
//        [--elevation-shelf-db <dB>] [--control-port <n>] [--exit-with-parent]
//
//   --rate                 sample rate in Hz (default 48000)
//   --channels             input channel count (default 2; downmixed to mono)
//   --azimuth              initial azimuth, degrees (default 0 = front,
//                          clockwise-positive: +90 = right, ±180 = rear,
//                          -90 = left — same convention as the Now Playing
//                          pad and PCMDistanceGain's neighboring stage)
//   --elevation            initial elevation, degrees (default 0; -90...90)
//   --head-radius          meters, for the ITD model (default 0.0875,
//                          average adult head)
//   --ild-depth            far-ear level reduction at full pan, 0-1
//                          (default 0.6 — far ear never fully silenced)
//   --shadow-min-cutoff    head-shadow lowpass cutoff at full pan, Hz
//                          (default 1500)
//   --shadow-max-cutoff    head-shadow lowpass cutoff at az=0 (no shadow —
//                          effectively bypassed), Hz (default 18000)
//   --elevation-shelf-db   max high-shelf tilt at ±90° elevation, dB
//                          (default 4.0) — see the elevation note below
//   --control-port         UDP port for live updates (see below)
//   --exit-with-parent     exit if the parent process dies
//
// Control port (UDP, one-line ASCII, e.g. via `nc -u`):
//   az <deg>         set azimuth
//   el <deg>         set elevation
//   pos <az> <el>    set both together
//   pos?             reply with the current azimuth, elevation, and the
//                    derived ITD (ms) and per-ear gain, for debugging
//
// Elevation note: ITD/ILD panning has no physical mechanism for elevation —
// real elevation perception comes from pinna spectral notches that only a
// measured HRTF captures. Rather than silently ignoring `--elevation`
// (leaving the control protocol's promise unmet) or faking precision this
// stage doesn't have, elevation drives a mild, clearly-labeled high-shelf
// tilt (brighter above, duller below) as a placeholder cue. It's a real,
// audible effect, but not a validated elevation cue — don't expect it to
// localize the way azimuth does. Replace this stage's whole approach with a
// measured-HRTF convolution engine when accurate elevation matters.

let log = FileHandle.standardError
func note(_ message: String) {
    log.write(Data("PCMBinauralPanner: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

// MARK: Argument parsing

struct Options {
    var sampleRate = 48_000.0
    var channels = 2
    var azimuth = 0.0
    var elevation = 0.0
    var headRadius = 0.0875
    var ildDepth = 0.6
    var shadowMinCutoff = 1_500.0
    var shadowMaxCutoff = 18_000.0
    var elevationShelfDB = 4.0
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
        case "--azimuth":
            i += 1
            guard i < args.count, let d = Double(args[i]) else {
                fail("Missing or invalid value for --azimuth")
            }
            o.azimuth = d
        case "--elevation":
            i += 1
            guard i < args.count, let d = Double(args[i]), (-90...90).contains(d) else {
                fail("Missing or invalid value for --elevation (expected -90–90)")
            }
            o.elevation = d
        case "--head-radius":
            i += 1
            guard i < args.count, let r = Double(args[i]), r > 0 else {
                fail("Missing or invalid value for --head-radius (expected > 0)")
            }
            o.headRadius = r
        case "--ild-depth":
            i += 1
            guard i < args.count, let d = Double(args[i]), (0...1).contains(d) else {
                fail("Missing or invalid value for --ild-depth (expected 0–1)")
            }
            o.ildDepth = d
        case "--shadow-min-cutoff":
            i += 1
            guard i < args.count, let f = Double(args[i]), f > 0 else {
                fail("Missing or invalid value for --shadow-min-cutoff (expected > 0)")
            }
            o.shadowMinCutoff = f
        case "--shadow-max-cutoff":
            i += 1
            guard i < args.count, let f = Double(args[i]), f > 0 else {
                fail("Missing or invalid value for --shadow-max-cutoff (expected > 0)")
            }
            o.shadowMaxCutoff = f
        case "--elevation-shelf-db":
            i += 1
            guard i < args.count, let d = Double(args[i]), d >= 0 else {
                fail("Missing or invalid value for --elevation-shelf-db (expected >= 0)")
            }
            o.elevationShelfDB = d
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

// MARK: Direction model
//
// Azimuth folds to a front-referenced angle in [0°, 90°] with a sign
// (which side): folding 100° to 80° etc. reflects the real physical fact
// that ITD/ILD magnitude is front/back-symmetric — a source at 100° and one
// at 80° are equidistant from the interaural axis, differing only in front
// vs. back (a cue this stage, lacking pinna filtering, can't distinguish
// anyway). ITD uses Woodworth's spherical-head approximation:
//   ITD(θ) = (headRadius / speedOfSound) · (θ + sin θ), θ in radians, 0...π/2
// which folds smoothly to 0 at both azimuth 0° (front) and 180° (rear), and
// peaks at ±90° (directly left/right) — about 660 µs for an average head,
// matching the commonly cited human max ITD.
private let speedOfSound = 343.0 // m/s, dry air ~20°C

private struct Direction {
    let signedShadow0to1: Double   // magnitude 0...1, sign = which ear is far (+ = left is far, i.e. source on the right)
    let itdSeconds: Double         // signed; positive = right ear leads
    let elevationShelf: Double     // linear gain factor applied to the "high" component, both ears

    init(azimuthDegrees: Double, elevationDegrees: Double, headRadius: Double, elevationShelfDB: Double) {
        var az = azimuthDegrees.truncatingRemainder(dividingBy: 360)
        if az > 180 { az -= 360 }
        if az < -180 { az += 360 }
        let side = az >= 0 ? 1.0 : -1.0
        let absAz = abs(az)
        let foldedDegrees = absAz > 90 ? (180 - absAz) : absAz
        let theta = foldedDegrees * .pi / 180

        signedShadow0to1 = side * (theta / (.pi / 2))
        itdSeconds = side * (headRadius / speedOfSound) * (theta + sin(theta))

        let el = min(max(elevationDegrees, -90), 90)
        let shelfDB = (el / 90) * elevationShelfDB
        elevationShelf = pow(10, shelfDB / 20)
    }
}

/// One-pole lowpass coefficient for cutoff `fc` at sample rate `fs`: same
/// form FMDeemphasis uses (`alpha = exp(-1/(τ·fs))`), just parameterized by
/// cutoff frequency instead of a time constant (`τ = 1/(2π·fc)`).
private func onePoleAlpha(cutoffHz: Double, sampleRate: Double) -> Double {
    exp(-2 * .pi * cutoffHz / sampleRate)
}

// MARK: Live-updatable target (control thread writes, audio thread reads)

final class DirectionBox {
    private let lock = NSLock()
    private var azimuth: Double
    private var elevation: Double
    init(azimuth: Double, elevation: Double) {
        self.azimuth = azimuth
        self.elevation = elevation
    }
    func setAzimuth(_ value: Double) { lock.lock(); azimuth = value; lock.unlock() }
    func setElevation(_ value: Double) { lock.lock(); elevation = value; lock.unlock() }
    func setBoth(_ az: Double, _ el: Double) { lock.lock(); azimuth = az; elevation = el; lock.unlock() }
    func get() -> (az: Double, el: Double) { lock.lock(); defer { lock.unlock() }; return (azimuth, elevation) }
}

let target = DirectionBox(azimuth: options.azimuth, elevation: options.elevation)

// MARK: Control port (az / el / pos / pos? commands)

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
                case "az" where words.count == 2:
                    if let v = Double(words[1]) { target.setAzimuth(v) } else { note("control: bad value in '\(line)'") }
                case "el" where words.count == 2:
                    if let v = Double(words[1]), (-90...90).contains(v) {
                        target.setElevation(v)
                    } else {
                        note("control: bad value in '\(line)'")
                    }
                case "pos" where words.count == 3:
                    if let az = Double(words[1]), let el = Double(words[2]), (-90...90).contains(el) {
                        target.setBoth(az, el)
                    } else {
                        note("control: bad value in '\(line)'")
                    }
                case "pos?":
                    let (az, el) = target.get()
                    let d = Direction(azimuthDegrees: az, elevationDegrees: el,
                                      headRadius: options.headRadius, elevationShelfDB: options.elevationShelfDB)
                    let reply = "az=\(az) el=\(el) itd_ms=\(d.itdSeconds * 1000) shadow=\(d.signedShadow0to1)\n"
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

// MARK: Delay line + filter state (persistent across chunks)
//
// A mono ring buffer holds recent input history; each ear reads it at its
// own fractional delay (linear-interpolated, so the ITD isn't quantized to
// whole samples). `centerDelaySamples` keeps both read offsets comfortably
// positive — max half-ITD at 48kHz for an average head is ~16 samples, so
// 64 is ample headroom, and 256 total ring capacity leaves room to spare.
let ringSize = 256
var ring = [Double](repeating: 0, count: ringSize)
var writeIndex = 0
let centerDelaySamples = 64.0

// Head-shadow lowpass state, one per ear (one-pole, coefficient recomputed
// whenever direction changes — see the per-block recompute below).
var leftShadowState = 0.0
var rightShadowState = 0.0

// Elevation shelf reference lowpass (fixed corner; the "high" component is
// input-minus-this, scaled by the direction's elevationShelf factor). Same
// state shape, applied identically to both ears since elevation isn't a
// left/right cue here.
let elevationShelfCornerHz = 2_500.0
let elevationShelfAlpha = onePoleAlpha(cutoffHz: elevationShelfCornerHz, sampleRate: options.sampleRate)
var leftShelfLPState = 0.0
var rightShelfLPState = 0.0

@inline(__always)
func onePole(_ x: Double, state: inout Double, alpha: Double) -> Double {
    state = (1 - alpha) * x + alpha * state
    return state
}

/// Applies the head-shadow lowpass only when there's actually shadow to
/// apply (`shadowAmount > 0`); otherwise passes `x` through exactly and
/// keeps the filter's state caught up to the input, so there's no
/// coloration on the near/on-axis ear — a one-pole filter at even an
/// 18 kHz "no shadow" cutoff still measurably softens content well above
/// it — and no discontinuity if shadow later ramps up from zero.
@inline(__always)
func shadowFiltered(_ x: Double, state: inout Double, alpha: Double, shadowAmount: Double) -> Double {
    guard shadowAmount > 0 else {
        state = x
        return x
    }
    return onePole(x, state: &state, alpha: alpha)
}

@inline(__always)
func interpolatedRead(_ pos: Double) -> Double {
    var p = pos.truncatingRemainder(dividingBy: Double(ringSize))
    if p < 0 { p += Double(ringSize) }
    let i0 = Int(p)
    let frac = p - Double(i0)
    let i1 = (i0 + 1) % ringSize
    return ring[i0] * (1 - frac) + ring[i1] * frac
}

// MARK: Streaming panning loop

let inputChannels = options.channels
let bytesPerInputFrame = inputChannels * MemoryLayout<Int16>.size

note("started — \(Int(options.sampleRate)) Hz, \(inputChannels) ch in (downmixed) → 2 ch out, "
     + "azimuth \(options.azimuth)° elevation \(options.elevation)° (head radius \(options.headRadius) m), "
     + "stdin → stdout"
     + (options.controlPort.map { ", control port \($0)" } ?? ""))

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
var totalFrames = 0

var sawEOF = false
while !sawEOF {
    autoreleasepool {
        let chunk = input.availableData
        if chunk.isEmpty { sawEOF = true; return }   // EOF: upstream closed.

        let frameCount = chunk.count / bytesPerInputFrame
        guard frameCount > 0 else { return }

        // Recompute direction-derived coefficients once per chunk, not per
        // sample — same "block-rate parameter update" the neighboring
        // PCMDistanceGain stage uses. At typical chunk sizes (a few ms to a
        // few hundred ms) this is inaudible as a step and far cheaper than
        // recomputing filter coefficients every sample.
        let (az, el) = target.get()
        let direction = Direction(azimuthDegrees: az, elevationDegrees: el,
                                  headRadius: options.headRadius, elevationShelfDB: options.elevationShelfDB)
        let halfITDSamples = direction.itdSeconds * options.sampleRate / 2
        let leftDelay = centerDelaySamples + halfITDSamples
        let rightDelay = centerDelaySamples - halfITDSamples

        let leftShadowAmount = max(0, direction.signedShadow0to1)
        let rightShadowAmount = max(0, -direction.signedShadow0to1)
        let leftCutoff = options.shadowMaxCutoff - leftShadowAmount * (options.shadowMaxCutoff - options.shadowMinCutoff)
        let rightCutoff = options.shadowMaxCutoff - rightShadowAmount * (options.shadowMaxCutoff - options.shadowMinCutoff)
        let leftAlpha = onePoleAlpha(cutoffHz: leftCutoff, sampleRate: options.sampleRate)
        let rightAlpha = onePoleAlpha(cutoffHz: rightCutoff, sampleRate: options.sampleRate)
        let leftGain = 1 - options.ildDepth * leftShadowAmount
        let rightGain = 1 - options.ildDepth * rightShadowAmount

        var outData = Data(count: frameCount * 2 * MemoryLayout<Int16>.size) // 2 ch out
        chunk.withUnsafeBytes { rawIn in
            let inSamples = rawIn.bindMemory(to: Int16.self)
            outData.withUnsafeMutableBytes { rawOut in
                let outSamples = rawOut.bindMemory(to: Int16.self)
                for frame in 0..<frameCount {
                    // Downmix this frame's input channels to one mono sample.
                    var mono = 0.0
                    for ch in 0..<inputChannels {
                        mono += Double(inSamples[frame * inputChannels + ch])
                    }
                    mono /= Double(inputChannels)
                    mono /= 32_768.0

                    ring[writeIndex] = mono

                    let leftRaw = interpolatedRead(Double(writeIndex) - leftDelay)
                    let rightRaw = interpolatedRead(Double(writeIndex) - rightDelay)

                    let leftShadowed = shadowFiltered(leftRaw, state: &leftShadowState, alpha: leftAlpha, shadowAmount: leftShadowAmount)
                    let rightShadowed = shadowFiltered(rightRaw, state: &rightShadowState, alpha: rightAlpha, shadowAmount: rightShadowAmount)

                    let leftPanned = leftShadowed * leftGain
                    let rightPanned = rightShadowed * rightGain

                    // Elevation shelf: boost/cut the high component equally
                    // on both ears (see the elevation note in the header).
                    let leftLow = onePole(leftPanned, state: &leftShelfLPState, alpha: elevationShelfAlpha)
                    let rightLow = onePole(rightPanned, state: &rightShelfLPState, alpha: elevationShelfAlpha)
                    let leftFinal = leftLow + direction.elevationShelf * (leftPanned - leftLow)
                    let rightFinal = rightLow + direction.elevationShelf * (rightPanned - rightLow)

                    let leftScaled = (leftFinal * 32_767.0).rounded()
                    let rightScaled = (rightFinal * 32_767.0).rounded()
                    outSamples[frame * 2] = Int16(min(max(leftScaled, -32_768.0), 32_767.0))
                    outSamples[frame * 2 + 1] = Int16(min(max(rightScaled, -32_768.0), 32_767.0))

                    writeIndex = (writeIndex + 1) % ringSize
                }
            }
        }

        totalFrames += frameCount
        output.write(outData)
    }
}

note("stdin closed — \(totalFrames) frames processed; exiting")
