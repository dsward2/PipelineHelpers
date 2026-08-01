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
//   • PCMMixer          mixes two PCM inputs
//   • PCMSpeechSynth    self-pacing speech-synthesis source (test signal)
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
        .executable(name: "PCMMixer", targets: ["PCMMixer"]),
        .executable(name: "PCMSpeechSynth", targets: ["PCMSpeechSynth"]),
        .executable(name: "AUProcessor", targets: ["AUProcessor"]),
        .executable(name: "AudioInputCapture", targets: ["AudioInputCapture"]),
        .executable(name: "FMDeemphasis", targets: ["FMDeemphasis"]),
        .executable(name: "PCMJitterBuffer", targets: ["PCMJitterBuffer"]),
        .executable(name: "LiveAudioRecorder", targets: ["LiveAudioRecorder"])
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
        .binaryTarget(
            name: "PHCLame",
            path: "Frameworks/Mp3Lame.xcframework"
        ),
        .target(
            name: "AudioEncoders",
            dependencies: ["PHCLame"]
        ),
        .executableTarget(name: "PCMUDPSender"),
        .executableTarget(name: "PCMUDPReceiver"),
        .executableTarget(name: "PCMPassthrough"),
        .executableTarget(name: "PCMMixer"),
        .executableTarget(name: "PCMSpeechSynth"),
        .executableTarget(name: "AUProcessor"),
        .executableTarget(name: "AudioInputCapture"),
        .executableTarget(name: "FMDeemphasis"),
        .executableTarget(name: "PCMJitterBuffer"),
        .executableTarget(
            name: "LiveAudioRecorder",
            dependencies: ["AudioEncoders"]
        )
    ]
)
