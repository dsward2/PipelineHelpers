import Foundation

/// One pipeline stage — an executable path plus its arguments. Mirrors the
/// `{"path":...,"arguments":[...]}` shape both AntennaHead's `task_json` and
/// ControlBooth's `PipelineStage` already store, so either app's stage model
/// converts to/from this directly.
public struct CLIStage: Equatable, Sendable {
    public var path: String
    public var arguments: [String]

    public init(path: String, arguments: [String] = []) {
        self.path = path
        self.arguments = arguments
    }
}

/// Converts pipeline stages to and from the plain-text, shell-style form used
/// to copy a stage (or a whole pipeline) between AntennaHead and ControlBooth,
/// or to relocate a stage within one pipeline: `tool arg1 "arg with space"`,
/// with multiple stages joined by ` | ` the way a shell pipeline reads.
public enum CLIStageText {

    // MARK: Export

    /// One stage: `tool arg1 arg2 ...`.
    public static func export(_ stage: CLIStage) -> String {
        ([stage.path] + stage.arguments).map(quote).joined(separator: " ")
    }

    /// A whole pipeline: stages joined with ` | `.
    public static func export(pipeline stages: [CLIStage]) -> String {
        stages.map(export).joined(separator: " | ")
    }

    // MARK: Import

    /// Parses the first stage out of `text` (there's usually just one when
    /// copying a single stage). Returns `nil` for blank input.
    public static func importStage(_ text: String) -> CLIStage? {
        importPipeline(text).first
    }

    /// Splits `text` on unquoted `|` and parses each segment into a stage.
    /// Empty segments (blank text, a doubled `|`, a trailing `|`) are dropped.
    public static func importPipeline(_ text: String) -> [CLIStage] {
        tokenizeStages(text).compactMap { tokens in
            guard let path = tokens.first else { return nil }
            return CLIStage(path: path, arguments: Array(tokens.dropFirst()))
        }
    }

    // MARK: - Quoting

    private static func quote(_ token: String) -> String {
        let mustQuote = token.isEmpty || token.contains { " \t\n\"'|\\".contains($0) }
        guard mustQuote else { return token }
        var escaped = ""
        escaped.reserveCapacity(token.count)
        for ch in token {
            if ch == "\"" || ch == "\\" { escaped.append("\\") }
            escaped.append(ch)
        }
        return "\"\(escaped)\""
    }

    // MARK: - Tokenizing

    /// Shell-style lexer: whitespace separates arguments, single/double quotes
    /// group text containing spaces or `|`, a backslash escapes the next
    /// character, and an unquoted `|` starts a new stage. This is the inverse
    /// of `quote`/`export`, so anything this package exports round-trips.
    private static func tokenizeStages(_ text: String) -> [[String]] {
        var stages: [[String]] = []
        var currentStage: [String] = []
        var token = ""
        var tokenStarted = false
        var inSingleQuote = false
        var inDoubleQuote = false

        func endToken() {
            if tokenStarted {
                currentStage.append(token)
                token = ""
                tokenStarted = false
            }
        }
        func endStage() {
            endToken()
            stages.append(currentStage)
            currentStage = []
        }

        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            if inSingleQuote {
                if ch == "'" { inSingleQuote = false } else { token.append(ch) }
                continue
            }
            if inDoubleQuote {
                if ch == "\"" {
                    inDoubleQuote = false
                } else if ch == "\\", let escaped = iterator.next() {
                    if escaped == "\"" || escaped == "\\" {
                        token.append(escaped)
                    } else {
                        token.append(ch)
                        token.append(escaped)
                    }
                } else {
                    token.append(ch)
                }
                continue
            }
            switch ch {
            case "'":
                inSingleQuote = true
                tokenStarted = true
            case "\"":
                inDoubleQuote = true
                tokenStarted = true
            case " ", "\t", "\n", "\r":
                endToken()
            case "|":
                endStage()
            case "\\":
                if let escaped = iterator.next() {
                    token.append(escaped)
                    tokenStarted = true
                }
            default:
                token.append(ch)
                tokenStarted = true
            }
        }
        endStage()
        return stages.filter { !$0.isEmpty }
    }
}
