"""Unit tests for the `harness.py model` subcommand.

Covers the plumbing only: reads input.bin, calls run_model, writes output.bin
in the same binary format `make sim` produces. The model itself is exercised
in test_models.py.
"""

import argparse
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np

from frames.frame_io import read_frames, write_frames
from models import run_model
from profiles import resolve as resolve_cfg
from harness import cmd_model


def _make_test_frames(width=8, height=4, num_frames=3):
    rng = np.random.RandomState(42)
    return [rng.randint(0, 256, (height, width, 3), dtype=np.uint8)
            for _ in range(num_frames)]


def test_model_passthrough_binary():
    """cmd_model output equals run_model('passthrough') output, frame-for-frame."""
    frames = _make_test_frames()
    h, w, _ = frames[0].shape
    n = len(frames)

    with tempfile.TemporaryDirectory() as td:
        in_path  = Path(td) / "input.bin"
        out_path = Path(td) / "output.bin"
        write_frames(in_path, frames, mode="binary")

        args = argparse.Namespace(
            input=str(in_path), output=str(out_path),
            ctrl_flow="passthrough", cfg="default",
            width=w, height=h, frames=n, mode="binary",
        )
        cmd_model(args)

        got = read_frames(out_path, mode="binary")
        cfg = resolve_cfg("default")
        expected = run_model("passthrough", frames, **cfg)

        assert len(got) == len(expected), \
            f"frame count mismatch: got {len(got)} expected {len(expected)}"
        for i, (a, e) in enumerate(zip(got, expected)):
            np.testing.assert_array_equal(
                a, e, err_msg=f"frame {i} differs from run_model output")


def test_model_motion_demo_profile():
    """cmd_model with cfg=demo and ctrl_flow=motion matches run_model() exactly.

    Frame size 64x32 — wide enough for the post-scaler HUD bitmap (8x8 glyphs)
    not to clip; HUD is enabled in the demo profile.
    """
    rng = np.random.RandomState(7)
    frames = [rng.randint(0, 256, (32, 64, 3), dtype=np.uint8) for _ in range(4)]

    with tempfile.TemporaryDirectory() as td:
        in_path  = Path(td) / "input.bin"
        out_path = Path(td) / "output.bin"
        write_frames(in_path, frames, mode="binary")

        args = argparse.Namespace(
            input=str(in_path), output=str(out_path),
            ctrl_flow="motion", cfg="demo",
            width=64, height=32, frames=4, mode="binary",
        )
        cmd_model(args)

        got = read_frames(out_path, mode="binary")
        cfg = resolve_cfg("demo")
        expected = run_model("motion", frames, **cfg)

        assert len(got) == len(expected) == 4
        for i, (a, e) in enumerate(zip(got, expected)):
            np.testing.assert_array_equal(
                a, e, err_msg=f"frame {i} differs from run_model output")


if __name__ == "__main__":
    test_model_passthrough_binary()
    test_model_motion_demo_profile()
    print("All tests passed!")
