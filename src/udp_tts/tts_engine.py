"""TTS engine abstraction and implementations.

The server talks to TTS only through :class:`TTSEngine`, so the UDP streaming
layer never depends on a specific model. Two implementations ship here:

* :class:`MockTTSEngine` -- needs only numpy. Generates a tone sequence so you
  can develop and test the full UDP pipeline on any machine (e.g. a Mac with no
  GPU) before the real model is available.
* :class:`Qwen3TTSEngine` -- wraps QwenLM/Qwen3-TTS. Requires an NVIDIA GPU plus
  ``qwen-tts``/``torch`` and is meant to run on the GPU host.

``synthesize`` returns ``(sample_rate, chunks)`` where ``chunks`` is an iterator
of mono float32 numpy arrays in [-1, 1]. The server packetizes them.
"""

from abc import ABC, abstractmethod
from typing import Iterator, Tuple

import numpy as np


class TTSEngine(ABC):
    """Produces audio for a piece of text as a stream of float32 chunks."""

    @property
    @abstractmethod
    def channels(self) -> int:
        ...

    @abstractmethod
    def synthesize(self, text: str, **params) -> Tuple[int, Iterator[np.ndarray]]:
        """Return ``(sample_rate, chunk_iterator)`` for ``text``.

        Each chunk is a 1-D float32 numpy array (mono) with samples in [-1, 1].
        Implementations may yield chunks lazily as the model decodes.
        """
        ...


class MockTTSEngine(TTSEngine):
    """Deterministic test engine: emits a short tone per word of input.

    Useful for exercising the network path without a model or GPU. The pitch
    rises with each word so you can hear/verify ordering and gaps.
    """

    def __init__(self, sample_rate: int = 24000, chunk_samples: int = 480):
        self._sample_rate = sample_rate
        self._chunk_samples = chunk_samples

    @property
    def channels(self) -> int:
        return 1

    def synthesize(self, text: str, **params) -> Tuple[int, Iterator[np.ndarray]]:
        words = text.split() or ["silence"]
        return self._sample_rate, self._generate(words)

    def _generate(self, words) -> Iterator[np.ndarray]:
        sr = self._sample_rate
        samples_per_word = int(sr * 0.35)  # 350 ms per word
        base_freq = 220.0
        phase = 0.0
        for i, _word in enumerate(words):
            freq = base_freq * (2 ** (i % 12 / 12.0))  # climb a chromatic scale
            n = samples_per_word
            t = np.arange(n, dtype=np.float32) / sr
            # Continuous phase across chunks avoids clicks.
            tone = 0.25 * np.sin(2 * np.pi * freq * t + phase).astype(np.float32)
            phase = (phase + 2 * np.pi * freq * n / sr) % (2 * np.pi)
            # Short fade in/out per word to soften edges.
            fade = min(int(sr * 0.01), n // 2)
            if fade > 0:
                env = np.ones(n, dtype=np.float32)
                env[:fade] = np.linspace(0, 1, fade, dtype=np.float32)
                env[-fade:] = np.linspace(1, 0, fade, dtype=np.float32)
                tone *= env
            for start in range(0, n, self._chunk_samples):
                yield tone[start:start + self._chunk_samples]


class Qwen3TTSEngine(TTSEngine):
    """Wraps QwenLM/Qwen3-TTS. Runs on the GPU host.

    ``torch`` and ``qwen_tts`` are imported lazily so importing this module does
    not require them on machines that only run the client or the mock engine.
    """

    def __init__(
        self,
        model_name: str = "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
        device: str = "cuda:0",
        default_language: str = "English",
        default_speaker: str = "Ryan",
        chunk_ms: int = 40,
        attn_implementation: str = "flash_attention_2",
    ):
        import torch  # noqa: F401  (validates the dependency is present)
        from qwen_tts import Qwen3TTSModel

        self._default_language = default_language
        self._default_speaker = default_speaker
        self._chunk_ms = chunk_ms
        self._model = Qwen3TTSModel.from_pretrained(
            model_name,
            device_map=device,
            dtype=torch.bfloat16,
            attn_implementation=attn_implementation,
        )

    @property
    def channels(self) -> int:
        return 1

    def synthesize(self, text: str, **params) -> Tuple[int, Iterator[np.ndarray]]:
        language = params.get("language", self._default_language)
        speaker = params.get("speaker", self._default_speaker)

        # NOTE: Qwen3-TTS advertises low-latency streaming generation. Its public
        # streaming API is not documented in the README yet, so we generate the
        # full waveform and then chunk it for transport. When the streaming
        # decode API lands, replace this block with the per-chunk generator and
        # the rest of the pipeline is unchanged.
        wavs, sr = self._model.generate_custom_voice(
            text=text, language=language, speaker=speaker
        )
        wav = np.asarray(wavs[0], dtype=np.float32).reshape(-1)
        chunk_samples = max(1, int(sr * self._chunk_ms / 1000))
        return sr, self._chunk(wav, chunk_samples)

    @staticmethod
    def _chunk(wav: np.ndarray, chunk_samples: int) -> Iterator[np.ndarray]:
        for start in range(0, len(wav), chunk_samples):
            yield wav[start:start + chunk_samples]


def build_engine(name: str, **kwargs) -> TTSEngine:
    """Factory used by the server CLI. ``name`` is 'mock' or 'qwen'."""
    name = name.lower()
    if name == "mock":
        return MockTTSEngine()
    if name in ("qwen", "qwen3", "qwen3-tts"):
        return Qwen3TTSEngine(**kwargs)
    raise ValueError("unknown engine %r (use 'mock' or 'qwen')" % name)
