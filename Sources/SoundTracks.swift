import Foundation
import AVFoundation
import CoreMedia

/// One sound track in a video, with what we know about it.
struct SoundTrack {
    let track: AVAssetTrack
    let channels: Int
    let sampleRate: Double
    /// Four-character codec code, e.g. "aac ", "lpcm", "apac".
    let codec: String
    let isEnabled: Bool

    /// Plain-English codec name for messages.
    var codecName: String {
        switch codec.trimmingCharacters(in: .whitespaces).lowercased() {
        case "aac", "mp4a": return "AAC"
        case "lpcm", "sowt", "twos", "in24", "in32", "fl32", "fl64", "raw": return "PCM"
        case "apac": return "Apple Spatial Audio (APAC)"
        case "alac": return "Apple Lossless"
        case ".mp3", "mp3": return "MP3"
        case "ac-3": return "Dolby Digital"
        case "ec-3": return "Dolby Digital Plus"
        case "opus": return "Opus"
        case "flac": return "FLAC"
        case "": return "unknown"
        default: return "'\(codec)'"
        }
    }
}

enum SoundTracks {
    /// All sound tracks in the file, enabled ones first.
    static func load(from asset: AVAsset) async throws -> [SoundTrack] {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw MonoError.cannotRead(error.localizedDescription)
        }
        var found: [SoundTrack] = []
        for track in tracks {
            var channels = 2
            var rate = 48_000.0
            var codec = ""
            if let format = (try? await track.load(.formatDescriptions))?.first {
                codec = fourCC(CMFormatDescriptionGetMediaSubType(format))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                    if asbd.pointee.mChannelsPerFrame > 0 { channels = Int(asbd.pointee.mChannelsPerFrame) }
                    if asbd.pointee.mSampleRate > 0 { rate = asbd.pointee.mSampleRate }
                }
            }
            let enabled = (try? await track.load(.isEnabled)) ?? true
            found.append(SoundTrack(track: track, channels: channels, sampleRate: rate, codec: codec, isEnabled: enabled))
        }
        // Keep the file's order, but try enabled tracks before disabled ones.
        return found.filter { $0.isEnabled } + found.filter { !$0.isEnabled }
    }

    /// Finds a way to decode one of the tracks to float PCM with the given rate and channel count,
    /// adds that output to the reader, and returns it. Tries each track as-is, then with an explicit
    /// channel layout, then through an audio-mix output (which handles some multichannel layouts
    /// a plain track output refuses).
    static func addOutput(to reader: AVAssetReader,
                          from tracks: [SoundTrack],
                          sampleRate: Double,
                          channels: Int = 2) throws -> (output: AVAssetReaderOutput, track: SoundTrack) {
        let plain = PCM.readerSettings(sampleRate: sampleRate, channels: channels)
        var withLayout = plain
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        withLayout[AVChannelLayoutKey] = withUnsafeBytes(of: &layout) { Data($0) }

        for track in tracks {
            for settings in [plain, withLayout] {
                let output = AVAssetReaderTrackOutput(track: track.track, outputSettings: settings)
                output.alwaysCopiesSampleData = false
                if reader.canAdd(output) {
                    reader.add(output)
                    return (output, track)
                }
            }
            for settings in [plain, withLayout] {
                let output = AVAssetReaderAudioMixOutput(audioTracks: [track.track], audioSettings: settings)
                output.alwaysCopiesSampleData = false
                if reader.canAdd(output) {
                    reader.add(output)
                    return (output, track)
                }
            }
        }
        throw MonoError.cannotRead(unsupportedMessage(tracks))
    }

    static func unsupportedMessage(_ tracks: [SoundTrack]) -> String {
        let described = tracks.map { "\($0.codecName), \($0.channels) ch, \(Int($0.sampleRate)) Hz" }
            .joined(separator: "; ")
        return "Its sound (\(described)) can't be decoded on this Mac."
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        return printable ? String(bytes: bytes, encoding: .ascii) ?? "" : String(format: "0x%08x", code)
    }
}
