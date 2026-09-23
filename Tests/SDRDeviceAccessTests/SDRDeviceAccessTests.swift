import XCTest
@testable import SDRDeviceAccess

/// A fixed set of dongles; `busy` indices fail the trial open with -3.
private struct FakeBackend: RTLSDRBackend {
    var serials: [String?]
    var busy: Set<UInt32> = []
    func deviceCount() -> UInt32 { UInt32(serials.count) }
    func serial(at index: UInt32) -> String? { serials[Int(index)] }
    func tryOpen(at index: UInt32) -> Int32 { busy.contains(index) ? -3 : 0 }
}

final class RTLSDRDeviceResolverTests: XCTestCase {
    // The user's dongles, in one observed enumeration order.
    let serials: [String?] = ["00000090", "00000360", "00000180"]

    func testEmptyValueIsIndexZero() {
        XCTAssertEqual(RTLSDRDeviceResolver.rtlToolIndex(for: "", serials: serials), 0)
    }

    func testSmallNumberIsAnIndex() {
        XCTAssertEqual(RTLSDRDeviceResolver.rtlToolIndex(for: "2", serials: serials), 2)
        XCTAssertEqual(RTLSDRDeviceResolver.rtlToolIndex(for: "0x1", serials: serials), 1)
    }

    func testIndexWinsOverAMatchingSerial() {
        XCTAssertEqual(RTLSDRDeviceResolver.rtlToolIndex(for: "1", serials: ["a", "b", "1"]), 1)
    }

    func testEightDigitSerialsMatchExactly() {
        // "00000360" is valid octal (240) but not a valid index, so it falls
        // through to serial matching; "00000090" isn't octal at all.
        XCTAssertEqual(RTLSDRDeviceResolver.rtlToolIndex(for: "00000360", serials: serials), 1)
        XCTAssertEqual(RTLSDRDeviceResolver.rtlToolIndex(for: "00000090", serials: serials), 0)
    }

    func testPrefixThenSuffixMatch() {
        XCTAssertEqual(RTLSDRDeviceResolver.rtlToolIndex(for: "0000018", serials: serials), 2)
        XCTAssertEqual(RTLSDRDeviceResolver.rtlToolIndex(for: "360", serials: serials), 1)
    }

    func testOutOfRangeNumberWithNoSerialMatchIsNil() {
        XCTAssertNil(RTLSDRDeviceResolver.rtlToolIndex(for: "7", serials: serials))
        XCTAssertNil(RTLSDRDeviceResolver.rtlToolIndex(for: "00000270", serials: serials))
        XCTAssertNil(RTLSDRDeviceResolver.rtlToolIndex(for: "0", serials: []))
    }

    func testUnreadableSerialsAreSkipped() {
        XCTAssertEqual(RTLSDRDeviceResolver.rtlToolIndex(for: "00000180", serials: [nil, "00000180"]), 1)
    }

    func testOsmosdrDeviceStrings() {
        XCTAssertEqual(RTLSDRDeviceResolver.osmosdrIndex(for: "rtl=0", serials: serials), 0)
        XCTAssertEqual(RTLSDRDeviceResolver.osmosdrIndex(for: "rtl=00000360", serials: serials), 1)
        XCTAssertEqual(RTLSDRDeviceResolver.osmosdrIndex(for: "rtl=00000180,bias=1", serials: serials), 2)
        XCTAssertEqual(RTLSDRDeviceResolver.osmosdrIndex(for: "rtl", serials: serials), 0)
        XCTAssertNil(RTLSDRDeviceResolver.osmosdrIndex(for: "rtl=9", serials: serials))
        XCTAssertNil(RTLSDRDeviceResolver.osmosdrIndex(for: "rtl_tcp=127.0.0.1:1234", serials: serials))
        XCTAssertNil(RTLSDRDeviceResolver.osmosdrIndex(for: "airspy=0", serials: serials))
        XCTAssertNil(RTLSDRDeviceResolver.osmosdrIndex(for: "file=/tmp/x.raw,rate=96000", serials: serials))
    }
}

final class RTLSDRPreflightTests: XCTestCase {
    let serials: [String?] = ["00000090", "00000360", "00000180"]
    let gqrx = SDRDeviceHolder(pid: 10, name: "Gqrx", app: "Gqrx-for-AntennaHead")

