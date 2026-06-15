"""UDP TTS streaming client.

Sends a REQUEST, then receives the audio stream and plays it in real time.

Because UDP packets can arrive late, out of order, or not at all, incoming DATA
packets feed a :class:`JitterBuffer` that reorders by sequence number within a
small window and conceals losses with silence. A receiver thread fills the
buffer; the sounddevice callback drains it. Underflow plays silence rather than
blocking the audio device.

A ``--output`` save mode reassembles the stream into a WAV file instead of
playing it, which needs no audio hardware -- handy for testing the network path.
"""

import argparse
import logging
import random
import socket
import threading
import time
import wave
from typing import Dict

import numpy as np

from . import protocol

log = logging.getLogger("udp_tts.client")


class JitterBuffer:
    """Reorders PCM frames by sequence number and conceals gaps with silence.

    A linear byte FIFO (``_fifo``) holds samples ready for playout. Packets that
    arrive ahead of ``_expected`` are parked in ``_pending`` until the gap fills
    or the reorder window is exceeded, at which point the missing frame is
    replaced with one frame of silence so playout never stalls on a lost packet.
    """

    def __init__(self, frame_bytes: int, reorder_window: int = 8):
        self._frame_bytes = frame_bytes
        self._reorder_window = reorder_window
        self._lock = threading.Lock()
        self._fifo = bytearray()
        self._pending: Dict[int, bytes] = {}
        self._expected = 0
        self._concealed = 0
        self._received = 0
        self._complete = threading.Event()

    def push(self, seq: int, pcm: bytes) -> None:
        with self._lock:
            if seq < self._expected:
                return  # too late, already played past this point
            self._received += 1
            self._pending[seq] = pcm
            self._drain_pending_locked()
            # If we've already received packets well beyond the expected one, the
            # missing head is almost certainly lost (not merely reordered):
            # conceal it with silence and advance so playout doesn't stall.
            while (self._pending and
                   max(self._pending) - self._expected > self._reorder_window):
                self._fifo.extend(b"\x00" * self._frame_bytes)
                self._concealed += 1
                self._expected += 1
                self._drain_pending_locked()

    def _drain_pending_locked(self) -> None:
        while self._expected in self._pending:
            self._fifo.extend(self._pending.pop(self._expected))
            self._expected += 1

    def flush_pending(self) -> None:
        """At end-of-stream, emit any remaining parked packets in order."""
        with self._lock:
            for seq in sorted(self._pending):
                if seq < self._expected:
                    continue
                while self._expected < seq:
                    self._fifo.extend(b"\x00" * self._frame_bytes)
                    self._concealed += 1
                    self._expected += 1
                self._fifo.extend(self._pending.pop(seq))
                self._expected += 1

    def read(self, nbytes: int) -> bytes:
        """Pop up to ``nbytes`` from the FIFO, zero-padded on underflow.

        Used by the live audio callback, which must always return a full block.
        """
        with self._lock:
            take = min(nbytes, len(self._fifo))
            out = bytes(self._fifo[:take])
            del self._fifo[:take]
        if take < nbytes:
            out += b"\x00" * (nbytes - take)
        return out

    def read_available(self, max_bytes: int) -> bytes:
        """Pop up to ``max_bytes`` of real data, never padded. May be empty."""
        with self._lock:
            take = min(max_bytes, len(self._fifo))
            out = bytes(self._fifo[:take])
            del self._fifo[:take]
        return out

    def available(self) -> int:
        with self._lock:
            return len(self._fifo)

    def mark_complete(self) -> None:
        """Signal that no further packets will arrive (END received/timeout)."""
        self._complete.set()

    def is_complete(self) -> bool:
        return self._complete.is_set()

    def is_drained(self) -> bool:
        """True once the stream ended and all buffered audio has been read."""
        return self._complete.is_set() and self.available() == 0

    @property
    def stats(self):
        return {"received": self._received, "concealed": self._concealed}


