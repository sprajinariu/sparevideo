"""Per-frame metadata for the HUD model. Reads latency_us from a sidecar
file written by sparevideo_top during simulation."""
from __future__ import annotations
import os
from pathlib import Path

DEFAULT_PATH = "dv/data/hud_latency.txt"


def _project_root() -> Path:
    # py/models/ops/_hud_metadata.py -> ../../../ is repo root.
    return Path(__file__).resolve().parents[3]


def load_latencies(num_frames: int) -> list[int]:
    """One latency per frame, in microseconds. If the file is missing or short,
    pads with zeros (useful for unit tests and sw-dry-run paths)."""
    path = os.environ.get("HUD_LATENCY_FILE")
    if path is None:
        p = _project_root() / DEFAULT_PATH
    else:
        p = Path(path)
    if not p.exists():
        return [0] * num_frames
    raw = [int(x.strip()) for x in p.read_text().splitlines() if x.strip()]
    if len(raw) < num_frames:
        raw = raw + [0] * (num_frames - len(raw))
    return raw[:num_frames]
