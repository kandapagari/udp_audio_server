import Foundation
import PDFKit

/// A chapter of plain text.
public struct Chapter: Equatable {
    public let title: String?
    public let text: String
    public init(title: String?, text: String) {
        self.title = title
        self.text = text
    }
}

/// A loaded book: a title plus ordered chapters. Swift counterpart of the
/// Python `Book`. Loads .txt, .md/.markdown natively and .pdf via PDFKit.
/// (EPUB is handled by the Python `udp-tts-read` CLI; Swift skips it.)
public struct Book: Equatable {
    public let title: String
    public let chapters: [Chapter]

    public var fullText: String { chapters.map(\.text).joined(separator: "\n\n") }
    public var wordCount: Int {
        chapters.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count }
    }

    public static let supportedExtensions = ["txt", "text", "md", "markdown", "pdf"]

    public enum LoadError: Error, LocalizedError {
        case unsupported(String)
        case unreadable(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .unsupported(let ext): return "Unsupported format “.\(ext)”"
            case .unreadable(let why): return "Couldn't read file: \(why)"
            case .empty: return "No readable text found"
            }
        }
    }

    public static func load(from url: URL) throws -> Book {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "txt", "text": return try loadText(url)
        case "md", "markdown": return try loadMarkdown(url)
        case "pdf": return try loadPDF(url)
        default: throw LoadError.unsupported(ext)
        }
    }

    // MARK: - loaders

    private static func loadText(_ url: URL) throws -> Book {
        let raw = try readString(url)
        let chapters = splitPlainChapters(raw)
        return Book(title: titleFromURL(url), chapters: chapters)
    }

    private static func loadMarkdown(_ url: URL) throws -> Book {
        let raw = try readString(url).replacingOccurrences(of: "\r\n", with: "\n")
        var title = titleFromURL(url)
        var chapters: [Chapter] = []
        var currentTitle: String?
        var buf: [String] = []

        func flush() {
            let body = normalize(stripMarkdown(buf.joined(separator: "\n")))
            if !body.isEmpty { chapters.append(Chapter(title: currentTitle, text: body)) }
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let h = headingMatch(line) {
                if h.level == 1 && chapters.isEmpty && buf.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    title = h.text     // top-level H1 is the book title
                    continue
                }
                flush(); buf = []; currentTitle = h.text
            } else {
                buf.append(line)
            }
        }
        flush()
        if chapters.isEmpty {
            chapters = [Chapter(title: nil, text: normalize(stripMarkdown(raw)))]
        }
        return Book(title: title, chapters: chapters)
    }

    private static func loadPDF(_ url: URL) throws -> Book {
        guard let doc = PDFDocument(url: url) else {
            throw LoadError.unreadable("not a valid PDF")
        }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            pages.append(doc.page(at: i)?.string ?? "")
        }
        let text = normalize(pages.joined(separator: "\n\n"))
        if text.isEmpty { throw LoadError.empty }  // likely a scanned/image PDF
        let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespaces)
        return Book(title: (title?.isEmpty == false ? title! : titleFromURL(url)),
                    chapters: [Chapter(title: nil, text: text)])
    }

    // MARK: - helpers

    private static func readString(_ url: URL) throws -> String {
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch {
            if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return s }
            throw LoadError.unreadable(error.localizedDescription)
        }
    }

    private static func titleFromURL(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let t = base.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Untitled" : t
    }

    private static func splitPlainChapters(_ raw: String) -> [Chapter] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chapters: [Chapter] = []
        var currentTitle: String?
        var buf: [String] = []
        func flush() {
            let body = normalize(buf.joined(separator: "\n"))
            if !body.isEmpty { chapters.append(Chapter(title: currentTitle, text: body)) }
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count < 60, chapterHeadingRegex.firstMatch(
                in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                flush(); buf = []; currentTitle = trimmed
            } else {
                buf.append(line)
            }
        }
        flush()
        if chapters.isEmpty { chapters = [Chapter(title: nil, text: normalize(raw))] }
        return chapters
    }

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#" { level += 1; idx = line.index(after: idx) }
        guard level <= 2, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    private static let chapterHeadingRegex = try! NSRegularExpression(
        pattern: "^\\s*(chapter|part|book|section)\\b.{0,60}$", options: [.caseInsensitive])
}

// MARK: - normalization (mirrors book.py normalize_text / strip_markdown)

func normalize(_ input: String) -> String {
    var text = input.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    text = regexReplace(text, "(\\w+)-\\n(\\w+)", "$1$2")          // de-hyphenate
    text = String(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 32 })
    text = regexReplace(text, "[ \\t]+", " ")                      // collapse spaces
    text = regexReplace(text, "\\n{3,}", "\n\n")                   // cap blank runs
    text = regexReplace(text, "(?<!\\n)\\n(?!\\n)", " ")           // soft-wrap -> space
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func stripMarkdown(_ input: String) -> String {
    var t = input
    t = regexReplace(t, "```[\\s\\S]*?```", "")
    t = regexReplace(t, "`([^`]*)`", "$1")
    t = regexReplace(t, "!\\[[^\\]]*\\]\\([^)]*\\)", "")
    t = regexReplace(t, "\\[([^\\]]+)\\]\\([^)]*\\)", "$1")
    t = regexReplace(t, "(?m)^\\s{0,3}>\\s?", "")
    t = regexReplace(t, "(\\*\\*|__|\\*|_|~~)", "")
    t = regexReplace(t, "(?m)^\\s{0,3}([-*+]|\\d+\\.)\\s+", "")
    return t
}

private func regexReplace(_ text: String, _ pattern: String, _ template: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(location: 0, length: (text as NSString).length)
    return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
}
