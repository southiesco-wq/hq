import Foundation
import AppKit
import UniformTypeIdentifiers

/// The channel setting picked in the window.
enum ChannelChoice: String, CaseIterable, Identifiable {
    case auto, mix, left, right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .mix: return "Mix L+R"
        case .left: return "Left"
        case .right: return "Right"
        }
    }

    func source(recommended: ChannelSource?) -> ChannelSource {
        switch self {
        case .auto: return recommended ?? .mix
        case .mix: return .mix
        case .left: return .left
        case .right: return .right
        }
    }
}

/// How the mono sound is stored in the new file.
enum OutputChannels: String, CaseIterable, Identifiable {
    case mono, both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mono: return "Mono track (1 channel)"
        case .both: return "Same sound in both ears"
        }
    }

    var channelCount: Int { self == .mono ? 1 : 2 }
}

/// One video in the list. Only changed on the main thread.
final class VideoItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case analyzing, ready, noAudio, converting, done
        case failed(String)
    }

    let id = UUID()
    let url: URL
    @Published var state: State = .analyzing
    @Published var report: ChannelReport?
    @Published var progress: Double = 0
    @Published var outputURL: URL?
    @Published var usedSource: ChannelSource?
    @Published var stage: ConvertStage = .saving
    /// What was done to the sound, shown once the file is saved.
    @Published var usedCleanup = ""

    init(url: URL) {
        self.url = url
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var choice: ChannelChoice = .auto
    @Published var output: OutputChannels = .mono
    @Published private(set) var isConverting = false

    // Sound clean-up settings, remembered between launches.
    @Published var noise: NoiseLevel {
        didSet { UserDefaults.standard.set(noise.rawValue, forKey: "noise") }
    }
    @Published var enhanceVoice: Bool {
        didSet { UserDefaults.standard.set(enhanceVoice, forKey: "enhanceVoice") }
    }
    @Published var evenLoudness: Bool {
        didSet { UserDefaults.standard.set(evenLoudness, forKey: "evenLoudness") }
    }

    /// Apple's voice isolation exists on macOS 13 and later; checked once.
    let noiseRemovalAvailable = VoiceIsolator.isAvailable

    init() {
        let defaults = UserDefaults.standard
        let savedNoise = NoiseLevel(rawValue: defaults.string(forKey: "noise") ?? "") ?? .off
        noise = VoiceIsolator.isAvailable ? savedNoise : .off
        enhanceVoice = defaults.bool(forKey: "enhanceVoice")
        evenLoudness = defaults.bool(forKey: "evenLoudness")
    }

    var cleanup: CleanupOptions {
        CleanupOptions(noise: noiseRemovalAvailable ? noise : .off,
                       enhanceVoice: enhanceVoice,
                       evenLoudness: evenLoudness)
    }

    private var cancelFlag = CancelFlag()
    private var analysisQueue: [VideoItem] = []
    private var isAnalyzing = false

    var readyCount: Int { items.filter { $0.state == .ready }.count }
    var hasFinished: Bool { items.contains { $0.state == .done } }

    // MARK: Adding files

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose Videos"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in
                guard let url = url else { return }
                Task { @MainActor in
                    self.add(urls: [url])
                }
            }
        }
        return accepted
    }

    func add(urls: [URL]) {
        for url in expand(urls) where !items.contains(where: { $0.url == url }) {
            let item = VideoItem(url: url)
            items.append(item)
            analysisQueue.append(item)
        }
        runAnalysis()
    }

    func remove(_ item: VideoItem) {
        guard item.state != .converting else { return }
        items.removeAll { $0 === item }
    }

    func clearFinished() {
        items.removeAll { $0.state == .done }
    }

    /// Files stay as they are; folders are searched for videos (skipping earlier "(mono)" results).
    private func expand(_ urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                var inFolder: [URL] = []
                let enumerator = FileManager.default.enumerator(at: url,
                                                                includingPropertiesForKeys: [.contentTypeKey],
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let child = enumerator?.nextObject() as? URL {
                    let name = child.lastPathComponent
                    if Self.isMovie(child) && !name.contains(" (mono") && !name.contains(" (clean") {
                        inFolder.append(child)
                    }
                }
                inFolder.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                found.append(contentsOf: inFolder)
            } else if Self.isMovie(url) {
                found.append(url)
            }
        }
        return found
    }

    static func isMovie(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .movie)
        }
        return ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
    }

    // MARK: Checking the sound

    /// Files are checked one at a time so a big drop doesn't swamp the Mac.
    private func runAnalysis() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        Task {
            while !analysisQueue.isEmpty {
                let item = analysisQueue.removeFirst()
                guard items.contains(where: { $0 === item }) else { continue }
                do {
                    let report = try await ChannelAnalyzer.analyze(url: item.url)
                    item.report = report
                    item.state = .ready
                } catch MonoError.noAudio {
                    item.state = .noAudio
                } catch {
                    item.state = .failed(error.localizedDescription)
                }
            }
            isAnalyzing = false
        }
    }

    // MARK: Converting

    func convertAll() {
        guard !isConverting else { return }
        let batch = items.filter { $0.state == .ready }
        guard !batch.isEmpty else { return }
        isConverting = true
        let flag = CancelFlag()
        cancelFlag = flag
        let choice = self.choice
        let channels = output.channelCount
        let cleanup = self.cleanup
        Task {
            for item in batch {
                if flag.isSet { break }
                guard items.contains(where: { $0 === item }), item.state == .ready else { continue }
                await convert(item, choice: choice, channels: channels, cleanup: cleanup, flag: flag)
            }
            isConverting = false
        }
    }

    func stop() {
        cancelFlag.set()
    }

    private func convert(_ item: VideoItem, choice: ChannelChoice, channels: Int,
                         cleanup: CleanupOptions, flag: CancelFlag) async {
        let source = choice.source(recommended: item.report?.recommendation)
        let destination = Self.outputURL(for: item.url, cleaned: cleanup.isActive)
        item.state = .converting
        item.progress = 0
        item.stage = cleanup.isActive ? .cleaning : .saving
        item.usedSource = source
        do {
            try await MonoConverter.convert(input: item.url,
                                            output: destination,
                                            options: ConvertOptions(source: source, outputChannels: channels, cleanup: cleanup),
                                            cancel: flag) { @Sendable fraction, stage in
                Task { @MainActor in
                    if item.state == .converting {
                        item.progress = fraction
                        item.stage = stage
                    }
                }
            }
            item.progress = 1
            item.outputURL = destination
            item.usedCleanup = cleanup.summary
            item.state = .done
        } catch MonoError.cancelled {
            try? FileManager.default.removeItem(at: destination)
            item.state = .ready
        } catch {
            try? FileManager.default.removeItem(at: destination)
            item.state = .failed(error.localizedDescription)
        }
    }

    /// "Clip.mov" becomes "Clip (mono).mov", or "Clip (clean).mov" when the sound was cleaned up,
    /// next to the original, never overwriting anything.
    static func outputURL(for input: URL, cleaned: Bool) -> URL {
        let ext = input.pathExtension.lowercased()
        let outExt = ["mov", "m4v"].contains(ext) ? ext : "mp4"
        let base = input.deletingPathExtension().lastPathComponent
        let folder = input.deletingLastPathComponent()
        let tag = cleaned ? "clean" : "mono"
        var candidate = folder.appendingPathComponent("\(base) (\(tag)).\(outExt)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(tag) \(number)).\(outExt)")
            number += 1
        }
        return candidate
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
