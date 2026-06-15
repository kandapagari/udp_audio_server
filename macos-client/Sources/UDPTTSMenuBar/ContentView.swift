import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The panel shown when the menu-bar icon is clicked.
struct ContentView: View {
    @EnvironmentObject private var model: TTSClientModel
    @EnvironmentObject private var hotKeyInfo: HotKeyInfo
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform")
                Text("UDP TTS").font(.headline)
                Spacer()
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Connection settings")
            }

            if showSettings {
                settings
                Divider()
            }

            Text("Text to speak")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.text)
                .font(.body)
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                if model.isBusy {
                    Button(role: .cancel) { model.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button { model.speak() } label: {
                        Label("Speak", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canSpeak)
                }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }

            if model.isBusy {
                LevelMeterView(level: model.level)
            }

            Divider()
            bookSection

            statusLine

            Divider()
            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(hotKeyInfo.label) to toggle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: book reading

    private var bookSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { openBook() } label: { Label("Open Book…", systemImage: "book") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("txt · md · pdf").font(.caption2).foregroundStyle(.tertiary)
            }

            if model.hasBook {
                Text(model.bookTitle ?? "")
                    .font(.subheadline).bold().lineLimit(1)
                if let chapter = model.currentChapter {
                    Text(chapter).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressView(value: Double(model.currentChunk + 1),
                             total: Double(max(1, model.chunks.count)))
                    .controlSize(.small)
                Text("Chunk \(model.currentChunk + 1) of \(model.chunks.count)")
                    .font(.caption2).foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button { model.skip(by: -1) } label: { Image(systemName: "backward.fill") }
                    Button { model.togglePlayPause() } label: {
                        Image(systemName: model.isReadingBook && !model.isPaused
                              ? "pause.fill" : "play.fill")
                    }
                    Button { model.skip(by: 1) } label: { Image(systemName: "forward.fill") }
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func openBook() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.plainText, .pdf]
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let markdown = UTType("net.daringfireball.markdown") { types.append(markdown) }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url {
            model.loadBook(url: url)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Host").frame(width: 64, alignment: .leading)
                TextField("127.0.0.1", text: $model.host).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Port").frame(width: 64, alignment: .leading)
                TextField("50007", text: $model.port).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Speaker").frame(width: 64, alignment: .leading)
                TextField("(default)", text: $model.speaker).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Language").frame(width: 64, alignment: .leading)
                TextField("(default)", text: $model.language).textFieldStyle(.roundedBorder)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var statusColor: Color {
        if model.statusText.hasPrefix("Error") { return .red }
        if model.isBusy { return .green }
        return .secondary
    }
}

/// A horizontal VU meter: a gradient bar whose width tracks the output level.
struct LevelMeterView: View {
    let level: Float  // 0...1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(
                        colors: [.green, .green, .yellow, .red],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(max(0, min(level, 1))))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Output level")
    }
}
