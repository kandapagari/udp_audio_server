import XCTest
@testable import UDPTTSCore

final class ChunkerTests: XCTestCase {
    func testSplitsBasicSentences() {
        XCTAssertEqual(Chunker.splitSentences("Hello there. How are you? I am fine!"),
                       ["Hello there.", "How are you?", "I am fine!"])
    }

    func testDoesNotSplitOnAbbreviations() {
        XCTAssertEqual(Chunker.splitSentences("Dr. Smith met Mr. Jones today. They talked."),
                       ["Dr. Smith met Mr. Jones today.", "They talked."])
    }

    func testParagraphBreaksSeparate() {
        XCTAssertEqual(Chunker.splitSentences("First line one\nline two.\n\nSecond para."),
                       ["First line one line two.", "Second para."])
    }

    func testChunksRespectMaxChars() {
        let text = (0..<40).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let chunks = Chunker.chunkText(text, maxChars: 80)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 80 })
        XCTAssertTrue(chunks.last!.contains("Sentence number 39 is here."))
    }

    func testLongSentenceSplitAtClauses() {
        let long = "This clause is first, and this clause is second; then a third clause appears: finally the end."
        let chunks = Chunker.chunkText(long, maxChars: 40)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 40 })
        XCTAssertGreaterThan(chunks.count, 1)
    }

    func testHugeWordLeftIntact() {
        let chunks = Chunker.chunkText(String(repeating: "x", count: 100) + ".", maxChars: 20)
        XCTAssertTrue(chunks.contains { $0.count > 20 })
    }

    func testChunkBookIndexesAndChapterStarts() {
        let book = Book(title: "T", chapters: [
            Chapter(title: "One", text: "Alpha sentence. Beta sentence."),
            Chapter(title: "Two", text: "Gamma sentence."),
        ])
        let chunks = Chunker.chunkBook(book, maxChars: 200)
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
        let starts = chunks.filter { $0.isChapterStart }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0].chapterTitle, "One")
        XCTAssertEqual(starts[1].chapterTitle, "Two")
    }
}

final class BookLoaderTests: XCTestCase {
    private func writeTemp(_ name: String, _ content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testLoadTextSingleChapter() throws {
        let url = try writeTemp("my_book.txt", "Just one block of prose. The end.")
        let book = try Book.load(from: url)
        XCTAssertEqual(book.title, "my book")
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertTrue(book.chapters[0].text.contains("The end."))
    }

    func testLoadTextSplitsOnChapterHeadings() throws {
        let url = try writeTemp("novel.txt",
            "Chapter 1\nThe beginning happens here.\n\nChapter 2\nThe middle happens.")
        let book = try Book.load(from: url)
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertTrue(book.chapters[0].title?.hasPrefix("Chapter 1") ?? false)
    }

    func testLoadMarkdownTitleAndChapters() throws {
        let md = "# The Great Book\n\nIntro.\n\n## First\n\nContent **one** [link](http://x).\n\n## Second\n\nTwo.\n"
        let url = try writeTemp("doc.md", md)
        let book = try Book.load(from: url)
        XCTAssertEqual(book.title, "The Great Book")
        // Intro text before the first ## becomes a titleless chapter (matches Python).
        let titles = book.chapters.compactMap(\.title)
        XCTAssertEqual(titles, ["First", "Second"])
        XCTAssertTrue(book.fullText.contains("Intro."))
        XCTAssertFalse(book.fullText.contains("**"))
        XCTAssertFalse(book.fullText.contains("http://x"))
        XCTAssertTrue(book.fullText.contains("link"))
    }

    func testUnsupportedExtensionThrows() throws {
        let url = try writeTemp("x.docx", "nope")
        XCTAssertThrowsError(try Book.load(from: url))
    }

    func testNormalizeDehyphenates() {
        let out = normalize("jum-\nped over   the\nlazy dog.\n\n\n\nNext.")
        XCTAssertTrue(out.contains("jumped over the lazy dog."))
        XCTAssertTrue(out.contains("\n\n"))
        XCTAssertFalse(out.contains("   "))
    }
}
