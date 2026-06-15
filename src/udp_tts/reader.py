"""Narrate a whole book over the UDP TTS pipeline.

Loads and chunks a book, then streams each chunk through :class:`TTSClient` in
reading order -- playing live, or accumulating into a single WAV. The server
stays stateless: the reader simply sends one chunk of text at a time and lets
the existing streaming/jitter-buffer machinery handle each one.

Chunks are read sequentially (the next request goes out once the current chunk
finishes playing). The gap between chunks is just one request round-trip plus
first-packet latency.
"""

import argparse
import logging
import time
import wave
from typing import Dict, List, Optional

from .book import load_book
from .chunker import Chunk, chunk_book, DEFAULT_MAX_CHARS
from .client import TTSClient, play_live

log = logging.getLogger("udp_tts.reader")


def _pcm_collector(sink: bytearray):
    """A consumer that appends real (un-padded) audio to ``sink``."""
    def consume(buffer, header):
        while not buffer.is_drained():
            chunk = buffer.read_available(8192)
            if chunk:
                sink.extend(chunk)
            else:
                time.sleep(0.01)
    return consume


class BookReader:
    def __init__(self, client: TTSClient, chunks: List[Chunk],
                 params: Optional[Dict] = None, gap: float = 0.25):
        self._client = client
        self._chunks = chunks
        self._params = params or {}
        self._gap = gap
        self._stop = False

    def stop(self) -> None:
        self._stop = True

    def read_live(self, start: int = 0, on_progress=None) -> None:
        for chunk in self._chunks[start:]:
            if self._stop:
                break
            if on_progress:
                on_progress(chunk, len(self._chunks))
            self._client.stream(chunk.text, play_live(), **self._params)
            if self._gap:
                time.sleep(self._gap)

    def read_to_wav(self, path: str, start: int = 0, on_progress=None) -> None:
        sink = bytearray()
        sample_rate = 24000
        channels = 1
        for chunk in self._chunks[start:]:
            if self._stop:
                break
            if on_progress:
                on_progress(chunk, len(self._chunks))
            header = self._client.stream(chunk.text, _pcm_collector(sink), **self._params)
            sample_rate = header["sample_rate"]
            channels = header["channels"]
        with wave.open(path, "wb") as wav:
            wav.setnchannels(channels)
            wav.setsampwidth(2)
            wav.setframerate(sample_rate)
            wav.writeframes(bytes(sink))
        log.info("wrote %s (%d frames)", path, len(sink) // (2 * channels))


def _print_progress(chunk: Chunk, total: int) -> None:
    marker = ""
    if chunk.is_chapter_start and chunk.chapter_title:
        marker = "\n=== %s ===\n" % chunk.chapter_title
    print("%s[%d/%d] %s" % (marker, chunk.index + 1, total, _preview(chunk.text)))


def _preview(text: str, width: int = 70) -> str:
    return text if len(text) <= width else text[:width - 1] + "…"


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(description="Read a book over UDP TTS")
    parser.add_argument("path", help="book file (.txt .md .epub .pdf)")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=50007)
    parser.add_argument("--max-chars", type=int, default=DEFAULT_MAX_CHARS,
                        help="max characters per TTS chunk")
    parser.add_argument("--start-chapter", type=int, default=None,
                        help="start at this 1-based chapter")
    parser.add_argument("--start-chunk", type=int, default=1,
                        help="start at this 1-based chunk (ignored if --start-chapter)")
    parser.add_argument("--output", help="save the whole book to one WAV instead of playing")
    parser.add_argument("--language", default=None)
    parser.add_argument("--speaker", default=None)
    parser.add_argument("--list-chapters", action="store_true",
                        help="print chapters and chunk counts, then exit")
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    book = load_book(args.path)
    chunks = chunk_book(book, args.max_chars)
    print("“%s” — %d chapters, %d chunks, ~%d words"
          % (book.title, len(book.chapters), len(chunks), book.word_count))

    if args.list_chapters:
        counts = {}
        for c in chunks:
            counts.setdefault(c.chapter_index, 0)
            counts[c.chapter_index] += 1
        for i, chapter in enumerate(book.chapters):
            print("  %2d. %-40s %3d chunks"
                  % (i + 1, (chapter.title or "(untitled)")[:40], counts.get(i, 0)))
        return

    start = max(0, args.start_chunk - 1)
    if args.start_chapter is not None:
        target = args.start_chapter - 1
        for c in chunks:
            if c.chapter_index == target and c.is_chapter_start:
                start = c.index
                break

    params = {}
    if args.language:
        params["language"] = args.language
    if args.speaker:
        params["speaker"] = args.speaker

    client = TTSClient(args.host, args.port, timeout=args.timeout)
    reader = BookReader(client, chunks, params)
    try:
        if args.output:
            reader.read_to_wav(args.output, start=start, on_progress=_print_progress)
        else:
            reader.read_live(start=start, on_progress=_print_progress)
    except KeyboardInterrupt:
        reader.stop()
        print("\nstopped")
    finally:
        client.close()


if __name__ == "__main__":
    main()
