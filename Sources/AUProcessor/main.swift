import AVFoundation
import AudioToolbox
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// AUProcessor — Audio Unit effect stage of an AntennaHead audio pipeline.
//
// Contract:
//   • Input  : S16LE interleaved PCM on stdin at --rate / --channels
//   • Output : the same format on stdout, processed through one Audio Unit
//     effect. Frame counts match 1:1, so the stage is transparent to the
//     pipeline's clocking — upstream (the radio) paces it, exactly like sox.
//   • The AU is hosted in an AVAudioEngine in offline manual-rendering mode;
//     no audio device is touched and no plugin UI is shown. Parameters are
//     controlled headlessly (see below).
//
// Usage: AUProcessor --unit <name | type:subtype:manuf>
//        [--rate <hz>] [--channels <n>]
//        [--param <name>=<value> …] [--preset <path.aupreset>]
//        [--factory-preset <index>] [--control-port <n>]
//        [--out-of-process] [--exit-with-parent]
//        AUProcessor --list-units
//        AUProcessor --unit <spec> --list-params
//
//   --unit            component name (e.g. "AUGraphicEQ") or the three
//                     four-char codes from --list-units (e.g. aufx:eq10:appl)
//   --rate            sample rate in Hz (default 48000, must match neighbors)
//   --channels        channel count (default 2, must match neighbors)
//   --param           set a parameter by identifier or display name; repeatable
//   --preset          load a .aupreset saved from any AU host (GarageBand,
//                     Logic, AU Lab) — the headless route to the plugin's GUI
//   --factory-preset  select one of the unit's built-in presets by index
//   --control-port    UDP port for live commands (see below)
//   --out-of-process  load the AU in a system extension process instead of
//                     in-process (useful for third-party v2 plugins that
//                     clash with library validation; v3 AUs do this anyway)
//   --list-units      print installed effect units and exit
//   --list-params     print the chosen unit's parameters / factory presets
//
// Control port (UDP, one-line ASCII commands, e.g. via `nc -u`):
//   param <name…> <value>   set a parameter (name may contain spaces)
//   params                  reply to the sender with the current values
//   bypass on|off           toggle the effect's bypass
//   preset <path>           load a .aupreset file

