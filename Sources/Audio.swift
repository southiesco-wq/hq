import Foundation
import AVFoundation
import CoreMedia

// MARK: - Shared types

/// Which part of the original stereo sound becomes the new mono track.
enum ChannelSource: String {
    case mix, left, right

    var label: String {
        switch self {
        case .mix: return "Left + right mixed"
        case .left: return "Left channel"
        case .right: return "Right channel"
        }
    }
}

/// What the analysis found in a file's sound track.
struct ChannelReport {
    /// Channels in the original track (1 means it is already mono).
    let sourceChannels: Int
    /// Average loudness (RMS, dBFS) of each side.
    let leftDB: Double
    let rightDB: Double
    /// What Auto will use for this file, and a sentence explaining why.
    let recommendation: ChannelSource
    let note: String
}

struct ConvertOptions {
    let source: ChannelSource
    /// 1 = true mono track, 2 = the same mono sound on both left and right.
    let outputChannels: Int
    var cleanup = CleanupOptions()
}

/// Which step a conversion is on, for the progress line.
enum ConvertStage: Equatable {
    case cleaning, saving

    var label: String {
        switch self {
        case .cleaning: return "Cleaning up the sound"
        case .saving: return "Saving"
        }
    }
}

enum MonoError: LocalizedError {
    case noAudio
    case cannotRead(String)
    case cannotWrite(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noAudio: return "This file has no sound track."
        case .cannotRead(let why): return "Couldn't read this video. \(why)"
        case .cannotWrite(let why): return "Couldn't save the new video. \(why)"
        case .cancelled: return "Stopped."
        }
    }
}

/// A thread-safe stop switch shared between the window and the converter.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); value = true; lock.unlock()
    }
}

/// Runs blocking work on a background thread and returns the result to async code.
func runInBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Decoded audio helpers

enum PCM {
    /// Decoder settings: interleaved 32-bit float. With two channels, a mono original
    /// arrives as two identical channels and surround is folded down to stereo.
    static func readerSettings(sampleRate: Double, channels: Int = 2) -> [String: Any] {
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// Copies a decoded interleaved float buffer, e.g. [L, R, L, R, ...] for two channels.
    static func samples(of buffer: CMSampleBuffer, channels: Int) -> [Float]? {
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0, let block = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        let wanted = frames * channels * MemoryLayout<Float>.size
        let byteCount = min(CMBlockBufferGetDataLength(block), wanted)
        let floatCount = byteCount / MemoryLayout<Float>.size / channels * channels
        guard floatCount >= channels else { return nil }
        var samples = [Float](repeating: 0, count: floatCount)
        let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: floatCount * MemoryLayout<Float>.size, destination: raw.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? samples : nil
    }

    static func stereoSamples(of buffer: CMSampleBuffer) -> [Float]? {
        samples(of: buffer, channels: 2)
    }

    /// Wraps interleaved float samples in a sample buffer the AAC encoder can take.
    static func makeBuffer(_ samples: [Float], frames: Int, format: CMAudioFormatDescription, time: CMTime) -> CMSampleBuffer? {
        let byteCount = samples.count * MemoryLayout<Float>.size
        guard byteCount > 0 else { return nil }
        var blockOut: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: nil,
                                                        blockLength: byteCount,
                                                        blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil,
                                                        offsetToData: 0,
                                                        dataLength: byteCount,
                                                        flags: kCMBlockBufferAssureMemoryNowFlag,
                                                        blockBufferOut: &blockOut)
        guard status == kCMBlockBufferNoErr, let block = blockOut else { return nil }
        status = samples.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleOut: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
                                                                      dataBuffer: block,
                                                                      formatDescription: format,
                                                                      sampleCount: frames,
                                                                      presentationTimeStamp: time,
                                                                      packetDescriptions: nil,
                                                                      sampleBufferOut: &sampleOut)
        guard status == noErr else { return nil }
        return sampleOut
    }
}

// MARK: - Analysis

