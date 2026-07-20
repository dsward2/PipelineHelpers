import Foundation

// FMDeemphasis — first-order IIR FM de-emphasis filter.
//
// Contract (shared by every pipeline unit):
//   Input  : raw S16LE PCM, interleaved channels, on stdin
//   Output : the same format with de-emphasis applied, on stdout
//
// Usage: FMDeemphasis [--rate <Hz>] [--channels <n>] [--tau <µs>]
//   --rate      sample rate in Hz (default: 48000)
//   --channels  1 or 2 (default: 2)
//   --tau       de-emphasis time constant in microseconds (default: 75.0, U.S.)
//               Use 50.0 for the European/ITU standard.
//
// Filter: y[n] = (1 - α)·x[n] + α·y[n-1]   where α = exp(-1 / (τ · fs))
// This is a bilinear-transform first-order IIR lowpass (RC network model)
// running in floating point to avoid the integer-division rounding errors in
// rtl_fm's built-in implementation.  Running at 48 kHz after sox resampling
// also keeps the filter away from the FM pilot tone and stereo subcarrier.

let log = FileHandle.standardError
func note(_ msg: String) { log.write(Data("FMDeemphasis: \(msg)\n".utf8)) }

// MARK: - Argument parsing

var sampleRate = 48_000.0
var channels = 2
var tauMicroseconds = 75.0

var argIdx = 1
let argv = CommandLine.arguments
while argIdx < argv.count {
    switch argv[argIdx] {
    case "--rate":
        argIdx += 1
        if argIdx < argv.count, let v = Double(argv[argIdx]) { sampleRate = v }
    case "--channels":
        argIdx += 1
        if argIdx < argv.count, let v = Int(argv[argIdx]) { channels = v }
    case "--tau":
        argIdx += 1
        if argIdx < argv.count, let v = Double(argv[argIdx]) { tauMicroseconds = v }
    default:
        note("unknown argument: \(argv[argIdx])")
    }
    argIdx += 1
}

// MARK: - Filter coefficients

let tau = tauMicroseconds * 1e-6
let alpha = exp(-1.0 / (tau * sampleRate))
let gain  = 1.0 - alpha   // unity DC gain

note("started — \(Int(sampleRate)) Hz / \(channels) ch / τ=\(tauMicroseconds) µs / α=\(String(format: "%.6f", alpha))")

// MARK: - Streaming filter loop

var state = [Double](repeating: 0.0, count: channels)
let input  = FileHandle.standardInput
let output = FileHandle.standardOutput
var totalFrames = 0

while true {
    let chunk = input.availableData
    if chunk.isEmpty { break }  // EOF: upstream closed

    // Work on a mutable copy so we can re-interpret bytes as Int16 in place.
    var processed = chunk
    processed.withUnsafeMutableBytes { rawPtr in
        let samples = rawPtr.bindMemory(to: Int16.self)
        for i in 0..<samples.count {
            let ch = i % channels
            let x = Double(samples[i])
            state[ch] = gain * x + alpha * state[ch]
            // Clamp before converting; filter output should stay in range but
            // guard against floating-point edge cases at the Int16 boundary.
            let clamped = max(-32_768.0, min(32_767.0, state[ch]))
            samples[i] = Int16(clamped.rounded())
        }
        totalFrames += samples.count / channels
    }

    do {
        try output.write(contentsOf: processed)
    } catch {
        note("write failed: \(error)")
        exit(1)
    }
}

note("stdin closed — \(totalFrames) frames processed; exiting")
