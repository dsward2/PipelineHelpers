import XCTest
#if canImport(Darwin)
import Darwin
#endif

/// Tests for `PCMMixer`'s `--duck-input` sidechain ducking (added for the
/// AntennaHead periodic-filler-announcement feature).
///
/// The mixer's input 0 is the clock master (fed here on stdin); input 1 is a
/// UDP input whose FIFO silence-pads on underrun. The sidechain payload is
/// pushed in ahead of the master through a real `PCMUDPSender` hop, lightly
/// paced so nothing overflows the socket buffer, then the master is written in
/// one go — so output frame N lines up with sidechain frame N by byte offset,
/// not wall clock.
///
/// With `--gain 1=0` the sidechain contributes nothing to the mix but still
/// drives the envelope, so the output is purely `master × duckEnvelope` and
/// the attenuation is directly measurable.
final class PCMMixerDuckingTests: XCTestCase {

    // MARK: Locating the built helpers

    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("could not locate the products directory")
    }

    private func helperURL(_ name: String) throws -> URL {
        let url = productsDirectory.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: url.path),
                          "\(name) not built at \(url.path)")
        return url
    }

    // MARK: Signal helpers

    private let rate = 48_000
    private let channels = 2

    /// Interleaved S16LE stereo tone, `seconds` long.
    private func tone(seconds: Double, hz: Double, amplitude: Double) -> Data {
        let frames = Int(seconds * Double(rate))
        var data = Data(capacity: frames * 4)
        let step = 2.0 * Double.pi * hz / Double(rate)
        for n in 0 ..< frames {
            let v = Int16((sin(Double(n) * step) * amplitude * 32_767).rounded())
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func silence(seconds: Double) -> Data {
        Data(count: Int(seconds * Double(rate)) * 4)
    }

    /// RMS (0…1) of the stereo window `[from, to)` seconds of `pcm`.
    private func rms(_ pcm: Data, from: Double, to: Double) -> Double {
        let lo = Int(from * Double(rate)) * channels
        let hi = min(Int(to * Double(rate)) * channels, pcm.count / 2)
        guard hi > lo else { return 0 }
        return pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            var acc = 0.0
            for i in lo ..< hi { let x = Double(s[i]) / 32_768.0; acc += x * x }
            return (acc / Double(hi - lo)).squareRoot()
        }
    }

    override func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)   // a broken pipe must not kill the test runner
    }

    /// Sends `payload` to 127.0.0.1:`port` over UDP in 2048-byte datagrams
    /// (matching PCMUDPSender), paced every few KiB so the mixer's socket
    /// receive buffer never overflows.
    private func sendUDP(_ payload: Data, toPort port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return XCTFail("socket() failed") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return XCTFail("connect() failed: \(String(cString: strerror(errno)))") }
        var offset = 0
        var sinceSleep = 0
        while offset < payload.count {
            let n = min(2_048, payload.count - offset)
            let sent = payload.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), n, 0) }
            XCTAssertEqual(sent, n, "short UDP send: \(String(cString: strerror(errno)))")
            offset += n
            sinceSleep += n
            if sinceSleep >= 8_192 { Thread.sleep(forTimeInterval: 0.002); sinceSleep = 0 }
        }
    }

    // MARK: Running the mixer with a pre-loaded UDP sidechain

    private func runMixer(extraArgs: [String], master: Data, sidechain: Data, port: UInt16) throws -> Data {
        let mixer = try helperURL("PCMMixer")

        let mix = Process()
        mix.executableURL = mixer
        mix.arguments = ["--input", "stdin", "--input", "udp:\(port)"] + extraArgs
        let mixIn = Pipe(), mixOut = Pipe()
        mix.standardInput = mixIn
        mix.standardOutput = mixOut
        mix.standardError = FileHandle.nullDevice
        try mix.run()

        // Drain stdout continuously so the pipe never blocks the mixer.
        var captured = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "drain").async {
            let h = mixOut.fileHandleForReading
            while case let d = h.availableData, !d.isEmpty { captured.append(d) }
            done.signal()
        }

        // Push the whole sidechain in ahead of the master so output frame N
        // lines up with sidechain frame N by byte offset, not wall clock.
        Thread.sleep(forTimeInterval: 0.2)   // let the mixer bind its UDP input
        sendUDP(sidechain, toPort: port)
        Thread.sleep(forTimeInterval: 0.3)   // let the FIFO reader drain the socket

        // Now the master, in one write; its EOF ends the mix.
        mixIn.fileHandleForWriting.write(master)
        try? mixIn.fileHandleForWriting.close()
        mix.waitUntilExit()
        _ = done.wait(timeout: .now() + 5)
        XCTAssertEqual(mix.terminationStatus, 0, "PCMMixer exited \(mix.terminationStatus)")
        return captured
    }

    // MARK: Tests

    /// Loud sidechain in the middle third pulls the master bed down to roughly
    /// `--duck-attenuation`, then it recovers.
    func test_duckInput_attenuatesBedWhileSidechainIsLoud() throws {
        let master = tone(seconds: 2.0, hz: 180, amplitude: 0.5)
        let sidechain = silence(seconds: 0.7) + tone(seconds: 0.6, hz: 900, amplitude: 0.8) + silence(seconds: 0.7)
        let out = try runMixer(
            extraArgs: ["--gain", "1=0", "--rate", "48000", "--channels", "2",
                        "--duck-input", "1", "--duck-threshold", "0.05",
                        "--duck-attenuation", "0.25", "--duck-attack-ms", "40",
                        "--duck-release-ms", "250", "--duck-hold-ms", "150"],
            master: master, sidechain: sidechain, port: 53_701)

        let baseline = rms(out, from: 0.15, to: 0.55)
        let ducked = rms(out, from: 1.05, to: 1.25)
        let recovered = rms(out, from: 1.60, to: 1.95)

        XCTAssertGreaterThan(baseline, 0.2, "bed should be near full level before the sidechain")
        XCTAssertEqual(ducked / baseline, 0.25, accuracy: 0.08,
                       "bed should fall to ~--duck-attenuation while the sidechain is loud")
        XCTAssertGreaterThan(recovered / baseline, 0.8, "bed should recover after the sidechain stops")
    }

    /// The sidechain itself is never ducked: with unity gain on both inputs and
    /// a silent master, the loud middle section passes through at full level.
    func test_duckInput_doesNotDuckTheSidechainItself() throws {
        let master = silence(seconds: 2.0)
        let sidechain = silence(seconds: 0.7) + tone(seconds: 0.6, hz: 900, amplitude: 0.6) + silence(seconds: 0.7)
        let out = try runMixer(
            extraArgs: ["--rate", "48000", "--channels", "2",
                        "--duck-input", "1", "--duck-threshold", "0.05",
                        "--duck-attenuation", "0.1"],
            master: master, sidechain: sidechain, port: 53_702)

        XCTAssertEqual(rms(out, from: 0.9, to: 1.2), 0.6 / 2.0.squareRoot(), accuracy: 0.06,
                       "sidechain passes through un-ducked")
    }

    /// Without `--duck-input` the mix is byte-identical to master+sidechain with
    /// no envelope — a silent-then-loud sidechain at gain 0 leaves the master
    /// bed untouched throughout.
    func test_noDuckInput_bedIsUnchanged() throws {
        let master = tone(seconds: 1.6, hz: 180, amplitude: 0.5)
        let sidechain = silence(seconds: 0.6) + tone(seconds: 0.5, hz: 900, amplitude: 0.9) + silence(seconds: 0.5)
        let out = try runMixer(
            extraArgs: ["--gain", "1=0"],
            master: master, sidechain: sidechain, port: 53_703)

        let before = rms(out, from: 0.15, to: 0.45)
        let during = rms(out, from: 0.75, to: 1.0)
        XCTAssertEqual(during, before, accuracy: 0.02, "no --duck-input ⇒ bed level is flat")
    }
}
