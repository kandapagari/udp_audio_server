import Foundation
import SwiftUI
import UDPTTSCore

/// Observable state + orchestration for the menu-bar client.
///
/// `speak()` opens a `UDPStreamer`; when the stream HEADER arrives it spins up an
/// `AudioPlayer` bound to the same `JitterBuffer`. A drain monitor keeps playback
/// alive until the buffer empties after END, then tears everything down.
@MainActor
final class TTSClientModel: ObservableObject {
    @AppStorage("host") var host: String = "127.0.0.1"
    @AppStorage("port") var port: String = "50007"
    @AppStorage("speaker") var speaker: String = ""
    @AppStorage("language") var language: String = ""

    @Published var text: String = ""
    @Published var statusText: String = "Idle"
    @Published var isBusy: Bool = false
    @Published var received: Int = 0
    @Published var concealed: Int = 0
    @Published var level: Float = 0   // 0...1 output level for the VU meter

    // Book reading
    @Published var bookTitle: String?
    @Published var chunks: [BookChunk] = []
    @Published var currentChunk: Int = 0
    @Published var currentChapter: String?
    @Published var isReadingBook: Bool = false
    @Published var isPaused: Bool = false

    private var streamer: UDPStreamer?
    private var player: AudioPlayer?
    private var buffer: JitterBuffer?
    private var drainTimer: Timer?
    private var timeoutTimer: Timer?

    var canSpeak: Bool {
        !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasBook: Bool { !chunks.isEmpty }

    func speak() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !trimmed.isEmpty else { return }
        isReadingBook = false
        beginStream(text: trimmed)
    }

    func stop() {
        guard isBusy else { return }
        isReadingBook = false
        isPaused = false
        teardown()
        isBusy = false
        statusText = "Stopped"
    }

    /// Set up a stream for one piece of text. Shared by single speak and book
    /// reading. Returns immediately; completion is handled by the drain monitor.
    private func beginStream(text: String) {
        guard let portNum = UInt16(port.trimmingCharacters(in: .whitespaces)) else {
            statusText = "Invalid port"; return
        }
        let host = self.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { statusText = "Enter a host"; return }

        teardown()
        isBusy = true
        received = 0
        concealed = 0
        statusText = "Connecting…"

        var extras: [String: String] = [:]
        let lang = language.trimmingCharacters(in: .whitespaces)
        let spk = speaker.trimmingCharacters(in: .whitespaces)
        if !lang.isEmpty { extras["language"] = lang }
        if !spk.isEmpty { extras["speaker"] = spk }

        let streamer = UDPStreamer(host: host, port: portNum, text: text, extras: extras)
        streamer.onHeader = { [weak self] header, jb in self?.handleHeader(header, jb) }
        streamer.onState = { [weak self] state in self?.handleState(state) }
        streamer.onStats = { [weak self] r, c in
            self?.received = r
            self?.concealed = c
        }
        self.streamer = streamer
        streamer.start()

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.player == nil, self.isBusy else { return }
                self.fail("No response from server")
            }
        }
    }

    // MARK: - book reading

    /// Load and chunk a book file. Throws are surfaced as a status message.
    func loadBook(url: URL) {
        stop()
        do {
            let book = try Book.load(from: url)
            let maxChars = Chunker.defaultMaxChars
            let chunked = Chunker.chunkBook(book, maxChars: maxChars)
            guard !chunked.isEmpty else { statusText = "Book has no readable text"; return }
            bookTitle = book.title
            chunks = chunked
            currentChunk = 0
            currentChapter = chunked.first?.chapterTitle
            isReadingBook = false
            isPaused = false
            statusText = "“\(book.title)” — \(book.chapters.count) ch, \(chunked.count) chunks"
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    /// Start (or restart) reading the loaded book from `index`.
    func startReading(from index: Int? = nil) {
        guard hasBook else { return }
        if let index = index { currentChunk = min(max(0, index), chunks.count - 1) }
        isReadingBook = true
        isPaused = false
        currentChapter = chunks[currentChunk].chapterTitle
        beginStream(text: chunks[currentChunk].text)
    }

    /// Toggle play/pause while reading a book.
    func togglePlayPause() {
        guard hasBook else { return }
        if isReadingBook && !isPaused {
            // Pause: stop the current chunk; resume re-reads it from the start.
            isPaused = true
            teardown()
            isBusy = false
            statusText = "Paused — chunk \(currentChunk + 1)/\(chunks.count)"
        } else {
            startReading(from: currentChunk)
        }
    }

    func skip(by delta: Int) {
        guard hasBook else { return }
        let target = min(max(0, currentChunk + delta), chunks.count - 1)
        if isReadingBook && !isPaused {
            startReading(from: target)   // jump and keep playing
        } else {
            currentChunk = target
            currentChapter = chunks[target].chapterTitle
            statusText = "Chunk \(target + 1)/\(chunks.count)"
        }
    }

    // MARK: - callbacks

    private func handleHeader(_ header: UDPProtocol.StreamHeader, _ jb: JitterBuffer) {
        timeoutTimer?.invalidate(); timeoutTimer = nil
        do {
            let player = AudioPlayer(sampleRate: Double(header.sampleRate),
                                     channels: Int(header.channels), buffer: jb)
            try player.start()
            self.player = player
            self.buffer = jb
            if isReadingBook {
                statusText = "Reading \(currentChunk + 1)/\(chunks.count)"
            } else {
                statusText = "Streaming… (\(header.sampleRate) Hz)"
            }
            startDrainMonitor()
        } catch {
            fail("audio init failed: \(error.localizedDescription)")
        }
    }

    private func handleState(_ state: UDPStreamer.StreamState) {
        switch state {
        case .connecting, .streaming:
            break  // status already reflected
        case .finished:
            if buffer != nil {
                statusText = "Finishing playback…"  // drain monitor will complete
            }
        case .failed(let message):
            fail(message)
        }
    }

    private func startDrainMonitor() {
        drainTimer?.invalidate()
        // ~20 fps: smooth VU updates plus drain detection.
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let jb = self.buffer else { return }
                self.level = self.player?.meter.level ?? 0
                if jb.isDrained { self.finishPlayback() }
            }
        }
    }

    private func finishPlayback() {
        let r = received, c = concealed
        teardown()

        if isReadingBook && !isPaused {
            let next = currentChunk + 1
            if next < chunks.count {
                currentChunk = next
                currentChapter = chunks[next].chapterTitle
                beginStream(text: chunks[next].text)   // auto-advance
                return
            }
            isReadingBook = false
            isBusy = false
            statusText = "Finished “\(bookTitle ?? "book")”"
            return
        }

        isBusy = false
        statusText = "Done — \(r) packets, \(c) concealed"
    }

    private func fail(_ message: String) {
        teardown()
        isBusy = false
        statusText = "Error: \(message)"
    }

    private func teardown() {
        timeoutTimer?.invalidate(); timeoutTimer = nil
        drainTimer?.invalidate(); drainTimer = nil
        streamer?.cancel(); streamer = nil
        player?.stop(); player = nil
        buffer = nil
        level = 0
    }
}