let log = FileHandle.standardError
func note(_ message: String) {
    log.write(Data("AUProcessor: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

// MARK: Argument parsing

struct Options {
    var unitSpec: String?
    var sampleRate = 48_000.0
    var channels = 2
    var params: [(name: String, value: Float)] = []
    var presetPath: String?
    var factoryPreset: Int?
    var controlPort: UInt16?
    var outOfProcess = false
    var listUnits = false
    var listParams = false
    var exitWithParent = false
}

func parseArguments() -> Options {
    var o = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--unit":
            i += 1
            guard i < args.count else { fail("Missing value for --unit") }
            o.unitSpec = args[i]
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
        case "--param":
            i += 1
            guard i < args.count else { fail("Missing value for --param") }
            // Task editors may split a spaced name ("Delay Time=0.4") into
            // several arguments; rejoin until the spec ends in =<number>.
            let parsed: (String) -> (name: String, value: Float)? = { spec in
                guard let eq = spec.lastIndex(of: "="), eq != spec.startIndex,
                      let value = Float(spec[spec.index(after: eq)...]) else { return nil }
                return (String(spec[..<eq]), value)
            }
            var spec = args[i]
            while parsed(spec) == nil, i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                i += 1
                spec += " " + args[i]
            }
            guard let (name, value) = parsed(spec) else {
                fail("Invalid --param '\(spec)' (expected <name>=<value>)")
            }
            o.params.append((name, value))
        case "--preset":
            i += 1
            guard i < args.count else { fail("Missing value for --preset") }
            o.presetPath = args[i]
        case "--factory-preset":
            i += 1
            guard i < args.count, let index = Int(args[i]), index >= 0 else {
                fail("Missing or invalid value for --factory-preset (expected an index from --list-params)")
            }
            o.factoryPreset = index
        case "--control-port":
            i += 1
            guard i < args.count, let port = UInt16(args[i]), port > 0 else {
                fail("Missing or invalid value for --control-port")
            }
            o.controlPort = port
        case "--out-of-process":
            o.outOfProcess = true
        case "--list-units":
            o.listUnits = true
        case "--list-params":
            o.listParams = true
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
    guard o.listUnits || o.unitSpec != nil else {
        fail("--unit is required (a name or type:subtype:manuf codes) — try --list-units")
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

// MARK: Four-char code helpers

func fourCCString(_ code: OSType) -> String {
    let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff),
                 UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
    guard bytes.allSatisfy({ (0x20...0x7e).contains($0) }) else {
        return String(format: "0x%08x", code)
    }
    return String(decoding: bytes, as: UTF8.self)
}

func fourCC(_ string: Substring) -> OSType? {
    let bytes = Array(string.utf8)
    guard bytes.count == 4 else { return nil }
    return bytes.reduce(0) { $0 << 8 | OSType($1) }
}

// MARK: Component discovery

/// All installed effect-type Audio Units (plain and music effects).
func effectComponents() -> [AVAudioUnitComponent] {
    AVAudioUnitComponentManager.shared().components { component, _ in
        let type = component.audioComponentDescription.componentType
        return type == kAudioUnitType_Effect || type == kAudioUnitType_MusicEffect
    }
}

func codesSpec(_ description: AudioComponentDescription) -> String {
    "\(fourCCString(description.componentType)):\(fourCCString(description.componentSubType)):\(fourCCString(description.componentManufacturer))"
}

if options.listUnits {
    let components = effectComponents().sorted {
        ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name)
    }
    for component in components {
        print("\(codesSpec(component.audioComponentDescription))  \(component.name)  (\(component.manufacturerName))")
    }
    exit(0)
}

/// Resolves --unit to a component: either exact type:subtype:manuf codes, or
/// a name match (exact first, then substring; ambiguity is an error).
func resolveComponent(_ spec: String) -> AVAudioUnitComponent {
    let parts = spec.split(separator: ":")
    if parts.count == 3, let type = fourCC(parts[0]), let subtype = fourCC(parts[1]),
       let manufacturer = fourCC(parts[2]) {
        let matches = effectComponents().filter {
            let d = $0.audioComponentDescription
            return d.componentType == type && d.componentSubType == subtype
                && d.componentManufacturer == manufacturer
        }
        guard let match = matches.first else { fail("no installed unit matches '\(spec)' — try --list-units") }
        return match
    }
    let wanted = spec.lowercased()
    let components = effectComponents()
    let exact = components.filter { $0.name.lowercased() == wanted }
    if exact.count == 1 { return exact[0] }
    let partial = exact.isEmpty ? components.filter { $0.name.lowercased().contains(wanted) } : exact
    switch partial.count {
    case 0:
        fail("no installed unit matches '\(spec)' — try --list-units")
    case 1:
        return partial[0]
    default:
        note("'\(spec)' is ambiguous; matches:")
        for component in partial {
            note("  \(codesSpec(component.audioComponentDescription))  \(component.name)  (\(component.manufacturerName))")
        }
        exit(1)
    }
}

let component = resolveComponent(options.unitSpec!)

// MARK: Instantiation (pump the run loop until the completion handler fires)

let instantiationLock = NSLock()
var instantiatedUnit: AVAudioUnit?
var instantiationError: Error?
var instantiationDone = false

AVAudioUnit.instantiate(with: component.audioComponentDescription,
                        options: options.outOfProcess ? [.loadOutOfProcess] : []) { unit, error in
    instantiationLock.lock()
    instantiatedUnit = unit
    instantiationError = error
    instantiationDone = true
    instantiationLock.unlock()
}

while true {
    instantiationLock.lock()
    let done = instantiationDone
    instantiationLock.unlock()
    if done { break }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}

guard let effectUnit = instantiatedUnit else {
    fail("could not instantiate \(component.name): \(instantiationError?.localizedDescription ?? "unknown error")")
}

// MARK: Parameters, presets

func allParameters() -> [AUParameter] {
    effectUnit.auAudioUnit.parameterTree?.allParameters ?? []
}

/// Finds a parameter by identifier, display name, or key path, falling back
/// to a display-name prefix match. Matching is case-insensitive and treats
/// underscores as spaces, so a spaced name like "Delay Time" can be written
/// split-proof as "Delay_Time".
func findParameter(_ name: String) -> AUParameter? {
    let canonical: (String) -> String = { $0.lowercased().replacingOccurrences(of: "_", with: " ") }
    let wanted = canonical(name)
    let parameters = allParameters()
    return parameters.first { canonical($0.identifier) == wanted }
        ?? parameters.first { canonical($0.displayName) == wanted }
        ?? parameters.first { canonical($0.keyPath) == wanted }
        ?? parameters.first { canonical($0.displayName).hasPrefix(wanted) }
}

/// Sets a parameter, clamping to its published range. `orFail` distinguishes
/// launch arguments (typos should abort) from control-port commands.
func applyParameter(name: String, value: Float, orFail: Bool) {
    guard let parameter = findParameter(name) else {
        if orFail { fail("no parameter matching '\(name)' — try --list-params") }
        note("no parameter matching '\(name)' — ignoring")
        return
    }
    let clamped = min(max(value, parameter.minValue), parameter.maxValue)
    parameter.value = clamped
    note("param \"\(parameter.displayName)\" = \(clamped)"
         + (clamped == value ? "" : " (clamped from \(value))"))
}

func loadPreset(path: String, orFail: Bool) {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let state = plist as? [String: Any] else {
            throw NSError(domain: "AUProcessor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "not a plist dictionary"])
        }
        effectUnit.auAudioUnit.fullState = state
        note("loaded preset \(path)")
    } catch {
        if orFail { fail("could not load preset '\(path)': \(error.localizedDescription)") }
        note("could not load preset '\(path)': \(error.localizedDescription)")
    }
}

if options.listParams {
    print("\(component.name)  (\(component.manufacturerName))  \(codesSpec(component.audioComponentDescription))")
    print("")
    print("Parameters (set with --param <name>=<value>; write spaces in names as underscores):")
    let parameters = allParameters()
    if parameters.isEmpty {
        print("  (none published)")
    }
    for parameter in parameters {
        var line = "  \"\(parameter.displayName)\"  \(parameter.minValue)…\(parameter.maxValue)"
        if let unitName = parameter.unitName, !unitName.isEmpty { line += " \(unitName)" }
        line += "  (current \(parameter.value))"
        print(line)
        if let strings = parameter.valueStrings, !strings.isEmpty {
            print("      values: \(strings.enumerated().map { "\($0.offset)=\($0.element)" }.joined(separator: ", "))")
        }
    }
    if let presets = effectUnit.auAudioUnit.factoryPresets, !presets.isEmpty {
        print("")
        print("Factory presets (set with --factory-preset <index>):")
        for preset in presets {
            print("  \(preset.number)  \(preset.name)")
        }
    }
    exit(0)
}

if let path = options.presetPath {
    loadPreset(path: path, orFail: true)
}

if let index = options.factoryPreset {
    guard let presets = effectUnit.auAudioUnit.factoryPresets,
          let preset = presets.first(where: { $0.number == index }) else {
        fail("no factory preset \(index) — try --list-params")
    }
    effectUnit.auAudioUnit.currentPreset = preset
    note("factory preset \(preset.number): \(preset.name)")
}

for (name, value) in options.params {
    applyParameter(name: name, value: value, orFail: true)
}

// MARK: Engine setup — offline manual rendering, stdin as the input node
//
// inputNode → effect → mainMixer(→ output). In manual rendering mode the
// input node pulls from our block instead of a device, and renderOffline
// delivers into a buffer instead of a device — the process never touches
// audio hardware.

let channelCount = options.channels
let bytesPerFrame = channelCount * MemoryLayout<Int16>.size
let maxFrames: AVAudioFrameCount = 4_096

guard let processingFormat = AVAudioFormat(standardFormatWithSampleRate: options.sampleRate,
                                           channels: AVAudioChannelCount(channelCount)) else {
    fail("could not create a \(Int(options.sampleRate)) Hz / \(channelCount) ch format")
}

let engine = AVAudioEngine()
do {
    try engine.enableManualRenderingMode(.offline, format: processingFormat,
                                         maximumFrameCount: maxFrames)
} catch {
    fail("could not enable manual rendering: \(error.localizedDescription)")
}

engine.attach(effectUnit)
engine.connect(engine.inputNode, to: effectUnit, format: processingFormat)
engine.connect(effectUnit, to: engine.mainMixerNode, format: processingFormat)

guard let pendingBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: maxFrames),
      let sliceBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: maxFrames),
      let renderedBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: maxFrames) else {
    fail("could not allocate render buffers")
}

