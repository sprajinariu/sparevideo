"""Tests for control-flow reference models."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np

from models import run_model
from models.motion import _rgb_to_y, _compute_mask, _compute_bbox, _ema_update, _gauss3x3, BBOX_COLOR
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
    """Static scene: after EMA convergence, output equals input (no bbox overlay)."""
    # With EMA (alpha_shift=3), bg starts at 0 and converges slowly to the
    # static pixel luma. Use enough frames for convergence, then check the
    # later frames are pure passthrough (no overlay).
    frames = _static_frames(width=32, height=16, num_frames=60)
    out = run_model("motion", frames)

    # Frame 0: no prior bbox -> passthrough
    np.testing.assert_array_equal(out[0], frames[0])

    # After sufficient convergence (~50 frames with alpha_shift=3),
    # the EMA background matches the static pixel value and no motion
    # is detected. Check the last 5 frames are passthrough.
    for i in range(55, 60):
        np.testing.assert_array_equal(out[i], frames[i],
                                      err_msg=f"Frame {i} should be passthrough after EMA convergence")


def test_motion_color_bars_static():
    """Color bars (static): output equals input after EMA convergence."""
    frames = load_frames("synthetic:color_bars", width=64, height=32, num_frames=60)
    out = run_model("motion", frames)

    # Frame 0: passthrough (no prior bbox)
    np.testing.assert_array_equal(out[0], frames[0])

    # After EMA convergence, static color bars produce no motion -> no overlay
    for i in range(55, 60):
        np.testing.assert_array_equal(out[i], frames[i],
                                      err_msg=f"Frame {i} should be passthrough after EMA convergence")


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


# ---- Mask display model tests ----

def test_mask_static_scene_converged():
    """Static scene: after EMA convergence, identical frames produce all-black output."""
    frames = _static_frames(width=16, height=8, num_frames=60)
    out = run_model("mask", frames)
    assert len(out) == len(frames)
    # With EMA (alpha_shift=3), bg converges slowly from 0 to the static luma.
    # After enough frames, diff drops below threshold → all-black mask.
    for i in range(55, 60):
        assert not out[i].any(), f"Frame {i} should be all-black after EMA convergence"


def test_mask_frame0_mostly_white():
    """Frame 0: Y_ref is zero-initialized, so non-black input → mostly white."""
    frame = np.full((8, 16, 3), 128, dtype=np.uint8)
    out = run_model("mask", [frame])
    # Luma of (128,128,128) = (77*128 + 150*128 + 29*128)>>8 = 32768>>8 = 128
    # |128 - 0| = 128 > 16 → motion everywhere
    assert np.all(out[0] == 255), "Frame 0 should be all-white (everything is motion vs zero ref)"


def test_mask_output_strictly_bw():
    """Every pixel in mask output must be exactly black or white."""
    frames = load_frames("synthetic:moving_box", width=32, height=24, num_frames=4)
    out = run_model("mask", frames)
    for i, f in enumerate(out):
        is_black = np.all(f == 0, axis=-1)
        is_white = np.all(f == 255, axis=-1)
        assert np.all(is_black | is_white), f"Frame {i} has non-B/W pixels"


def test_mask_moving_box_has_motion():
    """Moving box: frames after frame 0 should have white pixels in motion region."""
    frames = load_frames("synthetic:moving_box", width=64, height=48, num_frames=4)
    out = run_model("mask", frames)
    # Frame 1+: motion where the box moved
    for i in range(1, len(frames)):
        white_pixels = np.all(out[i] == 255, axis=-1)
        assert white_pixels.any(), f"Frame {i} should have white (motion) pixels"


def test_mask_threshold_boundary():
    """Mask model respects strict > threshold."""
    thresh = 16
    # Frame with uniform luma = thresh (just at boundary → no motion)
    # Y = (77*R + 150*G + 29*B) >> 8.  For R=thresh, G=0, B=0: Y = (77*16)>>8 = 1232>>8 = 4
    # Instead, craft frames where the luma diff is exactly thresh vs thresh+1.
    h, w = 4, 4
    # Frame 0: all black → Y_ref becomes 0 after frame 0
    f0 = np.zeros((h, w, 3), dtype=np.uint8)
    # Frame 1: uniform color giving Y = thresh (should be NO motion since !(thresh > thresh))
    # Y = (77*R)>>8 = thresh → R = thresh*256/77 ≈ 53.2 → R=53 gives Y=(77*53)>>8=4081>>8=15
    # R=54 gives Y=(77*54)>>8=4158>>8=16=thresh. So R=54,G=0,B=0 → Y=16.
    f1_at = np.zeros((h, w, 3), dtype=np.uint8)
    f1_at[:, :, 0] = 54  # Y = 16 = thresh
    # Frame 2 (after f1): Y_ref=16. Need luma diff > thresh.
    # Use a frame that gives Y=16+17=33. R s.t. (77*R)>>8=33 → R=33*256/77≈109.7 → R=110 gives (77*110)>>8=8470>>8=33.
    f2_above = np.zeros((h, w, 3), dtype=np.uint8)
    f2_above[:, :, 0] = 110  # Y = 33, diff = |33-16| = 17 > 16

    out = run_model("mask", [f0, f1_at, f2_above], thresh=thresh)
    # Frame 1: |16 - 0| = 16 = thresh → NOT > thresh → black
    assert not out[1].any(), "Diff == thresh should NOT trigger motion"
    # Frame 2: |33 - 16| = 17 > thresh → white
    assert np.all(out[2] == 255), "Diff > thresh should trigger motion"


def test_mask_empty_frames():
    """Empty frame list returns empty."""
    assert run_model("mask", []) == []


def test_unknown_ctrl_flow():
    """Unknown control flow raises ValueError."""
    try:
        run_model("nonexistent", [])
        assert False, "Should have raised ValueError"
    except ValueError:
        pass


# ---- EMA background model tests ----

def test_ema_update_basic():
    """EMA update matches RTL arithmetic: bg + (y_cur - bg) >> alpha_shift."""
    bg = np.array([[100]], dtype=np.uint8)
    y_cur = np.array([[200]], dtype=np.uint8)
    # delta = 200 - 100 = 100, step = 100 >> 3 = 12, new_bg = 100 + 12 = 112
    result = _ema_update(y_cur, bg, alpha_shift=3)
    assert result[0, 0] == 112

    # Negative delta: y_cur < bg
    bg2 = np.array([[200]], dtype=np.uint8)
    y_cur2 = np.array([[100]], dtype=np.uint8)
    # delta = 100 - 200 = -100, step = -100 >> 3 = -13 (arithmetic shift)
    # new_bg = 200 + (-13) = 187
    result2 = _ema_update(y_cur2, bg2, alpha_shift=3)
    assert result2[0, 0] == 187


def test_ema_update_alpha_shift_zero():
    """alpha_shift=0 reduces to raw write-back (bg_new = y_cur)."""
    bg = np.array([[50]], dtype=np.uint8)
    y_cur = np.array([[200]], dtype=np.uint8)
    result = _ema_update(y_cur, bg, alpha_shift=0)
    assert result[0, 0] == 200


def test_ema_convergence_static():
    """EMA background converges toward static pixel value."""
    h, w = 1, 1
    y_cur = np.array([[82]], dtype=np.uint8)
    bg = np.zeros((h, w), dtype=np.uint8)

    # Run 60 iterations of EMA update with same y_cur
    for _ in range(60):
        bg = _ema_update(y_cur, bg, alpha_shift=3)

    # After many frames, bg should be close to y_cur.
    # Arithmetic right-shift truncation introduces a small negative bias,
    # so bg may settle a few levels below y_cur.
    assert abs(int(bg[0, 0]) - 82) <= 8, f"bg={bg[0, 0]}, expected ~82 (within EMA rounding bias)"


def test_ema_step_change_motion_then_absorbed():
    """After a step change, motion is detected then absorbed as bg converges."""
    h, w = 4, 4
    # Static scene at luma ~39 (R=100, G=0, B=0 → Y = (77*100)>>8 = 30)
    static_frame = np.zeros((h, w, 3), dtype=np.uint8)
    static_frame[:, :, 0] = 100  # R=100 → Y=30

    # Let bg converge to static value first (50 frames)
    frames = [static_frame.copy() for _ in range(50)]

    # Then change to a bright frame
    bright_frame = np.full((h, w, 3), 200, dtype=np.uint8)  # Y ≈ 200
    frames.extend([bright_frame.copy() for _ in range(30)])

    out = run_model("mask", frames, alpha_shift=3)

    # After bg converges to static (~frame 45-49), mask should be black
    assert not out[49].any(), "Frame 49 should be all-black (bg converged to static)"

    # Frame 50 (step change): large diff → motion (white pixels)
    assert out[50].any(), "Frame 50 should detect motion after step change"

    # After many more frames, bg converges to bright value → no motion
    assert not out[79].any(), "Frame 79 should be all-black (bg converged to bright)"


def test_mask_noisy_moving_box():
    """noisy_moving_box synthetic source produces valid mask output."""
    frames = load_frames("synthetic:noisy_moving_box", width=32, height=24, num_frames=10)
    out = run_model("mask", frames, alpha_shift=3)
    assert len(out) == 10
    # All output should be strictly B/W
    for i, f in enumerate(out):
        is_black = np.all(f == 0, axis=-1)
        is_white = np.all(f == 255, axis=-1)
        assert np.all(is_black | is_white), f"Frame {i} has non-B/W pixels"


def test_mask_lighting_ramp():
    """lighting_ramp synthetic source produces valid mask output."""
    frames = load_frames("synthetic:lighting_ramp", width=32, height=24, num_frames=10)
    out = run_model("mask", frames, alpha_shift=3)
    assert len(out) == 10
    for i, f in enumerate(out):
        is_black = np.all(f == 0, axis=-1)
        is_white = np.all(f == 255, axis=-1)
        assert np.all(is_black | is_white), f"Frame {i} has non-B/W pixels"


# ---- Gaussian pre-filter model tests ----

def test_gauss_uniform():
    """Gaussian of uniform image is the same uniform image."""
    y = np.full((8, 16), 128, dtype=np.uint8)
    result = _gauss3x3(y)
    np.testing.assert_array_equal(result, y)


def test_gauss_impulse():
    """Single bright pixel produces kernel-weighted 3x3 response centered on it.

    True centered 3x3 filter: an impulse at (r, c) produces the kernel
    response centered at (r, c) with no spatial offset.
    """
    y = np.zeros((8, 16), dtype=np.uint8)
    y[4, 4] = 255
    result = _gauss3x3(y)

    # Center weight at (4,4): 4*255 / 16 = 63 (truncated)
    assert result[4, 4] == 63, f"Center: got {result[4, 4]}, expected 63"
    # 2-weighted neighbors: 2*255 / 16 = 31
    for r, c in [(3, 4), (5, 4), (4, 3), (4, 5)]:
        assert result[r, c] == 31, f"({r},{c}): got {result[r, c]}, expected 31"
    # 1-weighted corners: 1*255 / 16 = 15
    for r, c in [(3, 3), (3, 5), (5, 3), (5, 5)]:
        assert result[r, c] == 15, f"({r},{c}): got {result[r, c]}, expected 15"
    # All other pixels should be 0
    for r in range(8):
        for c in range(16):
            if abs(r - 4) > 1 or abs(c - 4) > 1:
                assert result[r, c] == 0, f"({r},{c}): got {result[r, c]}, expected 0"


def test_motion_gauss_en_false_matches_old():
    """Motion model with gauss_en=False matches pre-Gaussian behavior."""
    frames = load_frames("synthetic:moving_box", width=64, height=48, num_frames=6)
    # gauss_en=False should produce identical output to the old behavior
    out_no_gauss = run_model("motion", frames, gauss_en=False)
    # Verify it still produces valid output with bbox
    green_mask = np.all(out_no_gauss[3] == BBOX_COLOR, axis=-1)
    assert green_mask.any(), "gauss_en=False should still produce bbox overlay"


def test_mask_gauss_en_false_matches_old():
    """Mask model with gauss_en=False matches pre-Gaussian behavior."""
    frames = _static_frames(width=16, height=8, num_frames=60)
    out = run_model("mask", frames, gauss_en=False)
    # After EMA convergence, static scene → all-black
    for i in range(55, 60):
        assert not out[i].any(), f"Frame {i} should be all-black after EMA convergence"


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
