import Foundation
#if canImport(Darwin)
import Darwin
#endif

// PCMMixer — N-input PCM mixing stage of an AntennaHead audio pipeline.
//
// Contract:
//   • Inputs : two or more S16LE PCM streams, each from stdin or a UDP port.
//     All inputs must share the same sample rate and channel count (normalize
//     upstream with sox); mixing is sample-wise with Int16 saturation.
//   • Output : the mixed stream, to stdout (default) or a UDP destination.
//   • Input 0 is the CLOCK MASTER: its read pace drives the output. The other
//     inputs are buffered on reader threads and contribute whatever has
//     arrived — silence on underrun, oldest bytes dropped on overflow — so
//     unsynchronized sources can't stall the pipeline.
//
// Usage: PCMMixer --input stdin --input udp:<port> [--input udp:<port> …]
//        [--output udp:<host>:<port>] [--control-port <n>]
//        [--gain <i>=<g> …] [--ratio <0..1>] [--exit-with-parent]
//
// Control port (UDP, one-line ASCII commands, e.g. via `nc -u`):
//   ratio <0..1>     crossfade inputs 0/1 (gain0 = 1−r, gain1 = r)
//   gain <i> <g>     set input i's gain (g ≥ 0; > 1 amplifies)
//   gains            reply to the sender with the current gain list
//
// sox `-m` mixes with volumes fixed at launch; this helper exists for the
// dynamic control.

let log = FileHandle.standardError
func note(_ message: String) {
    log.write(Data("PCMMixer: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    note(message)
    exit(1)
}

// MARK: Argument parsing

enum InputSource {
    case stdin
    case udp(UInt16)

    var label: String {
        switch self {
        case .stdin: return "stdin"
        case .udp(let port): return "udp:\(port)"
        }
    }
}

struct Options {
    var inputs: [InputSource] = []
    var outputUDP: (host: String, port: UInt16)?   // nil = stdout
    var controlPort: UInt16?
    var initialGains: [Int: Double] = [:]
    var initialRatio: Double?
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
                o.inputs.append(.stdin)
            } else if value.hasPrefix("udp:"), let port = UInt16(value.dropFirst(4)), port > 0 {
                o.inputs.append(.udp(port))
            } else {
                fail("Invalid --input '\(value)' (expected 'stdin' or 'udp:<port>')")
            }
        case "--output":
            i += 1
            guard i < args.count else { fail("Missing value for --output") }
            let value = args[i]
            if value == "stdout" {
                o.outputUDP = nil
            } else if value.hasPrefix("udp:") {
                let parts = value.dropFirst(4).split(separator: ":")
                guard parts.count == 2, let port = UInt16(parts[1]), port > 0 else {
                    fail("Invalid --output '\(value)' (expected 'stdout' or 'udp:<host>:<port>')")
                }
                o.outputUDP = (String(parts[0]), port)
            } else {
                fail("Invalid --output '\(value)' (expected 'stdout' or 'udp:<host>:<port>')")
            }
        case "--control-port":
            i += 1
            guard i < args.count, let port = UInt16(args[i]), port > 0 else {
                fail("Missing or invalid value for --control-port")
            }
            o.controlPort = port
        case "--gain":
            i += 1
            guard i < args.count else { fail("Missing value for --gain") }
            let parts = args[i].split(separator: "=")
            guard parts.count == 2, let index = Int(parts[0]), let gain = Double(parts[1]), gain >= 0 else {
                fail("Invalid --gain '\(args[i])' (expected <index>=<gain>)")
            }
            o.initialGains[index] = gain
        case "--ratio":
            i += 1
            guard i < args.count, let ratio = Double(args[i]), (0.0...1.0).contains(ratio) else {
                fail("Missing or invalid value for --ratio (expected 0..1)")
            }
            o.initialRatio = ratio
        case "--exit-with-parent":
            o.exitWithParent = true
        default:
            fail("Unknown argument '\(args[i])'")
        }
        i += 1
    }
    guard o.inputs.count >= 2 else { fail("At least two --input sources are required") }
    guard o.inputs.filter({ if case .stdin = $0 { return true } else { return false } }).count <= 1 else {
        fail("Only one --input may be stdin")
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

// MARK: Gain table (shared with the control-port thread)

final class GainTable: @unchecked Sendable {
    private var gains: [Double]
    private let lock = NSLock()

    init(count: Int, initialGains: [Int: Double], initialRatio: Double?) {
        gains = [Double](repeating: 1.0, count: count)
        if let ratio = initialRatio, count >= 2 {
            gains[0] = 1.0 - ratio
            gains[1] = ratio
        }
        for (index, gain) in initialGains where gains.indices.contains(index) {
            gains[index] = gain
        }
    }

    func snapshot() -> [Double] {
        lock.lock(); defer { lock.unlock() }
        return gains
    }

    func set(index: Int, gain: Double) {
        lock.lock(); defer { lock.unlock() }
        guard gains.indices.contains(index), gain >= 0 else { return }
        gains[index] = gain
    }

    func setRatio(_ ratio: Double) {
        lock.lock(); defer { lock.unlock() }
        guard gains.count >= 2 else { return }
        let r = min(max(ratio, 0), 1)
        gains[0] = 1.0 - r
        gains[1] = r
    }
}

let gainTable = GainTable(count: options.inputs.count,
                          initialGains: options.initialGains,
                          initialRatio: options.initialRatio)

// MARK: Byte FIFO for the non-master inputs

final class ByteFIFO: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    /// ~5 s of 48 kHz stereo S16LE; beyond this the oldest audio is dropped.
    private let capacity = 1_000_000

    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(bytes)
        if data.count > capacity {
            data.removeFirst(data.count - capacity)
        }
    }

    /// Pops exactly `count` bytes, zero-padding (silence) on underrun.
    func pop(_ count: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        if data.count >= count {
            let out = Data(data.prefix(count))
            data.removeFirst(count)
            return out
        }
        var out = data
        out.append(Data(count: count - data.count))
        data.removeAll(keepingCapacity: true)
        return out
    }
}

