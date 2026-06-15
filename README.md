# udp-tts — UDP streaming for Qwen3-TTS audio

Stream text-to-speech audio over **UDP** in real time. A server runs
[Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS), packetizes the generated audio,
and streams it to a client that reorders packets through a jitter buffer and
plays them through the speakers as they arrive.

```
client ──REQUEST(text)──▶ server  ──┐ synthesize with Qwen3-TTS
                                     ▼
client ◀─HEADER, DATA×N, END──────── server   (16-bit PCM over UDP)
   │
   └─▶ jitter buffer ──▶ sounddevice ──▶ 🔊
```

## Why UDP

UDP has no retransmission or ordering, which is exactly what you want for live
audio: a packet that arrives late is useless anyway, so it's better to skip it
than to stall the stream waiting for a re-send. The client absorbs normal
network jitter with a small reorder buffer and conceals lost packets with
silence (see [`JitterBuffer`](src/udp_tts/client.py)). The trade-off is that
heavy loss is audible as gaps — acceptable for streaming, unlike a file download.

## Layout

| File | Role |
|------|------|
| [`src/udp_tts/protocol.py`](src/udp_tts/protocol.py) | Binary wire format (REQUEST / HEADER / DATA / END / ERROR) |
| [`src/udp_tts/tts_engine.py`](src/udp_tts/tts_engine.py) | `TTSEngine` interface, `MockTTSEngine`, `Qwen3TTSEngine` |
| [`src/udp_tts/server.py`](src/udp_tts/server.py) | UDP server: receives text, streams paced PCM packets |
| [`src/udp_tts/client.py`](src/udp_tts/client.py) | UDP client: jitter buffer + real-time playback / WAV save |
| [`src/udp_tts/book.py`](src/udp_tts/book.py) · [`chunker.py`](src/udp_tts/chunker.py) · [`reader.py`](src/udp_tts/reader.py) | Book loading (txt/md native; epub/pdf/docx/… via markitdown), TTS chunking, and whole-book narration (`udp-tts-read`) |
| [`scripts/run_server.py`](scripts/run_server.py) · [`scripts/run_client.py`](scripts/run_client.py) | Plain-`python` entry points (uv-free fallback) |
| [`tests/`](tests) | Protocol, jitter-buffer, chunker, and book-loader tests |
| [`macos-client/`](macos-client) | Native SwiftUI **menu-bar** client (verified byte-compatible with this server) — see its [README](macos-client/README.md) |

## Environment ([uv](https://docs.astral.sh/uv/) + dependency groups)

Dependencies are managed with `uv`. The shared base is just `numpy`; the two
sides live in separate PEP 735 **dependency groups** so each host installs only
what it needs:

| Group | Host | Adds |
|-------|------|------|
| `client` | Mac / any playback host | `sounddevice` (bundles PortAudio) |
| `server` | NVIDIA GPU host (Py 3.12+) | `torch`, `qwen-tts`, `soundfile` |

Groups are not installed by a bare `uv sync` — pick a side explicitly:

```bash
uv sync --group client      # playback host
uv sync --group server      # GPU host
```

`uv` provisions the right Python automatically (no system Python or conda
needed). Console scripts `udp-tts-server` / `udp-tts-client` are installed into
the venv; run them with `uv run`.

## Quick start (mock engine — no GPU needed)

The **mock engine** emits a tone sequence so you can exercise the entire UDP
path on any machine, including this Mac. Use it to validate networking before
the real model is wired up.

```bash
uv sync --group client

# Terminal 1 — server
uv run udp-tts-server --engine mock --port 50007

# Terminal 2 — client, live playback through your speakers
uv run udp-tts-client "Hello world" --host 127.0.0.1 --port 50007

# …or save to a WAV instead of playing (needs no audio device):
uv run udp-tts-client "Hello world" --output out.wav
```

## Running Qwen3-TTS (on the GPU host)

Qwen3-TTS needs an **NVIDIA GPU** and Python 3.12 — it won't run on the Mac.
Run the server on the GPU box and point the client at it over the network.

```bash
# On the GPU host
uv sync --group server
# optional speedup: uv pip install -U flash-attn --no-build-isolation

uv run udp-tts-server --engine qwen \
    --model Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice \
    --device cuda:0 --host 0.0.0.0 --port 50007
```

```bash
# On your Mac (or anywhere), stream from it
uv run udp-tts-client "The quick brown fox" \
    --host <gpu-host-ip> --port 50007 --speaker Ryan --language English
```

> `torch` defaults to the build chosen by uv's resolver. For a specific CUDA
> build, add a `[[tool.uv.index]]` for the PyTorch index in `pyproject.toml`
> (see the uv docs on PyTorch).

The server reports the model's real sample rate in the stream HEADER, so the
client configures playback automatically regardless of the model variant.

> **Streaming note:** Qwen3-TTS advertises low-latency streaming generation, but
> its public streaming decode API isn't documented yet. `Qwen3TTSEngine`
> currently generates the full waveform then chunks it for transport. When the
> streaming API lands, swap the generation block in
> [`tts_engine.py`](src/udp_tts/tts_engine.py) for a per-chunk generator — the
> server, protocol and client are already chunk-based and need no changes.

## Adding your own TTS engine

Implement [`TTSEngine`](src/udp_tts/tts_engine.py): a `channels` property and
`synthesize(text, **params) -> (sample_rate, iterator_of_float32_chunks)`. Each
chunk is a mono float32 numpy array in `[-1, 1]`. Register it in `build_engine`.

## Protocol summary

4-byte header (`magic "QT"`, version, type) + type-specific body. Audio is
little-endian signed 16-bit PCM. Payloads stay under ~1100 bytes to avoid IP
fragmentation. See [`protocol.py`](src/udp_tts/protocol.py) for exact layouts.

## Reading a book

`udp-tts-read` loads a book, splits it into TTS-friendly chunks (sentence-aware,
capped at `--max-chars`), and narrates it chunk-by-chunk through the same UDP
pipeline. `.txt`/`.md` are parsed natively; everything else —
`.epub`, `.pdf`, `.docx`, `.pptx`, `.xlsx`, `.html`, `.csv`, `.json`, `.xml` —
is converted to Markdown by [markitdown](https://github.com/microsoft/markitdown)
(in the `client` group) and run through the same chapter-splitter. Chapters come
from Markdown headings, or a "Chapter N" heuristic when there are none.

```bash
uv run udp-tts-read mybook.epub --host <server> --port 50007   # narrate live
uv run udp-tts-read mybook.pdf --output audiobook.wav          # render to one WAV
uv run udp-tts-read mybook.md --list-chapters                  # inspect structure
uv run udp-tts-read book.txt --start-chapter 3 --speaker Ryan  # resume + voice
```

Book loading + chunking is purely client-side — the server stays stateless
(text in, audio out). The macOS app has the same feature with a file picker and
transport controls (see [macos-client](macos-client/README.md)).

## Tests

```bash
uv run python tests/test_protocol.py
uv run python tests/test_jitter_buffer.py
# or, if you add pytest:  uv run --with pytest pytest tests/
```

The tests need only the base install (`numpy`), so any synced group works.

## Tuning knobs

- **Server** `PACING_RATIO` in [`server.py`](src/udp_tts/server.py): how fast
  packets are emitted relative to real time (0 = send as fast as possible).
- **Client** `--prebuffer-ms`: jitter cushion before playback starts (raise on
  lossy/jittery networks for smoother audio at the cost of latency).
- **Client** `JitterBuffer(reorder_window=...)`: how many packets to wait past a
  gap before concealing it as lost.
