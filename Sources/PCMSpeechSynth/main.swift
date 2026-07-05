import AVFoundation
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// PCMSpeechSynth — text-to-speech source stage of an AntennaHead audio pipeline.
//
// Contract:
//   • Input  : text — from stdin (read to EOF), a file, or a UDP port (each
//     datagram replaces the current text, so a repeating announcement can be
//     retargeted while running)
//   • Output : S16LE mono PCM on stdout at --rate, PACED IN REAL TIME. As a
//     source stage there is no radio clocking the pipeline and UDP sinks have
//     no backpressure, so this helper meters its own output.
//   • Sits at the START of a TaskPipelineManager chain; a downstream sox
//     stage normalizes rate/channels to the 48 kHz / 2 ch LAS contract.
//
// Usage: PCMSpeechSynth --input stdin|file:<path>|udp:<port>|text:<string>
//        [--rate <hz>] [--voice <identifier-or-language>] [--speech-rate <0..1>]
//        [--ssml] [--repeat] [--gap <seconds>] [--list-voices] [--exit-with-parent]
//
//   --text <string>  shorthand for --input text:<string>
//   --rate         output sample rate in Hz (default 22050)
//   --voice        AVSpeechSynthesisVoice identifier or BCP-47 language code
//   --speech-rate  speaking rate 0..1 (default: the system default)
//   --ssml         parse the text as SSML markup (<speak>…</speak>) — prosody
//                  control for the modern voices, which do not understand the
//                  classic [[cmnd]] embedded commands (they read them aloud;
//                  only com.apple.speech.synthesis.voice.* voices honor them)
//   --repeat       loop the audio continuously
//   --gap          seconds of silence between repeats / utterances (default 1.0)
//   --list-voices  print available voices to stdout and exit

let log = FileHandle.standardError
func note(_ message: String) {
    log.write(Data("PCMSpeechSynth: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

// MARK: Argument parsing

enum TextSource {
    case stdin
    case file(String)
    case udp(UInt16)
    case literal(String)
}

struct Options {
    var source: TextSource?
    var sampleRate = 22_050.0
    var voice: String?
    var speechRate = AVSpeechUtteranceDefaultSpeechRate
    var ssml = false
    var repeatForever = false
    var gapSeconds = 1.0
    var exitWithParent = false
}

func parseArguments() -> Options {
    var o = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--input":
            i += 1
            guard i < args.count else { fail("Missing value for --input") }
            let value = args[i]
            if value == "stdin" {
                o.source = .stdin
            } else if value.hasPrefix("file:") {
                o.source = .file(String(value.dropFirst(5)))
            } else if value.hasPrefix("udp:"), let port = UInt16(value.dropFirst(4)), port > 0 {
                o.source = .udp(port)
            } else if value.hasPrefix("text:") {
                o.source = .literal(String(value.dropFirst(5)))
            } else {
                fail("Invalid --input '\(value)' (expected 'stdin', 'file:<path>', 'udp:<port>' or 'text:<string>')")
            }
        case "--text":
            i += 1
            guard i < args.count else { fail("Missing value for --text") }
            o.source = .literal(args[i])
        case "--rate":
            i += 1
            guard i < args.count, let rate = Double(args[i]), rate >= 8_000, rate <= 48_000 else {
                fail("Missing or invalid value for --rate (expected 8000–48000)")
            }
            o.sampleRate = rate
        case "--voice":
            i += 1
            guard i < args.count else { fail("Missing value for --voice") }
            o.voice = args[i]
        case "--speech-rate":
            i += 1
            guard i < args.count, let rate = Float(args[i]), (0.0...1.0).contains(rate) else {
                fail("Missing or invalid value for --speech-rate (expected 0..1)")
            }
            o.speechRate = rate
        case "--ssml":
            o.ssml = true
        case "--repeat":
            o.repeatForever = true
        case "--gap":
            i += 1
            guard i < args.count, let gap = Double(args[i]), gap >= 0 else {
                fail("Missing or invalid value for --gap (seconds)")
            }
            o.gapSeconds = gap
        case "--list-voices":
            for voice in AVSpeechSynthesisVoice.speechVoices() {
                print("\(voice.identifier)  [\(voice.language)]  \(voice.name)")
            }
            exit(0)
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
    guard o.source != nil else {
        fail("--input is required ('stdin', 'file:<path>', 'udp:<port>' or 'text:<string>'), or use --text <string>")
    }
    return o
}

let options = parseArguments()
let source = options.source!

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

// MARK: Voice selection

func resolveVoice(_ spec: String?) -> AVSpeechSynthesisVoice? {
    guard let spec else { return nil }
    if let voice = AVSpeechSynthesisVoice(identifier: spec) { return voice }
    if let voice = AVSpeechSynthesisVoice(language: spec) { return voice }
    fail("Unknown voice '\(spec)' — try --list-voices")
}

let voice = resolveVoice(options.voice)

// MARK: Offline speech rendering (AVSpeechSynthesizer.write → PCM Data)

final class SpeechRenderer: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var rendered = Data()
    private var finished = false

    init(sampleRate: Double) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                         channels: 1, interleaved: true) else {
            fail("could not create output format at \(sampleRate) Hz")
        }
        outputFormat = format
        super.init()
        synthesizer.delegate = self
    }

    /// Renders one utterance to S16LE mono Data at the output rate. Blocks
    /// (pumping the run loop) until synthesis completes. With `ssml` the text
    /// is parsed as SSML markup; a parse failure returns empty Data.
    func render(text: String, voice: AVSpeechSynthesisVoice?, speechRate: Float, ssml: Bool) -> Data {
        lock.lock()
        rendered = Data()
        finished = false
        converter = nil
        lock.unlock()

        let utterance: AVSpeechUtterance
        if ssml {
            guard let parsed = AVSpeechUtterance(ssmlRepresentation: text) else {
                note("invalid SSML — the markup could not be parsed (wrap the text in <speak>…</speak>)")
                return Data()
            }
            utterance = parsed
        } else {
            utterance = AVSpeechUtterance(string: text)
        }
        if let voice { utterance.voice = voice }
        utterance.rate = speechRate

        synthesizer.write(utterance) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if pcm.frameLength == 0 {
                self.finished = true   // zero-length buffer signals completion
            } else {
                self.rendered.append(self.convertLocked(pcm))
            }
        }

        // Wait for the completion buffer and/or the delegate's didFinish.
        while true {
            lock.lock()
            let done = finished
            lock.unlock()
            if done { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        lock.lock()
        rendered.append(flushConverterLocked())
        let out = rendered
        rendered = Data()
        lock.unlock()
        return out
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        lock.lock()
        finished = true
        lock.unlock()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        lock.lock()
        finished = true
        lock.unlock()
    }

    /// Converts one source buffer (whatever format the voice renders — often
    /// 22.05 kHz mono Float32) to the output format. The converter persists
    /// across buffers so resampler state carries through the utterance.
    /// Caller holds `lock`.
    private func convertLocked(_ buffer: AVAudioPCMBuffer) -> Data {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return Data() }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return Data() }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            note("conversion failed: \(error?.localizedDescription ?? "unknown")")
            return Data()
        }
        return Self.data(from: out)
    }

    /// Drains the resampler at the end of an utterance. Caller holds `lock`.
    private func flushConverterLocked() -> Data {
        guard let converter else { return Data() }
        defer { self.converter = nil }
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else { return Data() }
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error else { return Data() }
        return Self.data(from: out)
    }

    private static func data(from buffer: AVAudioPCMBuffer) -> Data {
        guard let samples = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return Data() }
        return Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }
}

