"""Smoke tests for motion_vibe / mask_vibe / ccl_bbox_vibe reference models.

Bit-exact pinning is intentionally avoided — the cfg defaults might tune
in Phase 1.x. We assert structural and qualitative properties only.
"""
from __future__ import annotations

import numpy as np
import pytest

from frames.video_source import load_frames
from profiles import DEFAULT_VIBE


def _vibe_kwargs():
    """All ViBe kwargs from DEFAULT_VIBE, minus the wrapping/tail flags
    that run_model() pops off. Caller passes these to model run()."""
    keep = {k: v for k, v in DEFAULT_VIBE.items()
            if not k.endswith("_en") or k == "gauss_en"}
    # Drop fields the vibe models don't consume directly:
    for f in ("motion_thresh", "alpha_shift", "alpha_shift_slow",
              "grace_frames", "grace_alpha_shift", "morph_close_kernel",
              "bbox_color", "bg_model"):
        keep.pop(f, None)
    return keep


def _frames_moving_box(num=12, w=64, h=48):
    return load_frames("synthetic:moving_box", width=w, height=h, num_frames=num)


def test_motion_vibe_run_shape_and_dtype():
    from models.motion_vibe import run
    frames = _frames_moving_box(num=8)
    out = run(frames, morph_open_en=True, morph_close_en=True,
              morph_close_kernel=3, **_vibe_kwargs())
    assert len(out) == len(frames)
    for f in out:
        assert f.dtype == np.uint8
        assert f.shape == frames[0].shape


def test_motion_vibe_run_frame0_is_priming():
    """Frame 0 returns the input untouched (no bboxes yet)."""
    from models.motion_vibe import run
    frames = _frames_moving_box(num=4)
    out = run(frames, morph_open_en=True, morph_close_en=True,
              morph_close_kernel=3, **_vibe_kwargs())
    assert np.array_equal(out[0], frames[0])


def test_mask_vibe_run_outputs_are_bw():
    from models.mask_vibe import run
    frames = _frames_moving_box(num=6)
    out = run(frames, morph_open_en=True, morph_close_en=True,
              morph_close_kernel=3, **_vibe_kwargs())
    assert len(out) == len(frames)
    # Every pixel must be either (0,0,0) or (255,255,255).
    for f in out:
        flat = f.reshape(-1, 3)
        unique = {tuple(p) for p in np.unique(flat, axis=0)}
        assert unique.issubset({(0, 0, 0), (255, 255, 255)}), \
            f"non-binary pixel in mask_vibe output: {unique}"


def test_ccl_bbox_vibe_run_uses_grey_canvas():
    from models.ccl_bbox import BG_GREY  # canonical canvas-bg value (0x20)
    from models.ccl_bbox_vibe import run
    frames = _frames_moving_box(num=6)
    out = run(frames, morph_open_en=True, morph_close_en=True,
              morph_close_kernel=3, **_vibe_kwargs())
    assert len(out) == len(frames)
    # At least one frame's "background" pixel must be the canonical BG_GREY.
    grey_seen = any((f == BG_GREY).all(axis=-1).any() for f in out)
    assert grey_seen, f"expected BG_GREY={tuple(BG_GREY)} pixels in ccl_bbox_vibe output"


def test_motion_vibe_accepts_all_default_vibe_keys():
    """Regression guard: every key in DEFAULT_VIBE must be acceptable as
    a kwarg to motion_vibe.run, even if the model ignores it. Otherwise
    the dispatcher in run_model() will explode at runtime."""
    from models.motion_vibe import run
    frames = _frames_moving_box(num=3)
    # Pass EVERY field in DEFAULT_VIBE as kwargs (mirrors what run_model does).
    cfg = dict(DEFAULT_VIBE)
    cfg.pop("hflip_en", None)  # head op, popped by run_model before dispatch
    cfg.pop("gamma_en", None)
    cfg.pop("scaler_en", None)
    cfg.pop("hud_en", None)
    cfg.pop("bg_model", None)
    out = run(frames, **cfg)
    assert len(out) == len(frames)
