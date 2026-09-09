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
let bytesPerFrame = channels * MemoryLayout<Int16>.size
var totalFrames = 0

// `availableData` only lands on a frame boundary when the upstream stage writes
// frame-aligned blocks. A PCMUDPReceiver ahead of us writes each datagram
// payload verbatim, so a read routinely ends 1–3 bytes into a frame. Without a
// carry, `i % channels` then assigns the wrong filter state to each channel
// from that read on, and a trailing odd byte passes through unfiltered. Carry
// the partial frame into the next read.
var carry = Data()

var sawEOF = false
while !sawEOF {
    // availableData returns an autoreleased NSData; this loop runs no run loop,
    // so wrap each iteration or every chunk read since startup stays alive.
    autoreleasepool {
        let chunk = input.availableData
        if chunk.isEmpty { sawEOF = true; return }  // EOF: upstream closed
        carry.append(chunk)

        let frameCount = carry.count / bytesPerFrame
        guard frameCount > 0 else { return }

        // Work on a mutable copy of the whole frames so we can re-interpret
        // bytes as Int16 in place; the partial frame stays in `carry`.
        var processed = Data(carry.prefix(frameCount * bytesPerFrame))
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

        output.write(processed)

        // Drop the consumed frames by rebuilding `carry` from a fresh copy of
        // the sub-frame remainder (0–3 bytes). `Data.removeFirst` only advances
        // the slice's start index — it never releases the consumed prefix's
        // backing allocation, so `append` + `removeFirst` on a long-lived `Data`
        // grows without bound at the input data rate.
        carry = Data(Array(carry.dropFirst(frameCount * bytesPerFrame)))
    }
}

note("stdin closed — \(totalFrames) frames processed; exiting")
