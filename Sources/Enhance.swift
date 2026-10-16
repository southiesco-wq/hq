import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

// MARK: - Settings

/// How hard to remove background noise. Uses Apple's on-device voice isolation (macOS 13+).
enum NoiseLevel: String, CaseIterable, Identifiable {
    case off, light, medium, strong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .medium: return "Medium"
        case .strong: return "Strong"
        }
    }

    /// Share of the isolated voice in the result (the rest is the original sound).
    var wetPercent: Float {
        switch self {
        case .off: return 0
        case .light: return 55
        case .medium: return 80
        case .strong: return 100
        }
    }
}

struct CleanupOptions {
    var noise: NoiseLevel = .off
    /// Gentle speech EQ: rumble cut, less boxiness, more clarity.
    var enhanceVoice = false
    /// Brings the result to a standard level and keeps peaks from clipping.
    var evenLoudness = false

    var isActive: Bool { noise != .off || enhanceVoice || evenLoudness }

    /// Short description for the finished-file line, e.g. "noise removed (strong), voice enhanced".
    var summary: String {
        var parts: [String] = []
        if noise != .off { parts.append("noise removed (\(noise.label.lowercased()))") }
        if enhanceVoice { parts.append("voice enhanced") }
        if evenLoudness { parts.append("loudness evened") }
        return parts.joined(separator: ", ")
    }
}

/// Speech loudness target, in LUFS. Common for podcasts, voice-overs and social video.
let targetLoudness = -16.0

// MARK: - Filters

/// One second-order filter section (Direct Form II transposed).
struct Biquad {
    private let b0, b1, b2, a1, a2: Double
    private var z1 = 0.0
    private var z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func highPass(rate: Double, frequency: Double, q: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / rate
        let c = cos(w), alpha = sin(w) / (2 * q), a0 = 1 + alpha
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0,
                      a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    static func peak(rate: Double, frequency: Double, gainDB: Double, q: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * frequency / rate
        let c = cos(w), alpha = sin(w) / (2 * q), a0 = 1 + alpha / a
        return Biquad(b0: (1 + alpha * a) / a0, b1: -2 * c / a0, b2: (1 - alpha * a) / a0,
                      a1: -2 * c / a0, a2: (1 - alpha / a) / a0)
    }

    // K-weighting stages from ITU-R BS.1770, worked out for any sample rate.
    static func kShelf(rate: Double) -> Biquad {
        let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
        let k = tan(Double.pi * f0 / rate)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                      a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }

    static func kHighPass(rate: Double) -> Biquad {
        let f0 = 38.13547087602444, q = 0.5003270373238773
        let k = tan(Double.pi * f0 / rate)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }
}

/// A light speech EQ: removes rumble below 80 Hz, trims boxiness around 250 Hz,
/// and lifts presence (3.5 kHz) and air (10 kHz) so voices sound clearer.
struct VoiceEQ {
    private var stages: [Biquad]

    init(rate: Double) {
        stages = [
            .highPass(rate: rate, frequency: 80, q: 0.707),
            .peak(rate: rate, frequency: 250, gainDB: -2.5, q: 1.0),
            .peak(rate: rate, frequency: 3500, gainDB: 3.0, q: 0.9),
            .peak(rate: rate, frequency: 10000, gainDB: 1.5, q: 0.7)
        ]
    }

    mutating func process(_ samples: inout [Float]) {
        for i in samples.indices {
            var x = Double(samples[i])
            for s in stages.indices { x = stages[s].process(x) }
            samples[i] = Float(x)
        }
    }
}

/// Integrated loudness (LUFS) per ITU-R BS.1770 / EBU R128, for one channel.
final class LoudnessMeter {
    private var shelf: Biquad
    private var highPass: Biquad
    private let blockSize: Int
    private var sum = 0.0
    private var count = 0
    private var blocks: [Double] = []

    init(rate: Double) {
        shelf = .kShelf(rate: rate)
        highPass = .kHighPass(rate: rate)
        blockSize = max(1, Int((rate * 0.1).rounded()))
    }

    func add(_ samples: [Float]) {
        for v in samples {
            let y = highPass.process(shelf.process(Double(v)))
            sum += y * y
            count += 1
            if count == blockSize {
                blocks.append(sum / Double(count))
                sum = 0
                count = 0
            }
        }
    }

