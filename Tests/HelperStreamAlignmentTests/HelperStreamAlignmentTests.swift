import XCTest

/// Regression tests for the "alternating speech and static" bug in a
/// ControlBooth → AntennaHead broadcast.
///
/// The stream-processing helpers read stdin with `FileHandle.availableData`,
/// which only lands on a frame boundary when the upstream stage writes
/// frame-aligned blocks. `PCMUDPReceiver` does not: it writes each UDP
/// datagram payload verbatim, and `PCMUDPSender` chops its input into
/// assorted ≤2048-byte datagrams, so a downstream read routinely ends 1–3
/// bytes into a 4-byte S16LE stereo frame. Helpers that processed
/// `chunk.count / bytesPerFrame` frames and discarded the remainder shifted
/// every later sample by an odd byte count — full-scale white-noise static.
///
/// Each test runs a helper twice on the same PCM: once fed directly in a
/// single write (the frame-aligned "golden"), once fed through a real
/// `PCMUDPSender | PCMUDPReceiver` hop (the arrangement that exposed the
/// bug). The outputs must match. Before the fix the piped run came out
/// shorter and full of hash.
final class HelperStreamAlignmentTests: XCTestCase {

    // MARK: Locating the built helpers

    /// The directory `swift test` drops product binaries into (next to the
    /// `.xctest` bundle). `swift test` builds every product in the package
    /// before running tests, so the helpers are already here.
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

    // MARK: Running a helper

    /// Feeds `input` straight to `helper args` in one write; returns stdout.
    private func runDirect(_ helper: URL, _ args: [String], input: Data) throws -> Data {
        let process = Process()
        process.executableURL = helper
        process.arguments = args
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        DispatchQueue(label: "stdin").async {
            stdinPipe.fileHandleForWriting.write(input)
            try? stdinPipe.fileHandleForWriting.close()
        }
        let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(helper.lastPathComponent) exited \(process.terminationStatus)")
        return out
    }

    /// Feeds `input` to `helper args` through a live
    /// `PCMUDPSender --port P | (udp) | PCMUDPReceiver --port P` hop, so the
    /// helper sees exactly the ragged, frame-straddling writes it gets in a
    /// real ControlBooth → AntennaHead pipeline. Returns the helper's stdout.
    private func runOverUDPHop(_ helper: URL, _ args: [String], input: Data, port: UInt16) throws -> Data {
        let sender = try helperURL("PCMUDPSender")
        let receiver = try helperURL("PCMUDPReceiver")

        let rx = Process()
        rx.executableURL = receiver
        rx.arguments = ["--port", String(port), "--bind", "127.0.0.1"]
        let rxOut = Pipe()
        rx.standardOutput = rxOut
        rx.standardError = FileHandle.nullDevice

        let dsp = Process()
        dsp.executableURL = helper
        dsp.arguments = args
        dsp.standardInput = rxOut          // receiver stdout → helper stdin
        let dspOut = Pipe()
        dsp.standardOutput = dspOut
        dsp.standardError = FileHandle.nullDevice

        try rx.run()
        try dsp.run()
        Thread.sleep(forTimeInterval: 0.3)   // let the receiver bind before we send

        let tx = Process()
        tx.executableURL = sender
        tx.arguments = ["--host", "127.0.0.1", "--port", String(port)]
        let txIn = Pipe()
        tx.standardInput = txIn
        tx.standardError = FileHandle.nullDevice
        try tx.run()

        // Light pacing in deliberately odd-sized writes: well under the UDP
        // receive buffer (nothing is dropped), but PCMUDPSender then emits a
        // trailing sub-2048 datagram per write whose length is not a multiple
        // of the 4-byte frame — exactly what makes a downstream read end
        // mid-frame. A round-number step (e.g. 4096) would split into all
        // 2048-byte datagrams and never trigger the bug.
        let feedSteps = [4093, 1021, 2731, 677, 3583]
        DispatchQueue(label: "feed").async {
            var offset = 0
            var i = 0
            while offset < input.count {
                let n = min(feedSteps[i % feedSteps.count], input.count - offset)
                txIn.fileHandleForWriting.write(input.subdata(in: offset ..< offset + n))
                offset += n
                i += 1
                Thread.sleep(forTimeInterval: 0.001)
            }
            try? txIn.fileHandleForWriting.close()
        }

        // Drain the helper's stdout on a background queue while we wait.
        var captured = Data()
        let drain = DispatchQueue(label: "drain")
        let done = DispatchSemaphore(value: 0)
        drain.async {
            let h = dspOut.fileHandleForReading
            while case let d = h.availableData, !d.isEmpty { captured.append(d) }
            done.signal()
        }

        tx.waitUntilExit()
        // Sender is done → drain the socket, then tear the receiver down so the
        // helper sees EOF and flushes.
        Thread.sleep(forTimeInterval: 0.3)
        rx.terminate()
        dsp.waitUntilExit()
        _ = done.wait(timeout: .now() + 5)
        return captured
    }

    // MARK: Test signal