    /// `gqrxDevice`: Gqrx's `\get_input_device` reply; nil = remote control off.
    private func check(_ device: String, busy: Set<UInt32> = [], serials: [String?]? = nil,
                       holders: [SDRDeviceHolder] = [],
                       gqrxDevice: String? = nil) -> RTLSDRPreflightReport {
        RTLSDRPreflight.check(device: device,
                              backend: FakeBackend(serials: serials ?? self.serials, busy: busy),
                              holders: { holders }, gqrxInputDevice: { gqrxDevice })
    }

    func testAvailable() {
        let r = check("00000360")
        XCTAssertEqual(r.outcome, .available)
        XCTAssertEqual(r.index, 1)
        XCTAssertEqual(r.serial, "00000360")
        XCTAssertTrue(r.isAvailable)
    }

    func testNoDevicesAndNotFound() {
        XCTAssertEqual(check("0", serials: []).outcome, .noDevices)
        let r = check("00000270")
        XCTAssertEqual(r.outcome, .notFound)
        XCTAssertEqual(r.message, "No connected RTL-SDR matches USB device \u{201C}00000270\u{201D}.")
    }

    func testGqrxHoldingThisDeviceIsTheHolder() {
        let r = check("00000360", busy: [1], holders: [gqrx], gqrxDevice: "rtl=1")
        XCTAssertEqual(r.outcome, .busy(code: -3))
        XCTAssertTrue(r.gqrxIsHolder)
        XCTAssertEqual(r.message, "USB device 00000360 is in use by another program (Gqrx).")
    }

    func testGqrxOnADifferentDeviceIsNotBlamed() {
        let r = check("00000360", busy: [1],
                      holders: [gqrx, SDRDeviceHolder(pid: 11, name: "rtl_fm_localradio", app: "ControlBooth")],
                      gqrxDevice: "rtl=00000090")
        XCTAssertFalse(r.gqrxIsHolder)
        XCTAssertEqual(r.message,
                       "USB device 00000360 is in use by another program. Running now: rtl_fm_localradio (ControlBooth).")
    }

    func testGqrxWithoutDeviceQueryIsAssumedTheHolder() {
        // Reachable, but no \get_input_device (stock Gqrx): can't rule it out.
        XCTAssertTrue(check("0", busy: [0], holders: [gqrx], gqrxDevice: "").gqrxIsHolder)
    }

    func testGqrxOnANetworkSourceIsNotTheHolder() {
        XCTAssertFalse(check("0", busy: [0], holders: [gqrx], gqrxDevice: "rtl_tcp=127.0.0.1:1234").gqrxIsHolder)
    }

    func testGqrxWithRemoteControlOffIsBlamedOnlyWhenAlone() {
        XCTAssertTrue(check("0", busy: [0], holders: [gqrx], gqrxDevice: nil).gqrxIsHolder)
        let r = check("0", busy: [0], holders: [gqrx, SDRDeviceHolder(pid: 12, name: "rtl_tcp", app: nil)],
                      gqrxDevice: nil)
        XCTAssertFalse(r.gqrxIsHolder)
        XCTAssertEqual(r.message, "USB device 00000090 is in use by another program. Running now: Gqrx, rtl_tcp.")
    }

    func testGqrxNotRunningIsNeverAsked() {
        var asked = false
        _ = RTLSDRPreflight.check(device: "0", backend: FakeBackend(serials: serials, busy: [0]),
                                  holders: { [] }, gqrxInputDevice: { asked = true; return "rtl=0" })
        XCTAssertFalse(asked)
    }

    func testDuplicateHolderNamesCollapse() {
        let r = check("2", busy: [2], holders: [SDRDeviceHolder(pid: 1, name: "rtl_sdr", app: nil),
                                                SDRDeviceHolder(pid: 2, name: "rtl_sdr", app: nil)])
        XCTAssertEqual(r.message, "USB device 00000180 is in use by another program. Running now: rtl_sdr.")
    }

    func testDeviceLabelFallsBackToIndexWithoutSerial() {
        let r = check("1", busy: [1], serials: ["", ""])
        XCTAssertEqual(r.deviceLabel, "USB device 1")
    }
}

