// AudioEncoders — shared MP3/AAC PCM encoders for AntennaHead-family pipeline
// stages. Extracted from LiveAudioServer's MP3Encoder/AACEncoder so any
// stdin->stdout pipeline stage (e.g. LiveAudioRecorder) can encode PCM
// without depending on LiveAudioServer's HTTP-streaming machinery
// (ChunkBroadcaster, HLSSegmenter, ServerConfig). LiveAudioServerCore keeps
// its own copies for now; migrating it to depend on this target instead is a
// follow-up, not part of this scaffold.

import Foundation

public struct AudioEncoderConfig {
    public var sampleRate: Int
    public var channels: Int
    public var mp3Bitrate: Int      // kbps
    public var aacBitrate: Int      // bps (AudioToolbox uses bps, not kbps)
    public var chunkFrames: Int     // frames per input chunk; sizes the MP3 scratch buffer
    public var verbose: Bool

    public init(sampleRate: Int = 48000, channels: Int = 2, mp3Bitrate: Int = 128,
                aacBitrate: Int = 128_000, chunkFrames: Int = 4096, verbose: Bool = false) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.mp3Bitrate = mp3Bitrate
        self.aacBitrate = aacBitrate
        self.chunkFrames = chunkFrames
        self.verbose = verbose
    }
}

public enum AudioEncoderError: Error, CustomStringConvertible {
    case initFailed(String)

    public var description: String {
        switch self {
        case .initFailed(let s): return "Encoder init failed: \(s)"
        }
    }
}

func encoderLog(_ msg: String, verbose: Bool = false, config: AudioEncoderConfig? = nil) {
    if verbose, let cfg = config, !cfg.verbose { return }
    FileHandle.standardError.write(Data("[AudioEncoders] \(msg)\n".utf8))
}
