import Foundation

/// One unit of text to synthesize, with its place in the book.
public struct BookChunk: Equatable {
    public let text: String
    public let index: Int
    public let chapterIndex: Int
    public let chapterTitle: String?
    public let isChapterStart: Bool
}

/// Splits book text into TTS-friendly chunks. Swift port of `chunker.py`:
/// segment into sentences, then greedily pack sentences into chunks up to
/// `maxChars` without breaking mid-sentence (over-long sentences fall back to
/// clause, then word, boundaries).
public enum Chunker {
    public static let defaultMaxChars = 400

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g",
        "i.e", "fig", "no", "vol", "pp", "al", "inc", "ltd", "co",
    ]

    // MARK: Sentence segmentation

    public static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        // Split into paragraphs on blank lines so we never merge across them.
        let paragraphs = text.components(separatedBy: blankLineRegex)
        for para in paragraphs {
            let collapsed = para.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            if collapsed.isEmpty { continue }
            sentences.append(contentsOf: segment(collapsed))
        }
        return sentences
    }

    /// Manual scanner: break after .!? (+ optional closing quote) when followed
    /// by whitespace and a capital/digit/quote, unless the preceding token is a
    /// known abbreviation.
    private static func segment(_ paragraph: String) -> [String] {
        let chars = Array(paragraph)
        var sentences: [String] = []
        var start = 0
        var i = 0
        let terminators: Set<Character> = [".", "!", "?"]
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]"]
        let openers: Set<Character> = ["\"", "'", "“", "‘", "(", "["]

        while i < chars.count {
            if terminators.contains(chars[i]) {
                var j = i + 1
                while j < chars.count && closers.contains(chars[j]) { j += 1 }
                // require whitespace next
                guard j < chars.count, chars[j].isWhitespace else { i += 1; continue }
                var k = j
                while k < chars.count && chars[k].isWhitespace { k += 1 }
                guard k < chars.count else { break }
                let next = chars[k]
                let startsNewSentence = next.isUppercase || next.isNumber || openers.contains(next)
                if startsNewSentence && !endsWithAbbreviation(chars, from: start, to: i) {
                    let sentence = String(chars[start..<j]).trimmingCharacters(in: .whitespaces)
                    if !sentence.isEmpty { sentences.append(sentence) }
                    start = k
                    i = k
                    continue
                }
            }
            i += 1
        }
        let tail = String(chars[start..<chars.count]).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    private static func endsWithAbbreviation(_ chars: [Character], from: Int, to: Int) -> Bool {
        // Last whitespace-delimited token in chars[from..<to], minus trailing dots.
        var s = to
        while s > from && !chars[s - 1].isWhitespace { s -= 1 }
        let token = String(chars[s..<to]).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return abbreviations.contains(token)
    }

    // MARK: Packing

    public static func chunkText(_ text: String, maxChars: Int = defaultMaxChars) -> [String] {
        precondition(maxChars >= 1)
        var chunks: [String] = []
        var buf = ""
        for sentence in splitSentences(text) {
            for piece in splitLongSentence(sentence, maxChars: maxChars) {
                let candidate = buf.isEmpty ? piece : buf + " " + piece
                if candidate.count <= maxChars {
                    buf = candidate
                } else {
                    if !buf.isEmpty { chunks.append(buf) }
                    buf = piece
                }
            }
        }
        if !buf.isEmpty { chunks.append(buf) }
        return chunks
    }

    private static func splitLongSentence(_ sentence: String, maxChars: Int) -> [String] {
        if sentence.count <= maxChars { return [sentence] }
        let parts = sentence.components(separatedBy: clauseRegex)
        var out: [String] = []
        var buf = ""
        for part in parts {
            let candidate = buf.isEmpty ? part : buf + " " + part
            if candidate.count <= maxChars {
                buf = candidate
            } else {
                if !buf.isEmpty { out.append(buf) }
                if part.count <= maxChars {
                    buf = part
                } else {
                    out.append(contentsOf: splitByWords(part, maxChars: maxChars))
                    buf = ""
                }
            }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }

    private static func splitByWords(_ text: String, maxChars: Int) -> [String] {
        var out: [String] = []
        var buf = ""
        for word in text.split(separator: " ") {
            let candidate = buf.isEmpty ? String(word) : buf + " " + word
            if candidate.count <= maxChars {
                buf = candidate
            } else {
                if !buf.isEmpty { out.append(buf) }
                buf = String(word)  // a single over-long word is left intact
            }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }

    public static func chunkBook(_ book: Book, maxChars: Int = defaultMaxChars) -> [BookChunk] {
        var chunks: [BookChunk] = []
        var index = 0
        for (chapterIndex, chapter) in book.chapters.enumerated() {
            let texts = chunkText(chapter.text, maxChars: maxChars)
            for (i, text) in texts.enumerated() {
                chunks.append(BookChunk(
                    text: text, index: index, chapterIndex: chapterIndex,
                    chapterTitle: chapter.title, isChapterStart: i == 0))
                index += 1
            }
        }
        return chunks
    }

    // MARK: Regexes (compiled once)

    private static let blankLineRegex = try! NSRegularExpression(pattern: "\\n\\s*\\n")
    private static let clauseRegex = try! NSRegularExpression(pattern: "(?<=[,;:—])\\s+")
}

private extension String {
    /// Split on each match of `regex`, returning the pieces between matches.
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let ns = self as NSString
        let matches = regex.matches(in: self, range: NSRange(location: 0, length: ns.length))
        var pieces: [String] = []
        var last = 0
        for m in matches {
            pieces.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        pieces.append(ns.substring(from: last))
        return pieces
    }
}
