import Foundation

// PCMPassthrough — a no-op AntennaHead audio-pipeline stage.
//
// Contract (shared by every pipeline unit):
//   • Input  : raw signed 16-bit little-endian, mono, 48000 Hz PCM on stdin
//   • Output : the same PCM format on stdout
//   • Sits between rtl_fm and LiveAudioServer in the TaskPipelineManager chain.
//
// This stage copies stdin to stdout unchanged. To build a real filter, replace
// the copy below with your DSP while preserving the format and the
// stdin -> stdout streaming contract (process in chunks, never buffer the
// whole stream).

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let log = FileHandle.standardError

func note(_ message: String) {
    log.write(Data("PCMPassthrough: \(message)\n".utf8))
}

note("started — passing through S16LE mono 48000 Hz")

var totalBytes = 0
while true {
    let chunk = input.availableData
    if chunk.isEmpty { break } // EOF: upstream (rtl_fm) closed.
    output.write(chunk)
    totalBytes += chunk.count
}

note("stdin closed — \(totalBytes) bytes passed through; exiting")
