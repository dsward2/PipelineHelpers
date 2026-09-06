import XCTest
@testable import PipelineRunner

/// Guards `PipelineHelperCatalog` against drifting away from the helpers it
/// describes. The catalog is hand-authored; these tests fail loudly when a
/// helper gains, loses, or renames a flag without the catalog following.
final class PipelineHelperCatalogTests: XCTestCase {

    // Package root: this file is at
    // <root>/Tests/PipelineRunnerTests/PipelineHelperCatalogTests.swift
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(forHelper name: String) throws -> String {
        let url = Self.packageRoot
            .appendingPathComponent("Sources/\(name)/main.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `.executableTarget(name: "…")` in Package.swift.
    private func executableTargetNames() throws -> Set<String> {
        let manifest = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let pattern = #"\.executableTarget\(\s*\n?\s*name:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(manifest.startIndex..., in: manifest)
        var names = Set<String>()
        regex.enumerateMatches(in: manifest, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: manifest) else { return }
            names.insert(String(manifest[r]))
        }
        return names
    }

    // MARK: Tests

    func testEveryExecutableTargetHasACatalogEntry() throws {
        let targets = try executableTargetNames()
        XCTAssertFalse(targets.isEmpty, "regex found no executable targets — pattern is stale")

        let catalog = Set(PipelineHelperCatalog.all.map(\.name))

        XCTAssertEqual(
            catalog, targets,
            "catalog and Package.swift executables disagree.\n"
            + "  missing from catalog: \(targets.subtracting(catalog).sorted())\n"
            + "  not real executables: \(catalog.subtracting(targets).sorted())"
        )
    }

    func testEveryCatalogFlagAppearsInItsHelperSource() throws {
        for spec in PipelineHelperCatalog.all {
            let src = try source(forHelper: spec.name)
            let tokens = spec.options.flatMap { [$0.flag] + $0.aliases } + spec.diagnosticFlags
            for token in tokens {
                XCTAssertTrue(
                    src.contains("\"\(token)\""),
                    "\(spec.name): catalog lists '\(token)' but its main.swift never matches that literal"
                )
            }
        }
    }

    func testNoDuplicateFlagsWithinASpec() {
        for spec in PipelineHelperCatalog.all {
            let flags = spec.options.map(\.flag)
            XCTAssertEqual(
                flags.count, Set(flags).count,
                "\(spec.name) has a duplicated option flag: \(flags)"
            )
        }
    }

    func testRequiredOptionsHaveNoDefault() {
        for spec in PipelineHelperCatalog.all {
            for option in spec.options where option.isRequired {
                XCTAssertNil(
                    option.defaultValue,
                    "\(spec.name) \(option.flag): a required option shouldn't advertise a default"
                )
            }
        }
    }

    // MARK: spec(forToolPath:)

    func testSpecLookupMatchesBareNameOnly() {
        XCTAssertEqual(PipelineHelperCatalog.spec(forToolPath: "PCMUDPSender")?.name, "PCMUDPSender")
        XCTAssertNil(PipelineHelperCatalog.spec(forToolPath: "/opt/local/bin/nrsc5"))
        XCTAssertNil(PipelineHelperCatalog.spec(forToolPath: "Contents/Helpers/PCMUDPSender"))
        XCTAssertNil(PipelineHelperCatalog.spec(forToolPath: "nrsc5"))
        XCTAssertNil(PipelineHelperCatalog.spec(forToolPath: ""))
    }

    func testOptionLookupResolvesAliases() {
        let jitter = PipelineHelperCatalog.spec(forToolPath: "PCMJitterBuffer")
        XCTAssertEqual(jitter?.option(forToken: "-r")?.flag, "--rate")
        XCTAssertEqual(jitter?.option(forToken: "--rate")?.flag, "--rate")
        XCTAssertNil(jitter?.option(forToken: "--nonesuch"))
    }
}
