"""Load books from common formats into normalized chapters of plain text.

``.txt`` and ``.md``/``.markdown`` are parsed natively (no dependencies, plus a
"Chapter N" heading heuristic for plain text). Every other format -- ``.epub``,
``.pdf``, ``.docx``, ``.pptx``, ``.xlsx``, ``.html``, ``.csv``, ``.json``,
``.xml`` -- is routed through Microsoft's `markitdown
<https://github.com/microsoft/markitdown>`_, which converts it to Markdown that
we then run through the same Markdown chapter-splitter. markitdown is imported
lazily, so the native path needs nothing installed.

Everything reduces to a :class:`Book` -- a title plus ordered :class:`Chapter`
objects -- which :mod:`udp_tts.chunker` then splits into TTS chunks.
"""

import os
import re
from dataclasses import dataclass, field
from typing import List, Optional

# Lines that look like chapter headings in plain text.
_CHAPTER_HEADING = re.compile(
    r"^\s*(chapter|part|book|section)\b.{0,60}$", re.IGNORECASE)


@dataclass
class Chapter:
    title: Optional[str]
    text: str


@dataclass
class Book:
    title: str
    chapters: List[Chapter] = field(default_factory=list)

    @property
    def full_text(self) -> str:
        return "\n\n".join(c.text for c in self.chapters)

    @property
    def word_count(self) -> int:
        return sum(len(c.text.split()) for c in self.chapters)


# --- text normalization -----------------------------------------------------

def normalize_text(text: str) -> str:
    """Clean raw extracted text without destroying paragraph structure."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    # Join words hyphenated across a line break (common in PDF extraction).
    text = re.sub(r"(\w+)-\n(\w+)", r"\1\2", text)
    # Drop control characters except newline/tab.
    text = "".join(ch for ch in text if ch == "\n" or ch == "\t" or ord(ch) >= 32)
    # Collapse runs of spaces/tabs, but keep newlines.
    text = re.sub(r"[ \t]+", " ", text)
    # Collapse 3+ newlines to a paragraph break.
    text = re.sub(r"\n{3,}", "\n\n", text)
    # A single newline inside a paragraph becomes a space; doubles stay.
    text = re.sub(r"(?<!\n)\n(?!\n)", " ", text)
    return text.strip()


def _strip_markdown(text: str) -> str:
    text = re.sub(r"```.*?```", "", text, flags=re.DOTALL)      # code fences
    text = re.sub(r"`([^`]*)`", r"\1", text)                    # inline code
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)            # images
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)        # links -> text
    text = re.sub(r"^\s{0,3}>\s?", "", text, flags=re.MULTILINE)  # blockquotes
    text = re.sub(r"(\*\*|__|\*|_|~~)", "", text)               # emphasis
    text = re.sub(r"^\s{0,3}([-*+]|\d+\.)\s+", "", text, flags=re.MULTILINE)
    return text


def _title_from_path(path: str) -> str:
    base = os.path.splitext(os.path.basename(path))[0]
    return base.replace("_", " ").replace("-", " ").strip() or "Untitled"


# --- format loaders ---------------------------------------------------------

def _load_txt(path: str) -> Book:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        raw = f.read()
    chapters = _split_plaintext_chapters(raw)
    return Book(title=_title_from_path(path), chapters=chapters)


def _split_plaintext_chapters(raw: str) -> List[Chapter]:
    """Split on lines that look like 'Chapter N' headings; else one chapter.

    Heading detection runs on the line-preserved raw text; each chapter body is
    normalized afterwards (normalization collapses single newlines, which would
    otherwise hide standalone heading lines).
    """
    lines = raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    chapters: List[Chapter] = []
    current_title: Optional[str] = None
    buf: List[str] = []

    def flush():
        body = normalize_text("\n".join(buf))
        if body:
            chapters.append(Chapter(title=current_title, text=body))

    for line in lines:
        if _CHAPTER_HEADING.match(line) and len(line.strip()) < 60:
            flush()
            buf = []
            current_title = line.strip()
        else:
            buf.append(line)
    flush()
    if not chapters:
        chapters = [Chapter(title=None, text=normalize_text(raw))]
    return chapters


def _load_markdown(path: str) -> Book:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        raw = f.read()
    return _book_from_markdown(raw, default_title=_title_from_path(path))


def _book_from_markdown(raw: str, default_title: str) -> Book:
    """Build a Book from Markdown text: H1/H2 headings become chapter boundaries.

    Shared by the native ``.md`` loader and the markitdown path (which converts
    every other format to Markdown first).
    """
    title = default_title
    chapters: List[Chapter] = []
    current_title: Optional[str] = None
    buf: List[str] = []
    saw_chapter_heading = False

    def flush():
        body = normalize_text(_strip_markdown("\n".join(buf)))
        if body:
            chapters.append(Chapter(title=current_title, text=body))

    for line in raw.replace("\r\n", "\n").split("\n"):
        heading = re.match(r"^(#{1,2})\s+(.*)$", line)
        if heading:
            level = len(heading.group(1))
            text = heading.group(2).strip()
            if level == 1 and not chapters and not buf and not saw_chapter_heading:
                title = text  # top-level H1 is the book title
                continue
            saw_chapter_heading = True
            flush()
            buf = []
            current_title = text
        else:
            buf.append(line)

    if not saw_chapter_heading:
        # No Markdown chapter headings (common for PDF/plain conversions): fall
        # back to the plain-text "Chapter N" heuristic so it's still chaptered.
        return Book(title=title,
                    chapters=_split_plaintext_chapters("\n".join(buf)))

    flush()
    if not chapters:
        chapters = [Chapter(title=None, text=normalize_text(_strip_markdown(raw)))]
    return Book(title=title, chapters=chapters)


def _load_via_markitdown(path: str) -> Book:
    """Convert any markitdown-supported format to Markdown, then split chapters."""
    try:
        from markitdown import MarkItDown
    except ImportError as exc:
        raise RuntimeError(
            "this format needs 'markitdown' (uv sync --group client)"
        ) from exc

    result = MarkItDown().convert(path)
    text = (getattr(result, "text_content", None) or "").strip()
    if not text:
        raise RuntimeError(
            "no extractable text (the file may be empty or scanned images)")
    title = (getattr(result, "title", None) or "").strip() or _title_from_path(path)
    return _book_from_markdown(text, default_title=title)


# .txt/.md are native; everything else goes through markitdown.
_NATIVE_LOADERS = {
    ".txt": _load_txt,
    ".text": _load_txt,
    ".md": _load_markdown,
    ".markdown": _load_markdown,
}
_MARKITDOWN_EXTENSIONS = [
    ".epub", ".pdf", ".docx", ".doc", ".pptx", ".ppt", ".xlsx", ".xls",
    ".html", ".htm", ".csv", ".json", ".xml",
]
_LOADERS = dict(_NATIVE_LOADERS)
for _ext in _MARKITDOWN_EXTENSIONS:
    _LOADERS[_ext] = _load_via_markitdown


def supported_extensions() -> List[str]:
    return sorted(_LOADERS.keys())


def load_book(path: str) -> Book:
    """Load ``path`` into a :class:`Book`, dispatching on file extension."""
    if not os.path.isfile(path):
        raise FileNotFoundError(path)
    ext = os.path.splitext(path)[1].lower()
    loader = _LOADERS.get(ext)
    if loader is None:
        raise ValueError(
            "unsupported format %r (supported: %s)"
            % (ext, ", ".join(supported_extensions()))
        )
    return loader(path)
