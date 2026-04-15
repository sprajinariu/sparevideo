"""Tests for control-flow reference models."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np

from models import run_model
from models.motion import _rgb_to_y, _compute_mask, _compute_bbox, BBOX_COLOR
from frames.video_source import load_frames


def _static_frames(width=16, height=8, num_frames=4, color=(100, 50, 200)):
    """Generate identical static frames."""
    frame = np.full((height, width, 3), color, dtype=np.uint8)
    return [frame.copy() for _ in range(num_frames)]


# ---- Passthrough model tests ----

def test_passthrough_identity():
    """Passthrough output equals input."""
    frames = _static_frames()
    out = run_model("passthrough", frames)
    assert len(out) == len(frames)
    for inp, got in zip(frames, out):
        np.testing.assert_array_equal(inp, got)


def test_passthrough_no_aliasing():
    """Passthrough returns copies, not references."""
    frames = _static_frames(num_frames=1)
    out = run_model("passthrough", frames)
    out[0][0, 0] = [0, 0, 0]
    assert not np.array_equal(frames[0], out[0])


# ---- Luma extraction tests ----

def test_rgb_to_y_known_values():
    """Y extraction matches hand-computed values."""
    # Pure white (255, 255, 255): Y = (77*255 + 150*255 + 29*255) >> 8
    #   = (19635 + 38250 + 7395) >> 8 = 65280 >> 8 = 255
    frame = np.full((1, 1, 3), 255, dtype=np.uint8)
    assert _rgb_to_y(frame)[0, 0] == 255

    # Pure black
    frame = np.zeros((1, 1, 3), dtype=np.uint8)
    assert _rgb_to_y(frame)[0, 0] == 0

    # Pure red (255, 0, 0): Y = (77*255) >> 8 = 19635 >> 8 = 76
    frame = np.array([[[255, 0, 0]]], dtype=np.uint8)
    assert _rgb_to_y(frame)[0, 0] == 76

    # Pure green (0, 255, 0): Y = (150*255) >> 8 = 38250 >> 8 = 149
    frame = np.array([[[0, 255, 0]]], dtype=np.uint8)
    assert _rgb_to_y(frame)[0, 0] == 149

    # Pure blue (0, 0, 255): Y = (29*255) >> 8 = 7395 >> 8 = 28
    frame = np.array([[[0, 0, 255]]], dtype=np.uint8)
    assert _rgb_to_y(frame)[0, 0] == 28


# ---- Motion mask tests ----

def test_mask_threshold_boundary():
    """Strict > threshold: diff == thresh -> no motion, diff == thresh+1 -> motion."""
    thresh = 16
    y_ref = np.array([[100]], dtype=np.uint8)

    # Exactly at threshold: no motion
    y_at = np.array([[100 + thresh]], dtype=np.uint8)
    assert not _compute_mask(y_at, y_ref, thresh)[0, 0]

    # One above threshold: motion
    y_above = np.array([[100 + thresh + 1]], dtype=np.uint8)
    assert _compute_mask(y_above, y_ref, thresh)[0, 0]

    # Negative direction
    y_below = np.array([[100 - thresh - 1]], dtype=np.uint8)
    assert _compute_mask(y_below, y_ref, thresh)[0, 0]


def test_mask_static_scene():
    """Identical frames produce no motion."""
    y = np.full((8, 16), 128, dtype=np.uint8)
    mask = _compute_mask(y, y, thresh=16)
    assert not mask.any()


# ---- Bbox tests ----

def test_bbox_empty():
    """No motion pixels -> empty bbox."""
    mask = np.zeros((8, 16), dtype=bool)
    _, _, _, _, empty = _compute_bbox(mask)
    assert empty


def test_bbox_single_pixel():
    """Single motion pixel -> bbox is that pixel."""
    mask = np.zeros((8, 16), dtype=bool)
    mask[3, 7] = True
    min_x, max_x, min_y, max_y, empty = _compute_bbox(mask)
    assert not empty
    assert (min_x, max_x, min_y, max_y) == (7, 7, 3, 3)


def test_bbox_region():
    """Motion region -> tightest enclosing rectangle."""
    mask = np.zeros((8, 16), dtype=bool)
    mask[2:5, 4:10] = True
    min_x, max_x, min_y, max_y, empty = _compute_bbox(mask)
    assert not empty
    assert (min_x, max_x, min_y, max_y) == (4, 9, 2, 4)


# ---- End-to-end motion model tests ----

def test_motion_static_scene():
    """Static scene: after priming, output equals input (no bbox overlay)."""
    frames = _static_frames(width=32, height=16, num_frames=6)
    out = run_model("motion", frames)

    # Frame 0: no prior bbox -> passthrough
    np.testing.assert_array_equal(out[0], frames[0])

    # Frames 1+: no motion detected (same frames), output should be passthrough
    # (bbox_empty=True for all frames since static scene)
    for i in range(1, len(frames)):
        np.testing.assert_array_equal(out[i], frames[i])


def test_motion_color_bars_static():
    """Color bars (static): output equals input after priming."""
    frames = load_frames("synthetic:color_bars", width=64, height=32, num_frames=6)
    out = run_model("motion", frames)

    # Frame 0: passthrough (no prior bbox)
    np.testing.assert_array_equal(out[0], frames[0])

    # All frames: since color bars are static, mask is zero after priming,
    # and bbox is empty -> no overlay
    for i in range(1, len(frames)):
        np.testing.assert_array_equal(out[i], frames[i])


def test_motion_moving_box_has_overlay():
    """Moving box: frames after priming+delay should have green bbox pixels."""
    frames = load_frames("synthetic:moving_box", width=64, height=48, num_frames=6)
    out = run_model("motion", frames)

    # Frame 0: no prior bbox -> passthrough
    np.testing.assert_array_equal(out[0], frames[0])

    # Frames 1, 2: bbox is empty due to priming (PrimeFrames=2)
    # Frame 1: bbox from frame 0 -> frame_cnt was 0 at frame 0 EOF, not primed -> empty
    np.testing.assert_array_equal(out[1], frames[1])
    # Frame 2: bbox from frame 1 -> frame_cnt was 1 at frame 1 EOF, not primed -> empty
    np.testing.assert_array_equal(out[2], frames[2])

    # Frame 3: bbox from frame 2 -> frame_cnt was 2 at frame 2 EOF, primed -> should have overlay
    # Check that some green pixels exist
    green_mask = np.all(out[3] == BBOX_COLOR, axis=-1)
    assert green_mask.any(), "Frame 3 should have green bbox overlay"

    # Verify green pixels are NOT in the input
    input_green = np.all(frames[3] == BBOX_COLOR, axis=-1)
    new_green = green_mask & ~input_green
    assert new_green.any(), "Frame 3 should have NEW green pixels from bbox"


def test_motion_dark_moving_box():
    """Dark-on-bright scene: polarity-agnostic detection still produces bbox."""
    frames = load_frames("synthetic:dark_moving_box", width=64, height=48, num_frames=6)
    out = run_model("motion", frames)

    # Frame 3 should have overlay (same priming logic)
    green_mask = np.all(out[3] == BBOX_COLOR, axis=-1)
    assert green_mask.any(), "Dark moving box should produce bbox overlay on frame 3"


def test_motion_two_boxes():
    """Two moving objects: single bbox encompasses both."""
    frames = load_frames("synthetic:two_boxes", width=64, height=48, num_frames=6)
    out = run_model("motion", frames)

    # Frame 3 should have overlay
    green_mask = np.all(out[3] == BBOX_COLOR, axis=-1)
    assert green_mask.any(), "Two boxes should produce bbox overlay on frame 3"


def test_motion_priming_frames():
    """Priming: frames 0-2 are passthrough, frame 3 is first potential overlay."""
    frames = load_frames("synthetic:moving_box", width=32, height=24, num_frames=5)
    out = run_model("motion", frames)

    # Frames 0, 1, 2: should be identical to input (no overlay)
    for i in range(3):
        np.testing.assert_array_equal(out[i], frames[i],
                                      err_msg=f"Frame {i} should be passthrough (priming)")


def test_motion_empty_frames():
    """Empty frame list returns empty."""
    assert run_model("motion", []) == []


def test_unknown_ctrl_flow():
    """Unknown control flow raises ValueError."""
    try:
        run_model("nonexistent", [])
        assert False, "Should have raised ValueError"
    except ValueError:
        pass


# ---- Run all tests ----

if __name__ == "__main__":
    import traceback

    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = 0
    failed = 0
    for test in tests:
        try:
            test()
            print(f"  PASS: {test.__name__}")
            passed += 1
        except Exception:
            print(f"  FAIL: {test.__name__}")
            traceback.print_exc()
            failed += 1

    print(f"\n{passed} passed, {failed} failed, {passed + failed} total")
    sys.exit(1 if failed else 0)