    /// nil when there is no measurable sound.
    var integrated: Double? {
        guard blocks.count >= 4 else { return nil }
        func lufs(_ power: Double) -> Double { -0.691 + 10 * log10(max(power, 1e-20)) }
        var windows: [Double] = []
        windows.reserveCapacity(blocks.count - 3)
        for i in 0..<(blocks.count - 3) {
            windows.append((blocks[i] + blocks[i + 1] + blocks[i + 2] + blocks[i + 3]) / 4)
        }
        let loud = windows.filter { lufs($0) > -70 }
        guard !loud.isEmpty else { return nil }
        let relative = lufs(loud.reduce(0, +) / Double(loud.count)) - 10
        let kept = loud.filter { lufs($0) > relative }
        guard !kept.isEmpty else { return nil }
        return lufs(kept.reduce(0, +) / Double(kept.count))
    }
}

/// Look-ahead peak limiter that keeps the result under -1 dBFS without audible clipping.
final class Limiter {
    private let ceiling: Double
    private let lookahead: Int
    private var delay: [Double]
    private var position = 0
    private var hold = 1.0
    private var holdCount = 0
    private var gain = 1.0
    private let release: Double
    private let attack: Double

    init(rate: Double, ceilingDB: Double = -1.0) {
        ceiling = pow(10, ceilingDB / 20)
        lookahead = max(1, Int(rate * 0.005))
        delay = [Double](repeating: 0, count: lookahead)
        release = exp(-1 / (rate * 0.15))
        attack = exp(-1 / (Double(lookahead) / 8))
    }

    /// Delay added by the look-ahead, in frames.
    var latency: Int { lookahead }

    func process(_ x: Double) -> Double {
        let level = abs(x)
        let needed = level > ceiling ? ceiling / level : 1.0
        if needed < hold {
            hold = needed
            holdCount = lookahead
        } else if holdCount > 0 {
            holdCount -= 1
        } else {
            hold = 1 - (1 - hold) * release
        }
        gain = hold < gain ? gain * attack + hold * (1 - attack) : hold

        let delayed = delay[position]
        delay[position] = x
        position = (position + 1) % lookahead
        return min(max(delayed * gain, -ceiling), ceiling)
    }
}

// MARK: - Voice isolation (Apple's AUSoundIsolation)

/// Wraps Apple's built-in neural voice-isolation effect so it can be run over a whole file
/// faster than real time. Feed it audio, get cleaned audio back (delayed by `latencyFrames`).
final class VoiceIsolator {
    // 'vois' — kAudioUnitSubType_AUSoundIsolation. Written out so older SDKs build too.
    private static let subType: OSType = 0x766f_6973
    private static let paramWetDry: AudioUnitParameterID = 0      // kAUSoundIsolationParam_WetDryMixPercent
    private static let paramSoundType: AudioUnitParameterID = 1   // kAUSoundIsolationParam_SoundToIsolate
    private static let soundHighQualityVoice: AudioUnitParameterValue = 0

