"""Unit tests for py/demo/stabilize.py — trim + stabilize + resize."""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import cv2
import numpy as np
import pytest

from demo.stabilize import stabilize_clip


def _make_dummy_mp4(path, width, height, num_frames, fps=30):
    """Generate a synthetic test MP4 with mild simulated camera shake.

    Frame i is a solid grey field with a small dot at offset (sin(i)*3, cos(i)*3) px.
    Simulates ~3 px sub-pixel-ish camera jitter that the stabilizer should remove.
    """
    fourcc = cv2.VideoWriter_fourcc(*'mp4v')
    out = cv2.VideoWriter(str(path), fourcc, float(fps), (width, height))
    assert out.isOpened(), f"cv2.VideoWriter failed for {path}"
    for i in range(num_frames):
        frame = np.full((height, width, 3), 100, dtype=np.uint8)
        # Add ~50 stable feature dots at a grid plus shake offset
        dx = int(round(3 * np.sin(i * 0.4)))
        dy = int(round(3 * np.cos(i * 0.4)))
        for gy in range(20, height - 20, 20):
            for gx in range(20, width - 20, 20):
                cv2.circle(frame, (gx + dx, gy + dy), 3, (255, 255, 255), -1)
        out.write(frame)
    out.release()


def test_stabilize_creates_output(tmp_path):
    src = tmp_path / "src.mp4"
    dst = tmp_path / "dst.mp4"
    _make_dummy_mp4(src, 320, 240, num_frames=90, fps=30)
    stabilize_clip(src, dst, start_s=0.0, duration_s=2.0,
                   target_w=160, target_h=120, target_fps=15)
    assert dst.exists()
    assert dst.stat().st_size > 0


def test_stabilize_output_dimensions(tmp_path):
    src = tmp_path / "src.mp4"
    dst = tmp_path / "dst.mp4"
    _make_dummy_mp4(src, 640, 480, num_frames=90, fps=30)
    stabilize_clip(src, dst, start_s=0.0, duration_s=2.0,
                   target_w=320, target_h=240, target_fps=15)
    cap = cv2.VideoCapture(str(dst))
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()
    assert (w, h) == (320, 240)


def test_stabilize_frame_count(tmp_path):
    src = tmp_path / "src.mp4"
    dst = tmp_path / "dst.mp4"
    _make_dummy_mp4(src, 320, 240, num_frames=90, fps=30)
    # 2 s @ 15 fps = 30 frames
    stabilize_clip(src, dst, start_s=0.0, duration_s=2.0,
                   target_w=160, target_h=120, target_fps=15)
    cap = cv2.VideoCapture(str(dst))
    count = 0
    while True:
        ok, _ = cap.read()
        if not ok: break
        count += 1
    cap.release()
    # OpenCV's CAP_PROP_FRAME_COUNT is unreliable for some codecs, so we
    # actually iterate. Allow ±1 frame tolerance for end-of-stream rounding.
    assert abs(count - 30) <= 1, f"expected 30 frames, got {count}"


def test_stabilize_reduces_motion_on_shaky_input(tmp_path):
    """Sanity: stabilized output should have less frame-to-frame change than the source."""
    src = tmp_path / "src.mp4"
    dst = tmp_path / "dst.mp4"
    _make_dummy_mp4(src, 320, 240, num_frames=60, fps=30)
    stabilize_clip(src, dst, start_s=0.0, duration_s=1.5,
                   target_w=320, target_h=240, target_fps=15)

    def _mean_consecutive_diff(path):
        cap = cv2.VideoCapture(str(path))
        prev = None
        diffs = []
        while True:
            ok, frame = cap.read()
            if not ok: break
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY).astype(np.float32)
            if prev is not None:
                diffs.append(np.abs(gray - prev).mean())
            prev = gray
        cap.release()
        return float(np.mean(diffs))

    src_diff = _mean_consecutive_diff(src)
    dst_diff = _mean_consecutive_diff(dst)
    # Stabilization should at least halve the inter-frame jitter on this synthetic input.
    assert dst_diff < src_diff * 0.5, \
        f"stabilization didn't reduce motion: src_diff={src_diff:.3f} dst_diff={dst_diff:.3f}"
