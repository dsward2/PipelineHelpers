import Foundation
import AudioEncoders

// LiveAudioRecorder — MP3/AAC file recording as its own pipeline stage.
//
// Contract (shared by every pipeline unit):
//   Input  : raw S16LE PCM, interleaved channels, on stdin
//   Output : the same PCM, unmodified, on stdout
//
// This stage is a lossless tap, not a filter: it copies stdin to stdout
// unchanged and encodes a tapped copy to MP3 and/or AAC files on the side.
// That means it can sit anywhere in a TaskPipelineManager chain — before or
// after LiveAudioServer in AntennaHead, or standalone in ControlBooth, where
// several instances can run concurrently against different sources (multiple
// RTL-SDR devices, UDP feeds, AirPlay receivers, etc.).
//
// Usage: LiveAudioRecorder [--mp3 <path>] [--aac <path>] [--rate <Hz>]
//                           [--channels <n>] [--mp3-bitrate <kbps>]
//                           [--aac-bitrate <bps>] [--verbose]
//
// At least one of --mp3 / --aac is required. Both may be given at once to
// write two files from a single PCM stream in one pass.

let log = FileHandle.standardError
func note(_ msg: String) { log.write(Data("LiveAudioRecorder: \(msg)\n".utf8)) }

// MARK: - Argument parsing

var mp3Path: String?
var aacPath: String?
var sampleRate = 48_000
var channels = 2
var mp3Bitrate = 128
var aacBitrate = 128_000
var verbose = false

var argIdx = 1
let argv = CommandLine.arguments
while argIdx < argv.count {
    switch argv[argIdx] {
    case "--mp3":
        argIdx += 1
        if argIdx < argv.count { mp3Path = argv[argIdx] }
    case "--aac":
        argIdx += 1
        if argIdx < argv.count { aacPath = argv[argIdx] }
    case "--rate":
        argIdx += 1
        if argIdx < argv.count, let v = Int(argv[argIdx]) { sampleRate = v }
    case "--channels":
        argIdx += 1
        if argIdx < argv.count, let v = Int(argv[argIdx]) { channels = v }
    case "--mp3-bitrate":
        argIdx += 1
        if argIdx < argv.count, let v = Int(argv[argIdx]) { mp3Bitrate = v }
    case "--aac-bitrate":
        argIdx += 1
        if argIdx < argv.count, let v = Int(argv[argIdx]) { aacBitrate = v }
    case "--verbose":
        verbose = true
    default:
        note("unknown argument: \(argv[argIdx])")
    }
    argIdx += 1
}

guard mp3Path != nil || aacPath != nil else {
    note("nothing to record — pass --mp3 <path> and/or --aac <path> (stdin still passes through to stdout)")
    exit(1)
}

let config = AudioEncoderConfig(sampleRate: sampleRate, channels: channels,
                                 mp3Bitrate: mp3Bitrate, aacBitrate: aacBitrate,
                                 verbose: verbose)

// MARK: - Output files

func openForWriting(_ path: String) -> FileHandle? {
    let resolved = (path as NSString).expandingTildeInPath
    guard FileManager.default.createFile(atPath: resolved, contents: nil) else {
        note("cannot create file: \(resolved)")
        return nil
    }
    return FileHandle(forWritingAtPath: resolved)
}

var mp3File: FileHandle?
var mp3Encoder: MP3Encoder?
if let path = mp3Path, let handle = openForWriting(path) {
    mp3File = handle
    let encoder = MP3Encoder(config: config) { data in handle.write(data) }
    do {
        try encoder.start()
        mp3Encoder = encoder
        note("recording MP3 → \(path)")
    } catch {
        note("MP3 encoder failed to start: \(error)")
    }
}

var aacFile: FileHandle?
var aacEncoder: AACEncoder?
if let path = aacPath, let handle = openForWriting(path) {
    aacFile = handle
    let encoder = AACEncoder(config: config) { data in handle.write(data) }
    do {
        try encoder.start()
        aacEncoder = encoder
        note("recording AAC → \(path)")
    } catch {
        note("AAC encoder failed to start: \(error)")
    }
}

// MARK: - Passthrough + tee loop

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let bytesPerFrame = channels * MemoryLayout<Int16>.size
var totalBytes = 0

note("started — \(sampleRate) Hz / \(channels) ch")

// The stdout passthrough is byte-exact and must stay immediate, but the
// encoders bind the chunk as `Int16` and expect whole interleaved frames.
// `availableData` ends mid-frame whenever the upstream stage writes
// non-frame-aligned blocks (e.g. a PCMUDPReceiver forwarding datagram
// payloads), which would drop the odd trailing byte from the encoder feed
// only and drift the recorded file's channels. Feed the encoders from a
// frame-aligned carry instead.
var encoderCarry = Data()

var sawEOF = false
while !sawEOF {
    // availableData returns an autoreleased NSData; this loop runs no run loop,
    // so wrap each iteration or every chunk read since startup stays alive.
    autoreleasepool {
        let chunk = input.availableData
        if chunk.isEmpty { sawEOF = true; return } // EOF: upstream closed.
        output.write(chunk)
        totalBytes += chunk.count

        encoderCarry.append(chunk)
        let wholeBytes = (encoderCarry.count / bytesPerFrame) * bytesPerFrame
        guard wholeBytes > 0 else { return }
        let block = Data(encoderCarry.prefix(wholeBytes))
        block.withUnsafeBytes { rawPtr in
            let samples = rawPtr.bindMemory(to: Int16.self)
            mp3Encoder?.encode(samples: samples)
            aacEncoder?.encode(samples: samples)
        }
        // Drop the consumed bytes by rebuilding `encoderCarry` from a fresh copy
        // of the sub-frame remainder (0–3 bytes). `Data.removeFirst` only
        // advances the slice's start index — it never releases the consumed
        // prefix's backing allocation, so `append` + `removeFirst` on a
        // long-lived `Data` grows without bound at the input data rate.
        encoderCarry = Data(Array(encoderCarry.dropFirst(wholeBytes)))
    }
}

mp3Encoder?.stop()
aacEncoder?.stop()
try? mp3File?.close()
try? aacFile?.close()

note("stdin closed — \(totalBytes) bytes passed through; exiting")
