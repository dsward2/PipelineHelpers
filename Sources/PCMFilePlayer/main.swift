import AVFoundation
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// PCMFilePlayer — AAC/MP3 (or any AVAudioFile-readable) file source stage of
// an AntennaHead audio pipeline.
//
// Contract:
//   • Input  : one or more audio files (AAC/M4A, MP3, WAV, CAF, …) — given as
//     literal --file paths and/or a --playlist text file (one path per line;
//     blank lines and lines starting with '#' are ignored). Every track is
//     fully decoded into memory up front (same cache-then-play approach as
//     PCMSpeechSynth, which renders its whole utterance before looping it),
//     so this isn't meant for hours-long files.
//   • Output : S16LE PCM on stdout at --rate/--channels, PACED IN REAL TIME.
//     As a source stage there is no radio clocking the pipeline and UDP sinks
//     have no backpressure, so this helper meters its own output.
//   • Sits at the START of a TaskPipelineManager chain; a downstream sox
//     stage normalizes rate/channels to the 48 kHz / 2 ch LAS contract.
//
// Usage: PCMFilePlayer (--file <path>)... [--playlist <path>]
//        [--rate <hz>] [--channels <n>] [--gap <seconds>] [--repeat]
//        [--exit-with-parent]
//
//   --file       one track; repeatable, played in the order given
//   --playlist   a text file listing one path per line (blank lines and '#'
//                comments ignored); combines with --file entries in the
//                order the flags appear on the command line
//   --rate       output sample rate in Hz (default 48000)
//   --channels   output channel count (default 2)
//   --gap        seconds of silence between tracks, and between the last
//                track and the first when --repeat loops back (default 0.0)
//   --repeat     loop the whole playlist continuously

let log = FileHandle.standardError
func note(_ message: String) {
    log.write(Data("PCMFilePlayer: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

// MARK: Argument parsing

struct Options {
    var tracks: [String] = []
    var sampleRate = 48_000.0
    var channels: UInt32 = 2
    var gapSeconds = 0.0
    var repeatForever = false
    var exitWithParent = false
}

func loadPlaylist(_ path: String) -> [String] {
    let resolved = (path as NSString).expandingTildeInPath
    guard let contents = try? String(contentsOfFile: resolved, encoding: .utf8) else {
        fail("could not read playlist '\(resolved)'")
    }
    return contents.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        return trimmed
    }
}

func parseArguments() -> Options {
    var o = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--file":
            i += 1
            guard i < args.count else { fail("Missing value for --file") }
            o.tracks.append(args[i])
        case "--playlist":
            i += 1
            guard i < args.count else { fail("Missing value for --playlist") }
            o.tracks.append(contentsOf: loadPlaylist(args[i]))
        case "--rate":
            i += 1
            guard i < args.count, let rate = Double(args[i]), rate >= 8_000, rate <= 192_000 else {
                fail("Missing or invalid value for --rate (expected 8000–192000)")
            }
            o.sampleRate = rate
        case "--channels":
            i += 1
            guard i < args.count, let ch = UInt32(args[i]), ch >= 1, ch <= 8 else {
                fail("Missing or invalid value for --channels (expected 1–8)")
            }
            o.channels = ch
        case "--gap":
            i += 1
            guard i < args.count, let gap = Double(args[i]), gap >= 0 else {
                fail("Missing or invalid value for --gap (seconds)")
            }
            o.gapSeconds = gap
        case "--repeat":
            o.repeatForever = true
        case "--exit-with-parent":
            o.exitWithParent = true
        default:
            // Smart-dashes substitution turns "--" into an em dash when typed
            // in some text fields; call that out since it's invisible on screen.
            if args[i].hasPrefix("—") || args[i].hasPrefix("–") {
                fail("Unknown argument '\(args[i])' — this starts with an em/en dash, not '--'. "
                     + "Re-type the option with two hyphens (disable smart dashes).")
            }
            fail("Unknown argument '\(args[i])'")
        }
        i += 1
    }
    guard !o.tracks.isEmpty else {
        fail("no tracks to play — pass one or more --file <path>, or --playlist <path>")
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

// MARK: File decoding (AVAudioFile → S16LE interleaved Data at the output format)

guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: options.sampleRate,
                                        channels: options.channels, interleaved: true) else {
    fail("could not create output format at \(options.sampleRate) Hz / \(options.channels) ch")
}

/// Decodes one file to S16LE interleaved Data at `outputFormat`. Returns nil
/// (after logging) if the file can't be opened, read, or converted — the
/// caller skips it and keeps going with the rest of the playlist.
func decode(_ path: String) -> Data? {
    let resolved = (path as NSString).expandingTildeInPath
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: resolved)) else {
        note("could not open '\(resolved)' — skipping")
        return nil
    }
    let sourceFormat = file.processingFormat
    guard file.length > 0, let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        note("'\(resolved)' has no audio — skipping")
        return nil
    }
    do {
        try file.read(into: inBuffer)
    } catch {
        note("could not read '\(resolved)': \(error) — skipping")
        return nil
    }
    guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
        note("could not convert '\(resolved)' (\(Int(sourceFormat.sampleRate)) Hz / \(sourceFormat.channelCount) ch) — skipping")
        return nil
    }

    var resultData = Data()
    var inputConsumed = false
    while true {
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 65_536) else { break }
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if inputConsumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            inputStatus.pointee = .haveData
            return inBuffer
        }
        if let samples = outBuffer.int16ChannelData?[0], outBuffer.frameLength > 0 {
            resultData.append(Data(bytes: samples, count: Int(outBuffer.frameLength) * Int(outputFormat.channelCount) * MemoryLayout<Int16>.size))
        }
        switch status {
        case .haveData, .inputRanDry:
            continue
        case .endOfStream:
            return resultData.isEmpty ? nil : resultData
        case .error:
            note("conversion failed for '\(resolved)': \(error?.localizedDescription ?? "unknown") — skipping")
            return nil
        @unknown default:
            return resultData.isEmpty ? nil : resultData
        }
    }
    return resultData.isEmpty ? nil : resultData
}

