import AVFoundation
import CoreMedia
import Foundation
import Speech
#if canImport(Darwin)
import Darwin
#endif

// PCMTranscriber — speech-to-text tap stage of an AntennaHead audio pipeline.
//
// Contract (shared by every pipeline unit):
//   • Input  : raw S16LE PCM, interleaved, on stdin (rate/channels via flags;
//              defaults 48000 Hz / 2 ch — the LiveAudioServer contract)
//   • Output : the same PCM on stdout, byte-for-byte unchanged
//
// Like LiveAudioRecorder, this is a lossless tap, not a filter: it copies stdin
// to stdout untouched and feeds a resampled copy to Apple's on-device
// SpeechAnalyzer / SpeechTranscriber (macOS 26+). Recognition results are
// emitted out of band:
//   • --udp-port <n>        newline-delimited JSON events to <udp-host>:<n>
//                           (one datagram per event; for a live-captions client)
//   • --transcript-file <p> finalized segments appended to <p>, as plain text
//                           or as SRT / WebVTT when the extension is .srt / .vtt
// At least one of the two is required (stdin still passes through regardless).
//
// Because it only tees, it can sit anywhere in a TaskPipelineManager chain; put
// it after the normalize stage so it sees a steady 48 kHz / 2 ch stream.
//
// Usage: PCMTranscriber [--rate <Hz>] [--channels <n>] [--locale <bcp47>]
//                       [--udp-port <n>] [--udp-host <addr>]
//                       [--transcript-file <path>] [--partials]
//                       [--exit-with-parent]
//
//   --partials  also emit volatile (not-yet-final) hypotheses over UDP, for
//               low-latency captions. The transcript file only ever gets
//               finalized text.

// MARK: - Logging

let log = FileHandle.standardError
func note(_ message: String) { log.write(Data("PCMTranscriber: \(message)\n".utf8)) }
func fail(_ message: String) -> Never { note(message); exit(1) }

// MARK: - Argument parsing

struct Options {
    var inputRate = 48_000.0
    var inputChannels: AVAudioChannelCount = 2
    var locale = "en-US"
    var udpPort: UInt16?
    var udpHost = "127.0.0.1"
    var transcriptFile: String?
    var emitPartials = false
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
            guard i < args.count, let v = Double(args[i]), v >= 8_000, v <= 192_000 else {
                fail("Missing or invalid value for --rate (expected 8000–192000)")
            }
            o.inputRate = v
        case "--channels":
            i += 1
            guard i < args.count, let v = UInt32(args[i]), v == 1 || v == 2 else {
                fail("Missing or invalid value for --channels (expected 1 or 2)")
            }
            o.inputChannels = AVAudioChannelCount(v)
        case "--locale":
            i += 1
            guard i < args.count else { fail("Missing value for --locale") }
            o.locale = args[i]
        case "--udp-port":
            i += 1
            guard i < args.count, let v = UInt16(args[i]), v > 0 else {
                fail("Missing or invalid value for --udp-port (expected 1–65535)")
            }
            o.udpPort = v
        case "--udp-host":
            i += 1
            guard i < args.count else { fail("Missing value for --udp-host") }
            o.udpHost = args[i]
        case "--transcript-file":
            i += 1
            guard i < args.count else { fail("Missing value for --transcript-file") }
            o.transcriptFile = args[i]
        case "--partials":
            o.emitPartials = true
        case "--exit-with-parent":
            o.exitWithParent = true
        default:
            fail("Unknown argument '\(args[i])'")
        }
        i += 1
    }
    guard o.udpPort != nil || o.transcriptFile != nil else {
        fail("nothing to do — pass --udp-port and/or --transcript-file (stdin still passes through to stdout)")
    }
    return o
}

let options = parseArguments()

// MARK: - Parent-death watchdog (same pattern as the other pipeline helpers)

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
if options.exitWithParent { startParentDeathWatchdog() }

signal(SIGPIPE, SIG_IGN)

// MARK: - Result sinks

/// Serializes writes to both sinks; recognition results can arrive on any executor.
let sinkQueue = DispatchQueue(label: "PCMTranscriber.sinks")

struct ResultEvent: Encodable {
    let type: String        // "partial" | "final"
    let text: String
    let start: Double?
    let end: Double?
}

let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes]
    return e
}()

/// Connected UDP datagram socket, mirroring PCMUDPSender's setup.
final class UDPResultSink {
    private let fd: Int32
    init?(host: String, port: UInt16) {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { note("socket() failed: \(String(cString: strerror(errno)))"); return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            note("invalid --udp-host '\(host)'"); return nil
        }
        let ok = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else {
            note("connect() to \(host):\(port) failed: \(String(cString: strerror(errno)))"); return nil
        }
        note("emitting result JSON to \(host):\(port)")
    }

    func emit(_ event: ResultEvent) {
        guard var data = try? jsonEncoder.encode(event) else { return }
        data.append(0x0A)   // newline-delimited
        _ = data.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    }
}

/// Appends finalized segments to a file as plain text, SRT, or WebVTT.
final class FileResultSink {
    enum Format { case text, srt, vtt }
    private let handle: FileHandle
    private let format: Format
    private var index = 1