enum ChannelAnalyzer {
    /// Decodes the sound once and measures each side, so Auto can pick the right source.
    static func analyze(url: URL) async throws -> ChannelReport {
        let asset = AVURLAsset(url: url)
        let tracks = try await SoundTracks.load(from: asset)
        guard !tracks.isEmpty else { throw MonoError.noAudio }

        return try await runInBackground {
            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                throw MonoError.cannotRead(error.localizedDescription)
            }
            // A lower rate is plenty for measuring loudness and decodes faster.
            let (output, chosen) = try SoundTracks.addOutput(to: reader, from: tracks, sampleRate: 24_000)
            let channels = chosen.channels
            guard reader.startReading() else {
                throw MonoError.cannotRead(reader.error?.localizedDescription ?? "Reading didn't start.")
            }

            var sumLeft = 0.0
            var sumRight = 0.0
            var sumMix = 0.0
            var frames = 0
            while let buffer = output.copyNextSampleBuffer() {
                guard let samples = PCM.stereoSamples(of: buffer) else { continue }
                var i = 0
                while i + 1 < samples.count {
                    let l = Double(samples[i])
                    let r = Double(samples[i + 1])
                    let m = (l + r) * 0.5
                    sumLeft += l * l
                    sumRight += r * r
                    sumMix += m * m
                    frames += 1
                    i += 2
                }
            }
            if reader.status == .failed {
                throw MonoError.cannotRead(reader.error?.localizedDescription ?? "Reading stopped.")
            }
            return ChannelAnalyzer.makeReport(channels: channels, sumLeft: sumLeft, sumRight: sumRight, sumMix: sumMix, frames: frames)
        }
    }

    static func makeReport(channels: Int, sumLeft: Double, sumRight: Double, sumMix: Double, frames: Int) -> ChannelReport {
        func decibels(_ sum: Double) -> Double {
            guard frames > 0 else { return -120 }
            return 10 * log10(max(sum / Double(frames), 1e-12))
        }
        let left = decibels(sumLeft)
        let right = decibels(sumRight)
        let mix = decibels(sumMix)
        let louder = max(left, right)

        let pick: ChannelSource
        let note: String
        if channels == 1 {
            pick = .mix
            note = "Already mono. Converting keeps the sound as it is."
        } else if louder < -70 {
            pick = .mix
            note = "No audible sound found in this file."
        } else if left - right > 20 {
            pick = .left
            note = "Sound is only on the left. Auto uses the left channel."
        } else if right - left > 20 {
            pick = .right
            note = "Sound is only on the right. Auto uses the right channel."
        } else if louder - mix > 6 {
            // Mixing makes it much quieter than either side: the channels are out of phase.
            pick = left >= right ? .left : .right
            note = "The two sides cancel out when mixed. Auto uses the \(left >= right ? "left" : "right") channel."
        } else if abs(left - right) < 0.5 && louder - mix < 0.2 {
            pick = .mix
            note = "Left and right are identical. Auto keeps that sound."
        } else {
            pick = .mix
            note = "Sound on both sides. Auto mixes left and right."
        }
        return ChannelReport(sourceChannels: channels, leftDB: left, rightDB: right, recommendation: pick, note: note)
    }
}

// MARK: - Conversion

private struct VideoSpec {
    let track: AVAssetTrack
    let format: CMFormatDescription?
    let transform: CGAffineTransform
}

/// What the audio lane does with each decoded buffer before writing it.
enum LaneResult {
    case buffer(CMSampleBuffer)
    case skip
    case failed
}

private struct Lane {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    /// nil for the picture (copied as-is); set for the sound.
    let transform: ((CMSampleBuffer) -> LaneResult)?
}

/// Shared between the writing threads: first error and how far the writing has got.
private final class PumpState: @unchecked Sendable {
    private let lock = NSLock()
    private var firstError: MonoError?
    private var furthestSeconds = 0.0

    var error: MonoError? {
        lock.lock(); defer { lock.unlock() }
        return firstError
    }

    var failed: Bool { error != nil }

    var furthest: Double {
        lock.lock(); defer { lock.unlock() }
        return furthestSeconds
    }

    func fail(_ error: MonoError) {
        lock.lock()
        if firstError == nil { firstError = error }
        lock.unlock()
    }

    func reached(_ seconds: Double) {
        lock.lock()
        if seconds > furthestSeconds { furthestSeconds = seconds }
        lock.unlock()
    }
}

/// Makes sure each writing lane reports "finished" exactly once.
private final class LaneDone: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    /// True the first time it is called, false afterwards.
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

