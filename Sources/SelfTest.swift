import Foundation

/// Command-line test mode used by the automated build to check real conversions:
///   MonoMaker --selftest <input> <output> [--noise light|medium|strong] [--enhance] [--loud] [--both] [--source mix|left|right]
/// Prints what it found and did, and exits 0 on success.
enum SelfTest {
    static func run(_ args: [String]) -> Never {
        let rest = args.filter { $0 != "--selftest" }
        guard rest.count >= 2 else {
            print("usage: --selftest <input> <output> [options]")
            exit(2)
        }
        let input = URL(fileURLWithPath: rest[0])
        let output = URL(fileURLWithPath: rest[1])
        func value(after flag: String) -> String? {
            guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else { return nil }
            return rest[i + 1]
        }
        var cleanup = CleanupOptions()
        if let n = value(after: "--noise"), let level = NoiseLevel(rawValue: n) { cleanup.noise = level }
        cleanup.enhanceVoice = rest.contains("--enhance")
        cleanup.evenLoudness = rest.contains("--loud")
        let channels = rest.contains("--both") ? 2 : 1
        let forced = value(after: "--source").flatMap(ChannelSource.init(rawValue:))
        let options = cleanup

        Task.detached {
            do {
                let report = try await ChannelAnalyzer.analyze(url: input)
                print(String(format: "analysis: channels=%d left=%.1f dB right=%.1f dB auto=%@ (%@)",
                             report.sourceChannels, report.leftDB, report.rightDB,
                             report.recommendation.rawValue, report.note))
                let source = forced ?? report.recommendation
                let shown = ShownProgress()
                try await MonoConverter.convert(input: input,
                                                output: output,
                                                options: ConvertOptions(source: source, outputChannels: channels, cleanup: options),
                                                cancel: CancelFlag()) { fraction, stage in
                    let pct = Int(fraction * 100)
                    if shown.update(pct / 25) {
                        print("progress: \(stage.label) \(pct)%")
                    }
                }
                print("converted: source=\(source.rawValue) channels=\(channels) cleanup=[\(options.summary)] -> \(output.lastPathComponent)")
                exit(0)
            } catch {
                print("FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }
}

/// Remembers the last progress step printed (shared with the progress callback's thread).
private final class ShownProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    /// True when `step` differs from the last one shown.
    func update(_ step: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if step == last { return false }
        last = step
        return true
    }
}
