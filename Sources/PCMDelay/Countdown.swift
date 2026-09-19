import AVFoundation
import Foundation

// Countdown cues for PCMDelay's leading silence.
//
// While a stage that starts with `--delay N` is still playing that initial
// silence, the listener has no way to know whether anything is wrong. With
// `--countdown` PCMDelay mixes cues into the silence, counted down to the
// moment live audio begins:
//
//   • a short beep once per second (`beeps` / `both`), and
//   • a synthesized spoken countdown (`speech` / `both`):
//       – every second for the last 10 ("10", "9", … "1"),
//       – every 5 s from 60 s down to 15 s ("60 seconds" … "15 seconds"),
//       – every 30 s above a minute ("4 minutes 30 seconds", "4 minutes", …),
//       – plus the total once at the start when it isn't on that schedule.
//
// Cues are counted back from the end of the silence, so "1" is spoken one
// second before the audio starts. The spoken phrases are rendered offline on a
// main thread at launch (AVSpeechSynthesizer.write, like PCMSpeechSynth);
// the audio path never waits on them. A phrase that isn't rendered yet when its
// moment arrives is played late if it becomes ready within `maxLateness`
// seconds, and otherwise skipped.

enum CountdownMode: String {
    case none, beeps, speech, both

    var beeps: Bool { self == .beeps || self == .both }
    var speech: Bool { self == .speech || self == .both }
}

enum CountdownPhrases {
    /// What to say when `seconds` of silence remain out of `total`, or nil
    /// for silence (a beep-only second).
    static func phrase(forRemaining seconds: Int, total: Int) -> String? {
        guard seconds >= 1 else { return nil }
        if seconds == total { return spoken(seconds) }
        switch seconds {
        case 1...10: return spoken(seconds)
        case 11...60: return seconds % 5 == 0 ? spoken(seconds) : nil
        default: return seconds % 30 == 0 ? spoken(seconds) : nil
        }
    }

    /// The words for a remaining time. Single numbers up to 10 are spoken bare
    /// ("10 9 8 …"); larger values get their unit.
    static func spoken(_ seconds: Int) -> String {
        if seconds <= 10 { return "\(seconds)" }
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        let rest = seconds % 60
        let minutesText = "\(minutes) minute" + (minutes == 1 ? "" : "s")
        return rest == 0 ? minutesText : "\(minutesText) \(rest) seconds"
    }

    /// Every distinct phrase a countdown from `total` seconds will want,
    /// soonest-needed first (largest remaining time first).
    static func all(total: Int) -> [String] {
        var seen = Set<String>()
        var result = [String]()
        for t in stride(from: total, through: 1, by: -1) {
            if let text = phrase(forRemaining: t, total: total), seen.insert(text).inserted {
                result.append(text)
            }
        }
        return result
    }
}

/// Renders the countdown phrases to mono S16 at the stream rate (on the main
/// thread, while the audio loop runs elsewhere) and hands finished clips over.
final class CountdownSpeechBank: @unchecked Sendable {
    private let lock = NSLock()
    private var clips: [String: [Int16]] = [:]

    func clip(for text: String) -> [Int16]? {
        lock.lock(); defer { lock.unlock() }
        return clips[text]
    }

    private func store(_ text: String, _ samples: [Int16]) {
        lock.lock(); clips[text] = samples; lock.unlock()
    }

    /// Renders every phrase, blocking the calling thread until done. Must be
    /// called on the main thread from top-level code — not from inside a
    /// `DispatchQueue.main` block: AVSpeechSynthesizer.write delivers its
    /// buffers through the main queue, which a running main-queue block
    /// would itself be holding (PCMDelay keeps its stdin loop off the main
    /// thread precisely so main is free to do this).
    func renderAll(phrases: [String], voice: AVSpeechSynthesisVoice?, sampleRate: Double,
                   log: (String) -> Void) {
        guard let renderer = OfflineSpeechRenderer(sampleRate: sampleRate) else {
            log("countdown: could not create speech output format; spoken cues disabled")
            return
        }
        for text in phrases {
            let samples = renderer.render(text: text, voice: voice)
            if samples.isEmpty {
                log("countdown: no audio rendered for '\(text)'")
            } else {
                store(text, Self.normalized(samples))
            }
        }
    }

    /// Scales a clip so its peak is a consistent, moderate level — different
    /// phrases (and voices) otherwise come out at noticeably different loudness.
    private static func normalized(_ samples: [Int16]) -> [Int16] {
        let peak = samples.reduce(0) { max($0, abs(Int($1))) }
        guard peak > 0 else { return samples }
        let scale = (0.7 * 32_767.0) / Double(peak)
        return samples.map { Int16(max(-32_768.0, min(32_767.0, (Double($0) * scale).rounded()))) }
    }
}