// The engine may pull the block's input in slices smaller than one render
// call, so serve from `pendingBuffer` at a moving offset.
var pendingOffset = 0

let inputBlockAccepted = engine.inputNode.setManualRenderingInputPCMFormat(processingFormat) { requestedFrames in
    let available = Int(pendingBuffer.frameLength) - pendingOffset
    let count = min(Int(requestedFrames), available)
    guard count > 0 else { return nil }
    for channel in 0..<channelCount {
        sliceBuffer.floatChannelData![channel]
            .update(from: pendingBuffer.floatChannelData![channel] + pendingOffset, count: count)
    }
    sliceBuffer.frameLength = AVAudioFrameCount(count)
    pendingOffset += count
    return UnsafePointer(sliceBuffer.mutableAudioBufferList)
}
guard inputBlockAccepted else { fail("input node rejected the manual rendering format") }

do {
    try engine.start()
} catch {
    fail("could not start engine: \(error.localizedDescription)")
}

// MARK: Control port (param / params / bypass / preset commands)

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
        let bufferSize = 4_096
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
                case "param" where words.count >= 3:
                    // The name may contain spaces; the last word is the value.
                    if let value = Float(words.last!) {
                        let name = words[1..<(words.count - 1)].joined(separator: " ")
                        applyParameter(name: name, value: value, orFail: false)
                    } else {
                        note("control: bad value in '\(line)'")
                    }
                case "params":
                    let reply = allParameters()
                        .map { "\"\($0.displayName)\"=\($0.value)" }
                        .joined(separator: "\n") + "\n"
                    _ = reply.withCString { cString in
                        withUnsafePointer(to: &sender) { rawSender in
                            rawSender.withMemoryRebound(to: sockaddr.self, capacity: 1) { senderAddr in
                                sendto(fd, cString, strlen(cString), 0, senderAddr, senderLen)
                            }
                        }
                    }
                case "bypass" where words.count == 2:
                    let on = ["on", "1", "true"].contains(words[1].lowercased())
                    effectUnit.auAudioUnit.shouldBypassEffect = on
                    note("control: bypass \(on ? "on" : "off")")
                case "preset" where words.count >= 2:
                    loadPreset(path: words[1...].joined(separator: " "), orFail: false)
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