class TTSClient:
    def __init__(self, server_host: str, server_port: int, timeout: float = 10.0):
        self._addr = (server_host, server_port)
        self._timeout = timeout
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.settimeout(timeout)

    def request(self, text: str, **params) -> int:
        stream_id = random.randint(1, 0x7FFFFFFF)
        self._sock.sendto(protocol.build_request(stream_id, text, **params), self._addr)
        return stream_id

    def _await_header(self, stream_id: int) -> Dict:
        deadline = time.monotonic() + self._timeout
        while time.monotonic() < deadline:
            datagram, _ = self._sock.recvfrom(65535)
            msg_type, body = protocol.parse_header(datagram)
            if msg_type == protocol.MsgType.HEADER:
                hdr = protocol.parse_header_body(body)
                if hdr["stream_id"] == stream_id:
                    return hdr
            elif msg_type == protocol.MsgType.ERROR:
                err_id, message = protocol.parse_error(body)
                if err_id == stream_id:
                    raise RuntimeError("server error: %s" % message)
        raise TimeoutError("no stream header received")

    def stream(self, text: str, on_audio, **params) -> Dict:
        """Drive one request/stream. ``on_audio(buffer, header)`` consumes audio.

        Returns the parsed stream header. ``on_audio`` is given the live
        :class:`JitterBuffer` plus header and should block until playout is done.
        """
        stream_id = self.request(text, **params)
        header = self._await_header(stream_id)
        log.info("stream %d: %d Hz, %d ch, %d-bit", stream_id,
                 header["sample_rate"], header["channels"], header["bits_per_sample"])

        frame_bytes = (header["samples_per_frame"]
                       * header["channels"] * header["bits_per_sample"] // 8)
        buffer = JitterBuffer(frame_bytes)

        consumer = threading.Thread(target=on_audio, args=(buffer, header), daemon=True)
        consumer.start()

        total_frames = None
        last_packet = time.monotonic()
        while True:
            try:
                datagram, _ = self._sock.recvfrom(65535)
            except socket.timeout:
                if time.monotonic() - last_packet > self._timeout:
                    log.warning("stream %d: receive timeout", stream_id)
                    break
                continue
            last_packet = time.monotonic()
            msg_type, body = protocol.parse_header(datagram)
            if msg_type == protocol.MsgType.DATA:
                sid, seq, pcm = protocol.parse_data(body)
                if sid == stream_id:
                    buffer.push(seq, pcm)
            elif msg_type == protocol.MsgType.END:
                sid, total_frames = protocol.parse_end(body)
                if sid == stream_id:
                    log.info("stream %d: END (%d packets sent)", stream_id, total_frames)
                    break
            elif msg_type == protocol.MsgType.ERROR:
                sid, message = protocol.parse_error(body)
                if sid == stream_id:
                    raise RuntimeError("server error: %s" % message)

        buffer.flush_pending()
        buffer.mark_complete()
        consumer.join(timeout=self._timeout + 5.0)
        log.info("stream %d done: %s", stream_id, buffer.stats)
        return header

    def close(self) -> None:
        self._sock.close()


# --- audio consumers --------------------------------------------------------

def play_live(prebuffer_ms: int = 120):
    """Return an on_audio callback that plays through the default output device."""

    def consume(buffer: JitterBuffer, header: Dict) -> None:
        import sounddevice as sd  # lazy: only needed for live playback

        sample_rate = header["sample_rate"]
        channels = header["channels"]
        bytes_per_frame = 2 * channels  # int16
        prebuffer_bytes = int(sample_rate * channels * 2 * prebuffer_ms / 1000)

        # Wait for a small cushion so early jitter doesn't underflow immediately
        # (or until the stream is already complete for very short utterances).
        deadline = time.monotonic() + 5.0
        while (buffer.available() < prebuffer_bytes
               and not buffer.is_complete()
               and time.monotonic() < deadline):
            time.sleep(0.005)

        def callback(outdata, frames, time_info, status):
            if status:
                log.debug("sounddevice status: %s", status)
            raw = buffer.read(frames * bytes_per_frame)
            outdata[:] = np.frombuffer(raw, dtype="<i2").reshape(frames, channels)

        with sd.OutputStream(samplerate=sample_rate, channels=channels,
                             dtype="int16", callback=callback):
            # Play until the stream has ended and the buffer is fully drained.
            while not buffer.is_drained():
                time.sleep(0.02)
            # Let the last queued block flush through the device.
            time.sleep(float(frames_to_seconds(prebuffer_ms)))

    return consume


def frames_to_seconds(ms: int) -> float:
    return max(0.05, ms / 1000.0)


def save_wav(path: str):
    """Return an on_audio callback that reassembles the stream into a WAV file."""

    def consume(buffer: JitterBuffer, header: Dict) -> None:
        sample_rate = header["sample_rate"]
        channels = header["channels"]
        bytes_per_frame = 2 * channels
        collected = bytearray()
        # Drain real (never padded) audio until the stream ends and empties.
        while not buffer.is_drained():
            chunk = buffer.read_available(bytes_per_frame * 1024)
            if chunk:
                collected.extend(chunk)
            else:
                time.sleep(0.01)

        with wave.open(path, "wb") as wav:
            wav.setnchannels(channels)
            wav.setsampwidth(2)
            wav.setframerate(sample_rate)
            wav.writeframes(bytes(collected))
        log.info("wrote %s (%d frames)", path, len(collected) // bytes_per_frame)

    return consume


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(description="UDP TTS streaming client")
    parser.add_argument("text", help="text to synthesize")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=50007)
    parser.add_argument("--output", help="save to WAV instead of live playback")
    parser.add_argument("--language", default=None)
    parser.add_argument("--speaker", default=None)
    parser.add_argument("--prebuffer-ms", type=int, default=120)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    params = {}
    if args.language:
        params["language"] = args.language
    if args.speaker:
        params["speaker"] = args.speaker

    consumer = save_wav(args.output) if args.output else play_live(args.prebuffer_ms)

    client = TTSClient(args.host, args.port, timeout=args.timeout)
    try:
        client.stream(args.text, consumer, **params)
    finally:
        client.close()


if __name__ == "__main__":
    main()
