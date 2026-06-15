"""Wire protocol for the UDP TTS audio stream.

UDP datagrams are unreliable, unordered and size-limited, so every packet is
self-describing: a 4-byte common header (magic + version + type) followed by a
type-specific body. Audio is carried as little-endian signed 16-bit PCM.

Message flow:

    client --REQUEST--> server          (JSON: text + voice params)
    server --HEADER---> client          (sample rate, channels, format)
    server --DATA-----> client  (xN)    (seq number + PCM frame)
    server --END------> client          (total frame count)
    server --ERROR----> client          (on failure, UTF-8 message)

Keep UDP payloads under ~1200 bytes to stay below the typical Ethernet MTU and
avoid IP fragmentation (a fragmented datagram is lost entirely if any fragment
is dropped).
"""

import json
import struct
from enum import IntEnum
from typing import Dict, Tuple

MAGIC = b"QT"
VERSION = 1

# Common header: magic(2) + version(1) + type(1)
_HEADER_FMT = "!2sBB"
HEADER_SIZE = struct.calcsize(_HEADER_FMT)

# Stay well under a 1500-byte MTU once IP/UDP/app headers are accounted for.
MAX_PAYLOAD_BYTES = 1100


class MsgType(IntEnum):
    REQUEST = 1  # client -> server
    HEADER = 2   # server -> client
    DATA = 3     # server -> client
    END = 4      # server -> client
    ERROR = 5    # server -> client


# --- common header ----------------------------------------------------------

def _frame(msg_type: MsgType, body: bytes) -> bytes:
    return struct.pack(_HEADER_FMT, MAGIC, VERSION, int(msg_type)) + body


def parse_header(datagram: bytes) -> Tuple[MsgType, bytes]:
    """Return (message type, body) for a received datagram.

    Raises ValueError if the datagram is malformed or from another protocol.
    """
    if len(datagram) < HEADER_SIZE:
        raise ValueError("datagram shorter than header")
    magic, version, raw_type = struct.unpack(_HEADER_FMT, datagram[:HEADER_SIZE])
    if magic != MAGIC:
        raise ValueError("bad magic %r" % (magic,))
    if version != VERSION:
        raise ValueError("unsupported version %d" % version)
    try:
        msg_type = MsgType(raw_type)
    except ValueError:
        raise ValueError("unknown message type %d" % raw_type)
    return msg_type, datagram[HEADER_SIZE:]


# --- REQUEST (client -> server) ---------------------------------------------

def build_request(stream_id: int, text: str, **params) -> bytes:
    payload = {"stream_id": stream_id, "text": text}
    payload.update(params)
    return _frame(MsgType.REQUEST, json.dumps(payload).encode("utf-8"))


def parse_request(body: bytes) -> Dict:
    return json.loads(body.decode("utf-8"))


# --- HEADER (server -> client) ----------------------------------------------

# stream_id(uint32) sample_rate(uint32) channels(uint16)
# bits_per_sample(uint16) samples_per_frame(uint32)
_HDR_BODY_FMT = "!IIHHI"


def build_header(stream_id: int, sample_rate: int, channels: int,
                 bits_per_sample: int, samples_per_frame: int) -> bytes:
    body = struct.pack(_HDR_BODY_FMT, stream_id, sample_rate, channels,
                       bits_per_sample, samples_per_frame)
    return _frame(MsgType.HEADER, body)


def parse_header_body(body: bytes) -> Dict:
    (stream_id, sample_rate, channels, bits_per_sample,
     samples_per_frame) = struct.unpack(_HDR_BODY_FMT, body)
    return {
        "stream_id": stream_id,
        "sample_rate": sample_rate,
        "channels": channels,
        "bits_per_sample": bits_per_sample,
        "samples_per_frame": samples_per_frame,
    }


# --- DATA (server -> client) ------------------------------------------------

# stream_id(uint32) seq(uint32) followed by raw PCM bytes
_DATA_BODY_FMT = "!II"
_DATA_BODY_SIZE = struct.calcsize(_DATA_BODY_FMT)


def build_data(stream_id: int, seq: int, pcm: bytes) -> bytes:
    return _frame(MsgType.DATA, struct.pack(_DATA_BODY_FMT, stream_id, seq) + pcm)


def parse_data(body: bytes) -> Tuple[int, int, bytes]:
    stream_id, seq = struct.unpack(_DATA_BODY_FMT, body[:_DATA_BODY_SIZE])
    return stream_id, seq, body[_DATA_BODY_SIZE:]


# --- END (server -> client) -------------------------------------------------

_END_BODY_FMT = "!II"  # stream_id(uint32) total_frames(uint32)


def build_end(stream_id: int, total_frames: int) -> bytes:
    return _frame(MsgType.END, struct.pack(_END_BODY_FMT, stream_id, total_frames))


def parse_end(body: bytes) -> Tuple[int, int]:
    return struct.unpack(_END_BODY_FMT, body)


# --- ERROR (server -> client) -----------------------------------------------

_ERR_BODY_FMT = "!I"  # stream_id(uint32) followed by UTF-8 message
_ERR_BODY_SIZE = struct.calcsize(_ERR_BODY_FMT)


def build_error(stream_id: int, message: str) -> bytes:
    body = struct.pack(_ERR_BODY_FMT, stream_id) + message.encode("utf-8")
    return _frame(MsgType.ERROR, body)


def parse_error(body: bytes) -> Tuple[int, str]:
    (stream_id,) = struct.unpack(_ERR_BODY_FMT, body[:_ERR_BODY_SIZE])
    return stream_id, body[_ERR_BODY_SIZE:].decode("utf-8", "replace")
