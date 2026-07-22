import XCTest
@testable import PipelineRunner

final class CLIStageTextTests: XCTestCase {

    // MARK: Export

    func testExportStageJoinsPathAndArguments() {
        let stage = CLIStage(path: "rtl_fm", arguments: ["-f", "89100000", "-M", "wbfm"])
        XCTAssertEqual(CLIStageText.export(stage), "rtl_fm -f 89100000 -M wbfm")
    }

    func testExportQuotesArgumentsContainingSpaces() {
        let stage = CLIStage(path: "/usr/bin/say", arguments: ["hello there", "world"])
        XCTAssertEqual(CLIStageText.export(stage), "/usr/bin/say \"hello there\" world")
    }

    func testExportEscapesEmbeddedQuotesAndBackslashes() {
        let stage = CLIStage(path: "tool", arguments: [#"say "hi" \ done"#])
        XCTAssertEqual(CLIStageText.export(stage), #"tool "say \"hi\" \\ done""#)
    }

    func testExportQuotesEmptyArgument() {
        let stage = CLIStage(path: "tool", arguments: [""])
        XCTAssertEqual(CLIStageText.export(stage), "tool \"\"")
    }

    func testExportPipelineJoinsStagesWithPipe() {
        let stages = [
            CLIStage(path: "nrsc5", arguments: ["-o", "-", "97.1", "0"]),
            CLIStage(path: "sox", arguments: ["-t", "raw", "-", "-t", "raw", "-"])
        ]
        XCTAssertEqual(CLIStageText.export(pipeline: stages),
                        "nrsc5 -o - 97.1 0 | sox -t raw - -t raw -")
    }

    // MARK: Import — single stage

    func testImportStageSplitsOnWhitespace() {
        let stage = CLIStageText.importStage("rtl_fm -f 89100000 -M wbfm")
        XCTAssertEqual(stage, CLIStage(path: "rtl_fm", arguments: ["-f", "89100000", "-M", "wbfm"]))
    }

    func testImportStageHonorsDoubleQuotedArgument() {
        let stage = CLIStageText.importStage(#"/usr/bin/say "hello there" world"#)
        XCTAssertEqual(stage, CLIStage(path: "/usr/bin/say", arguments: ["hello there", "world"]))
    }

    func testImportStageHonorsSingleQuotedArgument() {
        let stage = CLIStageText.importStage("tool 'a | b' arg2")
        XCTAssertEqual(stage, CLIStage(path: "tool", arguments: ["a | b", "arg2"]))
    }

    func testImportStageHonorsBackslashEscape() {
        let stage = CLIStageText.importStage(#"tool a\ b"#)
        XCTAssertEqual(stage, CLIStage(path: "tool", arguments: ["a b"]))
    }

    func testImportStageUnescapesQuotesAndBackslashesInsideDoubleQuotes() {
        let stage = CLIStageText.importStage(#"tool "say \"hi\" \\ done""#)
        XCTAssertEqual(stage, CLIStage(path: "tool", arguments: [#"say "hi" \ done"#]))
    }

    func testImportStageAdjacentQuotesConcatenateIntoOneToken() {
        let stage = CLIStageText.importStage(#"tool foo"bar baz"qux"#)
        XCTAssertEqual(stage, CLIStage(path: "tool", arguments: ["foobar bazqux"]))
    }

    func testImportStageReturnsNilForBlankText() {
        XCTAssertNil(CLIStageText.importStage("   "))
        XCTAssertNil(CLIStageText.importStage(""))
    }

    // MARK: Import — pipeline

    func testImportPipelineSplitsOnUnquotedPipe() {
        let stages = CLIStageText.importPipeline("nrsc5 -o - 97.1 0 | sox -t raw - -t raw -")
        XCTAssertEqual(stages, [
            CLIStage(path: "nrsc5", arguments: ["-o", "-", "97.1", "0"]),
            CLIStage(path: "sox", arguments: ["-t", "raw", "-", "-t", "raw", "-"])
        ])
    }

    func testImportPipelineIgnoresPipeInsideQuotes() {
        let stages = CLIStageText.importPipeline(#"tool "a | b" | tool2 c"#)
        XCTAssertEqual(stages, [
            CLIStage(path: "tool", arguments: ["a | b"]),
            CLIStage(path: "tool2", arguments: ["c"])
        ])
    }

    func testImportPipelineDropsEmptySegments() {
        let stages = CLIStageText.importPipeline("tool a ||  tool2 b | ")
        XCTAssertEqual(stages, [
            CLIStage(path: "tool", arguments: ["a"]),
            CLIStage(path: "tool2", arguments: ["b"])
        ])
    }

    func testImportPipelineReturnsEmptyArrayForBlankText() {
        XCTAssertEqual(CLIStageText.importPipeline(""), [])
        XCTAssertEqual(CLIStageText.importPipeline("   "), [])
    }

    // MARK: Round-trip

    func testExportThenImportRoundTripsArbitraryArguments() {
        let original = [
            CLIStage(path: "/opt/local/bin/sox", arguments: ["-V2", "-q", "rate", "48000"]),
            CLIStage(path: "tool", arguments: ["has space", "has|pipe", #"has"quote"#, #"has\backslash"#, ""])
        ]
        let text = CLIStageText.export(pipeline: original)
        XCTAssertEqual(CLIStageText.importPipeline(text), original)
    }
}
