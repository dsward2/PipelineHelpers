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
//
// Library product:
//   • PipelineRunner    TaskPipelineManager + TaskItem — Process-chain
//                       assembly/teardown used by both apps (previously
//                       duplicated verbatim in ControlBooth)
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
        .executable(name: "PCMUDPSender", targets: ["PCMUDPSender"]),
        .executable(name: "PCMUDPReceiver", targets: ["PCMUDPReceiver"]),
        .executable(name: "PCMPassthrough", targets: ["PCMPassthrough"]),
        .executable(name: "PCMMixer", targets: ["PCMMixer"]),
        .executable(name: "PCMSpeechSynth", targets: ["PCMSpeechSynth"]),
        .executable(name: "AUProcessor", targets: ["AUProcessor"]),
        .executable(name: "AudioInputCapture", targets: ["AudioInputCapture"])
    ],
    targets: [
        .target(name: "PipelineRunner"),
        .executableTarget(name: "PCMUDPSender"),
        .executableTarget(name: "PCMUDPReceiver"),
        .executableTarget(name: "PCMPassthrough"),
        .executableTarget(name: "PCMMixer"),
        .executableTarget(name: "PCMSpeechSynth"),
        .executableTarget(name: "AUProcessor"),
        .executableTarget(name: "AudioInputCapture")
    ]
)
