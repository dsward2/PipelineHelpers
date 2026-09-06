import XCTest
#if canImport(Darwin)
import Darwin
#endif

/// `PCMUDPSender` must never split an S16 sample-frame across a datagram
/// boundary.
///
/// Before the fix it chopped each `availableData` read into ≤2048-byte
/// datagrams, so a stdin chunk whose size was not a multiple of the frame
/// (e.g. `sox` writing in an odd `--buffer`) produced an odd-length trailing
/// datagram. Any UDP reordering or loss on the hop then shifted every later
/// sample by one byte — full-scale broadband static downstream (this is what
/// turned the first filler announcement into ~2 s of hash). With `--frame-bytes`
/// (default 4) the trailing 1…N−1 bytes are carried into the next datagram, so
/// a reorder/loss can only ever shift by whole frames.
final class PCMUDPSenderFramingTests: XCTestCase {

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

    /// An ascending 16-bit ramp — any 1-byte shift is instantly visible as a
    /// low/high-byte swap.
    private func ramp(bytes: Int) -> Data {
        var d = Data(capacity: bytes)
        var v: UInt16 = 0
        while d.count < bytes {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
            v &+= 1
        }
        return d.prefix(bytes)
    }

    /// Runs `PCMUDPSender --port <P> [extra]`, feeds `writes` to its stdin in
    /// exactly those chunk sizes, and returns every datagram received on P (in
    /// order — one local socket, no real reordering) plus their byte lengths.
    private func capture(port: UInt16, extraArgs: [String], writes: [Data]) throws -> (datagrams: [Data], lengths: [Int]) {
        let sender = try helperURL("PCMUDPSender")

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var big: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0, "bind: \(String(cString: strerror(errno)))")

        var datagrams = [Data]()
        let recvDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "recv").async {
            let buf = UnsafeMutableRawPointer.allocate(byteCount: 65_536, alignment: 1)
            defer { buf.deallocate() }
            var idleReads = 0
            while idleReads < 20 {   // stop after ~1s with no datagrams
                var tv = timeval(tv_sec: 0, tv_usec: 50_000)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                let n = recv(fd, buf, 65_536, 0)
                if n > 0 { datagrams.append(Data(bytes: buf, count: n)); idleReads = 0 }
                else { idleReads += 1 }
            }
            recvDone.signal()
        }

        let proc = Process()
        proc.executableURL = sender
        proc.arguments = ["--port", "\(port)", "--host", "127.0.0.1"] + extraArgs
        let stdin = Pipe()
        proc.standardInput = stdin
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        Thread.sleep(forTimeInterval: 0.2)

        for w in writes {
            stdin.fileHandleForWriting.write(w)
            Thread.sleep(forTimeInterval: 0.01)
        }
        try? stdin.fileHandleForWriting.close()
        proc.waitUntilExit()
        _ = recvDone.wait(timeout: .now() + 5)
        XCTAssertEqual(proc.terminationStatus, 0, "PCMUDPSender exited \(proc.terminationStatus)")
        return (datagrams, datagrams.map(\.count))
    }

    /// Odd-sized stdin reads must still yield only whole-frame (÷4) datagrams,
    /// and the byte stream must be preserved exactly.
    func test_defaultAlignment_datagramsAreWholeFrames_andStreamIsExact() throws {
        // Sizes deliberately not multiples of 4; total (2205+999+4097+1+3 = 7305)
        // is also not ÷4, so one leftover byte must be flushed at EOF.
        let writeSizes = [2205, 999, 4097, 1, 3]
        let input = ramp(bytes: writeSizes.reduce(0, +))
        var offset = 0
        let writes = writeSizes.map { n -> Data in defer { offset += n }; return input.subdata(in: offset ..< offset + n) }

        let (datagrams, lengths) = try capture(port: 53_811, extraArgs: [], writes: writes)

        XCTAssertFalse(datagrams.isEmpty, "no datagrams received")
        // Every datagram except possibly the final EOF-flush is a whole number
        // of 4-byte frames.
        for (i, len) in lengths.enumerated() where i < lengths.count - 1 {
            XCTAssertEqual(len % 4, 0, "datagram \(i) is \(len) bytes — splits a frame")
            XCTAssertLessThanOrEqual(len, 2048, "datagram \(i) exceeds the 2048-byte cap")
        }
        // Nothing lost or duplicated over the (single, ordered) socket.
        XCTAssertEqual(Data(datagrams.joined()), input, "byte stream not preserved")
    }

    /// The same ragged feed with a frame-aligned total leaves no straggler —
    /// then *every* datagram is ÷4.
    func test_defaultAlignment_frameAlignedTotal_allDatagramsWholeFrames() throws {
        let writeSizes = [2205, 999, 4096, 4]   // sum 7304, ÷4
        let input = ramp(bytes: writeSizes.reduce(0, +))
        var offset = 0
        let writes = writeSizes.map { n -> Data in defer { offset += n }; return input.subdata(in: offset ..< offset + n) }

        let (datagrams, lengths) = try capture(port: 53_812, extraArgs: [], writes: writes)
        XCTAssertFalse(datagrams.isEmpty)
        for (i, len) in lengths.enumerated() {
            XCTAssertEqual(len % 4, 0, "datagram \(i) is \(len) bytes — splits a frame")
        }
        XCTAssertEqual(Data(datagrams.joined()), input)
    }

    /// `--frame-bytes 1` restores the pre-fix behaviour: an odd-sized read
    /// produces an odd-length datagram.
    func test_frameBytes1_allowsOddDatagrams() throws {
        let input = ramp(bytes: 999)
        let (datagrams, lengths) = try capture(port: 53_813, extraArgs: ["--frame-bytes", "1"], writes: [input])
        XCTAssertEqual(Data(datagrams.joined()), input)
        XCTAssertTrue(lengths.contains { $0 % 2 != 0 }, "expected an odd-length datagram with --frame-bytes 1")
    }
}
