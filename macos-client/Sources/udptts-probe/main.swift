import Foundation
import UDPTTSCore

/// Headless UDP TTS client. Streams text (or a whole book) to a WAV file.
///
/// Shares the exact networking/jitter/book code the menu-bar app uses, so a
/// successful run proves the Swift client is byte-compatible with the Python
/// server. No audio hardware required.
///
///   udptts-probe "hello world" --host 127.0.0.1 --port 50007 -o out.wav
///   udptts-probe --book mybook.epub --port 50007 -o book.wav

struct Config {
    var text: String?
    var bookPath: String?
    var host = "127.0.0.1"
    var port: UInt16 = 50007
    var output = "probe_out.wav"
    var maxChars = Chunker.defaultMaxChars
    var timeout = 15.0
    var extras: [String: String] = [:]
}

func parseArgs() -> Config {
    let args = Array(CommandLine.arguments.dropFirst())
    var cfg = Config()
    var i = 0
    func value() -> String? { i + 1 < args.count ? { i += 1; return args[i] }() : nil }
    while i < args.count {
        switch args[i] {
        case "--host": cfg.host = value() ?? cfg.host
        case "--port": cfg.port = UInt16(value() ?? "") ?? cfg.port
        case "--output", "-o": cfg.output = value() ?? cfg.output
        case "--book": cfg.bookPath = value()
        case "--max-chars": cfg.maxChars = Int(value() ?? "") ?? cfg.maxChars
        case "--timeout": cfg.timeout = Double(value() ?? "") ?? cfg.timeout
        case "--speaker": cfg.extras["speaker"] = value()
        case "--language": cfg.extras["language"] = value()
        default: if cfg.text == nil { cfg.text = args[i] }
        }
        i += 1
    }
    if cfg.text == nil && cfg.bookPath == nil {
        FileHandle.standardError.write(Data(
            "usage: udptts-probe \"text\" | --book FILE [--host H] [--port P] [-o FILE]\n".utf8))
        exit(2)
    }
    return cfg
}

func writeWAV(path: String, pcm: Data, sampleRate: UInt32, channels: UInt16) {
    let byteRate = sampleRate * UInt32(channels) * 2
    var d = Data()
    func a32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func a16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    d.append(Data("RIFF".utf8)); a32(UInt32(36 + pcm.count)); d.append(Data("WAVE".utf8))
    d.append(Data("fmt ".utf8)); a32(16); a16(1); a16(channels)
    a32(sampleRate); a32(byteRate); a16(channels * 2); a16(16)
    d.append(Data("data".utf8)); a32(UInt32(pcm.count)); d.append(pcm)
    try? d.write(to: URL(fileURLWithPath: path))
}

/// Stream one piece of text to completion (blocking). Returns PCM + format.
func streamOne(text: String, cfg: Config) -> (pcm: Data, sampleRate: UInt32, channels: UInt16)? {
    var collected = Data()
    var header: UDPProtocol.StreamHeader?
    var failure: String?

    let streamer = UDPStreamer(host: cfg.host, port: cfg.port, text: text, extras: cfg.extras)
    streamer.onHeader = { hdr, jb in
        header = hdr
        DispatchQueue.global().async {
            while !jb.isDrained {
                let chunk = jb.readAvailable(maxBytes: 8192)
                if chunk.isEmpty { usleep(10_000) } else { collected.append(chunk) }
            }
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }
    streamer.onState = { state in
        if case .failed(let message) = state {
            failure = message
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }
    streamer.start()

    // Per-call timeout, cancelled once the loop ends so it can't fire later.
    let timeoutItem = DispatchWorkItem {
        if header == nil { failure = "timeout waiting for server"; CFRunLoopStop(CFRunLoopGetMain()) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + cfg.timeout, execute: timeoutItem)

    CFRunLoopRun()
    timeoutItem.cancel()
    streamer.cancel()

    if let failure = failure {
        FileHandle.standardError.write(Data("error: \(failure)\n".utf8))
        return nil
    }
    guard let h = header else { return nil }
    return (collected, h.sampleRate, h.channels)
}

let cfg = parseArgs()

// Build the list of texts to stream: a single string, or a chunked book.
var texts: [String] = []
var sampleRate: UInt32 = 24000
var channels: UInt16 = 1

if let bookPath = cfg.bookPath {
    do {
        let book = try Book.load(from: URL(fileURLWithPath: bookPath))
        let chunks = Chunker.chunkBook(book, maxChars: cfg.maxChars)
        FileHandle.standardError.write(Data(
            "“\(book.title)” — \(book.chapters.count) chapters, \(chunks.count) chunks\n".utf8))
        texts = chunks.map(\.text)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
} else {
    texts = [cfg.text!]
}

var allPCM = Data()
for (idx, text) in texts.enumerated() {
    guard let result = streamOne(text: text, cfg: cfg) else { exit(1) }
    allPCM.append(result.pcm)
    sampleRate = result.sampleRate
    channels = result.channels
    if texts.count > 1 {
        FileHandle.standardError.write(Data("  [\(idx + 1)/\(texts.count)]\n".utf8))
    }
}

writeWAV(path: cfg.output, pcm: allPCM, sampleRate: sampleRate, channels: channels)
let seconds = Double(allPCM.count) / Double(sampleRate * UInt32(channels) * 2)
print("wrote \(cfg.output): \(allPCM.count) bytes, \(String(format: "%.2f", seconds))s")