    private static var description: AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                  componentSubType: subType,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0,
                                  componentFlagsMask: 0)
    }

    /// True when this Mac has the voice-isolation effect (macOS 13 and later).
    static var isAvailable: Bool {
        var d = description
        return AudioComponentFindNext(nil, &d) != nil
    }

    private let unit: AudioUnit
    private let channels: Int
    private let chunk: Int
    private var initialized = false
    private var pending: [Float] = []
    private var pendingStart = 0
    private var sampleTime = 0.0
    private let outputList: UnsafeMutableAudioBufferListPointer
    private let outputStorage: [UnsafeMutablePointer<Float>]
    private let inputStorage: [UnsafeMutablePointer<Float>]
    private(set) var latencyFrames = 0

    /// Makes a ready-to-use isolator. Tries a mono stream first, then stereo.
    static func make(sampleRate: Double, wetPercent: Float) throws -> VoiceIsolator {
        var lastError: Error = MonoError.cannotWrite("Noise removal isn't available on this Mac.")
        for channels in [1, 2] {
            do {
                let unit = try createUnit(sampleRate: sampleRate, channels: channels, chunk: 1024)
                let isolator = VoiceIsolator(unit: unit, channels: channels, chunk: 1024)
                try isolator.start(sampleRate: sampleRate, wetPercent: wetPercent)
                return isolator
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func createUnit(sampleRate: Double, channels: Int, chunk: Int) throws -> AudioUnit {
        var d = description
        guard let component = AudioComponentFindNext(nil, &d) else {
            throw MonoError.cannotWrite("Noise removal needs macOS 13 or later.")
        }
        var instance: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let unit = instance else {
            throw MonoError.cannotWrite("Noise removal couldn't start (error \(status)).")
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var maxFrames = UInt32(chunk)

        status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                      &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        if status == noErr {
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, formatSize)
        }
        if status == noErr {
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, formatSize)
        }
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw MonoError.cannotWrite("Noise removal doesn't accept this sound format (error \(status)).")
        }
        return unit
    }

    private init(unit: AudioUnit, channels: Int, chunk: Int) {
        self.unit = unit
        self.channels = channels
        self.chunk = chunk
        outputStorage = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: chunk) }
        inputStorage = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: chunk) }
        outputList = AudioBufferList.allocate(maximumBuffers: channels)
    }

    deinit {
        if initialized { AudioUnitUninitialize(unit) }
        AudioComponentInstanceDispose(unit)
        outputStorage.forEach { $0.deallocate() }
        inputStorage.forEach { $0.deallocate() }
        free(outputList.unsafeMutablePointer)
    }

    private func start(sampleRate: Double, wetPercent: Float) throws {
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frameCount, ioData -> OSStatus in
                guard let ioData = ioData else { return kAudio_ParamError }
                let me = Unmanaged<VoiceIsolator>.fromOpaque(refCon).takeUnretainedValue()
                return me.provideInput(frames: Int(frameCount), to: ioData)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        var status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                          &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            throw MonoError.cannotWrite("Noise removal couldn't be connected (error \(status)).")
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            throw MonoError.cannotWrite("Noise removal couldn't start (error \(status)).")
        }
        initialized = true

        // Best-quality voice model where available; the effect keeps its default otherwise.
        _ = AudioUnitSetParameter(unit, Self.paramSoundType, kAudioUnitScope_Global, 0, Self.soundHighQualityVoice, 0)
        _ = AudioUnitSetParameter(unit, Self.paramWetDry, kAudioUnitScope_Global, 0, wetPercent, 0)

        var latencySeconds: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        if AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latencySeconds, &size) == noErr,
           latencySeconds.isFinite, latencySeconds > 0 {
            latencyFrames = Int((latencySeconds * sampleRate).rounded())
        }
    }

    /// Called by the effect when it wants more input.
    private func provideInput(frames: Int, to ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        let available = max(0, pending.count - pendingStart)
        let n = min(frames, available)
        for index in 0..<list.count {
            var buffer = list[index]
            if buffer.mData == nil {
                // The effect wants us to supply the memory.
                guard index < inputStorage.count, frames <= chunk else { return kAudio_ParamError }
                buffer.mData = UnsafeMutableRawPointer(inputStorage[index])
                buffer.mDataByteSize = UInt32(frames * 4)
                list[index] = buffer
            }
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            if n > 0 {
                pending.withUnsafeBufferPointer { src in
                    _ = memcpy(data, src.baseAddress! + pendingStart, n * 4)
                }
            }
            if n < frames {
                _ = memset(data + n, 0, (frames - n) * 4)
            }
        }
        pendingStart += n
        return noErr
    }

    private func renderChunk() throws -> [Float] {
        for i in 0..<channels {
            outputList[i] = AudioBuffer(mNumberChannels: 1,
                                        mDataByteSize: UInt32(chunk * 4),
                                        mData: UnsafeMutableRawPointer(outputStorage[i]))
        }
        var flags = AudioUnitRenderActionFlags()
        var stamp = AudioTimeStamp()
        stamp.mSampleTime = sampleTime
        stamp.mFlags = .sampleTimeValid
        let status = AudioUnitRender(unit, &flags, &stamp, 0, UInt32(chunk), outputList.unsafeMutablePointer)
        guard status == noErr else {
            throw MonoError.cannotWrite("Noise removal stopped (error \(status)).")
        }
        sampleTime += Double(chunk)
        // With a stereo stream both sides carry the same voice; take the first.
        let source = outputList[0].mData?.assumingMemoryBound(to: Float.self) ?? outputStorage[0]
        return Array(UnsafeBufferPointer(start: source, count: chunk))
    }

    /// Adds audio and returns whatever cleaned audio is ready.
    func process(_ samples: [Float]) throws -> [Float] {
        pending.append(contentsOf: samples)
        var out: [Float] = []
        while pending.count - pendingStart >= chunk {
            out.append(contentsOf: try renderChunk())
        }
        if pendingStart > 1 << 16 {
            pending.removeFirst(pendingStart)
            pendingStart = 0
        }
        return out
    }

    /// Pushes silence through so the last of the real audio comes out.
    func flush(padding: Int) throws -> [Float] {
        pending.append(contentsOf: [Float](repeating: 0, count: padding))
        var out: [Float] = []
        while pending.count - pendingStart > 0 {
            out.append(contentsOf: try renderChunk())
        }
        return out
    }
}

