import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run(Array(CommandLine.arguments.dropFirst()))
        } else {
            MonoMakerApp.main()
        }
    }
}

struct MonoMakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Mono Maker", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 500)
        }
        .defaultSize(width: 840, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Videos…") { model.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Window

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.items.isEmpty {
                    EmptyState(isTargeted: isTargeted) { model.chooseFiles() }
                        .padding(20)
                } else {
                    List {
                        ForEach(model.items) { item in
                            ItemRow(item: item)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .overlay {
                        if isTargeted {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                                .padding(6)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            ControlBar()
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            model.handleDrop(providers)
        }
    }
}

struct EmptyState: View {
    let isTargeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 46, weight: .light))
                .foregroundColor(isTargeted ? Color.accentColor : Color.secondary)
            Text("Drop videos here")
                .font(.title2.weight(.semibold))
            Text("MOV, MP4 or M4V files, or a whole folder. The picture is copied untouched; only the sound is changed: turned into mono, and cleaned up if you choose. New files are saved next to the originals.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Choose Videos…", action: choose)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.45),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        )
    }
}

// MARK: - One video

struct ItemRow: View {
    @ObservedObject var item: VideoItem
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let report = item.report {
                Levels(report: report)
                    .frame(width: 150)
            }

            trailing
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Show in Finder") { AppModel.reveal(item.outputURL ?? item.url) }
            Button("Remove from List") { model.remove(item) }
                .disabled(item.state == .converting)
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .analyzing:
            Text("Checking the sound…")
                .foregroundColor(.secondary)
        case .ready:
            Text(plan)
                .foregroundColor(.secondary)
        case .noAudio:
            Text("No sound track in this file.")
                .foregroundColor(.orange)
        case .converting:
            Text(verbatim: "\(item.stage.label) · \(Int(item.progress * 100))%")
                .foregroundColor(.secondary)
        case .done:
            Text(verbatim: savedLine)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .failed(let message):
            Text(message)
                .foregroundColor(.red)
                .lineLimit(2)
        }
    }

    private var savedLine: String {
        let name = item.outputURL?.lastPathComponent ?? ""
        var details = item.usedSource?.label ?? ""
        if !item.usedCleanup.isEmpty { details += ", \(item.usedCleanup)" }
        return "Saved as “\(name)” · \(details)"
    }

    private var plan: String {
        guard let report = item.report else { return "" }
        if model.choice == .auto { return report.note }
        return "Will use: \(model.choice.source(recommended: report.recommendation).label)"
    }

    @ViewBuilder private var trailing: some View {
        switch item.state {
        case .converting:
            ProgressView(value: item.progress)
                .frame(width: 86)
        case .done:
            Button {
                if let url = item.outputURL { AppModel.reveal(url) }
            } label: {
                Label("Show", systemImage: "magnifyingglass")
            }
        default:
            EmptyView()
        }
    }
}

/// Small loudness bars for the left and right channels.
struct Levels: View {
    let report: ChannelReport

    var body: some View {
        VStack(spacing: 4) {
            if report.sourceChannels == 1 {
                LevelBar(label: "M", decibels: report.leftDB)
            } else {
                LevelBar(label: "L", decibels: report.leftDB)
                LevelBar(label: "R", decibels: report.rightDB)
            }
        }
        .help("Average loudness of each channel")
    }
}

struct LevelBar: View {
    let label: String
    let decibels: Double

    private var isSilent: Bool { decibels < -70 }
    private var fraction: CGFloat { CGFloat(min(max((decibels + 60) / 60, 0), 1)) }
    private var readout: String { isSilent ? "silent" : "\(Int(decibels.rounded())) dB" }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 10)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(isSilent ? Color.orange : Color.accentColor)
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text(verbatim: readout)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(isSilent ? Color.orange : Color.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

// MARK: - Settings and actions

struct ControlBar: View {
    @EnvironmentObject var model: AppModel

    private var convertTitle: String {
        model.readyCount > 1 ? "Convert \(model.readyCount) Videos" : "Convert"
    }

    private var noiseNote: String {
        if !model.noiseRemovalAvailable {
            return "Noise removal needs macOS 13 or later."
        }
        switch model.noise {
        case .off: return "Removes hum, hiss, wind, traffic and room noise around voices."
        case .light: return "Keeps some of the room so it sounds natural."
        case .medium: return "Removes most background sound."
        case .strong: return "Keeps voices only. Background music is removed too."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Background noise")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Background noise", selection: $model.noise) {
                        ForEach(NoiseLevel.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                    .disabled(!model.noiseRemovalAvailable)
                    Text(noiseNote)
                        .font(.caption)
                        .foregroundColor(model.noise == .strong ? Color.orange : Color.secondary)
                        .frame(width: 280, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $model.enhanceVoice) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Enhance voice")
                            Text("Cuts rumble and boxiness, adds clarity")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Toggle(isOn: $model.evenLoudness) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Even out loudness")
                            Text(verbatim: "Sets a standard level (\(Int(targetLoudness)) LUFS), no clipping")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)

                Spacer(minLength: 0)
            }
            .disabled(model.isConverting)

            Divider()

            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Sound from")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Sound from", selection: $model.choice) {
                        ForEach(ChannelChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)
                }
                .disabled(model.isConverting)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Save as")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Save as", selection: $model.output) {
                        ForEach(OutputChannels.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
                .disabled(model.isConverting)

                Spacer(minLength: 8)

                if model.hasFinished && !model.isConverting {
                    Button("Clear Finished") { model.clearFinished() }
                }
                Button("Add Videos…") { model.chooseFiles() }
                if model.isConverting {
                    Button("Stop") { model.stop() }
                } else {
                    Button(convertTitle) {
                        model.convertAll()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.readyCount == 0)
                }
            }
        }
        .padding(16)
    }
}