// MARK: S16LE ↔ Float32 conversion

/// Deinterleaves whole S16LE frames into `pendingBuffer` as Float32.
func fillPending(from data: Data) {
    let frames = data.count / bytesPerFrame
    data.withUnsafeBytes { raw in
        let samples = raw.bindMemory(to: Int16.self)
        for channel in 0..<channelCount {
            let destination = pendingBuffer.floatChannelData![channel]
            var index = channel
            for frame in 0..<frames {
                destination[frame] = Float(samples[index]) / 32_768.0
                index += channelCount
            }
        }
    }
    pendingBuffer.frameLength = AVAudioFrameCount(frames)
}

/// Interleaves `renderedBuffer` back to S16LE with saturation.
func s16Data(from buffer: AVAudioPCMBuffer) -> Data {
    let frames = Int(buffer.frameLength)
    var out = Data(count: frames * bytesPerFrame)
    out.withUnsafeMutableBytes { raw in
        let samples = raw.bindMemory(to: Int16.self)
        for channel in 0..<channelCount {
            let source = buffer.floatChannelData![channel]
            var index = channel
            for frame in 0..<frames {
                let scaled = (source[frame] * 32_767.0).rounded()
                samples[index] = Int16(min(max(scaled, -32_768.0), 32_767.0))
                index += channelCount
            }
        }
    }
    return out
}

// MARK: Output

signal(SIGPIPE, SIG_IGN)

func writeStdout(_ data: Data) {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let written = write(1, base + offset, data.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                note("stdout closed (\(String(cString: strerror(errno)))); exiting")
                exit(0)
            }
            offset += written
        }
    }
}

// MARK: Process loop
//
// Read stdin, carve into ≤ maxFrames blocks of whole frames, render each
// through the engine, and write the same number of frames downstream.

note("started — \(component.name) (\(component.manufacturerName)), "
     + "\(Int(options.sampleRate)) Hz \(channelCount) ch, stdin → stdout"
     + (options.controlPort.map { ", control port \($0)" } ?? ""))

let stdinHandle = FileHandle.standardInput
var carry = Data()

while true {
    let chunk = stdinHandle.availableData
    if chunk.isEmpty { break }   // EOF: upstream closed.
    carry.append(chunk)

    let wholeFrames = carry.count / bytesPerFrame
    guard wholeFrames > 0 else { continue }

    var frameOffset = 0
    while frameOffset < wholeFrames {
        let frames = min(wholeFrames - frameOffset, Int(maxFrames))
        // Data keeps its indices after removeFirst, so range from startIndex.
        let byteStart = carry.startIndex + frameOffset * bytesPerFrame
        fillPending(from: carry.subdata(in: byteStart..<(byteStart + frames * bytesPerFrame)))
        pendingOffset = 0

        do {
            let status = try engine.renderOffline(AVAudioFrameCount(frames), to: renderedBuffer)
            guard status == .success else { fail("render failed with status \(status.rawValue)") }
        } catch {
            fail("render failed: \(error.localizedDescription)")
        }

        writeStdout(s16Data(from: renderedBuffer))
        frameOffset += frames
    }
    carry.removeFirst(wholeFrames * bytesPerFrame)
}

note("stdin closed — exiting")
