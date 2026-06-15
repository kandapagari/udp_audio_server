#!/usr/bin/env python3
"""Entry point for the UDP TTS server. Run from the repo root:

    python scripts/run_server.py --engine mock
    python scripts/run_server.py --engine qwen --device cuda:0
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from udp_tts.server import main  # noqa: E402

if __name__ == "__main__":
    main()
