"""Tests for the jitter buffer's reorder, conceal, late-drop and flush behavior."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from udp_tts.client import JitterBuffer

FB = 4  # bytes per frame for these tests


def _frame(n):
    return bytes([n & 0xFF]) * FB


def test_reorders_within_window():
    jb = JitterBuffer(FB, reorder_window=8)
    for seq in [0, 2, 1, 3]:
        jb.push(seq, _frame(seq))
    assert jb.read_available(1000) == _frame(0) + _frame(1) + _frame(2) + _frame(3)
    assert jb.stats["concealed"] == 0


def test_conceals_lost_packet_with_silence():
    jb = JitterBuffer(FB, reorder_window=2)
    for seq in [0, 2, 3, 4, 5]:  # seq 1 never arrives
        jb.push(seq, _frame(seq))
    expected = _frame(0) + b"\x00" * FB + _frame(2) + _frame(3) + _frame(4) + _frame(5)
    assert jb.read_available(1000) == expected
    assert jb.stats["concealed"] == 1


def test_drops_packet_that_arrives_too_late():
    jb = JitterBuffer(FB, reorder_window=2)
    for seq in [0, 1, 2, 3, 4]:
        jb.push(seq, _frame(seq))
    jb.read_available(1000)       # play through seq 4
    jb.push(2, _frame(2))         # arrives after playout point
    assert jb.read_available(1000) == b""


def test_flush_pending_emits_tail_with_silence():
    jb = JitterBuffer(FB, reorder_window=100)
    jb.push(0, _frame(0))
    jb.push(3, _frame(3))         # 1 and 2 missing, parked within window
    jb.flush_pending()
    assert jb.read_available(1000) == _frame(0) + b"\x00" * FB * 2 + _frame(3)


def test_is_drained_requires_complete_and_empty():
    jb = JitterBuffer(FB)
    jb.push(0, _frame(0))
    assert not jb.is_drained()
    jb.read_available(1000)
    assert not jb.is_drained()    # not complete yet
    jb.mark_complete()
    assert jb.is_drained()


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok", name)
    print("jitter buffer tests passed")
