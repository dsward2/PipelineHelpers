import XCTest
import Darwin

/// Regression test for the unbounded frame-carry buffer.
///
/// The stream helpers keep a `var carry = Data()` across their stdin loop,
/// `append`ing each read and dropping the consumed whole frames afterwards.
/// When that drop was `carry.removeFirst(n)`, the `Data` only advanced its
/// slice start index — the consumed prefix's backing allocation was never
/// released, so `append` + `removeFirst` grew the buffer without bound at the
/// input data rate. PCMDistanceGain and PCMBinauralPanner were seen holding
/// 1–3 GB of resident memory after a few hours of live capture, and drove the
/// 16 GB Mac mini to an overnight out-of-memory reboot.
///
/// Each test streams a large volume of PCM through a helper in many small
/// writes and samples the child's `phys_footprint` (the figure Activity
/// Monitor shows — and, unlike RSS, one the memory compressor does not mask).
/// A correct helper holds a near-constant working set no matter how many bytes
/// pass through; the pre-fix code climbed roughly in step with the total fed.
final class HelperMemoryBoundsTests: XCTestCase {

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

    /// `phys_footprint` of a live pid, in bytes, via `proc_pid_rusage`.
    private func physFootprint(of pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return rc == 0 ? info.ri_phys_footprint : nil
    }

    /// Interleaved S16LE stereo silence — content is irrelevant here, only volume.
    private func silence(bytes: Int) -> Data { Data(count: bytes) }

    /// Streams `totalBytes` through `helper args` in `writeSize` chunks while
    /// polling the child's phys_footprint. Returns the peak seen (bytes).
    private func peakFootprintStreaming(_ helper: URL, _ args: [String],
                                        totalBytes: Int, writeSize: Int) throws -> UInt64 {
        let process = Process()
        process.executableURL = helper
        process.arguments = args
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier

        // Drain stdout so the helper never blocks on write.
        let drainDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "drain").async {
            let h = stdoutPipe.fileHandleForReading
            while case let d = h.availableData, !d.isEmpty {}
            drainDone.signal()
        }

        // Feed on a background queue.
        let block = silence(bytes: writeSize)
        let feedDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "feed").async {
            let w = stdinPipe.fileHandleForWriting
            var sent = 0
            while sent < totalBytes {
                w.write(block)
                sent += writeSize
            }
            try? w.close()
            feedDone.signal()
        }

        // Poll footprint until the feed completes, then a couple more times.
        var peak: UInt64 = 0
        while feedDone.wait(timeout: .now() + 0.05) == .timedOut {
            if let f = physFootprint(of: pid) { peak = max(peak, f) }
        }
        for _ in 0..<3 {
            if let f = physFootprint(of: pid) { peak = max(peak, f) }
            usleep(20_000)
        }

        process.waitUntilExit()
        _ = drainDone.wait(timeout: .now() + 5)
        XCTAssertEqual(process.terminationStatus, 0,
                       "\(helper.lastPathComponent) exited \(process.terminationStatus)")
        return peak
    }

    // 256 MB fed in 64 KB writes. Pre-fix, the carry buffer tracked the total
    // and phys_footprint blew past 256 MB; post-fix the working set is a few
    // tens of MB. 128 MB is a wide separator either way.
    private let totalBytes = 256 * 1024 * 1024
    private let writeSize  = 64 * 1024
    private let ceilingBytes: UInt64 = 128 * 1024 * 1024

    private func assertBounded(_ helper: String, _ args: [String]) throws {
        let url = try helperURL(helper)
        let peak = try peakFootprintStreaming(url, args, totalBytes: totalBytes, writeSize: writeSize)
        XCTAssertLessThan(peak, ceilingBytes,
            "\(helper) phys_footprint peaked at \(peak / (1024 * 1024)) MB while streaming "
            + "\(totalBytes / (1024 * 1024)) MB — the frame-carry buffer is growing with the input.")
    }

    func test_pcmDistanceGain_footprintStaysBounded() throws {
        try assertBounded("PCMDistanceGain",
                          ["--rate", "48000", "--channels", "2", "--distance", "4.0"])
    }

    func test_fmDeemphasis_footprintStaysBounded() throws {
        try assertBounded("FMDeemphasis", ["--rate", "48000", "--channels", "2"])
    }

    func test_pcmBinauralPanner_footprintStaysBounded() throws {
        try assertBounded("PCMBinauralPanner",
                          ["--rate", "48000", "--channels", "2",
                           "--azimuth", "0", "--elevation", "0", "--distance", "1.0"])
    }
}
