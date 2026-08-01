// Sources/AudioEncoders/AACEncoder.swift
// Real-time AAC encoder using macOS AudioToolbox (AudioConverter).
// Produces a raw ADTS-framed AAC bitstream. Ported from LiveAudioServer's
// AACEncoder: takes plain PCM in, hands encoded frames to a caller-supplied
// closure instead of a ChunkBroadcaster, and drops the HLSSegmenter hookup —
// HLS playlist segmenting is an HTTP-streaming concern that doesn't belong in
// a plain file-recording pipeline stage.
//
// ADTS framing is applied so that clients (or downstream tools like ffmpeg)
// can begin decoding at any frame boundary without an MP4 container.

import Foundation
import AudioToolbox

// MARK: - ADTS Framing Helper

/// Wraps a raw AAC frame in a 7-byte ADTS header so it can be written/streamed
/// without an MP4 container.
public func adtsHeader(frameLength: Int, sampleRate: Int, channels: Int) -> [UInt8] {
    // ADTS sync word + header (no CRC, so 7 bytes)
    let aacProfile: UInt8 = 2        // AAC-LC = profile 1 (value - 1 in header = 1)
    let freqIndex: UInt8  = sampleRateIndex(sampleRate)
    let chanConf: UInt8   = UInt8(channels)
    let fullLen = frameLength + 7     // frame + header

    var header = [UInt8](repeating: 0, count: 7)
    header[0] = 0xFF
    header[1] = 0xF1                 // 0xF9 for MPEG-2 AAC; 0xF1 = MPEG-4 + no CRC
    header[2] = ((aacProfile - 1) << 6) | (freqIndex << 2) | (chanConf >> 2)
    header[3] = ((chanConf & 0x3) << 6) | UInt8((fullLen >> 11) & 0x3)
    header[4] = UInt8((fullLen >> 3) & 0xFF)
    header[5] = UInt8((fullLen & 0x7) << 5) | 0x1F
    header[6] = 0xFC
    return header
}

private func sampleRateIndex(_ rate: Int) -> UInt8 {
    let table = [96000, 88200, 64000, 48000, 44100, 32000,
                 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    return UInt8(table.firstIndex(of: rate) ?? 4) // default 44100 = index 4
}

// MARK: - Input Buffer (PCM accumulator)

/// AudioConverter pulls PCM via a callback. We keep a rolling queue of Int16 frames.
private final class PCMQueue {
    private var buffer = [Int16]()
    private let lock  = NSLock()

    func push(_ samples: UnsafeBufferPointer<Int16>) {
        lock.lock()
        buffer.append(contentsOf: samples)
        lock.unlock()
    }

    /// Pull up to `count` samples. Returns nil if not enough data yet.
    func pull(count: Int) -> [Int16]? {
        lock.lock(); defer { lock.unlock() }
        guard buffer.count >= count else { return nil }
        let chunk = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        return chunk
    }

    var available: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }
}

// MARK: - AACEncoder

public final class AACEncoder {
    private let config: AudioEncoderConfig
    private let onEncoded: (Data) -> Void

    private var converter: AudioConverterRef?
    private let pcmQueue = PCMQueue()

    // AudioConverter input format constants
    private var inputFormat  = AudioStreamBasicDescription()
    private var outputFormat = AudioStreamBasicDescription()

    // Frames per AAC packet (1024 for AAC-LC)
    private let framesPerPacket: Int = 1024

    // Scratch output buffer
    private var outputBuf: [UInt8]

    public init(config: AudioEncoderConfig, onEncoded: @escaping (Data) -> Void) {
        self.config = config
        self.onEncoded = onEncoded
        self.outputBuf = [UInt8](repeating: 0, count: 8192)
    }

    // MARK: - Lifecycle

    public func start() throws {
        // Input: signed 16-bit integer PCM, interleaved
        inputFormat.mSampleRate       = Float64(config.sampleRate)
        inputFormat.mFormatID         = kAudioFormatLinearPCM
        inputFormat.mFormatFlags      = kLinearPCMFormatFlagIsSignedInteger |
                                        kLinearPCMFormatFlagIsPacked
        inputFormat.mBitsPerChannel   = 16
        inputFormat.mChannelsPerFrame = UInt32(config.channels)
        inputFormat.mBytesPerFrame    = UInt32(config.channels * 2)
        inputFormat.mFramesPerPacket  = 1
        inputFormat.mBytesPerPacket   = UInt32(config.channels * 2)

        // Output: AAC-LC
        outputFormat.mSampleRate       = Float64(config.sampleRate)
        outputFormat.mFormatID         = kAudioFormatMPEG4AAC
        outputFormat.mChannelsPerFrame = UInt32(config.channels)
        outputFormat.mFormatFlags      = 0
        outputFormat.mFramesPerPacket  = UInt32(framesPerPacket)
        // Remaining fields filled by AudioConverter

        var converterRef: AudioConverterRef?
        let status = AudioConverterNew(&inputFormat, &outputFormat, &converterRef)
        guard status == noErr, let conv = converterRef else {
            throw AudioEncoderError.initFailed("AudioConverterNew failed: \(status)")
        }
        converter = conv

        // Set target bitrate
        var bitrate = UInt32(config.aacBitrate)
        AudioConverterSetProperty(conv,
                                  kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size),
                                  &bitrate)

