import Foundation

// A machine-readable description of every executable helper this package
// builds — the option names each one's argument parser accepts, their value
// kinds, defaults, and one-line explanations.
//
// It exists so a host app's pipeline editor (ControlBooth's Pipelines view,
// and eventually AntennaHead's Custom Task pages) can show a structured form
// for a bundled helper instead of anonymous "Argument 1 / Argument 2" rows,
// while still falling back to the generic rows for external tools it knows
// nothing about (nrsc5, rtl_fm, …).
//
// The catalog is authored by hand from each helper's `main.swift` usage block
// and argument switch. `PipelineHelperCatalogTests` guards it against drift:
// every flag named here must appear literally in that helper's source, and
// every executable target must have an entry.

// MARK: - Option

/// One command-line option accepted by a helper.
public struct PipelineHelperOption: Sendable, Equatable {

    /// What kind of value (if any) follows the flag.
    public enum Kind: Sendable, Equatable {
        /// A bare switch with no value (`--repeat`, `--exit-with-parent`).
        case flag
        /// Free-form text (`--voice en-US`, `--device-name "…"`).
        case string
        /// A filesystem path — a host may offer a file picker.
        case path
        /// An integer, optionally constrained to a closed range.
        case int(ClosedRange<Int>?)
        /// A real number, optionally constrained to a closed range.
        case double(ClosedRange<Double>?)
        /// One of a fixed set of string values (`--during-prefix drop|hold`).
        case enumeration([String])
    }

    /// The canonical (long) flag, including leading dashes: `--rate`.
    public var flag: String
    /// Alternate spellings the parser also accepts, e.g. `["-p"]` for `--port`.
    /// A host reads these but always writes `flag`.
    public var aliases: [String]
    public var kind: Kind
    /// One line explaining the option, shown as help text / tooltip.
    public var summary: String
    /// The helper's own default when the flag is omitted, as display text
    /// (`"48000"`). `nil` when there is no default or the option is required.
    public var defaultValue: String?
    /// The helper refuses to start without this option.
    public var isRequired: Bool
    /// The flag may be given more than once (`--file`, `--param`, `--input`).
    public var isRepeatable: Bool
    /// Placeholder shown in an empty field (`"udp:<port>"`, `"<hz>"`).
    public var placeholder: String?

    public init(
        flag: String,
        aliases: [String] = [],
        kind: Kind,
        summary: String,
        defaultValue: String? = nil,
        isRequired: Bool = false,
        isRepeatable: Bool = false,
        placeholder: String? = nil
    ) {
        self.flag = flag
        self.aliases = aliases
        self.kind = kind
        self.summary = summary
        self.defaultValue = defaultValue
        self.isRequired = isRequired
        self.isRepeatable = isRepeatable
        self.placeholder = placeholder
    }
}

// MARK: - Spec

/// The full option surface of one helper executable.
public struct PipelineHelperSpec: Sendable, Equatable, Identifiable {

    /// Where the stage usually sits in a pipeline — used only to group the
    /// helpers in a picker.
    public enum Category: String, Sendable, CaseIterable {
        case source
        case processing
        case sink

        public var displayName: String {
            switch self {
            case .source: return "Sources"
            case .processing: return "Processing"
            case .sink: return "Sinks"
            }
        }
    }

    /// The product / executable name, which is also the bare tool name a
    /// stage stores in its `path` (`"PCMSpeechSynth"`).
    public var name: String
    public var category: Category
    /// One or two sentences on what the stage does.
    public var summary: String
    public var options: [PipelineHelperOption]
    /// Flags that are valid on the command line but make the process print
    /// something and exit immediately (`--list-voices`), so a host should not
    /// offer them as part of a running stage. Named here anyway so the
    /// drift-guard test accounts for them.
    public var diagnosticFlags: [String]

    public var id: String { name }

    public init(
        name: String,
        category: Category,
        summary: String,
        options: [PipelineHelperOption],
        diagnosticFlags: [String] = []
    ) {
        self.name = name
        self.category = category
        self.summary = summary
        self.options = options
        self.diagnosticFlags = diagnosticFlags
    }

    /// The option matching `token`, whether `token` is the canonical flag or
    /// one of its aliases.
    public func option(forToken token: String) -> PipelineHelperOption? {
        options.first { $0.flag == token || $0.aliases.contains(token) }
    }
}

// MARK: - Catalog

