"""Tests for sentence splitting and TTS chunking."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from udp_tts import chunker
from udp_tts.book import Book, Chapter


def test_splits_basic_sentences():
    s = chunker.split_sentences("Hello there. How are you? I am fine!")
    assert s == ["Hello there.", "How are you?", "I am fine!"]


def test_does_not_split_on_abbreviations():
    s = chunker.split_sentences("Dr. Smith met Mr. Jones today. They talked.")
    assert s == ["Dr. Smith met Mr. Jones today.", "They talked."]


def test_paragraph_breaks_separate_sentences():
    s = chunker.split_sentences("First para line one\nline two.\n\nSecond para.")
    assert s == ["First para line one line two.", "Second para."]


def test_chunks_respect_max_chars():
    text = " ".join("Sentence number %d is here." % i for i in range(40))
    chunks = chunker.chunk_text(text, max_chars=80)
    assert all(len(c) <= 80 for c in chunks)
    # Nothing dropped: every sentence's content survives.
    assert "Sentence number 39 is here." in chunks[-1]


def test_never_splits_mid_sentence_when_it_fits():
    text = "Short one. " + "A " * 10 + "longer sentence that still fits."
    chunks = chunker.chunk_text(text, max_chars=200)
    for c in chunks:
        # No chunk should end without terminal punctuation unless it was the
        # forced split of an over-long sentence (not the case here).
        assert c.strip()[-1] in ".!?"


def test_long_sentence_is_split_at_clauses():
    long = ("This clause is first, and this clause is second; "
            "then a third clause appears: finally the end.")
    chunks = chunker.chunk_text(long, max_chars=40)
    assert all(len(c) <= 40 for c in chunks)
    assert len(chunks) > 1


def test_single_huge_word_left_intact():
    word = "x" * 100
    chunks = chunker.chunk_text(word + ".", max_chars=20)
    assert any(len(c) > 20 for c in chunks)  # an unsplittable token survives


def test_chunk_book_indexes_and_chapter_starts():
    book = Book(title="T", chapters=[
        Chapter(title="One", text="Alpha sentence. Beta sentence."),
        Chapter(title="Two", text="Gamma sentence."),
    ])
    chunks = chunker.chunk_book(book, max_chars=200)
    assert [c.index for c in chunks] == list(range(len(chunks)))
    starts = [c for c in chunks if c.is_chapter_start]
    assert len(starts) == 2
    assert starts[0].chapter_title == "One"
    assert starts[1].chapter_title == "Two"


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok", name)
    print("chunker tests passed")