/// AVSpeechSynthesizer.write → mono S16 at the output rate. Blocks (pumping the
/// run loop) until the utterance finishes; must be used from one thread (the main thread).
private final class OfflineSpeechRenderer: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    /// A fresh synthesizer per utterance (see `render`); kept here so the
    /// delegate callbacks and the write handler stay alive until it finishes.
    private var synthesizer = AVSpeechSynthesizer()
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var rendered = [Int16]()
    private var finished = false

    init?(sampleRate: Double) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                         channels: 1, interleaved: true) else { return nil }
        outputFormat = format
        super.init()
    }

    func render(text: String, voice: AVSpeechSynthesisVoice?) -> [Int16] {
        // One synthesizer per utterance: reusing one let the previous
        // utterance's late completion event mark the *next* render finished
        // immediately, so alternate short phrases came back empty.
        synthesizer.delegate = nil
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        lock.lock(); rendered = []; finished = false; converter = nil; lock.unlock()

        let utterance = AVSpeechUtterance(string: text)
        if let voice { utterance.voice = voice }

        synthesizer.write(utterance) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if pcm.frameLength == 0 {
                self.finished = true   // zero-length buffer signals completion
            } else {
                self.rendered.append(contentsOf: self.convertLocked(pcm))
            }
        }

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            lock.lock(); let done = finished; lock.unlock()
            if done { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        lock.lock()
        rendered.append(contentsOf: flushConverterLocked())
        let out = rendered
        rendered = []
        lock.unlock()
        return out
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        lock.lock(); finished = true; lock.unlock()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        lock.lock(); finished = true; lock.unlock()
    }

    private func convertLocked(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return [] }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { return [] }
        return Self.samples(from: out)
    }

    private func flushConverterLocked() -> [Int16] {
        guard let converter else { return [] }
        defer { self.converter = nil }
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else { return [] }
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error else { return [] }
        return Self.samples(from: out)
    }

    private static func samples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let data = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}

/// Produces the countdown overlay one frame at a time. The audio loop calls
/// `overlay(remainingFrames:)` once per output frame; the returned mono sample
/// is added to every channel.
final class CountdownMixer {
    private struct Playing {
        var clip: [Int16]
        var position: Int
    }

    /// How late (in seconds) a spoken phrase may still start if it finished
    /// rendering after its moment.
    private let maxLateness = 2.0
    /// Gap between a beep and the speech that shares its second, so the two
    /// don't start on top of each other.
    private let speechOffsetSeconds = 0.12

    private let rate: Int
    private let totalSeconds: Int
    private let mode: CountdownMode
    private let bank: CountdownSpeechBank?
    private let beep: [Int16]

    private var beepPlaying: Playing?
    private var speechPlaying: Playing?
    private var pendingSpeech: (text: String, startFrame: Int)?
    private var frame = 0

    init(rate: Int, totalSeconds: Int, mode: CountdownMode, bank: CountdownSpeechBank?) {
        self.rate = rate
        self.totalSeconds = totalSeconds
        self.mode = mode
        self.bank = bank
        self.beep = Self.makeBeep(rate: rate)
    }

    /// 1 kHz, 70 ms, with 5 ms attack/release so it doesn't click.
    private static func makeBeep(rate: Int) -> [Int16] {
        let count = rate * 70 / 1_000
        let ramp = max(1, rate * 5 / 1_000)
        return (0..<count).map { i in
            let envelope = min(1.0, Double(i) / Double(ramp), Double(count - 1 - i) / Double(ramp))
            let value = sin(2 * Double.pi * 1_000 * Double(i) / Double(rate)) * envelope * 0.3 * 32_767
            return Int16(value.rounded())
        }
    }

    /// `remainingFrames` is how many frames of leading silence are left (≤ 0
    /// once the audio has started, or when the countdown has been cancelled).
    func overlay(remainingFrames: Int) -> Int32 {
        defer { frame += 1 }

        if remainingFrames > 0, remainingFrames % rate == 0 {
            let seconds = remainingFrames / rate
            if mode.beeps { beepPlaying = Playing(clip: beep, position: 0) }
            if mode.speech,
               let text = CountdownPhrases.phrase(forRemaining: seconds, total: totalSeconds) {
                pendingSpeech = (text, frame + Int(speechOffsetSeconds * Double(rate)))
            }
        }

        if let pending = pendingSpeech {
            if frame - pending.startFrame > Int(maxLateness * Double(rate)) {
                pendingSpeech = nil                       // too late to be useful
            } else if frame >= pending.startFrame, let clip = bank?.clip(for: pending.text) {
                speechPlaying = Playing(clip: clip, position: 0)
                pendingSpeech = nil
            }
        }

        var sum: Int32 = 0
        sum += advance(&beepPlaying)
        sum += advance(&speechPlaying)
        return sum
    }

    private func advance(_ playing: inout Playing?) -> Int32 {
        guard var p = playing else { return 0 }
        let sample = Int32(p.clip[p.position])
        p.position += 1
        playing = p.position < p.clip.count ? p : nil
        return sample
    }

    /// Stops all cues (used when the delay is changed during the countdown,
    /// which makes the "time remaining" meaningless).
    func cancel() {
        beepPlaying = nil
        speechPlaying = nil
        pendingSpeech = nil
    }
}
