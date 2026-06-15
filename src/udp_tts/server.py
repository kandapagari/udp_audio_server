"""UDP TTS streaming server.

Listens for REQUEST datagrams, synthesizes audio with a :class:`TTSEngine`, and
streams it back to the requesting client as a sequence of PCM DATA packets,
paced at roughly real time so the client's jitter buffer stays small.

Each request is handled on its own thread, so several clients can stream at
once (subject to the TTS engine's own concurrency limits).
"""

import argparse
import logging
import socket
import threading
import time
from typing import Optional

import numpy as np

from . import protocol
from .tts_engine import TTSEngine, build_engine

log = logging.getLogger("udp_tts.server")

BITS_PER_SAMPLE = 16
# Real-time pacing: send each packet, then sleep for most of its duration. We
# sleep slightly less than wall-clock so the client buffer trends full rather
# than starving. Set to 0 to blast as fast as possible.
PACING_RATIO = 0.9


def float_to_pcm16(chunk: np.ndarray) -> bytes:
    """Convert float32 samples in [-1, 1] to little-endian int16 PCM bytes."""
    clipped = np.clip(chunk, -1.0, 1.0)
    return (clipped * 32767.0).astype("<i2").tobytes()


def _max_samples_per_packet(channels: int) -> int:
    bytes_per_sample = (BITS_PER_SAMPLE // 8) * channels
    return protocol.MAX_PAYLOAD_BYTES // bytes_per_sample


class TTSServer:
    def __init__(self, engine: TTSEngine, host: str = "0.0.0.0", port: int = 50007):
        self._engine = engine
        self._host = host
        self._port = port
        self._sock: Optional[socket.socket] = None
        self._running = False

    def serve_forever(self) -> None:
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind((self._host, self._port))
        self._running = True
        log.info("listening on %s:%d", self._host, self._port)
        try:
            while self._running:
                try:
                    datagram, addr = self._sock.recvfrom(65535)
                except OSError:
                    break
                self._dispatch(datagram, addr)
        finally:
            self._sock.close()

    def stop(self) -> None:
        self._running = False
        if self._sock is not None:
            # Closing the socket unblocks recvfrom.
            try:
                self._sock.close()
            except OSError:
                pass

    def _dispatch(self, datagram: bytes, addr) -> None:
        try:
            msg_type, body = protocol.parse_header(datagram)
        except ValueError as exc:
            log.warning("dropping malformed datagram from %s: %s", addr, exc)
            return
        if msg_type != protocol.MsgType.REQUEST:
            log.warning("ignoring %s from %s (expected REQUEST)", msg_type.name, addr)
            return
        try:
            req = protocol.parse_request(body)
        except (ValueError, UnicodeDecodeError) as exc:
            log.warning("bad REQUEST body from %s: %s", addr, exc)
            return

        stream_id = int(req.get("stream_id", 0))
        text = req.get("text", "")
        params = {k: v for k, v in req.items() if k not in ("stream_id", "text")}
        log.info("request from %s stream=%d text=%r", addr, stream_id, text[:80])
        threading.Thread(
            target=self._stream_to,
            args=(addr, stream_id, text, params),
            daemon=True,
        ).start()

    def _stream_to(self, addr, stream_id: int, text: str, params: dict) -> None:
        try:
            sample_rate, chunks = self._engine.synthesize(text, **params)
        except Exception as exc:  # surface engine failures to the client
            log.exception("synthesis failed for stream %d", stream_id)
            self._send(protocol.build_error(stream_id, "synthesis failed: %s" % exc), addr)
            return

        channels = self._engine.channels
        max_samples = _max_samples_per_packet(channels)

        self._send(
            protocol.build_header(
                stream_id, sample_rate, channels, BITS_PER_SAMPLE, max_samples
            ),
            addr,
        )

        seq = 0
        try:
            for chunk in chunks:
                chunk = np.asarray(chunk, dtype=np.float32).reshape(-1)
                # A model chunk may exceed one MTU; split into packet-sized pieces.
                for start in range(0, len(chunk), max_samples):
                    piece = chunk[start:start + max_samples]
                    pcm = float_to_pcm16(piece)
                    self._send(protocol.build_data(stream_id, seq, pcm), addr)
                    seq += 1
                    if PACING_RATIO > 0:
                        time.sleep(len(piece) / sample_rate * PACING_RATIO)
        except Exception as exc:
            log.exception("error mid-stream for stream %d", stream_id)
            self._send(protocol.build_error(stream_id, "stream error: %s" % exc), addr)
            return

        self._send(protocol.build_end(stream_id, seq), addr)
        log.info("finished stream %d (%d packets)", stream_id, seq)

    def _send(self, datagram: bytes, addr) -> None:
        if self._sock is not None:
            self._sock.sendto(datagram, addr)


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(description="UDP TTS streaming server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=50007)
    parser.add_argument("--engine", default="mock", help="'mock' or 'qwen'")
    parser.add_argument("--model", default="Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
                        help="model name for the qwen engine")
    parser.add_argument("--device", default="cuda:0", help="device for the qwen engine")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    engine_kwargs = {}
    if args.engine.lower().startswith("qwen"):
        engine_kwargs = {"model_name": args.model, "device": args.device}
    engine = build_engine(args.engine, **engine_kwargs)

    server = TTSServer(engine, host=args.host, port=args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down")
        server.stop()


if __name__ == "__main__":
    main()