// MARK: - Pass 1: clean the sound into a temporary file

struct CleanedAudio {
    let url: URL
    let rate: Double
    /// Real audio length, in frames.
    let frames: Int
    /// Frames to drop from the start of the file to undo the noise remover's delay.
    let skip: Int
    /// Gain to apply when saving, in dB.
    let gainDB: Double
    /// Where the original sound started on the video's timeline.
    let startTime: CMTime
}

private final class FloatFileWriter {
    private let file: AVAudioFile

    init(url: URL, rate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw MonoError.cannotWrite("Temporary sound file: \(error.localizedDescription)")
        }
    }

    func write(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw MonoError.cannotWrite("Out of memory while saving the sound.")
        }
        samples.withUnsafeBufferPointer { src in
            _ = memcpy(channel, src.baseAddress!, samples.count * 4)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        do {
            try file.write(from: buffer)
        } catch {
            throw MonoError.cannotWrite("Temporary sound file: \(error.localizedDescription)")
        }
    }
}

enum AudioCleaner {
    static let rate = 48_000.0

    /// Decodes the sound, picks the channel(s), removes noise / applies EQ, measures loudness,
    /// and writes the result to a temporary mono file. Runs on a background thread.
    static func clean(asset: AVAsset,
                      track: AVAssetTrack,
                      duration: CMTime,
                      source: ChannelSource,
                      options: CleanupOptions,
                      cancel: CancelFlag,
                      progress: (Double) -> Void) throws -> CleanedAudio {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MonoError.cannotRead(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: PCM.readerSettings(sampleRate: rate))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MonoError.cannotRead("Its sound format isn't supported by macOS.")
        }
        reader.add(output)

