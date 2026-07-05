import AVFoundation
import CoreAudio
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// AudioInputCapture — front-end source stage for AntennaHead's device-input path.
//
// Captures a named Core Audio input device with AVAudioEngine, converts to the
// pipeline contract (raw S16LE, interleaved, 48000 Hz, 2 channels), and writes
// it to stdout. Front-end normalization to 48 kHz means the downstream sox
// stage only applies the audio_output_filter (no resample).
//
// Usage: AudioInputCapture --device-name <name> [--rate 48000] [--channels 2] [--exit-with-parent]

let stderrHandle = FileHandle.standardError
func note(_ message: String) {
    stderrHandle.write(Data("AudioInputCapture: \(message)\n".utf8))
}
func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

// MARK: Arguments

func parseArguments() -> (deviceName: String?, rate: Double, channels: AVAudioChannelCount, exitWithParent: Bool) {
    var deviceName: String?
    var rate: Double = 48_000
    var channels: AVAudioChannelCount = 2
    var exitWithParent = false
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--device-name":
            i += 1; guard i < args.count else { fail("Missing value for --device-name") }
            deviceName = args[i]
        case "--rate":
            i += 1; guard i < args.count, let v = Double(args[i]) else { fail("Invalid --rate") }
            rate = v
        case "--channels":
            i += 1; guard i < args.count, let v = UInt32(args[i]) else { fail("Invalid --channels") }
            channels = AVAudioChannelCount(v)
        case "--exit-with-parent":
            exitWithParent = true
        default:
            fail("Unknown argument '\(args[i])'")
        }
        i += 1
    }
    return (deviceName, rate, channels, exitWithParent)
}

let (deviceName, targetRate, targetChannels, exitWithParent) = parseArguments()

// MARK: Parent-death watchdog (self-reap if the launching app dies; the sandbox
// can't kill an orphaned helper). Mirrors PCMUDPSender / rtl_fm_localradio.

if exitWithParent {
    let originalParent = getppid()
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            if getppid() != originalParent {
                note("parent exited; shutting down")
                exit(0)
            }
        }
    }
}

// MARK: Resolve device name -> AudioDeviceID

func inputDeviceID(named name: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }

    for id in ids where deviceInputChannelCount(id) > 0 {
        if deviceName(id) == name { return id }
    }
    return nil
}

func deviceName(_ id: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var name: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let cf = name?.takeRetainedValue() else { return nil }
    return (cf as String).trimmingCharacters(in: .whitespacesAndNewlines)
}

func deviceInputChannelCount(_ id: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

// MARK: Engine + tap

let engine = AVAudioEngine()
let inputNode = engine.inputNode

// Point the input unit at the requested device (else the system default input).
if let name = deviceName, let audioUnit = inputNode.audioUnit {
    if var id = inputDeviceID(named: name) {
        let status = AudioUnitSetProperty(audioUnit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { note("failed to set current device (status \(status)); using default input") }
    } else {
        note("input device '\(name)' not found; using default input")
    }
}

let tapFormat = inputNode.inputFormat(forBus: 0)
guard tapFormat.sampleRate > 0 else { fail("input device has no valid format (sampleRate 0)") }

guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: targetRate,
                                       channels: targetChannels,
                                       interleaved: true),
      let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
    fail("could not create converter from \(tapFormat) to \(targetRate) Hz / \(targetChannels) ch S16LE")
}

let stdoutHandle = FileHandle.standardOutput
let rateRatio = targetRate / tapFormat.sampleRate

inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * rateRatio) + 1024
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

    var consumed = false
    var convError: NSError?
    let status = converter.convert(to: outBuffer, error: &convError) { _, inStatus in
        if consumed { inStatus.pointee = .noDataNow; return nil }
        consumed = true
        inStatus.pointee = .haveData
        return buffer
    }
    guard status != .error, outBuffer.frameLength > 0 else { return }

    let abl = UnsafeMutableAudioBufferListPointer(outBuffer.mutableAudioBufferList)
    let audioBuffer = abl[0]
    guard let data = audioBuffer.mData else { return }
    stdoutHandle.write(Data(bytes: data, count: Int(audioBuffer.mDataByteSize)))
}

do {
    try engine.start()
    note("capturing '\(deviceName ?? "default")' (\(tapFormat.sampleRate) Hz, \(tapFormat.channelCount) ch) → \(Int(targetRate)) Hz / \(targetChannels) ch S16LE")
} catch {
    fail("engine.start() failed: \(error)")
}

dispatchMain()