enum MonoConverter {
    /// Sample rates the AAC encoder accepts.
    private static let aacRates: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]

    /// Copies the picture untouched and writes a new AAC sound track built from the chosen channel(s).
    static func convert(input: URL,
                        output: URL,
                        options: ConvertOptions,
                        cancel: CancelFlag,
                        progress: @escaping @Sendable (Double, ConvertStage) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        let audioTracks = try await SoundTracks.load(from: asset)
        let videoTracks: [AVAssetTrack]
        let duration: CMTime
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            duration = try await asset.load(.duration)
        } catch {
            throw MonoError.cannotRead(error.localizedDescription)
        }
        guard let firstSound = audioTracks.first else { throw MonoError.noAudio }
        let metadata = (try? await asset.load(.metadata)) ?? []

        let original = firstSound.sampleRate
        var rate = aacRates.min(by: { abs($0 - original) < abs($1 - original) }) ?? 48_000

        var specs: [VideoSpec] = []
        for track in videoTracks {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            specs.append(VideoSpec(track: track, format: formats.first, transform: transform))
        }
        let videoSpecs = specs

        let fileType: AVFileType
        switch output.pathExtension.lowercased() {
        case "mov": fileType = .mov
        case "m4v": fileType = .m4v
        default: fileType = .mp4
        }

        // Step 1 (only when cleaning up): process the sound into a temporary file.
        var cleaned: CleanedAudio?
        var cleanedTrack: AVAssetTrack?
        var saveStart = 0.0
        if options.cleanup.isActive {
            let result = try await runInBackground {
                try AudioCleaner.clean(asset: asset,
                                       tracks: audioTracks,
                                       duration: duration,
                                       source: options.source,
                                       options: options.cleanup,
                                       cancel: cancel) { fraction in
                    progress(fraction * 0.85, .cleaning)
                }
            }
            cleaned = result
            rate = result.rate
            saveStart = 0.85
            do {
                cleanedTrack = try await AVURLAsset(url: result.url).loadTracks(withMediaType: .audio).first
            } catch {
                cleanedTrack = nil
            }
            guard cleanedTrack != nil else {
                try? FileManager.default.removeItem(at: result.url)
                throw MonoError.cannotWrite("The cleaned sound couldn't be read back.")
            }
        }
        defer {
            if let url = cleaned?.url { try? FileManager.default.removeItem(at: url) }
        }

        // Step 2: copy the picture and write the new sound track.
        let finalRate = rate
        let cleanedAudio = cleaned
        let cleanedSource = cleanedTrack
        let start = saveStart
        try await runInBackground {
            try MonoConverter.run(asset: asset,
                                  videoSpecs: videoSpecs,
                                  audioTracks: audioTracks,
                                  cleaned: cleanedAudio,
                                  cleanedTrack: cleanedSource,
                                  rate: finalRate,
                                  duration: duration,
                                  metadata: metadata,
                                  fileType: fileType,
                                  output: output,
                                  options: options,
                                  cancel: cancel) { fraction in
                progress(start + fraction * (1 - start), .saving)
            }
        }
        progress(1, .saving)
    }

    private static func run(asset: AVAsset,
                            videoSpecs: [VideoSpec],
                            audioTracks: [SoundTrack],
                            cleaned: CleanedAudio?,
                            cleanedTrack: AVAssetTrack?,
                            rate: Double,
                            duration: CMTime,
                            metadata: [AVMetadataItem],
                            fileType: AVFileType,
                            output: URL,
                            options: ConvertOptions,
                            cancel: CancelFlag,
                            progress: @escaping @Sendable (Double) -> Void) throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MonoError.cannotRead(error.localizedDescription)
        }

        // Picture: compressed frames are handed straight through, never re-encoded.
        var videoOutputs: [AVAssetReaderTrackOutput] = []
        for spec in videoSpecs {
            let videoOutput = AVAssetReaderTrackOutput(track: spec.track, outputSettings: nil)
            videoOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOutput) else {
                throw MonoError.cannotRead("The picture track can't be copied.")
            }
            reader.add(videoOutput)
            videoOutputs.append(videoOutput)
        }

        // Sound: either the original decoded to stereo float (so a channel can be picked or mixed),
        // or the cleaned-up temporary file from step 1, read by its own reader.
        let audioReader: AVAssetReader
        let audioOutput: AVAssetReaderOutput
        if let cleaned = cleaned, let cleanedTrack = cleanedTrack {
            do {
                audioReader = try AVAssetReader(asset: AVURLAsset(url: cleaned.url))
            } catch {
                throw MonoError.cannotWrite("The cleaned sound couldn't be read back.")
            }
            let cleanedOutput = AVAssetReaderTrackOutput(track: cleanedTrack,
                                                         outputSettings: PCM.readerSettings(sampleRate: cleaned.rate, channels: 1))
            cleanedOutput.alwaysCopiesSampleData = false
            guard audioReader.canAdd(cleanedOutput) else {
                throw MonoError.cannotWrite("The cleaned sound couldn't be read back.")
            }
            audioReader.add(cleanedOutput)
            audioOutput = cleanedOutput
        } else {
            audioReader = reader
            audioOutput = try SoundTracks.addOutput(to: reader, from: audioTracks, sampleRate: rate).output
        }
        let separateAudioReader = audioReader !== reader

        var built = try makeWriter(output: output, fileType: fileType, videoSpecs: videoSpecs,
                                   rate: rate, channels: options.outputChannels, metadata: metadata)
        if !built.writer.startWriting() {
            guard !metadata.isEmpty else {
                throw MonoError.cannotWrite(built.writer.error?.localizedDescription ?? "The file couldn't be created.")
            }
            // Some original tags can't be carried into this file type. Try again without them.
            built = try makeWriter(output: output, fileType: fileType, videoSpecs: videoSpecs,
                                   rate: rate, channels: options.outputChannels, metadata: [])
            guard built.writer.startWriting() else {
                throw MonoError.cannotWrite(built.writer.error?.localizedDescription ?? "The file couldn't be created.")
            }
        }
        let writer = built.writer

        guard reader.startReading() else {
            writer.cancelWriting()
            throw MonoError.cannotRead(reader.error?.localizedDescription ?? "Reading didn't start.")
        }
        if separateAudioReader && !audioReader.startReading() {
            reader.cancelReading()
            writer.cancelWriting()
            throw MonoError.cannotWrite(audioReader.error?.localizedDescription ?? "The cleaned sound couldn't be read back.")
        }
        writer.startSession(atSourceTime: .zero)

        let format: CMAudioFormatDescription
        do {
            format = try pcmFormat(rate: rate, channels: options.outputChannels)
        } catch {
            reader.cancelReading()
            if separateAudioReader { audioReader.cancelReading() }
            writer.cancelWriting()
            throw error
        }
        let state = PumpState()
        let group = DispatchGroup()

        let audioTransform: (CMSampleBuffer) -> LaneResult
        if let cleaned = cleaned {
            let feeder = CleanedFeeder(cleaned: cleaned, channels: options.outputChannels, format: format)
            audioTransform = { feeder.transform($0) }
        } else {
            let source = options.source
            let channels = options.outputChannels
            audioTransform = { sample in
                if CMSampleBufferGetNumSamples(sample) == 0 { return .skip }
                guard let remixed = MonoConverter.remix(sample, source: source, channels: channels, format: format) else {
                    return .failed
                }
                return .buffer(remixed)
            }
        }

        var lanes: [Lane] = []
        for (index, videoOutput) in videoOutputs.enumerated() {
            lanes.append(Lane(output: videoOutput, input: built.video[index], transform: nil))
        }
        lanes.append(Lane(output: audioOutput, input: built.audio, transform: audioTransform))

        // Each track is fed on its own queue, the way AVFoundation expects for interleaved writing.
        for (index, lane) in lanes.enumerated() {
            group.enter()
            let laneDone = LaneDone()
            let queue = DispatchQueue(label: "local.monomaker.lane.\(index)")
            lane.input.requestMediaDataWhenReady(on: queue) {
                if laneDone.isDone { return }
                while lane.input.isReadyForMoreMediaData {
                    if cancel.isSet || state.failed {
                        if laneDone.finish() {
                            if writer.status == .writing { lane.input.markAsFinished() }
                            group.leave()
                        }
                        return
                    }
                    guard let sample = lane.output.copyNextSampleBuffer() else {
                        if laneDone.finish() {
                            if writer.status == .writing { lane.input.markAsFinished() }
                            group.leave()
                        }
                        return
                    }
                    var toWrite = sample
                    if let transform = lane.transform {
                        switch transform(sample) {
                        case .buffer(let processed):
                            toWrite = processed
                        case .skip:
                            continue
                        case .failed:
                            state.fail(.cannotWrite("The sound couldn't be processed."))
                            if laneDone.finish() { group.leave() }
                            return
                        }
                    }
                    let time = CMSampleBufferGetPresentationTimeStamp(toWrite)
                    if !lane.input.append(toWrite) {
                        state.fail(.cannotWrite(writer.error?.localizedDescription ?? "Writing stopped unexpectedly."))
                        if laneDone.finish() { group.leave() }
                        return
                    }
                    if time.isValid { state.reached(time.seconds) }
                }
            }
        }

        // Wait for all tracks, reporting progress and watching for Stop or failures.
        let total = max(duration.seconds, 0.001)
        var lastSent = -1.0
        while group.wait(timeout: .now() + .milliseconds(150)) == .timedOut {
            if cancel.isSet || state.failed || reader.status == .failed || audioReader.status == .failed || writer.status == .failed { break }
            let fraction = min(state.furthest / total, 0.99)
            if fraction - lastSent >= 0.005 {
                lastSent = fraction
                progress(fraction)
            }
        }

        let readerFailed = reader.status == .failed || audioReader.status == .failed
        let writerFailed = writer.status == .failed
        if cancel.isSet || state.failed || readerFailed || writerFailed {
            let reason: MonoError
            if cancel.isSet {
                reason = .cancelled
            } else if let error = state.error {
                reason = error
            } else if readerFailed {
                reason = .cannotRead((reader.error ?? audioReader.error)?.localizedDescription ?? "Reading stopped.")
            } else {
                reason = .cannotWrite(writer.error?.localizedDescription ?? "Writing stopped.")
            }
            reader.cancelReading()
            if separateAudioReader { audioReader.cancelReading() }
            _ = group.wait(timeout: .now() + .seconds(2))
            if writer.status == .writing { writer.cancelWriting() }
            throw reason
        }

        progress(0.995)
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw MonoError.cannotWrite(writer.error?.localizedDescription ?? "The file couldn't be finished.")
        }
    }

    private static func makeWriter(output: URL,
                                   fileType: AVFileType,
                                   videoSpecs: [VideoSpec],
                                   rate: Double,
                                   channels: Int,
                                   metadata: [AVMetadataItem]) throws -> (writer: AVAssetWriter, video: [AVAssetWriterInput], audio: AVAssetWriterInput) {
        try? FileManager.default.removeItem(at: output)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        } catch {
            throw MonoError.cannotWrite(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
        if !metadata.isEmpty { writer.metadata = metadata }

        var videoInputs: [AVAssetWriterInput] = []
        for spec in videoSpecs {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: spec.format)
            input.transform = spec.transform
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw MonoError.cannotWrite("This picture format can't go into a .\(output.pathExtension) file.")
            }
            writer.add(input)
            videoInputs.append(input)
        }

        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let layoutData = withUnsafeBytes(of: &layout) { Data($0) }

        let bitRate: Int
        if rate >= 32_000 {
            bitRate = channels == 1 ? 128_000 : 192_000
        } else if rate >= 16_000 {
            bitRate = channels == 1 ? 64_000 : 96_000
        } else {
            bitRate = channels == 1 ? 32_000 : 48_000
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layoutData,
            AVEncoderBitRateKey: bitRate
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw MonoError.cannotWrite("The mono sound track couldn't be set up.")
        }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw MonoError.cannotWrite("The mono sound track couldn't be added.")
        }
        writer.add(audioInput)
        return (writer, videoInputs, audioInput)
    }

    /// Describes the uncompressed float audio we hand to the AAC encoder.
    private static func pcmFormat(rate: Double, channels: Int) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        var formatOut: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    asbd: &asbd,
                                                    layoutSize: 0,
                                                    layout: nil,
                                                    magicCookieSize: 0,
                                                    magicCookie: nil,
                                                    extensions: nil,
                                                    formatDescriptionOut: &formatOut)
        guard status == noErr, let format = formatOut else {
            throw MonoError.cannotWrite("Audio format error \(status).")
        }
        return format
    }

    /// Turns one decoded stereo buffer into the new mono (or both-ears mono) buffer.
    private static func remix(_ buffer: CMSampleBuffer,
                              source: ChannelSource,
                              channels: Int,
                              format: CMAudioFormatDescription) -> CMSampleBuffer? {
        guard let stereo = PCM.stereoSamples(of: buffer) else { return nil }
        let frames = stereo.count / 2
        guard frames > 0 else { return nil }

        var mono = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let left = stereo[2 * frame]
            let right = stereo[2 * frame + 1]
            let value: Float
            switch source {
            case .left: value = left
            case .right: value = right
            case .mix: value = (left + right) * 0.5
            }
            for channel in 0..<channels {
                mono[frame * channels + channel] = value
            }
        }

        return PCM.makeBuffer(mono, frames: frames, format: format, time: CMSampleBufferGetPresentationTimeStamp(buffer))
    }
}