        let isolator: VoiceIsolator? = options.noise == .off
            ? nil
            : try VoiceIsolator.make(sampleRate: rate, wetPercent: options.noise.wetPercent)
        var eq: VoiceEQ? = options.enhanceVoice ? VoiceEQ(rate: rate) : nil
        let meter = LoudnessMeter(rate: rate)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoMaker-\(UUID().uuidString).caf")
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: url) } }

        // Kept only to measure the noise remover's delay if the effect doesn't report it.
        let probeLimit = Int(rate * 20)
        let probing = isolator != nil && isolator!.latencyFrames == 0
        var probeIn: [Float] = []
        var probeOut: [Float] = []

        var inputFrames = 0
        var startTime = CMTime.invalid
        let total = max(duration.seconds, 0.001)

        guard reader.startReading() else {
            throw MonoError.cannotRead(reader.error?.localizedDescription ?? "Reading didn't start.")
        }

        do {
            let writer = try FloatFileWriter(url: url, rate: rate)

            func finish(_ chunk: [Float]) throws {
                guard !chunk.isEmpty else { return }
                if probing && probeOut.count < probeLimit {
                    probeOut.append(contentsOf: chunk.prefix(probeLimit - probeOut.count))
                }
                var processed = chunk
                if eq != nil { eq!.process(&processed) }
                meter.add(processed)
                try writer.write(processed)
            }

            while let buffer = output.copyNextSampleBuffer() {
                if cancel.isSet {
                    reader.cancelReading()
                    throw MonoError.cancelled
                }
                guard let stereo = PCM.samples(of: buffer, channels: 2) else { continue }
                if !startTime.isValid {
                    startTime = CMSampleBufferGetPresentationTimeStamp(buffer)
                }
                let frames = stereo.count / 2
                var mono = [Float](repeating: 0, count: frames)
                for i in 0..<frames {
                    let l = stereo[2 * i], r = stereo[2 * i + 1]
                    switch source {
                    case .left: mono[i] = l
                    case .right: mono[i] = r
                    case .mix: mono[i] = (l + r) * 0.5
                    }
                }
                inputFrames += frames
                if probing && probeIn.count < probeLimit {
                    probeIn.append(contentsOf: mono.prefix(probeLimit - probeIn.count))
                }
                if let isolator = isolator {
                    try finish(try isolator.process(mono))
                } else {
                    try finish(mono)
                }
                progress(min(Double(inputFrames) / rate / total, 1))
            }
            if reader.status == .failed {
                throw MonoError.cannotRead(reader.error?.localizedDescription ?? "Reading stopped.")
            }
            if let isolator = isolator {
                // Enough extra silence to push out the delayed tail (at least one second).
                try finish(try isolator.flush(padding: isolator.latencyFrames + Int(rate)))
            }
            // A little silence at the end so the final limiter has room to release.
            try writer.write([Float](repeating: 0, count: Int(rate / 10)))
        }

        guard inputFrames > 0 else { throw MonoError.noAudio }

        var skip = isolator?.latencyFrames ?? 0
        if probing {
            skip = estimateDelay(input: probeIn, output: probeOut, rate: rate) ?? 0
        }

        var gain = 0.0
        if options.evenLoudness, let measured = meter.integrated {
            gain = min(max(targetLoudness - measured, -20), 20)
        }

        finished = true
        return CleanedAudio(url: url, rate: rate, frames: inputFrames, skip: skip, gainDB: gain,
                            startTime: startTime.isValid ? startTime : .zero)
    }

    /// Finds how far `output` lags `input` by matching their loudness envelopes (0–1 s).
    /// Returns nil when the match is too weak to trust.
    static func estimateDelay(input: [Float], output: [Float], rate: Double) -> Int? {
        let step = max(1, Int(rate / 2000))
        let n = min(input.count, output.count) / step
        guard n > 200 else { return nil }
        func envelope(_ x: [Float]) -> [Double] {
            var e = [Double](repeating: 0, count: n)
            for i in 0..<n {
                var s = 0.0
                for j in 0..<step { s += Double(abs(x[i * step + j])) }
                e[i] = s / Double(step)
            }
            let mean = e.reduce(0, +) / Double(n)
            return e.map { $0 - mean }
        }
        let a = envelope(input)
        let b = envelope(output)
        let maxLag = min(Int(1.0 * rate) / step, n / 2)
        var bestLag = 0
        var best = -1.0
        for lag in 0...maxLag {
            var dot = 0.0, na = 0.0, nb = 0.0
            for i in 0..<(n - lag) {
                let x = a[i], y = b[i + lag]
                dot += x * y; na += x * x; nb += y * y
            }
            let c = dot / (sqrt(na * nb) + 1e-12)
            if c > best { best = c; bestLag = lag }
        }
        return best > 0.4 ? bestLag * step : nil
    }
}

// MARK: - Pass 2: turn the cleaned file into the final sound track

/// Reads the cleaned temporary file and produces the final buffers: delay removed,
/// gain applied, peaks limited, and copied to 1 or 2 channels.
final class CleanedFeeder {
    private let rate: Double
    private let channels: Int
    private let gain: Double
    private let limiter: Limiter
    private let startTime: CMTime
    private let format: CMAudioFormatDescription
    private var toSkip: Int
    private var remaining: Int
    private var emitted: Int64 = 0

    init(cleaned: CleanedAudio, channels: Int, format: CMAudioFormatDescription) {
        rate = cleaned.rate
        self.channels = channels
        gain = pow(10, cleaned.gainDB / 20)
        limiter = Limiter(rate: cleaned.rate)
        startTime = cleaned.startTime
        self.format = format
        // The limiter's own look-ahead delay is removed the same way.
        toSkip = cleaned.skip + limiter.latency
        remaining = cleaned.frames
    }

    func transform(_ buffer: CMSampleBuffer) -> LaneResult {
        guard let mono = PCM.samples(of: buffer, channels: 1) else { return .skip }
        var out: [Float] = []
        out.reserveCapacity(mono.count * channels)
        for v in mono {
            let y = Float(limiter.process(Double(v) * gain))
            if toSkip > 0 { toSkip -= 1; continue }
            if remaining <= 0 { break }
            remaining -= 1
            for _ in 0..<channels { out.append(y) }
        }
        let frames = out.count / channels
        guard frames > 0 else { return .skip }
        let time = CMTimeAdd(startTime, CMTime(value: emitted, timescale: CMTimeScale(rate)))
        emitted += Int64(frames)
        guard let sample = PCM.makeBuffer(out, frames: frames, format: format, time: time) else { return .failed }
        return .buffer(sample)
    }

}
