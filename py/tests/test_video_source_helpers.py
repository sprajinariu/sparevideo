"""Unit tests for video_source helpers — alpha-blended object placement and bg texture."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np

from frames.video_source import _make_bg_texture, _place_object, generate_synthetic


def test_place_object_greyscale_unchanged():
    """Existing call sites pass `luma` and expect R=G=B output."""
    frame = np.zeros((20, 20, 3), dtype=np.uint8)
    _place_object(frame, 5, 5, 10, 10, luma=200)
    # Pixel near box centre should be near-uniform grey
    cx, cy = 10, 10
    assert frame[cy, cx, 0] == frame[cy, cx, 1] == frame[cy, cx, 2]
    assert frame[cy, cx, 0] > 100  # blurred but well into the bright range


def test_place_object_rgb_overrides_luma():
    """When rgb=(R,G,B) is provided, the box renders that color."""
    frame = np.zeros((20, 20, 3), dtype=np.uint8)
    _place_object(frame, 5, 5, 10, 10, luma=0, rgb=(255, 80, 80))
    cx, cy = 10, 10
    # Centre pixel should be dominated by red
    assert frame[cy, cx, 0] > frame[cy, cx, 1]
    assert frame[cy, cx, 0] > frame[cy, cx, 2]
    assert frame[cy, cx, 1] < 120
    assert frame[cy, cx, 2] < 120


def test_place_object_rgb_alpha_falloff():
    """RGB rendering still has a soft Gaussian edge."""
    frame = np.zeros((40, 40, 3), dtype=np.uint8)
    _place_object(frame, 15, 15, 10, 10, luma=0, rgb=(255, 0, 0))
    # Far from the box: zero. Inside: red. Near edge: intermediate.
    assert frame[5, 5, 0] == 0
    assert frame[20, 20, 0] > 200


def test_make_bg_texture_greyscale_unchanged():
    """Default call returns 2-D greyscale array (existing behavior)."""
    tex = _make_bg_texture(width=64, height=48)
    assert tex.ndim == 2
    assert tex.shape == (48, 64)
    assert tex.dtype == np.uint8


def test_make_bg_texture_tint_returns_rgb():
    """When tint=(R,G,B) is provided, returns a 3-D RGB array tinted accordingly."""
    tex = _make_bg_texture(width=64, height=48, tint=(255, 100, 100))
    assert tex.ndim == 3
    assert tex.shape == (48, 64, 3)
    assert tex.dtype == np.uint8
    # Red channel mean should clearly exceed green and blue means
    assert tex[..., 0].mean() > tex[..., 1].mean()
    assert tex[..., 0].mean() > tex[..., 2].mean()


def test_make_bg_texture_tint_preserves_variation():
    """Tinted output still has spatial variation (it's a textured bg, not flat color)."""
    tex = _make_bg_texture(width=64, height=48, tint=(200, 200, 200))
    # std-dev across the red channel should be nonzero (sinusoid + noise survives)
    assert tex[..., 0].std() > 1.0


def test_multi_speed_color_frame_count_and_shape():
    frames = generate_synthetic("multi_speed_color", width=64, height=48, num_frames=8)
    assert len(frames) == 8
    for f in frames:
        assert f.shape == (48, 64, 3)
        assert f.dtype == np.uint8


def test_multi_speed_color_frame0_is_bg_only():
    """Frame 0 has no foreground objects — only the tinted textured bg."""
    frames = generate_synthetic("multi_speed_color", width=64, height=48, num_frames=8)
    f0 = frames[0]
    f1 = frames[1]
    # Frame 1 contains object pixels; frame 0 does not. So per-pixel diff must be
    # nonzero in at least one location.
    diff = np.abs(f0.astype(int) - f1.astype(int)).sum(axis=-1)
    assert diff.max() > 50, "Frame 1 should differ from frame 0 at object locations"


def test_multi_speed_color_has_rgb_objects():
    """Frame 4 (mid-clip) must contain pixels dominated by red, green, and cyan respectively."""
    frames = generate_synthetic("multi_speed_color", width=64, height=48, num_frames=8)
    mid = frames[4].astype(int)
    R, G, B = mid[..., 0], mid[..., 1], mid[..., 2]
    # Strong red: R >> G, R >> B somewhere
    has_red   = ((R - G > 60) & (R - B > 60)).any()
    # Strong green: G >> R, G >> B somewhere
    has_green = ((G - R > 60) & (G - B > 60)).any()
    # Strong cyan: G >> R, B >> R somewhere
    has_cyan  = ((G - R > 60) & (B - R > 60)).any()
    assert has_red,   "no red-dominated pixel found"
    assert has_green, "no green-dominated pixel found"
    assert has_cyan,  "no cyan-dominated pixel found"


def test_multi_speed_color_deterministic():
    """Same seed → same frames (regression-friendly)."""
    a = generate_synthetic("multi_speed_color", width=64, height=48, num_frames=4)
    b = generate_synthetic("multi_speed_color", width=64, height=48, num_frames=4)
    for fa, fb in zip(a, b):
        np.testing.assert_array_equal(fa, fb)
