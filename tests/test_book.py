"""Tests for book loading and text normalization (txt/md; epub/pdf if libs present)."""
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from udp_tts import book


def _write(tmp, name, content):
    path = os.path.join(tmp, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return path


def test_normalize_dehyphenates_and_collapses():
    raw = "the quick brown fox jum-\nped over   the\nlazy dog.\n\n\n\nNext para."
    out = book.normalize_text(raw)
    assert "jumped over the lazy dog." in out
    assert "\n\n" in out          # paragraph break preserved
    assert "   " not in out       # runs of spaces collapsed


def test_load_txt_single_chapter():
    with tempfile.TemporaryDirectory() as tmp:
        path = _write(tmp, "my_book.txt", "Just one block of prose. The end.")
        b = book.load_book(path)
        assert b.title == "my book"
        assert len(b.chapters) == 1
        assert "The end." in b.chapters[0].text


def test_load_txt_splits_on_chapter_headings():
    text = "Chapter 1\nThe beginning happens here.\n\nChapter 2\nThe middle happens."
    with tempfile.TemporaryDirectory() as tmp:
        path = _write(tmp, "novel.txt", text)
        b = book.load_book(path)
        assert len(b.chapters) == 2
        assert b.chapters[0].title.startswith("Chapter 1")
        assert "beginning" in b.chapters[0].text


def test_load_markdown_uses_h1_title_and_h2_chapters():
    md = ("# The Great Book\n\nIntro line.\n\n"
          "## First\n\nContent **one** with a [link](http://x).\n\n"
          "## Second\n\nContent two.\n")
    with tempfile.TemporaryDirectory() as tmp:
        path = _write(tmp, "doc.md", md)
        b = book.load_book(path)
        assert b.title == "The Great Book"
        titles = [c.title for c in b.chapters]
        assert "First" in titles and "Second" in titles
        # Markdown emphasis/link syntax is stripped.
        joined = b.full_text
        assert "**" not in joined and "http://x" not in joined
        assert "link" in joined


def test_unsupported_extension_raises():
    with tempfile.TemporaryDirectory() as tmp:
        path = _write(tmp, "x.xyz", "nope")
        try:
            book.load_book(path)
        except ValueError:
            pass
        else:
            raise AssertionError("expected ValueError")


def test_missing_file_raises():
    try:
        book.load_book("/no/such/file.txt")
    except FileNotFoundError:
        pass
    else:
        raise AssertionError("expected FileNotFoundError")


def test_load_html_via_markitdown():
    """HTML routes through markitdown -> Markdown -> chapter splitter."""
    try:
        import markitdown  # noqa: F401
    except ImportError:
        print("(skip: markitdown not installed)")
        return
    html = ("<html><body><h1>The Web Book</h1><p>Intro paragraph.</p>"
            "<h2>Alpha</h2><p>First chapter body here.</p>"
            "<h2>Beta</h2><p>Second chapter body here.</p></body></html>")
    with tempfile.TemporaryDirectory() as tmp:
        path = _write(tmp, "page.html", html)
        b = book.load_book(path)
        titles = [c.title for c in b.chapters if c.title]
        assert "Alpha" in titles and "Beta" in titles, titles
        assert "First chapter body" in b.full_text
        assert "Second chapter body" in b.full_text


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok", name)
    print("book tests passed")
