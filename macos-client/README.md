# UDP TTS — macOS menu-bar client

A native SwiftUI **menu-bar** client for the [UDP TTS server](../README.md).
Type text, click **Speak**, and audio streams from the server over UDP and plays
in real time. No Dock icon, no main window — it lives in the menu bar.

It reimplements the wire protocol, jitter buffer, and playback in Swift, so it's
a self-contained `.app` with no Python runtime. The networking core is verified
byte-compatible with the Python server (see *Probe* below).

## Requirements

- macOS 14+
- Xcode 16+ / Swift 5.10+ toolchain (`swift --version`)

## Build & run the app

```bash
cd macos-client
./scripts/build_app.sh
open build/UDPTTSMenuBar.app      # waveform icon appears in the menu bar
```

Click the menu-bar icon (or press the global hotkey **⌃⌥S** from anywhere) to
toggle the panel → type text → **Speak** (⌘↩). While audio plays, a live VU
meter shows the output level. The gear icon reveals connection settings (host,
port, optional speaker/language), which persist between launches. Point **Host**
at your TTS server (the Python mock for local testing, or your GPU host running
Qwen3-TTS).

The global hotkey uses Carbon's `RegisterEventHotKey` (no Accessibility
permission needed) and is defined in
[`HotKeyManager`](Sources/UDPTTSMenuBar/HotKeyManager.swift) — change `keyCode` /
`modifiers` there to rebind it.

### Reading a book

Click **Open Book…** to pick a `.txt`, `.md`, or `.pdf` (PDF via the built-in
PDFKit — no dependency; EPUB is handled by the Python `udp-tts-read` CLI). The
app loads and chunks it, then the transport controls (⏮ ⏯ ⏭) narrate it
chunk-by-chunk through the UDP pipeline with auto-advance, a chapter label, and
a progress bar. The same `udptts-probe --book FILE -o out.wav` exercises this
path headlessly.

During development you can also just `swift run UDPTTSMenuBar` — it launches the
same menu-bar agent without bundling.

## Architecture

| Target | Role |
|--------|------|
| `UDPTTSCore` (library) | [`UDPProtocol`](Sources/UDPTTSCore/UDPProtocol.swift) (byte-compatible with `protocol.py`), [`JitterBuffer`](Sources/UDPTTSCore/JitterBuffer.swift) (reorder + silence concealment), [`UDPStreamer`](Sources/UDPTTSCore/UDPStreamer.swift) (`NWConnection` UDP), [`AudioPlayer`](Sources/UDPTTSCore/AudioPlayer.swift) (`AVAudioEngine` + `AVAudioSourceNode`), [`Book`](Sources/UDPTTSCore/Book.swift) + [`Chunker`](Sources/UDPTTSCore/Chunker.swift) (book loading + TTS chunking) |
| `UDPTTSMenuBar` (app) | Status-item + `NSPopover` UI, [`TTSClientModel`](Sources/UDPTTSMenuBar/TTSClientModel.swift) orchestration, global [`HotKeyManager`](Sources/UDPTTSMenuBar/HotKeyManager.swift), and a live VU meter |
| `udptts-probe` (CLI) | Headless: streams one utterance to a WAV file |

Flow: send `REQUEST(text)` → receive `HEADER` (configures playback sample rate)
→ `DATA` packets feed the jitter buffer → an `AVAudioSourceNode` render callback
pulls reordered PCM and plays it → `END` drains the buffer and stops the engine.

## Probe (headless integration test)

`udptts-probe` shares the exact networking code the app uses but writes to a WAV
instead of playing, so it runs without audio hardware and proves the Swift
client interoperates with the Python server:

```bash
# Terminal 1 — Python mock server (from repo root)
uv run udp-tts-server --engine mock --port 50007

# Terminal 2 — Swift probe
cd macos-client
swift run udptts-probe "hello from swift" --host 127.0.0.1 --port 50007 -o out.wav
```

## Tests

```bash
cd macos-client
swift test      # jitter-buffer behavior + protocol byte-layout round-trips
```

## Notes

- The app is **not sandboxed**; `build_app.sh` applies an ad-hoc signature so it
  runs locally. For distribution, sign with a Developer ID and — if you enable
  the App Sandbox — add the `com.apple.security.network.client` entitlement
  (outgoing UDP) and notarize.
- Audio output needs no entitlement (no microphone is used).
- `reorderWindow` (in `JitterBuffer`) and the 10 s connect timeout (in
  `TTSClientModel`) are the main tuning knobs for lossy networks.
