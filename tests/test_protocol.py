"""Round-trip tests for the wire protocol. Run: python -m pytest tests/ (or python tests/test_protocol.py)."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from udp_tts import protocol


def test_request_roundtrip():
    pkt = protocol.build_request(42, "hi there", language="English", speaker="Ryan")
    mtype, body = protocol.parse_header(pkt)
    assert mtype == protocol.MsgType.REQUEST
    req = protocol.parse_request(body)
    assert req == {"stream_id": 42, "text": "hi there",
                   "language": "English", "speaker": "Ryan"}


def test_header_roundtrip():
    pkt = protocol.build_header(7, 24000, 1, 16, 480)
    mtype, body = protocol.parse_header(pkt)
    assert mtype == protocol.MsgType.HEADER
    assert protocol.parse_header_body(body) == {
        "stream_id": 7, "sample_rate": 24000, "channels": 1,
        "bits_per_sample": 16, "samples_per_frame": 480,
    }


def test_data_roundtrip():
    pcm = bytes(range(256)) * 3
    pkt = protocol.build_data(7, 99, pcm)
    mtype, body = protocol.parse_header(pkt)
    assert mtype == protocol.MsgType.DATA
    assert protocol.parse_data(body) == (7, 99, pcm)


def test_end_and_error_roundtrip():
    mtype, body = protocol.parse_header(protocol.build_end(7, 1234))
    assert mtype == protocol.MsgType.END
    assert protocol.parse_end(body) == (7, 1234)

    mtype, body = protocol.parse_header(protocol.build_error(7, "boom"))
    assert mtype == protocol.MsgType.ERROR
    assert protocol.parse_error(body) == (7, "boom")


def test_rejects_foreign_datagram():
    for bad in [b"", b"XX\x01\x03", b"\x00" * 2]:
        try:
            protocol.parse_header(bad)
        except ValueError:
            pass
        else:
            raise AssertionError("expected ValueError for %r" % bad)


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok", name)
    print("protocol tests passed")
