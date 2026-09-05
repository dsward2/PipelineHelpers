// swift-tools-version: 5.9
import PackageDescription

// PipelineHelpers — the audio-pipeline pieces shared by AntennaHead and
// ControlBooth, consolidated from AntennaHead's seven single-executable
// packages so both apps stay synchronized with one local-package reference.
//
// Executable products (helper tools embedded in each app's Contents/Helpers;
// product names are load-bearing — custom tasks and Copy Files phases resolve
// them by name):
//   • PCMUDPSender      terminal stage: stdin → UDP datagrams (LiveAudioServer
//                       input, or cross-app hop to PCMUDPReceiver)
//   • PCMUDPReceiver    source stage: UDP datagrams → stdout
//   • PCMPassthrough    stdin → stdout template stage
//   • PCMPrefix         plays a pre-rendered clip, then passes stdin through —
//                       used for the spoken station announcement before playback
//   • PCMMixer          mixes two PCM inputs
//   • PCMSpeechSynth    self-pacing speech-synthesis source (test signal)
//   • PCMFilePlayer     self-pacing AAC/MP3 (or any AVAudioFile-readable)
//                       file/playlist source, with optional indefinite repeat
//   • AUProcessor       hosts one Audio Unit effect, stdin → effect → stdout
//   • AudioInputCapture Core Audio device capture → 48 kHz/2 ch S16LE stdout
//   • FMDeemphasis      first-order IIR de-emphasis filter (75 µs U.S. / 50 µs EU)
//   • PCMJitterBuffer   real-time pacing stage: absorbs bursty upstream
//                       delivery (e.g. nrsc5's ~186ms HD Radio logical-frame
//                       cadence) and re-emits it as a steady stream
//   • LiveAudioRecorder stdin → stdout passthrough stage that tees the PCM
//                       into MP3/AAC file recording; can sit before or after
//                       LiveAudioServer in AntennaHead, or run standalone
//                       (including several instances concurrently) in
//                       ControlBooth
//   • PCMTranscriber    stdin → stdout passthrough stage that tees the PCM
//                       into Apple's on-device SpeechAnalyzer/SpeechTranscriber
//                       (macOS 26+); emits result JSON over UDP and/or a
//                       text/SRT/VTT transcript file. No-ops on older systems.
//   • PCMDistanceGain   distance-based loudness falloff stage (spatial-audio
//                       prep, alongside PCMBinauralPanner); live-adjustable
//                       over its own UDP control port
//   • PCMBinauralPanner direction stage: ITD/ILD-based azimuth/elevation
//                       panning (not measured-HRTF), downmixing to mono and
//                       emitting true 2-channel binaural output; sits
//                       downstream of PCMDistanceGain, live-adjustable over
//                       its own UDP control port
//
// Library products:
//   • PipelineRunner    TaskPipelineManager + TaskItem — Process-chain
//                       assembly/teardown used by both apps (previously
//                       duplicated verbatim in ControlBooth)
//   • AudioEncoders     MP3/AAC PCM encoders (ported from LiveAudioServer's
//                       MP3Encoder/AACEncoder, minus its HTTP-streaming
//                       machinery) shared by LiveAudioRecorder; LiveAudioServer
//                       still carries its own copy for now — see repo notes on
//                       migrating it to depend on this target instead
//
// Every stage speaks the shared contract: raw S16LE PCM on stdin/stdout,
// normalized to 48 kHz / 2 ch before reaching LiveAudioServer.
let package = Package(
    name: "PipelineHelpers",
    platforms: [
        // PipelineRunner uses @Observable (Observation framework).
        .macOS(.v14)
    ],
    products: [
        .library(name: "PipelineRunner", targets: ["PipelineRunner"]),
        .library(name: "AudioEncoders", targets: ["AudioEncoders"]),
        .executable(name: "PCMUDPSender", targets: ["PCMUDPSender"]),
        .executable(name: "PCMUDPReceiver", targets: ["PCMUDPReceiver"]),
        .executable(name: "PCMPassthrough", targets: ["PCMPassthrough"]),
        .executable(name: "PCMPrefix", targets: ["PCMPrefix"]),
        .executable(name: "PCMMixer", targets: ["PCMMixer"]),
        .executable(name: "PCMSpeechSynth", targets: ["PCMSpeechSynth"]),
        .executable(name: "PCMFilePlayer", targets: ["PCMFilePlayer"]),
        .executable(name: "AUProcessor", targets: ["AUProcessor"]),
        .executable(name: "AudioInputCapture", targets: ["AudioInputCapture"]),
        .executable(name: "FMDeemphasis", targets: ["FMDeemphasis"]),
        .executable(name: "PCMJitterBuffer", targets: ["PCMJitterBuffer"]),
        .executable(name: "LiveAudioRecorder", targets: ["LiveAudioRecorder"]),
        .executable(name: "PCMTranscriber", targets: ["PCMTranscriber"]),
        .executable(name: "PCMDistanceGain", targets: ["PCMDistanceGain"]),
        .executable(name: "PCMBinauralPanner", targets: ["PCMBinauralPanner"])
    ],
    targets: [
        .target(name: "PipelineRunner"),
        .testTarget(name: "PipelineRunnerTests", dependencies: ["PipelineRunner"]),
        .testTarget(name: "AudioEncodersTests", dependencies: ["AudioEncoders"]),
        // Vendored libmp3lame as a universal (arm64 + x86_64) static
        // XCFramework, mirrored from LiveAudioServer/Frameworks. Regenerate
        // there via scripts/build-mp3lame-xcframework.sh and re-copy.
        //
        // Named PHCLame, not CLame: LiveAudioServer vendors the same
        // xcframework under its own "CLame" binaryTarget, and when both
        // packages sit in one app's dependency graph (AntennaHead, which
        // depends on both), SwiftPM requires every target name to be unique
        // across the whole graph — "CLame" here would collide with theirs.
        //
        // Directory named PHMp3Lame.xcframework (not Mp3Lame.xcframework) so
        // Xcode's SignatureCollection task produces a distinct output path from
        // LiveAudioServer's copy; duplicate output paths cause "Unexpected
        // duplicate tasks" during archive even though the SwiftPM target names
        // are already unique.
        .binaryTarget(
            name: "PHCLame",
            path: "Frameworks/PHMp3Lame.xcframework"
        ),
        .target(
            name: "AudioEncoders",
            dependencies: ["PHCLame"]
        ),
        .executableTarget(name: "PCMUDPSender"),
        .executableTarget(name: "PCMUDPReceiver"),
        .executableTarget(name: "PCMPassthrough"),
        .executableTarget(name: "PCMPrefix"),
        .executableTarget(name: "PCMMixer"),
        .executableTarget(name: "PCMSpeechSynth"),
        .executableTarget(name: "PCMFilePlayer"),
        .executableTarget(name: "AUProcessor"),
        .executableTarget(name: "AudioInputCapture"),
        .executableTarget(name: "FMDeemphasis"),
        .executableTarget(name: "PCMJitterBuffer"),
        .executableTarget(
            name: "LiveAudioRecorder",
            dependencies: ["AudioEncoders"]
        ),
        .executableTarget(name: "PCMTranscriber"),
        .executableTarget(name: "PCMDistanceGain"),
        .executableTarget(name: "PCMBinauralPanner")
    ]
)
