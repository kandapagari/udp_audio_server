#!/usr/bin/env python3
"""Entry point for the UDP TTS client. Run from the repo root:

    python scripts/run_client.py "Hello world" --host 127.0.0.1
    python scripts/run_client.py "Hello world" --output out.wav
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from udp_tts.client import main  # noqa: E402

if __name__ == "__main__":
    main()