public enum PipelineHelperCatalog {

    /// The bundled helper accepted for `path`, or `nil` when `path` is an
    /// absolute/relative path or a bare name that isn't one of ours — in which
    /// case a host should use its generic argument editor.
    public static func spec(forToolPath path: String) -> PipelineHelperSpec? {
        guard !path.contains("/"), !path.isEmpty else { return nil }
        return all.first { $0.name == path }
    }

    public static func specs(in category: PipelineHelperSpec.Category) -> [PipelineHelperSpec] {
        all.filter { $0.category == category }
    }

    // Shared option definitions --------------------------------------------

    /// Universal on the helpers that run a watchdog thread. Recommended on a
    /// pipeline's first stage so a crashed host never orphans the chain.
    private static let exitWithParent = PipelineHelperOption(
        flag: "--exit-with-parent",
        kind: .flag,
        summary: "Exit if the host app dies unexpectedly, so pipelines never orphan."
    )

    private static func rate(
        _ range: ClosedRange<Int>?,
        default def: String,
        summary: String = "Sample rate in Hz. Must match the neighbouring stages."
    ) -> PipelineHelperOption {
        PipelineHelperOption(
            flag: "--rate", kind: .int(range), summary: summary,
            defaultValue: def, placeholder: "<hz>"
        )
    }

    private static func channels(
        _ range: ClosedRange<Int>?,
        default def: String
    ) -> PipelineHelperOption {
        PipelineHelperOption(
            flag: "--channels", kind: .int(range),
            summary: "Channel count. Must match the neighbouring stages.",
            defaultValue: def, placeholder: "<n>"
        )
    }

    // The helpers ---------------------------------------------------------