    init?(path: String) {
        let resolved = (path as NSString).expandingTildeInPath
        switch (resolved as NSString).pathExtension.lowercased() {
        case "srt": format = .srt
        case "vtt": format = .vtt
        default:    format = .text
        }
        if !FileManager.default.fileExists(atPath: resolved) {
            FileManager.default.createFile(atPath: resolved, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: resolved) else {
            note("cannot open transcript file: \(resolved)"); return nil
        }
        handle = h
        h.seekToEndOfFile()
        if format == .vtt, h.offsetInFile == 0 { h.write(Data("WEBVTT\n\n".utf8)) }
        note("appending \(format) transcript to \(resolved)")
    }

    func writeFinal(text: String, start: Double?, end: Double?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let block: String
        switch format {
        case .text:
            block = trimmed + "\n"
        case .srt:
            let s = Self.stamp(start ?? 0, decimalSeparator: ",")
            let e = Self.stamp(end ?? ((start ?? 0) + 2), decimalSeparator: ",")
            block = "\(index)\n\(s) --> \(e)\n\(trimmed)\n\n"
            index += 1
        case .vtt:
            let s = Self.stamp(start ?? 0, decimalSeparator: ".")
            let e = Self.stamp(end ?? ((start ?? 0) + 2), decimalSeparator: ".")
            block = "\(s) --> \(e)\n\(trimmed)\n\n"
        }
        handle.write(Data(block.utf8))
    }

    func finish() { try? handle.close() }

    private static func stamp(_ seconds: Double, decimalSeparator: String) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        let ms = min(max(Int((clamped - Double(whole)) * 1000), 0), 999)
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
        return String(format: "%02d:%02d:%02d\(decimalSeparator)%03d", h, m, s, ms)
    }
}

// Both sinks are touched only from `sinkQueue` (a serial queue), so the
// cross-isolation access is safe; the annotation just tells the compiler so.
nonisolated(unsafe) let udpSink = options.udpPort.flatMap { UDPResultSink(host: options.udpHost, port: $0) }
nonisolated(unsafe) let fileSink = options.transcriptFile.flatMap { FileResultSink(path: $0) }

func emit(type: String, text: String, start: Double?, end: Double?) {
    let event = ResultEvent(type: type, text: text, start: start, end: end)
    sinkQueue.async {
        if type == "final" || options.emitPartials { udpSink?.emit(event) }
        if type == "final" { fileSink?.writeFinal(text: text, start: start, end: end) }
    }
}

// MARK: - Recognition engine (macOS 26 SpeechAnalyzer / SpeechTranscriber)

@available(macOS 26, *)
func runTranscription(_ options: Options) async {
    let locale = Locale(identifier: options.locale)

    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: options.emitPartials ? [.volatileResults] : [],
        attributeOptions: [.audioTimeRange]
    )

    // Reserve + install the on-device model for this locale. First run may need
    // the network; afterwards recognition is fully offline.
    _ = try? await AssetInventory.reserve(locale: locale)
    do {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            note("installing speech model for \(options.locale)…")
            try await request.downloadAndInstall()
        }
    } catch {
        fail("could not install the \(options.locale) speech model: \(error)")
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])

    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        fail("no compatible analyzer audio format for \(options.locale)")
    }
    guard
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                        sampleRate: options.inputRate,
                                        channels: options.inputChannels,
                                        interleaved: true),
        let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
    else {
        fail("could not build \(Int(options.inputRate)) Hz / \(options.inputChannels) ch → analyzer converter")
    }

    // Wrap one raw S16LE stdin chunk in an AVAudioPCMBuffer (no array copy).
    func makePCMBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = AVAudioFrameCount(data.count / bytesPerFrame)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let dst = abl[0].mData else { return nil }
        data.copyBytes(to: dst.assumingMemoryBound(to: UInt8.self), count: Int(frames) * bytesPerFrame)
        return buffer
    }

    // Resample/reformat one buffer to the analyzer format. The converter keeps
    // resampler state across calls, so feed every chunk in order.
    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = analyzerFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            note("conversion failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    func seconds(of result: SpeechTranscriber.Result) -> (Double?, Double?) {
        let range = result.range            // CMTimeRange (from .audioTimeRange)
        let start = range.start.seconds
        let end = range.end.seconds
        return (start.isFinite ? start : nil, end.isFinite ? end : nil)
    }

    let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

    do {
        try await analyzer.start(inputSequence: inputSequence)
    } catch {
        fail("SpeechAnalyzer failed to start: \(error)")
    }
    note("started — \(Int(options.inputRate)) Hz / \(options.inputChannels) ch in, "
         + "\(Int(analyzerFormat.sampleRate)) Hz to the recognizer")

    // Blocking stdin → stdout tee on its own thread; also feeds the recognizer.
    let stdinHandle = FileHandle.standardInput
    let stdoutHandle = FileHandle.standardOutput
    Thread.detachNewThread {
        var total = 0
        while true {
            let chunk = stdinHandle.availableData
            if chunk.isEmpty { break }            // EOF: upstream closed
            stdoutHandle.write(chunk)             // lossless passthrough — always first
            total += chunk.count
            if let buffer = makePCMBuffer(chunk), let converted = convert(buffer) {
                inputBuilder.yield(AnalyzerInput(buffer: converted))
            }
        }
        note("stdin closed — \(total) bytes passed through; finalizing transcript")
        inputBuilder.finish()
        Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    // Drain results until finalize completes and the stream ends.
    do {
        for try await result in transcriber.results {
            let text = String(result.text.characters)
            let (start, end) = seconds(of: result)
            emit(type: result.isFinal ? "final" : "partial", text: text, start: start, end: end)
        }
    } catch {
        note("recognition stream ended with error: \(error)")
    }

    sinkQueue.sync { fileSink?.finish() }
    note("done")
}

// MARK: - Entry point

if #available(macOS 26, *) {
    await runTranscription(options)
    exit(0)
} else {
    fail("SpeechAnalyzer requires macOS 26 or later")
}