note("decoding \(options.tracks.count) track\(options.tracks.count == 1 ? "" : "s") at \(Int(options.sampleRate)) Hz / \(options.channels) ch")

var playlist: [(path: String, audio: Data)] = []
for path in options.tracks {
    if let audio = decode(path) {
        playlist.append((path, audio))
    }
}
guard !playlist.isEmpty else {
    fail("no tracks could be decoded")
}
note("ready — \(playlist.count) of \(options.tracks.count) track\(options.tracks.count == 1 ? "" : "s") decoded"
     + (options.repeatForever ? ", repeating" : ""))

// MARK: Real-time paced stdout writer (same pattern as PCMSpeechSynth)

let bytesPerSecond = options.sampleRate * Double(options.channels) * 2
var paceDeadline = Date()

func writePaced(_ data: Data) {
    let chunkSize = 4_096
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let length = min(chunkSize, data.count - offset)
            var written = 0
            while written < length {
                let n = write(1, base + offset + written, length - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    note("stdout closed (\(String(cString: strerror(errno)))); exiting")
                    exit(0)
                }
                written += n
            }
            offset += length
            paceDeadline.addTimeInterval(Double(length) / bytesPerSecond)
            let delay = paceDeadline.timeIntervalSinceNow
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
    }
}

func writeSilence(seconds: Double) {
    guard seconds > 0 else { return }
    let frameBytes = 2 * Int(options.channels)
    var byteCount = Int(seconds * bytesPerSecond)
    byteCount -= byteCount % frameBytes
    writePaced(Data(count: byteCount))
}

signal(SIGPIPE, SIG_IGN)

// MARK: Main playback loop

paceDeadline = Date()
repeat {
    for (index, track) in playlist.enumerated() {
        note("playing \(track.path)")
        writePaced(track.audio)
        let isLastTrack = index == playlist.count - 1
        if !isLastTrack || options.repeatForever {
            writeSilence(seconds: options.gapSeconds)
        }
    }
} while options.repeatForever

note("playlist finished; exiting")
