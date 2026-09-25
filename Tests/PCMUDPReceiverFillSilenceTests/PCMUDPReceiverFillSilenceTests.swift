import XCTest
#if canImport(Darwin)
import Darwin
#endif

/// `PCMUDPReceiver --fill-silence` must turn a bursty UDP source (dsd-neo only
/// sends decoded voice during a radio call) into a continuous real-time
/// stream: silence while nothing arrives, the burst's bytes unchanged when it
/// does — including when a datagram boundary splits a sample-frame.
final class PCMUDPReceiverFillSilenceTests: XCTestCase {

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

    override func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    /// 8 kHz stereo S16LE: 32 000 bytes per second.
    private let rate = 8_000
    private let bytesPerSecond = 32_000

    /// Distinct, never-zero stereo frames so the burst can be found in the
    /// output and any byte shift shows up.
    private func burst(frames: Int) -> Data {
        var d = Data(capacity: frames * 4)
        for i in 0..<frames {
            let v = UInt16(truncatingIfNeeded: 1_000 + i)
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: (v &+ 7).littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

    private func startReceiver(port: UInt16) throws -> (Process, FileHandle) {
        let process = Process()
        process.executableURL = try helperURL("PCMUDPReceiver")
        process.arguments = ["--port", String(port), "--fill-silence",
                             "--rate", String(rate), "--channels", "2"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, out.fileHandleForReading)
    }

    /// Reads everything the receiver writes for `seconds`.
    private func read(_ handle: FileHandle, for seconds: TimeInterval) -> Data {
        let fd = handle.fileDescriptor
        var collected = Data()
        let deadline = Date().addingTimeInterval(seconds)
        var buf = [UInt8](repeating: 0, count: 65_536)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&pfd, 1, min(waitMs, 50)) > 0 else { continue }
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            collected.append(contentsOf: buf[0..<n])
        }
        return collected
    }

    private func send(_ payloads: [Data], to port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        for payload in payloads {
            _ = payload.withUnsafeBytes { bytes in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    func testIdleOutputIsRealTimeSilence() throws {
        let port: UInt16 = 47_311
        let (process, output) = try startReceiver(port: port)
        defer { process.terminate(); process.waitUntilExit() }

        _ = read(output, for: 0.3)                 // let it settle
        let idle = read(output, for: 1.0)
        XCTAssertGreaterThan(idle.count, bytesPerSecond * 8 / 10, "too little output: not paced in real time")
        XCTAssertLessThan(idle.count, bytesPerSecond * 12 / 10, "too much output: running faster than real time")
        XCTAssertEqual(idle.count % 4, 0, "output not frame-aligned")
        XCTAssertTrue(idle.allSatisfy { $0 == 0 }, "idle output should be silence")
    }

    func testBurstPassesThroughByteExactAcrossSplitFrames() throws {
        let port: UInt16 = 47_312
        let (process, output) = try startReceiver(port: port)
        defer { process.terminate(); process.waitUntilExit() }

        _ = read(output, for: 0.3)
        let audio = burst(frames: 1_600)           // 200 ms
        // Odd-sized datagrams, so two of them split a 4-byte frame.
        let sizes = [1_601, 1_599, 1_602, 1_598]
        var payloads: [Data] = []
        var offset = 0
        for size in sizes {
            payloads.append(audio.subdata(in: offset..<offset + size))
            offset += size
        }
        XCTAssertEqual(offset, audio.count)
        send(payloads, to: port)

        let captured = read(output, for: 0.8)
        guard let range = captured.range(of: audio) else {
            return XCTFail("burst not found intact in \(captured.count) bytes of output")
        }
        XCTAssertEqual(range.lowerBound % 4, 0, "burst starts mid-frame")
        XCTAssertTrue(captured[captured.startIndex..<range.lowerBound].allSatisfy { $0 == 0 },
                      "expected silence before the burst")
        XCTAssertTrue(captured[range.upperBound...].allSatisfy { $0 == 0 },
                      "expected silence after the burst")
    }
}