let renderer = SpeechRenderer(sampleRate: options.sampleRate)

// MARK: Real-time paced stdout writer

let bytesPerSecond = options.sampleRate * 2   // S16LE mono
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
    var byteCount = Int(seconds * bytesPerSecond)
    byteCount -= byteCount % 2   // keep S16 alignment
    writePaced(Data(count: byteCount))
}

signal(SIGPIPE, SIG_IGN)

// MARK: Text sources

/// Latest-text holder for the UDP source. A generation counter lets the main
/// loop re-render only when the text actually changed.
final class TextHolder: @unchecked Sendable {
    private var text: String?
    private var generation = 0
    private let lock = NSLock()

    func set(_ newText: String) {
        lock.lock(); defer { lock.unlock() }
        text = newText
        generation += 1
    }

    func snapshot() -> (text: String, generation: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let text else { return nil }
        return (text, generation)
    }
}

func startUDPTextListener(port: UInt16, into holder: TextHolder) {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { fail("socket() failed: \(String(cString: strerror(errno)))") }
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
    guard result == 0 else { fail("bind() to port \(port) failed: \(String(cString: strerror(errno)))") }

    Thread.detachNewThread {
        let bufferSize = 65_536
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
        while true {
            let received = recv(fd, buffer, bufferSize, 0)
            guard received > 0 else { continue }
            let text = String(decoding: UnsafeRawBufferPointer(start: buffer, count: received), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                note("received new text (\(text.count) characters)")
                holder.set(text)
            }
        }
    }
}

// MARK: Main loop

switch source {
case .stdin, .file, .literal:
    let text: String
    switch source {
    case .stdin:
        guard let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            fail("no text on stdin")
        }
        text = input
    case .file(let path):
        guard let input = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            fail("could not read text from '\(path)'")
        }
        text = input
    case .literal(let string):
        let input = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { fail("--text is empty") }
        text = input
    case .udp:
        fatalError("unreachable")
    }

    note("rendering \(text.count) characters at \(Int(options.sampleRate)) Hz"
         + (options.repeatForever ? ", repeating" : ""))
    let audio = renderer.render(text: text, voice: voice, speechRate: options.speechRate, ssml: options.ssml)
    guard !audio.isEmpty else { fail("synthesis produced no audio") }
    paceDeadline = Date()
    repeat {
        writePaced(audio)
        if options.repeatForever { writeSilence(seconds: options.gapSeconds) }
    } while options.repeatForever

case .udp(let port):
    let holder = TextHolder()
    startUDPTextListener(port: port, into: holder)
    note("waiting for text on udp:\(port)"
         + (options.repeatForever ? ", repeating current text" : ""))

    var audio = Data()
    var renderedGeneration = -1
    var spokenGeneration = -1
    paceDeadline = Date()
    while true {
        guard let (text, generation) = holder.snapshot() else {
            Thread.sleep(forTimeInterval: 0.1)
            paceDeadline = Date()
            continue
        }
        if generation != renderedGeneration {
            audio = renderer.render(text: text, voice: voice, speechRate: options.speechRate, ssml: options.ssml)
            renderedGeneration = generation
            paceDeadline = Date()
        }
        if options.repeatForever {
            // Loop the current text until a new datagram replaces it.
            writePaced(audio)
            writeSilence(seconds: options.gapSeconds)
        } else {
            // Speak each new text once, then wait for the next one.
            if generation != spokenGeneration {
                writePaced(audio)
                spokenGeneration = generation
            } else {
                Thread.sleep(forTimeInterval: 0.1)
                paceDeadline = Date()
            }
        }
    }
}
