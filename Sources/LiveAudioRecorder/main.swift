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
var totalBytes = 0

note("started — \(sampleRate) Hz / \(channels) ch")

while true {
    let chunk = input.availableData
    if chunk.isEmpty { break } // EOF: upstream closed.
    output.write(chunk)
    totalBytes += chunk.count

    chunk.withUnsafeBytes { rawPtr in
        let samples = rawPtr.bindMemory(to: Int16.self)
        mp3Encoder?.encode(samples: samples)
        aacEncoder?.encode(samples: samples)
    }
}

mp3Encoder?.stop()
aacEncoder?.stop()
try? mp3File?.close()
try? aacFile?.close()

note("stdin closed — \(totalBytes) bytes passed through; exiting")
