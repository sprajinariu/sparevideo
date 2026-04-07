"""Unit tests for frame_io.py — round-trip read/write in text and binary modes."""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np

from frames.frame_io import read_frames, write_frames


def _make_test_frames(width=8, height=4, num_frames=2):
    """Generate deterministic test frames."""
    rng = np.random.RandomState(42)
    return [rng.randint(0, 256, (height, width, 3), dtype=np.uint8)
            for _ in range(num_frames)]


def test_text_round_trip():
    frames = _make_test_frames()
    h, w, _ = frames[0].shape
    with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as f:
        path = f.name
    write_frames(path, frames, mode="text")
    loaded = read_frames(path, mode="text", width=w, height=h, num_frames=len(frames))
    assert len(loaded) == len(frames)
    for orig, got in zip(frames, loaded):
        np.testing.assert_array_equal(orig, got)
    Path(path).unlink()


def test_binary_round_trip():
    frames = _make_test_frames()
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        path = f.name
    write_frames(path, frames, mode="binary")
    loaded = read_frames(path, mode="binary")
    assert len(loaded) == len(frames)
    for orig, got in zip(frames, loaded):
        np.testing.assert_array_equal(orig, got)
    Path(path).unlink()


def test_single_frame():
    """Round-trip a single frame."""
    frames = _make_test_frames(num_frames=1)
    h, w, _ = frames[0].shape

    # Text
    with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as f:
        path = f.name
    write_frames(path, frames, mode="text")
    loaded = read_frames(path, mode="text", width=w, height=h, num_frames=1)
    assert len(loaded) == 1
    np.testing.assert_array_equal(frames[0], loaded[0])
    Path(path).unlink()

    # Binary
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        path = f.name
    write_frames(path, frames, mode="binary")
    loaded = read_frames(path, mode="binary")
    assert len(loaded) == 1
    np.testing.assert_array_equal(frames[0], loaded[0])
    Path(path).unlink()


def test_qvga_frame():
    """Round-trip at the default 320x240 resolution."""
    frames = _make_test_frames(width=320, height=240, num_frames=2)

    # Text
    with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as f:
        path = f.name
    write_frames(path, frames, mode="text")
    loaded = read_frames(path, mode="text", width=320, height=240, num_frames=2)
    assert len(loaded) == 2
    for orig, got in zip(frames, loaded):
        np.testing.assert_array_equal(orig, got)
    Path(path).unlink()

    # Binary
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        path = f.name
    write_frames(path, frames, mode="binary")
    loaded = read_frames(path, mode="binary")
    assert len(loaded) == 2
    for orig, got in zip(frames, loaded):
        np.testing.assert_array_equal(orig, got)
    Path(path).unlink()


if __name__ == "__main__":
    test_text_round_trip()
    test_binary_round_trip()
    test_single_frame()
    test_qvga_frame()
    print("All tests passed!")