    /// `frames` of interleaved S16LE stereo: a smooth low tone whose
    /// adjacent-sample delta stays small, so post-processing hash is obvious.
    private func stereoTone(frames: Int, hz: Double = 220, amplitude: Double = 0.4) -> Data {
        var data = Data(capacity: frames * 4)
        let step = 2.0 * Double.pi * hz / 48_000.0
        for n in 0 ..< frames {
            let l = Int16((sin(Double(n) * step) * amplitude * 32_767).rounded())
            let r = Int16((sin(Double(n) * step + 0.5) * amplitude * 32_767).rounded())
            withUnsafeBytes(of: l.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: r.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func maxAdjacentDelta(_ pcm: Data) -> Int {
        pcm.withUnsafeBytes { raw -> Int in
            let s = raw.bindMemory(to: Int16.self)
            var worst = 0
            for i in 1 ..< s.count { worst = max(worst, abs(Int(s[i]) - Int(s[i - 1]))) }
            return worst
        }
    }

    // MARK: Tests
    //
    // The UDP hop trims a little audio at the start (the receiver binds after
    // the first paced write) and end, so these compare the two runs on a
    // common interior window rather than byte-for-byte over the whole stream.

    private func assertMatchesOnOverlap(_ piped: Data, _ golden: Data,
                                        frameBytes: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(piped.count % frameBytes, 0, "piped output is not frame-aligned", file: file, line: line)
        XCTAssertGreaterThan(piped.count, golden.count / 2, "piped output lost too much audio", file: file, line: line)
        // Find where the piped run picks up inside the golden stream, then
        // compare a solid interior span.
        let probeLen = frameBytes * 4_000
        guard piped.count > probeLen * 2, golden.count > probeLen * 2 else {
            return XCTFail("streams too short to compare", file: file, line: line)
        }
        let probe = piped.subdata(in: frameBytes * 500 ..< frameBytes * 500 + probeLen)
        guard let r = golden.range(of: probe) else {
            return XCTFail("piped output does not appear in the golden stream — corrupted", file: file, line: line)
        }
        let span = min(piped.count - frameBytes * 500, golden.count - r.lowerBound) - frameBytes
        XCTAssertGreaterThan(span, frameBytes * 20_000, "overlap window too small", file: file, line: line)
        let a = piped.subdata(in: frameBytes * 500 ..< frameBytes * 500 + span)
        let b = golden.subdata(in: r.lowerBound ..< r.lowerBound + span)
        XCTAssertEqual(a, b, "helper output depends on how stdin is chunked — partial frame dropped", file: file, line: line)
    }

    func test_binauralPanner_udpHopMatchesDirectFeed() throws {
        let helper = try helperURL("PCMBinauralPanner")
        let args = ["--rate", "48000", "--channels", "2",
                    "--azimuth", "0", "--elevation", "0", "--distance", "1.0"]
        let input = stereoTone(frames: 120_000)
        let golden = try runDirect(helper, args, input: input)
        let piped = try runOverUDPHop(helper, args, input: input, port: 53_611)
        assertMatchesOnOverlap(piped, golden, frameBytes: 4)
    }

    func test_fmDeemphasis_udpHopMatchesDirectFeed() throws {
        let helper = try helperURL("FMDeemphasis")
        let args = ["--rate", "48000", "--channels", "2"]
        let input = stereoTone(frames: 120_000)
        let golden = try runDirect(helper, args, input: input)
        let piped = try runOverUDPHop(helper, args, input: input, port: 53_612)
        assertMatchesOnOverlap(piped, golden, frameBytes: 4)
    }

    func test_distanceGain_nonUnityGain_udpHopHasNoStatic() throws {
        let helper = try helperURL("PCMDistanceGain")
        let args = ["--rate", "48000", "--channels", "2", "--distance", "4.0"]
        let input = stereoTone(frames: 120_000)
        let golden = try runDirect(helper, args, input: input)
        let piped = try runOverUDPHop(helper, args, input: input, port: 53_613)
        assertMatchesOnOverlap(piped, golden, frameBytes: 4)
        // The tone's own adjacent-sample delta is a few thousand; a 1–3 byte
        // misalignment reinterprets sample bytes and pushes this near full scale.
        XCTAssertLessThan(maxAdjacentDelta(piped), 6_000, "static: output is byte-misaligned")
    }

    /// LiveAudioRecorder's stdout tee is byte-exact whether or not the
    /// encoder feed is frame-aligned, so this guards the passthrough
    /// specifically — the frame-carry fix is what keeps the *recorded* file's
    /// channels from drifting, which this test does not decode.
    func test_liveAudioRecorder_udpHopPassthroughIsClean() throws {
        let helper = try helperURL("LiveAudioRecorder")
        let aacPath = NSTemporaryDirectory() + "helper-align-\(UUID().uuidString).aac"
        defer { try? FileManager.default.removeItem(atPath: aacPath) }
        let args = ["--rate", "48000", "--channels", "2", "--aac", aacPath]
        let input = stereoTone(frames: 120_000)
        let golden = try runDirect(helper, args, input: input)   // == input (byte-exact tee)
        let piped = try runOverUDPHop(helper, args, input: input, port: 53_614)
        assertMatchesOnOverlap(piped, golden, frameBytes: 4)
    }
}