    public static let all: [PipelineHelperSpec] = [

        PipelineHelperSpec(
            name: "PCMSpeechSynth",
            category: .source,
            summary: "Text-to-speech source. Renders text (from --text, a file, "
                + "stdin, or a UDP port) to real-time-paced S16LE mono PCM. "
                + "Follow with a sox stage to reach 48 kHz stereo.",
            options: [
                PipelineHelperOption(
                    flag: "--text", kind: .string,
                    summary: "Speak this text. Shorthand for --input text:<string>. "
                        + "Give --text or --input.",
                    placeholder: "<string>"
                ),
                PipelineHelperOption(
                    flag: "--input", kind: .string,
                    summary: "Where the text comes from: stdin, file:<path>, "
                        + "udp:<port> (each datagram replaces the text), or text:<string>.",
                    placeholder: "stdin | file:… | udp:… | text:…"
                ),
                rate(8_000...48_000, default: "22050",
                     summary: "Output sample rate in Hz (8000–48000). Mono output."),
                PipelineHelperOption(
                    flag: "--voice", kind: .string,
                    summary: "AVSpeechSynthesisVoice identifier or BCP-47 language code, e.g. en-US.",
                    placeholder: "<id-or-language>"
                ),
                PipelineHelperOption(
                    flag: "--speech-rate", kind: .double(0.0...1.0),
                    summary: "Speaking rate, 0–1.", defaultValue: "system default",
                    placeholder: "0..1"
                ),
                PipelineHelperOption(
                    flag: "--ssml", kind: .flag,
                    summary: "Parse the text as SSML markup — prosody control for the modern voices."
                ),
                PipelineHelperOption(
                    flag: "--repeat", kind: .flag,
                    summary: "Loop the audio continuously."
                ),
                PipelineHelperOption(
                    flag: "--no-pace", kind: .flag,
                    summary: "Emit as fast as the sink accepts instead of in real time — "
                        + "for rendering a clip to a file, not driving a live pipeline."
                ),
                PipelineHelperOption(
                    flag: "--gap", kind: .double(nil),
                    summary: "Seconds of silence between repeats / utterances.",
                    defaultValue: "1.0", placeholder: "<seconds>"
                ),
                exitWithParent
            ],
            diagnosticFlags: ["--list-voices"]
        ),

        PipelineHelperSpec(
            name: "PCMFilePlayer",
            category: .source,
            summary: "AAC/MP3 (or any AVAudioFile-readable) file & playlist source. "
                + "Decodes each track into memory and writes real-time-paced S16LE PCM. "
                + "Not bundled with ControlBooth — point the stage at an absolute path to a build of it.",
            options: [
                PipelineHelperOption(
                    flag: "--file", kind: .path,
                    summary: "One track. Repeatable; played in the order given.",
                    isRepeatable: true, placeholder: "<path>"
                ),
                PipelineHelperOption(
                    flag: "--playlist", kind: .path,
                    summary: "A text file listing one path per line (blank lines and # comments ignored).",
                    placeholder: "<path>"
                ),
                rate(8_000...192_000, default: "48000"),
                channels(1...8, default: "2"),
                PipelineHelperOption(
                    flag: "--gap", kind: .double(nil),
                    summary: "Seconds of silence between tracks, and before the loop repeats.",
                    defaultValue: "0.0", placeholder: "<seconds>"
                ),
                PipelineHelperOption(
                    flag: "--repeat", kind: .flag,
                    summary: "Loop the whole playlist continuously."
                ),
                exitWithParent
            ]
        ),

        PipelineHelperSpec(
            name: "PCMMixer",
            category: .processing,
            summary: "Mixes two or more S16LE inputs sample-wise into one stream. "
                + "Input 0 is the clock master; the others are buffered and contribute "
                + "silence on under-run. Blend is live-adjustable over the control port.",
            options: [
                PipelineHelperOption(
                    flag: "--input", kind: .string,
                    summary: "An input source: stdin or udp:<port>. Give two or more; at most one stdin.",
                    isRequired: true, isRepeatable: true, placeholder: "stdin | udp:<port>"
                ),
                PipelineHelperOption(
                    flag: "--output", kind: .string,
                    summary: "Send the mix over UDP instead of stdout.",
                    defaultValue: "stdout", placeholder: "udp:<host>:<port>"
                ),
                PipelineHelperOption(
                    flag: "--control-port", kind: .int(1...65_535),
                    summary: "UDP port for live 'ratio' / 'gain' commands.",
                    placeholder: "<n>"
                ),
                PipelineHelperOption(
                    flag: "--gain", kind: .string,
                    summary: "Initial gain for one input, as <index>=<gain> (>1 amplifies). Repeatable.",
                    isRepeatable: true, placeholder: "<i>=<g>"
                ),
                PipelineHelperOption(
                    flag: "--ratio", kind: .double(0.0...1.0),
                    summary: "Initial crossfade of inputs 0/1 (gain0 = 1−r, gain1 = r).",
                    placeholder: "0..1"
                ),
                exitWithParent
            ]
        ),

        PipelineHelperSpec(
            name: "PCMUDPReceiver",
            category: .source,
            summary: "Listens for UDP datagrams and writes their payloads to stdout. "
                + "A bridge for tools you'd rather run outside the app: have them send "
                + "PCM to a loopback port this stage reads.",
            options: [
                PipelineHelperOption(
                    flag: "--port", aliases: ["-p"], kind: .int(1...65_535),
                    summary: "UDP port to listen on.",
                    isRequired: true, placeholder: "<n>"
                ),
                PipelineHelperOption(
                    flag: "--bind", kind: .string,
                    summary: "Listen address. 127.0.0.1 is loopback-only; use 0.0.0.0 for LAN senders.",
                    defaultValue: "127.0.0.1", placeholder: "<addr>"
                ),
                exitWithParent
            ]
        ),

        PipelineHelperSpec(
            name: "PCMUDPSender",
            category: .sink,
            summary: "Sends stdin as UDP datagrams (max 2048 bytes each). "
                + "ControlBooth appends this as every pipeline's final stage; it can "
                + "also feed a PCMMixer input or another machine mid-pipeline.",
            options: [
                PipelineHelperOption(
                    flag: "--port", aliases: ["-p"], kind: .int(1...65_535),
                    summary: "Destination UDP port.",
                    isRequired: true, placeholder: "<n>"
                ),
                PipelineHelperOption(
                    flag: "--host", kind: .string,
                    summary: "Destination address.",
                    defaultValue: "127.0.0.1", placeholder: "<addr>"
                ),
                exitWithParent
            ]
        ),

        PipelineHelperSpec(
            name: "PCMPassthrough",
            category: .processing,
            summary: "Copies stdin to stdout unchanged. Takes no options. Useful as a "
                + "placeholder, and its source is the template for new DSP stages.",
            options: []
        ),

        PipelineHelperSpec(
            name: "PCMPrefix",
            category: .processing,
            summary: "Plays a pre-rendered raw clip, then passes stdin through — the "
                + "spoken station announcement before live playback.",
            options: [
                PipelineHelperOption(
                    flag: "--prefix-file", kind: .path,
                    summary: "Raw S16LE clip to play first, at --rate. Missing or empty acts as a passthrough.",
                    placeholder: "<path>"
                ),
                PipelineHelperOption(
                    flag: "--during-prefix", kind: .enumeration(["drop", "hold"]),
                    summary: "What to do with stdin while the clip plays: drop it, or hold (buffer) it.",
                    defaultValue: "drop"
                ),
                PipelineHelperOption(
                    flag: "--prefix-channels", kind: .int(1...2),
                    summary: "Channel count of --prefix-file. 1 is up-mixed to --channels. No resampling is done.",
                    defaultValue: "2", placeholder: "1 | 2"
                ),
                rate(nil, default: "48000"),
                channels(nil, default: "2"),
                exitWithParent
            ]
        ),

        PipelineHelperSpec(
            name: "AUProcessor",
            category: .processing,
            summary: "Runs stdin → stdout through one installed Audio Unit effect — no "
                + "audio device, no plugin window. Set parameters with --param, load an "
                + ".aupreset, or adjust live over the control port.",
            options: [
                PipelineHelperOption(
                    flag: "--unit", kind: .string,
                    summary: "The effect: a name (AUGraphicEQ) or the type:subtype:manuf codes from --list-units.",
                    isRequired: true, placeholder: "<name | aufx:sub:manu>"
                ),
                rate(8_000...192_000, default: "48000"),
                channels(1...8, default: "2"),
                PipelineHelperOption(
                    flag: "--param", kind: .string,
                    summary: "Set a parameter as <name>=<value> (clamped to its published range). "
                        + "Write spaces in names as underscores. Repeatable.",
                    isRepeatable: true, placeholder: "<name>=<value>"
                ),
                PipelineHelperOption(
                    flag: "--preset", kind: .path,
                    summary: "Load an .aupreset file saved from any AU host.",
                    placeholder: "<path>.aupreset"
                ),
                PipelineHelperOption(
                    flag: "--factory-preset", kind: .int(nil),
                    summary: "Select a built-in preset by index (see --list-params).",
                    placeholder: "<index>"
                ),
                PipelineHelperOption(
                    flag: "--control-port", kind: .int(1...65_535),
                    summary: "UDP port for live 'param' / 'bypass' / 'preset' commands.",
                    placeholder: "<n>"
                ),
                PipelineHelperOption(
                    flag: "--out-of-process", kind: .flag,
                    summary: "Host the AU in a system-extension process — for v2 plugins that won't load in-process."
                ),
                exitWithParent
            ],
            diagnosticFlags: ["--list-units", "--list-params"]
        ),

        PipelineHelperSpec(
            name: "AudioInputCapture",
            category: .source,
            summary: "Captures a Core Audio input device (microphone, line-in, loopback "
                + "drivers) and writes S16LE PCM to stdout.",
            options: [
                PipelineHelperOption(
                    flag: "--device-name", kind: .string,
                    summary: "Input device name, e.g. \"MacBook Pro Microphone\".",
                    isRequired: true, placeholder: "<name>"
                ),
                rate(nil, default: "48000"),
                channels(nil, default: "2"),
                exitWithParent
            ]
        ),

        PipelineHelperSpec(
            name: "FMDeemphasis",
            category: .processing,
            summary: "First-order IIR FM de-emphasis filter (RC-network model), running "
                + "in floating point at 48 kHz after sox resampling.",
            options: [
                rate(nil, default: "48000"),
                channels(nil, default: "2"),
                PipelineHelperOption(
                    flag: "--tau", kind: .double(nil),
                    summary: "De-emphasis time constant in microseconds. 75 = U.S., 50 = Europe/ITU.",
                    defaultValue: "75.0", placeholder: "<µs>"
                )
            ]
        ),

        PipelineHelperSpec(
            name: "PCMJitterBuffer",
            category: .processing,
            summary: "Real-time pacing stage: absorbs bursty upstream delivery (e.g. "
                + "nrsc5's ~186 ms HD Radio frame cadence) and re-emits it as a steady "
                + "stream, trading a fixed --buffer-ms of latency.",
            options: [
                PipelineHelperOption(
                    flag: "--rate", aliases: ["-r"], kind: .int(nil),
                    summary: "Sample rate in Hz. Must match the neighbouring stages.",
                    isRequired: true, placeholder: "<hz>"
                ),
                PipelineHelperOption(
                    flag: "--channels", aliases: ["-c"], kind: .int(nil),
                    summary: "Channel count. Must match the neighbouring stages.",
                    defaultValue: "2", placeholder: "<n>"
                ),
                PipelineHelperOption(
                    flag: "--buffer-ms", kind: .int(nil),
                    summary: "Buffer depth in milliseconds — the latency traded for absorbing bursts.",
                    defaultValue: "400", placeholder: "<ms>"
                )
            ]
        ),

        PipelineHelperSpec(
            name: "LiveAudioRecorder",
            category: .processing,
            summary: "Passthrough stage that tees the PCM into MP3 and/or AAC file "
                + "recording. Can sit anywhere in a chain, or run standalone. "
                + "At least one of --mp3 / --aac is required.",
            options: [
                PipelineHelperOption(
                    flag: "--mp3", kind: .path,
                    summary: "Write an MP3 file at this path.",
                    placeholder: "<path>"
                ),
                PipelineHelperOption(
                    flag: "--aac", kind: .path,
                    summary: "Write an AAC (.m4a) file at this path.",
                    placeholder: "<path>"
                ),
                rate(nil, default: "48000"),
                channels(nil, default: "2"),
                PipelineHelperOption(
                    flag: "--mp3-bitrate", kind: .int(nil),
                    summary: "MP3 bitrate in kbps.", defaultValue: "128", placeholder: "<kbps>"
                ),
                PipelineHelperOption(
                    flag: "--aac-bitrate", kind: .int(nil),
                    summary: "AAC bitrate in bits per second.", defaultValue: "128000", placeholder: "<bps>"
                ),
                PipelineHelperOption(
                    flag: "--verbose", kind: .flag,
                    summary: "Log per-chunk encoder progress to stderr."
                )
            ]
        ),

        PipelineHelperSpec(
            name: "PCMTranscriber",
            category: .processing,
            summary: "Passthrough stage that tees the PCM into Apple's on-device "
                + "SpeechAnalyzer (macOS 26+). Emits result JSON over UDP and/or a "
                + "transcript file. No-ops on older systems. Needs --udp-port and/or --transcript-file.",
            options: [
                rate(8_000...192_000, default: "48000"),
                channels(1...2, default: "2"),
                PipelineHelperOption(
                    flag: "--locale", kind: .string,
                    summary: "Recognition locale as a BCP-47 tag.",
                    defaultValue: "en-US", placeholder: "<bcp47>"
                ),
                PipelineHelperOption(
                    flag: "--udp-port", kind: .int(1...65_535),
                    summary: "Send newline-delimited JSON transcription events to this port.",
                    placeholder: "<n>"
                ),
                PipelineHelperOption(
                    flag: "--udp-host", kind: .string,
                    summary: "Destination for the JSON events.",
                    defaultValue: "127.0.0.1", placeholder: "<addr>"
                ),
                PipelineHelperOption(
                    flag: "--transcript-file", kind: .path,
                    summary: "Append finalized segments to this file (plain text / SRT / VTT by extension).",
                    placeholder: "<path>"
                ),
                PipelineHelperOption(
                    flag: "--partials", kind: .flag,
                    summary: "Also emit volatile (not-yet-final) hypotheses over UDP."
                ),
                exitWithParent
            ]
        ),

        PipelineHelperSpec(
            name: "PCMDistanceGain",
            category: .processing,
            summary: "Distance-based loudness falloff stage (spatial-audio prep, "
                + "alongside PCMBinauralPanner). Live-adjustable over its own UDP control port.",
            options: [
                rate(8_000...192_000, default: "48000"),
                channels(1...8, default: "2"),
                PipelineHelperOption(
                    flag: "--distance", kind: .double(nil),
                    summary: "Initial distance in pad units (>= 0).",
                    defaultValue: "1.0", placeholder: "<d>"
                ),
                PipelineHelperOption(
                    flag: "--reference-distance", kind: .double(nil),
                    summary: "Distance at/inside which gain is unity (> 0).",
                    defaultValue: "1.0", placeholder: "<d>"
                ),
                PipelineHelperOption(
                    flag: "--rolloff", kind: .double(nil),
                    summary: "Falloff exponent. 1.0 = physical inverse-distance; lower is gentler.",
                    defaultValue: "0.8", placeholder: "<r>"
                ),
                PipelineHelperOption(
                    flag: "--min-gain", kind: .double(0.0...1.0),
                    summary: "Gain floor, so a far source fades but never vanishes.",
                    defaultValue: "0.05", placeholder: "0..1"
                ),
                PipelineHelperOption(
                    flag: "--control-port", kind: .int(1...65_535),
                    summary: "UDP port for live 'distance' updates.",
                    placeholder: "<n>"
                ),
                exitWithParent
            ]
        ),

        PipelineHelperSpec(
            name: "PCMBinauralPanner",
            category: .processing,
            summary: "Direction stage: ITD/ILD azimuth/elevation panning (not measured "
                + "HRTF) plus distance-driven air absorption, downmixing to mono and "
                + "emitting true 2-channel binaural. Sits downstream of PCMDistanceGain; "
                + "live-adjustable over its own UDP control port.",
            options: [
                rate(8_000...192_000, default: "48000"),
                channels(1...8, default: "2 (downmixed to mono)"),
                PipelineHelperOption(
                    flag: "--azimuth", kind: .double(nil),
                    summary: "Initial azimuth in degrees (0 = front, positive = right).",
                    defaultValue: "0", placeholder: "<deg>"
                ),
                PipelineHelperOption(
                    flag: "--elevation", kind: .double(-90.0...90.0),
                    summary: "Initial elevation in degrees (−90…90).",
                    defaultValue: "0", placeholder: "<deg>"
                ),
                PipelineHelperOption(
                    flag: "--head-radius", kind: .double(nil),
                    summary: "Head radius in metres, for the ITD model.",
                    defaultValue: "0.0875", placeholder: "<m>"
                ),
                PipelineHelperOption(
                    flag: "--ild-depth", kind: .double(0.0...1.0),
                    summary: "Far-ear level reduction at full pan, 0–1.",
                    defaultValue: "0.6", placeholder: "0..1"
                ),
                PipelineHelperOption(
                    flag: "--shadow-min-cutoff", kind: .double(nil),
                    summary: "Head-shadow lowpass cutoff (Hz) at full pan.",
                    defaultValue: "1500", placeholder: "<hz>"
                ),
                PipelineHelperOption(
                    flag: "--shadow-max-cutoff", kind: .double(nil),
                    summary: "Head-shadow lowpass cutoff (Hz) at azimuth 0 (no shadow).",
                    defaultValue: "18000", placeholder: "<hz>"
                ),
                PipelineHelperOption(
                    flag: "--elevation-shelf-db", kind: .double(nil),
                    summary: "Max high-shelf tilt at ±90° elevation, dB.",
                    defaultValue: "4.0", placeholder: "<dB>"
                ),
                PipelineHelperOption(
                    flag: "--distance", kind: .double(nil),
                    summary: "Initial distance in pad units, for air absorption (>= 0).",
                    defaultValue: "1.0", placeholder: "<d>"
                ),
                PipelineHelperOption(
                    flag: "--reference-distance", kind: .double(nil),
                    summary: "Distance at/inside which there's no air absorption. "
                        + "Match PCMDistanceGain's --reference-distance.",
                    defaultValue: "1.0", placeholder: "<d>"
                ),
                PipelineHelperOption(
                    flag: "--air-absorption-min-cutoff", kind: .double(nil),
                    summary: "Lowpass cutoff (Hz) at --air-absorption-distance.",
                    defaultValue: "1200", placeholder: "<hz>"
                ),
                PipelineHelperOption(
                    flag: "--air-absorption-max-cutoff", kind: .double(nil),
                    summary: "Lowpass cutoff (Hz) at/inside the reference distance.",
                    defaultValue: "20000", placeholder: "<hz>"
                ),
                PipelineHelperOption(
                    flag: "--air-absorption-distance", kind: .double(nil),
                    summary: "Distance at which the cutoff reaches its minimum. "
                        + "Must be greater than --reference-distance.",
                    defaultValue: "8.0", placeholder: "<d>"
                ),
                PipelineHelperOption(
                    flag: "--control-port", kind: .int(1...65_535),
                    summary: "UDP port for live 'azimuth' / 'elevation' / 'distance' updates.",
                    placeholder: "<n>"
                ),
                exitWithParent
            ]
        )
    ]
}