// MARK: UDP socket helpers

func boundUDPSocket(port: UInt16, purpose: String) -> Int32 {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { fail("socket() for \(purpose) failed: \(String(cString: strerror(errno)))") }
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
    guard result == 0 else { fail("bind() \(purpose) to port \(port) failed: \(String(cString: strerror(errno)))") }
    return fd
}

func connectedUDPSocket(host: String, port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { fail("socket() for output failed: \(String(cString: strerror(errno)))") }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { fail("invalid output host '\(host)'") }
    let result = withUnsafePointer(to: &addr) { rawAddr in
        rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
            connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else { fail("connect() to \(host):\(port) failed: \(String(cString: strerror(errno)))") }
    return fd
}

// MARK: Control port (ratio / gain / gains commands)

func startControlListener(port: UInt16) {
    let fd = boundUDPSocket(port: port, purpose: "control")
    Thread.detachNewThread {
        let bufferSize = 1024
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
                case "ratio" where words.count == 2:
                    if let ratio = Double(words[1]) {
                        gainTable.setRatio(ratio)
                        note("control: ratio \(ratio) → gains \(gainTable.snapshot())")
                    }
                case "gain" where words.count == 3:
                    if let index = Int(words[1]), let gain = Double(words[2]) {
                        gainTable.set(index: index, gain: gain)
                        note("control: gain \(index) = \(gain)")
                    }
                case "gains":
                    let reply = "gains " + gainTable.snapshot().map { "\($0)" }.joined(separator: " ") + "\n"
                    _ = reply.withCString { cString in
                        withUnsafePointer(to: &sender) { rawSender in
                            rawSender.withMemoryRebound(to: sockaddr.self, capacity: 1) { senderAddr in
                                sendto(fd, cString, strlen(cString), 0, senderAddr, senderLen)
                            }
                        }
                    }
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

// MARK: Reader threads for the non-master inputs

let fifos: [ByteFIFO?] = options.inputs.enumerated().map { index, input in
    guard index > 0 else { return nil }   // input 0 is read inline by the mix loop
    let fifo = ByteFIFO()
    switch input {
    case .stdin:
        Thread.detachNewThread {
            let stdinHandle = FileHandle.standardInput
            while true {
                let chunk = stdinHandle.availableData
                if chunk.isEmpty { note("stdin input ended"); return }
                fifo.append(chunk)
            }
        }
    case .udp(let port):
        let fd = boundUDPSocket(port: port, purpose: "input \(index)")
        Thread.detachNewThread {
            let bufferSize = 65_536
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
            while true {
                let received = recv(fd, buffer, bufferSize, 0)
                if received <= 0 {
                    if received < 0 && errno == EINTR { continue }
                    continue
                }
                fifo.append(Data(bytes: buffer, count: received))
            }
        }
    }
    return fifo
}

// MARK: Master input + output setup

let masterUDPSocket: Int32?
switch options.inputs[0] {
case .stdin:
    masterUDPSocket = nil
case .udp(let port):
    masterUDPSocket = boundUDPSocket(port: port, purpose: "input 0 (clock master)")
}

let outputUDPSocket: Int32? = options.outputUDP.map { connectedUDPSocket(host: $0.host, port: $0.port) }

// Exiting on a dead downstream reader is handled in the write path.
signal(SIGPIPE, SIG_IGN)

/// Sends the mixed bytes downstream. UDP datagrams are capped at 2048 bytes
/// (matching PCMUDPSender); stdout gets the chunk as-is.
func writeOutput(_ data: Data) {
    if let fd = outputUDPSocket {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let length = min(2048, data.count - offset)
                if send(fd, base + offset, length, 0) < 0 {
                    note("send() failed: \(String(cString: strerror(errno))); exiting")
                    exit(1)
                }
                offset += length
            }
        }
    } else {
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
}

// MARK: Mix loop
//
// Read a chunk from input 0, pop the same byte count from every other input's
// FIFO (silence-padded), apply gains, saturate, and write downstream.

let inputLabels = options.inputs.map(\.label).joined(separator: ", ")
note("started — mixing [\(inputLabels)] → \(options.outputUDP.map { "udp:\($0.host):\($0.port)" } ?? "stdout")"
     + (options.controlPort.map { ", control port \($0)" } ?? ""))

let masterBufferSize = 65_536
let masterBuffer = UnsafeMutableRawPointer.allocate(byteCount: masterBufferSize, alignment: 1)
var oddByteCarry = Data()

while true {
    // Read the pacing chunk from input 0.
    var chunk: Data
    if let fd = masterUDPSocket {
        let received = recv(fd, masterBuffer, masterBufferSize, 0)
        if received < 0 {
            if errno == EINTR { continue }
            fail("recv() on input 0 failed: \(String(cString: strerror(errno)))")
        }
        if received == 0 { continue }
        chunk = Data(bytes: masterBuffer, count: received)
    } else {
        chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { break }   // EOF: upstream closed.
    }

    // Keep S16 alignment: carry a trailing odd byte into the next chunk.
    if !oddByteCarry.isEmpty {
        chunk = oddByteCarry + chunk
        oddByteCarry.removeAll()
    }
    if chunk.count % 2 != 0 {
        oddByteCarry = chunk.suffix(1)
        chunk = chunk.dropFirst(0).prefix(chunk.count - 1)
    }
    if chunk.isEmpty { continue }

    let sampleCount = chunk.count / 2
    let gains = gainTable.snapshot()

    // Accumulate gained samples in Int32, master first, then each FIFO.
    var acc = [Int32](repeating: 0, count: sampleCount)
    func accumulate(_ data: Data, gain: Double) {
        guard gain != 0 else { return }
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for s in 0..<min(samples.count, sampleCount) {
                acc[s] += Int32((Double(samples[s]) * gain).rounded())
            }
        }
    }
    accumulate(chunk, gain: gains[0])
    for (index, fifo) in fifos.enumerated() {
        guard let fifo else { continue }
        accumulate(fifo.pop(chunk.count), gain: gains[index])
    }

    // Saturate to Int16 and write downstream.
    var mixed = Data(count: chunk.count)
    mixed.withUnsafeMutableBytes { raw in
        let out = raw.bindMemory(to: Int16.self)
        for s in 0..<sampleCount {
            out[s] = Int16(clamping: acc[s])
        }
    }
    writeOutput(mixed)
}

note("input 0 closed — exiting")