final class SDRDeviceHoldersTests: XCTestCase {
    func testKnownProgramNames() {
        XCTAssertEqual(SDRDeviceHolders.displayName(forCommand: "gqrx"), "Gqrx")
        XCTAssertEqual(SDRDeviceHolders.displayName(forCommand: "rtl_fm_localradi"), "rtl_fm_localradio")
        XCTAssertEqual(SDRDeviceHolders.displayName(forCommand: "rtl_fm"), "rtl_fm")
        XCTAssertEqual(SDRDeviceHolders.displayName(forCommand: "rtl_tcp"), "rtl_tcp")
        XCTAssertNil(SDRDeviceHolders.displayName(forCommand: "grep"))
        XCTAssertNil(SDRDeviceHolders.displayName(forCommand: "Finder"))
    }

    func testAppNameFromExecutablePath() {
        XCTAssertEqual(SDRDeviceHolders.appName(
            fromExecutablePath: "/Applications/ControlBooth.app/Contents/Helpers/rtl_fm_localradio"), "ControlBooth")
        XCTAssertNil(SDRDeviceHolders.appName(fromExecutablePath: "/opt/local/bin/rtl_tcp"))
    }

    func testLabels() {
        XCTAssertEqual(SDRDeviceHolder(pid: 1, name: "rtl_fm_localradio", app: "AntennaHead").label,
                       "rtl_fm_localradio (AntennaHead)")
        XCTAssertEqual(SDRDeviceHolder(pid: 1, name: "Gqrx", app: "Gqrx-for-AntennaHead").label, "Gqrx")
        XCTAssertEqual(SDRDeviceHolder(pid: 1, name: "rtl_tcp", app: nil).label, "rtl_tcp")
    }

    func testScanRunsAndExcludesPIDs() {
        // Only checks the sysctl walk works; which SDR tools happen to be
        // running on the test machine isn't knowable.
        let me = getpid()
        XCTAssertFalse(SDRDeviceHolders.running(excludingPIDs: [me]).contains { $0.pid == me })
    }
}

/// Talks to a fake Gqrx remote-control server on an ephemeral local port.
final class GqrxRemoteControlTests: XCTestCase {

    /// Serves `replies[command]` (one line) per received command line.
    private final class FakeGqrx {
        let port: UInt16
        private let listener: Int32
        var replies: [String: String]
        private(set) var received: [String] = []
        private let lock = NSLock()

        init(replies: [String: String]) {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            listen(s, 4)
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
            }
            self.replies = replies
            self.listener = s
            self.port = UInt16(bigEndian: bound.sin_port)
            Thread.detachNewThread { [self] in serve() }
        }

        var commands: [String] { lock.lock(); defer { lock.unlock() }; return received }

        private func serve() {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var pending = [UInt8]()
                var chunk = [UInt8](repeating: 0, count: 1024)
                while true {
                    let n = chunk.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
                    if n <= 0 { break }
                    pending.append(contentsOf: chunk[..<n])
                    while let nl = pending.firstIndex(of: 0x0A) {
                        let cmd = String(decoding: pending[..<nl], as: UTF8.self)
                        pending.removeSubrange(...nl)
                        lock.lock(); received.append(cmd); let reply = replies[cmd] ?? "RPRT 1"; lock.unlock()
                        let out = Array((reply + "\n").utf8)
                        _ = out.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                    }
                }
                close(client)
            }
        }

        func stop() { close(listener) }
    }

    func testInputDevice() {
        let gqrx = FakeGqrx(replies: ["\\get_input_device": "rtl=00000360"])
        defer { gqrx.stop() }
        XCTAssertEqual(GqrxRemoteControl.inputDevice(port: gqrx.port), "rtl=00000360")
    }

    func testGqrxWithoutDeviceQuery() {
        let gqrx = FakeGqrx(replies: [:])   // older Gqrx: RPRT 1
        defer { gqrx.stop() }
        XCTAssertEqual(GqrxRemoteControl.inputDevice(port: gqrx.port), "")
    }

    func testNoGqrxListening() {
        let gqrx = FakeGqrx(replies: [:])
        let port = gqrx.port
        gqrx.stop()
        XCTAssertNil(GqrxRemoteControl.inputDevice(port: port))
    }
}
