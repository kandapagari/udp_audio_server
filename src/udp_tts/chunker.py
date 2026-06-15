"""Split book text into TTS-friendly chunks.

TTS quality and latency are best when each request is a small, self-contained
piece of text that ends on a natural boundary. This module splits text into
sentences and greedily packs them into chunks up to ``max_chars`` without ever
breaking mid-sentence -- unless a single sentence is itself longer than the
limit, in which case it is split at clause or word boundaries as a fallback.

No NLP dependencies: sentence segmentation is a pragmatic regex that handles the
common cases (terminal punctuation, quotes/brackets, common abbreviations).
"""

import re
from dataclasses import dataclass
from typing import List, Optional

DEFAULT_MAX_CHARS = 400

# Abbreviations that end in a period but rarely end a sentence.
_ABBREVIATIONS = {
    "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g",
    "i.e", "fig", "no", "vol", "pp", "al", "inc", "ltd", "co",
}

# A sentence boundary: terminal punctuation, optional closing quote/bracket,
# then whitespace, then something that looks like the start of a new sentence.
_BOUNDARY = re.compile(
    r"""(?<=[.!?])["'”’)\]]?\s+(?=["'“‘(\[]?[A-Z0-9])""",
    re.VERBOSE,
)


@dataclass
class Chunk:
    """One unit of text to synthesize, with its place in the book."""
    text: str
    index: int                      # global 0-based chunk index
    chapter_index: int
    chapter_title: Optional[str]
    is_chapter_start: bool


def split_sentences(text: str) -> List[str]:
    """Split a block of text into sentences (best-effort, dependency-free)."""
    text = text.strip()
    if not text:
        return []
    # Split paragraphs first so we never merge across blank lines.
    sentences: List[str] = []
    for paragraph in re.split(r"\n\s*\n", text):
        paragraph = " ".join(paragraph.split())
        if not paragraph:
            continue
        pieces = _BOUNDARY.split(paragraph)
        sentences.extend(_merge_abbreviations(pieces))
    return [s.strip() for s in sentences if s.strip()]


def _merge_abbreviations(pieces: List[str]) -> List[str]:
    """Re-join splits that occurred right after a common abbreviation."""
    merged: List[str] = []
    for piece in pieces:
        if merged:
            last = merged[-1]
            tail = last.rsplit(" ", 1)[-1].rstrip(".").lower()
            if tail in _ABBREVIATIONS:
                merged[-1] = last + " " + piece
                continue
        merged.append(piece)
    return merged


def _split_long_sentence(sentence: str, max_chars: int) -> List[str]:
    """Break an over-long sentence at clause, then word, boundaries."""
    if len(sentence) <= max_chars:
        return [sentence]
    # Prefer clause boundaries (comma, semicolon, colon, dash).
    parts = re.split(r"(?<=[,;:—])\s+", sentence)
    out: List[str] = []
    buf = ""
    for part in parts:
        candidate = (buf + " " + part).strip() if buf else part
        if len(candidate) <= max_chars:
            buf = candidate
        else:
            if buf:
                out.append(buf)
            if len(part) <= max_chars:
                buf = part
            else:
                out.extend(_split_by_words(part, max_chars))
                buf = ""
    if buf:
        out.append(buf)
    return out


def _split_by_words(text: str, max_chars: int) -> List[str]:
    out, buf = [], ""
    for word in text.split():
        candidate = (buf + " " + word).strip() if buf else word
        if len(candidate) <= max_chars:
            buf = candidate
        else:
            if buf:
                out.append(buf)
            buf = word  # a single word longer than max_chars is left intact
    if buf:
        out.append(buf)
    return out


def chunk_text(text: str, max_chars: int = DEFAULT_MAX_CHARS) -> List[str]:
    """Pack the sentences of ``text`` into chunks no longer than ``max_chars``."""
    if max_chars < 1:
        raise ValueError("max_chars must be >= 1")
    chunks: List[str] = []
    buf = ""
    for sentence in split_sentences(text):
        for piece in _split_long_sentence(sentence, max_chars):
            candidate = (buf + " " + piece).strip() if buf else piece
            if len(candidate) <= max_chars:
                buf = candidate
            else:
                if buf:
                    chunks.append(buf)
                buf = piece
    if buf:
        chunks.append(buf)
    return chunks


def chunk_book(book, max_chars: int = DEFAULT_MAX_CHARS) -> List[Chunk]:
    """Chunk every chapter of a :class:`udp_tts.book.Book` in reading order."""
    chunks: List[Chunk] = []
    index = 0
    for chapter_index, chapter in enumerate(book.chapters):
        texts = chunk_text(chapter.text, max_chars)
        for i, text in enumerate(texts):
            chunks.append(Chunk(
                text=text,
                index=index,
                chapter_index=chapter_index,
                chapter_title=chapter.title,
                is_chapter_start=(i == 0),
            ))
            index += 1
    return chunks