        encoderLog("AAC encoder ready: \(config.aacBitrate/1000)kbps, \(config.channels)ch, \(config.sampleRate)Hz", config: config)
    }

    public func stop() {
        flush()
        if let conv = converter {
            AudioConverterDispose(conv)
            converter = nil
        }
    }

    // MARK: - Encoding

    /// Feed raw PCM into the encoder. Empty buffer = flush signal.
    public func encode(samples: UnsafeBufferPointer<Int16>) {
        if samples.count == 0 {
            flush()
            return
        }
        pcmQueue.push(samples)
        drainQueue()
    }

    // MARK: - Internal

    /// Drain as many complete 1024-frame packets as possible from the queue.
    private func drainQueue() {
        guard let converter = converter else { return }
        let samplesNeeded = framesPerPacket * config.channels

        while pcmQueue.available >= samplesNeeded {
            guard let pcmChunk = pcmQueue.pull(count: samplesNeeded) else { break }

            var inputData = pcmChunk  // mutable local copy
            let bytesAvailable = samplesNeeded * 2   // Int16 = 2 bytes

            // Borrow a stable pointer into inputData for the duration of the
            // synchronous AudioConverterFillComplexBuffer call. The callback
            // reads from ctx.samplesPtr while still inside this closure.
            inputData.withUnsafeMutableBufferPointer { pcmPtr in
                var ctx = ConverterContext(
                    samplesPtr: UnsafeMutableRawPointer(pcmPtr.baseAddress!),
                    bytesAvailable: UInt32(bytesAvailable),
                    channels: UInt32(config.channels),
                    packetsAvailable: UInt32(framesPerPacket)
                )

                var outPacketDesc = AudioStreamPacketDescription()
                var ioOutputDataPacketSize: UInt32 = 1
                var outputABL = AudioBufferList()
                outputABL.mNumberBuffers = 1

                let outputBufSize: Int = 8192
                var rawOutputBuf = [UInt8](repeating: 0, count: outputBufSize)
                rawOutputBuf.withUnsafeMutableBytes { outBufPtr in
                    withUnsafeMutableBytes(of: &outputABL.mBuffers) { ablPtr in
                        let buf = ablPtr.bindMemory(to: AudioBuffer.self).baseAddress!
                        buf.pointee.mNumberChannels = UInt32(config.channels)
                        buf.pointee.mDataByteSize   = UInt32(outputBufSize)
                        buf.pointee.mData           = outBufPtr.baseAddress
                    }

                    let fillStatus = withUnsafeMutablePointer(to: &ctx) { ctxPtr in
                        AudioConverterFillComplexBuffer(
                            converter,
                            converterInputDataProc,
                            ctxPtr,
                            &ioOutputDataPacketSize,
                            &outputABL,
                            &outPacketDesc
                        )
                    }

                    if fillStatus == noErr || fillStatus == kAudioConverterErr_InvalidInputSize {
                        withUnsafeBytes(of: outputABL.mBuffers) { ablPtr in
                            let audioBuf = ablPtr.bindMemory(to: AudioBuffer.self).baseAddress!
                            let frameBytes = Int(audioBuf.pointee.mDataByteSize)
                            if frameBytes > 0 {
                                let adts = adtsHeader(frameLength: frameBytes,
                                                      sampleRate: config.sampleRate,
                                                      channels: config.channels)
                                var frameData = Data(adts)
                                if let dataPtr = audioBuf.pointee.mData {
                                    frameData.append(Data(bytes: dataPtr, count: frameBytes))
                                }
                                self.onEncoded(frameData)
                            }
                        }
                    } else if fillStatus != noErr {
                        encoderLog("⚠ AudioConverterFillComplexBuffer error: \(fillStatus)", config: config)
                    }
                }
            }
        }
    }

    private func flush() {
        // AudioConverter doesn't have an explicit flush for streaming;
        // draining remaining PCM is sufficient for ADTS clients.
        if let conv = converter {
            AudioConverterReset(conv)
        }
        encoderLog("AAC encoder flushed", config: config)
    }
}

// MARK: - AudioConverter Input Callback

private struct ConverterContext {
    var samplesPtr: UnsafeMutableRawPointer
    var bytesAvailable: UInt32
    var channels: UInt32
    var packetsAvailable: UInt32
    var consumed: Bool = false
}

private let converterInputDataProc: AudioConverterComplexInputDataProc = {
    (_, ioNumberDataPackets, ioData, _, inUserData) -> OSStatus in

    guard let ctxPtr = inUserData?.assumingMemoryBound(to: ConverterContext.self) else {
        return kAudioConverterErr_UnspecifiedError
    }

    if ctxPtr.pointee.consumed {
        // No more data this round
        ioNumberDataPackets.pointee = 0
        return kAudioConverterErr_InvalidInputSize
    }

    withUnsafeMutableBytes(of: &ioData.pointee.mBuffers) { ablPtr in
        let buf = ablPtr.bindMemory(to: AudioBuffer.self).baseAddress!
        buf.pointee.mNumberChannels = ctxPtr.pointee.channels
        buf.pointee.mDataByteSize   = ctxPtr.pointee.bytesAvailable
        buf.pointee.mData           = ctxPtr.pointee.samplesPtr
    }

    ioNumberDataPackets.pointee = ctxPtr.pointee.packetsAvailable
    ctxPtr.pointee.consumed = true
    return noErr
}
