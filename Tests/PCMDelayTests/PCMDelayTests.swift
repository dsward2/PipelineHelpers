import XCTest
import Darwin

/// End-to-end tests for the PCMDelay helper: spawn the built binary, stream a
/// ramp through it, and check the output sample-for-sample.
///
/// The input is a stereo ramp where frame `i` holds the value `i % 30000 + 1`
/// in both channels — every frame is distinct and non-zero, so any repeated,
/// dropped, or shifted audio is visible in the output, and zero unambiguously
/// means "silence inserted by the delay".
final class PCMDelayTests: XCTestCase {

    private let rate = 8_000            // the helper's minimum; keeps tests fast

    // MARK: Locating the built helper

    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("could not locate the products directory")
    }

    private func helperURL() throws -> URL {
        let url = productsDirectory.appendingPathComponent("PCMDelay")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: url.path),
                          "PCMDelay not built at \(url.path)")
        return url
    }

    // MARK: Signal helpers

    /// `count` ramp frames starting at absolute frame `start`.
    private func ramp(from start: Int, count: Int) -> Data {
        var samples = [Int16]()
        samples.reserveCapacity(count * 2)
        for i in start..<(start + count) {
            let v = Int16(i % 30_000 + 1)
            samples.append(v); samples.append(v)
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Left-channel sample of each frame.
    private func leftChannel(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            return stride(from: 0, to: s.count, by: 2).map { s[$0] }
        }
    }

    // MARK: Running the helper

    /// Runs `PCMDelay args`, lets `drive` write to its stdin (and poke its
    /// control port), and returns everything it wrote to stdout.
    private func runHelper(_ args: [String], drive: (FileHandle) throws -> Void) throws -> Data {
        let process = Process()
        process.executableURL = try helperURL()
        process.arguments = ["--rate", "\(rate)"] + args
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        let collector = Collector()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue(label: "drain").async {
            let h = stdoutPipe.fileHandleForReading
            while case let d = h.availableData, !d.isEmpty { collector.append(d) }
            drained.signal()
        }

        try drive(stdinPipe.fileHandleForWriting)
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        _ = drained.wait(timeout: .now() + 5)
        XCTAssertEqual(process.terminationStatus, 0, "PCMDelay exited \(process.terminationStatus)")
        return collector.data
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    }

    // MARK: UDP control

    /// A loopback UDP socket for talking to the helper's control port.
    private final class ControlClient {
        let fd: Int32
        let port: UInt16
        init(port: UInt16) {
            self.port = port
            fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            var tv = timeval(tv_sec: 0, tv_usec: 100_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        deinit { close(fd) }

        func send(_ text: String) {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
            _ = text.withCString { c in
                withUnsafePointer(to: &addr) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, c, strlen(c), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        /// Sends `delay?` and returns the reply line, or nil on timeout.
        func query() -> String? {
            send("delay?\n")
            var buf = [UInt8](repeating: 0, count: 256)
            let n = recv(fd, &buf, buf.count, 0)
            return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : nil
        }

        /// The helper binds its port after launch; wait until it answers.
        func waitUntilListening() -> Bool {
            for _ in 0..<50 where query() != nil { return true }
            return false
        }
    }

    private func controlPort() -> UInt16 { UInt16(30_000 + Int(getpid()) % 20_000) }

    // MARK: Tests

    func test_zeroDelay_isIdentity() throws {
        let input = ramp(from: 0, count: 4_000)
        let out = try runHelper([]) { $0.write(input) }
        XCTAssertEqual(out, input)
    }

    func test_initialDelay_isLeadingSilenceThenExactCopy() throws {
        let delayFrames = 2_000          // 0.25 s at 8 kHz
        let input = ramp(from: 0, count: 6_000)
        let out = try runHelper(["--delay", "0.25"]) { $0.write(input) }

        XCTAssertEqual(out.count, input.count, "output must stay frame-for-frame with input")
        let left = leftChannel(out)
        XCTAssertTrue(left[0..<delayFrames].allSatisfy { $0 == 0 }, "leading delay must be silence")
        XCTAssertEqual(Array(left[delayFrames...]), Array(leftChannel(input)[..<(6_000 - delayFrames)]),
                       "after the silence, output must equal the input exactly")
    }

    func test_partialFrameWrites_areCarried() throws {
        let input = ramp(from: 0, count: 3_000)
        let out = try runHelper(["--delay", "0.1"]) { h in
            // 7-byte writes: never frame-aligned.
            var offset = 0
            while offset < input.count {
                let end = min(offset + 7, input.count)
                h.write(input.subdata(in: offset..<end))
                offset = end
            }
        }
        let left = leftChannel(out)
        XCTAssertEqual(out.count, input.count)
        XCTAssertEqual(Array(left[800...]), Array(leftChannel(input)[..<(3_000 - 800)]))
    }

    func test_delayLargerThanMax_isRejected() throws {
        let process = Process()
        process.executableURL = try helperURL()
        process.arguments = ["--delay", "10", "--max-delay", "5"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
    }

    func test_liveIncrease_pausesWithoutRepeatingAudio() throws {
        let port = controlPort()
        let client = ControlClient(port: port)
        let first = ramp(from: 0, count: 8_000)          // 1 s at delay 0
        let second = ramp(from: 8_000, count: 16_000)    // 2 s after the change
        var reply: String?

        let out = try runHelper(["--control-port", "\(port)"]) { h in
            XCTAssertTrue(client.waitUntilListening(), "control port never came up")
            h.write(first)
            usleep(200_000)
            client.send("delay 0.25\n")                  // +2000 frames
            usleep(200_000)
            reply = client.query()
            h.write(second)
        }

        XCTAssertEqual(out.count, first.count + second.count)
        let left = leftChannel(out)
        let inLeft = leftChannel(first + second)

        // Once the change has settled, output is the input delayed by 2000.
        let settled = 8_000 + 2_000 + 500
        for j in stride(from: settled, to: left.count, by: 97) {
            XCTAssertEqual(left[j], inLeft[j - 2_000], "frame \(j) is not the input delayed by 250 ms")
        }

        // The pause is real silence roughly as long as the added delay
        // (minus the fade ramps that bracket it) …
        var longestZeroRun = 0, zeros = 0
        for v in left[8_000...] { zeros = v == 0 ? zeros + 1 : 0; longestZeroRun = max(longestZeroRun, zeros) }
        XCTAssertGreaterThan(longestZeroRun, 2_000 - 2 * 240)

        // … and nothing is replayed: away from the fades, the non-silent
        // frames from the gap onward keep the input's strictly rising order.
        let afterGap = left[(8_000 + 500)...].filter { $0 != 0 }
        XCTAssertTrue(zip(afterGap, afterGap.dropFirst()).allSatisfy { $0 < $1 },
                      "audio was repeated or reordered after the delay increased")

        XCTAssertNotNil(reply)
        XCTAssertTrue(reply?.contains("delay=0.25") == true, "unexpected reply: \(reply ?? "nil")")
    }

    func test_liveDecrease_skipsForwardWithoutClicking() throws {
        let port = controlPort()
        let client = ControlClient(port: port)
        let first = ramp(from: 0, count: 8_000)
        let second = ramp(from: 8_000, count: 16_000)

        let out = try runHelper(["--delay", "0.5", "--control-port", "\(port)"]) { h in
            XCTAssertTrue(client.waitUntilListening(), "control port never came up")
            h.write(first)
            usleep(200_000)
            client.send("delay 0.1\n")                   // 4000 → 800 frames
            usleep(200_000)
            h.write(second)
        }

        XCTAssertEqual(out.count, first.count + second.count)
        let left = leftChannel(out)
        let inLeft = leftChannel(first + second)

        let settled = 8_000 + 500
        for j in stride(from: settled, to: left.count, by: 97) {
            XCTAssertEqual(left[j], inLeft[j - 800], "frame \(j) is not the input delayed by 100 ms")
        }

        // No click: the ramp's own slope is 1/frame and a 30 ms fade adds at
        // most ~125/frame, so any bigger step must be to or from silence.
        for j in 1..<left.count {
            let step = abs(Int(left[j]) - Int(left[j - 1]))
            if step > 400 {
                XCTAssertTrue(abs(Int(left[j])) < 400 || abs(Int(left[j - 1])) < 400,
                              "discontinuity of \(step) at frame \(j) with audio on both sides")
            }
        }
    }

    func test_controlValue_isClampedToMax() throws {
        let port = controlPort()
        let client = ControlClient(port: port)
        var reply: String?
        _ = try runHelper(["--max-delay", "2", "--control-port", "\(port)"]) { h in
            XCTAssertTrue(client.waitUntilListening())
            client.send("delay 99\n")
            usleep(100_000)
            reply = client.query()
            h.write(ramp(from: 0, count: 800))
            usleep(100_000)
        }
        XCTAssertTrue(reply?.contains("delay=2.0") == true, "unexpected reply: \(reply ?? "nil")")
        XCTAssertTrue(reply?.contains("max=2.0") == true)
    }
}
