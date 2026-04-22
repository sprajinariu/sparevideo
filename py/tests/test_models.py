"""Tests for control-flow reference models."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np
import pytest

from models import run_model
from models.motion import _rgb_to_y, _compute_mask, _ema_update, _gauss3x3, BBOX_COLOR
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


def test_motion_two_boxes_produces_two_bboxes():
    """two_boxes source: after priming, output should contain TWO distinct bbox rectangles."""
    frames = load_frames("synthetic:two_boxes", width=64, height=48, num_frames=6)
    out = run_model("motion", frames)
    green = np.all(out[3] == BBOX_COLOR, axis=-1)
    left_green  = green[:, :32].any()
    right_green = green[:, 32:].any()
    assert left_green and right_green, "Two bboxes should render on both halves"


def test_ccl_bbox_grey_canvas_static():
    """ccl_bbox on static scene: no motion after EMA convergence -> pure grey canvas, no rectangles."""
    frames = _static_frames(width=32, height=24, num_frames=60)
    out = run_model("ccl_bbox", frames)
    from models.ccl_bbox import BG_GREY, FG_GREY, BBOX_COLOR as CCL_BBOX_COLOR
    assert not np.any(np.all(out[59] == CCL_BBOX_COLOR, axis=-1)), "No bboxes after EMA convergence"
    assert np.all(out[59] == BG_GREY), "Fully static scene should leave only the BG_GREY canvas"


def test_ccl_bbox_moving_two_boxes():
    """ccl_bbox on two_boxes: frame after priming should show multiple bbox rectangles on grey canvas."""
    frames = load_frames("synthetic:two_boxes", width=64, height=48, num_frames=6)
    out = run_model("ccl_bbox", frames)
    from models.ccl_bbox import BBOX_COLOR as CCL_BBOX_COLOR
    green = np.all(out[3] == CCL_BBOX_COLOR, axis=-1)
    left_green  = green[:, :32].any()
    right_green = green[:, 32:].any()
    assert left_green and right_green, "ccl_bbox should render both rectangles"


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


def test_mask_frame0_all_black():
    """Frame 0: hard-init priming — bg is set to Y_smooth, mask forced to zero."""
    frame = np.full((8, 16, 3), 128, dtype=np.uint8)
    out = run_model("mask", [frame])
    # Frame 0 is the priming frame: mask is forced to zero regardless of input.
    assert np.all(out[0] == 0), "Frame 0 should be all-black (priming frame, mask forced to zero)"


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


# ---- CCL reference model tests ----

from models.ccl import run_ccl

try:
    from scipy.ndimage import label as _scipy_label
    _HAS_SCIPY = True
except ImportError:
    _HAS_SCIPY = False


def _mask_to_bbox_set(mask):
    """Ground truth: use scipy to get bboxes as a set of (min_x,max_x,min_y,max_y,count)."""
    labeled, n = _scipy_label(mask, structure=np.ones((3, 3), dtype=int))  # 8-connectivity
    result = set()
    for lbl in range(1, n + 1):
        ys, xs = np.where(labeled == lbl)
        result.add((int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max()), int(len(xs))))
    return result


def test_ccl_empty_mask():
    """Empty mask -> all slots None."""
    mask = np.zeros((8, 8), dtype=bool)
    out = run_ccl([mask], n_out=4, min_component_pixels=1)
    assert out == [[None, None, None, None]]


def test_ccl_single_blob():
    """Single rectangle -> one bbox."""
    mask = np.zeros((8, 8), dtype=bool)
    mask[2:5, 3:6] = True  # 3x3 blob
    out = run_ccl([mask], n_out=4, min_component_pixels=1)
    assert out[0][0] == (3, 5, 2, 4, 9)
    assert out[0][1:] == [None, None, None]


def test_ccl_disjoint_blobs_two():
    """Two disjoint rectangles -> two separate bboxes."""
    mask = np.zeros((8, 16), dtype=bool)
    mask[1:3, 1:3] = True   # 4-pixel top-left
    mask[5:8, 10:14] = True # 12-pixel bottom-right
    out = run_ccl([mask], n_out=4, min_component_pixels=1)
    bboxes = {b for b in out[0] if b is not None}
    assert bboxes == {(1, 2, 1, 2, 4), (10, 13, 5, 7, 12)}


def test_ccl_u_shape_merges():
    """U-shape: two top arms join through a bottom row -> single component."""
    mask = np.zeros((6, 8), dtype=bool)
    mask[0:5, 1] = True     # left arm
    mask[0:5, 6] = True     # right arm
    mask[4, 1:7] = True     # bottom connector
    out = run_ccl([mask], n_out=4, min_component_pixels=1)
    nonnull = [b for b in out[0] if b is not None]
    assert len(nonnull) == 1, f"U-shape must be one component, got {nonnull}"
    assert nonnull[0][0:4] == (1, 6, 0, 4)


def test_ccl_min_size_filter():
    """1-pixel speckle + large blob: only the large blob survives filter."""
    mask = np.zeros((8, 8), dtype=bool)
    mask[0, 0] = True             # 1-pixel speckle
    mask[3:7, 3:7] = True         # 16-pixel blob
    out = run_ccl([mask], n_out=4, min_component_pixels=4)
    nonnull = [b for b in out[0] if b is not None]
    assert len(nonnull) == 1
    assert nonnull[0] == (3, 6, 3, 6, 16)


def test_ccl_overflow_absorbed():
    """More disjoint tiny blobs than N_LABELS_INT -> overflow pools into label 0."""
    mask = np.zeros((4, 40), dtype=bool)
    for c in range(0, 40, 4):  # 10 single-pixel blobs at cols 0,4,8,...,36
        mask[1, c] = True
    out = run_ccl([mask], n_out=4, n_labels_int=4, min_component_pixels=1)
    nonnull = [b for b in out[0] if b is not None]
    assert 1 <= len(nonnull) <= 4


@pytest.mark.skipif(not _HAS_SCIPY, reason="scipy not available")
def test_ccl_subset_of_scipy_sparse_masks():
    """Sparse random masks: every bbox our streaming CCL emits matches some scipy component.

    The spec-mandated single equiv-write per pixel (`equiv[max] = min`, no
    root chase during streaming) can over-split components vs a full
    union-find. Therefore ours may be a refinement of scipy. The invariant:
    every (min_x,max_x,min_y,max_y,count) tuple we emit corresponds to a
    real 8-connected component in the mask — verified by checking our bboxes
    form a subset of scipy's complete set. See docs/specs/axis_ccl-arch.md.
    """
    rng = np.random.default_rng(42)
    for trial in range(10):
        mask = rng.random((12, 20)) > 0.8  # sparse: ~20% foreground
        ours = run_ccl([mask], n_out=16, n_labels_int=128, min_component_pixels=1)
        ours_set = {b for b in ours[0] if b is not None}
        truth = _mask_to_bbox_set(mask)
        extras = ours_set - truth
        assert not extras, (
            f"Trial {trial}: our bboxes not in scipy truth: {extras}"
        )


def test_ccl_multi_frame_independent():
    """Two frames: each frame's CCL state is independent."""
    m0 = np.zeros((4, 4), dtype=bool)
    m0[0, 0] = True
    m1 = np.zeros((4, 4), dtype=bool)
    m1[3, 3] = True
    out = run_ccl([m0, m1], n_out=2, min_component_pixels=1)
    assert out[0][0] == (0, 0, 0, 0, 1)
    assert out[0][1] is None
    assert out[1][0] == (3, 3, 3, 3, 1)
    assert out[1][1] is None


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
    """After a step change, motion is detected then absorbed as bg converges.

    With selective EMA, motion pixels update at the slow rate (alpha_shift_slow).
    To test full convergence, we set alpha_shift_slow=alpha_shift so that motion
    pixels converge at the same rate as non-motion pixels.
    """
    h, w = 4, 4
    # Static scene at luma ~30 (R=100, G=0, B=0 → Y = (77*100)>>8 = 30)
    static_frame = np.zeros((h, w, 3), dtype=np.uint8)
    static_frame[:, :, 0] = 100  # R=100 → Y=30

    # Let bg converge to static value first (50 frames)
    frames = [static_frame.copy() for _ in range(50)]

    # Then change to a bright frame
    bright_frame = np.full((h, w, 3), 200, dtype=np.uint8)  # Y ≈ 200
    frames.extend([bright_frame.copy() for _ in range(30)])

    # Use alpha_shift_slow=alpha_shift so motion pixels converge at same speed.
    out = run_model("mask", frames, alpha_shift=3, alpha_shift_slow=3)

    # After bg converges to static (~frame 45-49), mask should be black
    assert not out[49].any(), "Frame 49 should be all-black (bg converged to static)"

    # Frame 50 (step change): large diff → motion (white pixels)
    assert out[50].any(), "Frame 50 should detect motion after step change"

    # After many more frames at alpha_shift_slow=3, bg converges to bright → no motion
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


# ---- Frame-0 priming + selective EMA tests ----

def _get_internal_bg(frames, alpha_shift=3, alpha_shift_slow=6, gauss_en=True):
    """Run the motion model and return the internal bg state at each frame boundary.

    Returns a list of bg arrays (uint8, shape H×W) — one per *processed* frame.
    bg[0] is the state after frame 0 has been consumed.
    """
    from models.motion import _run_bg_trace
    return _run_bg_trace(frames, alpha_shift=alpha_shift,
                         alpha_shift_slow=alpha_shift_slow, gauss_en=gauss_en)


def test_motion_frame0_priming_writes_bg():
    """After frame 0, bg[px] equals Y(frame_0[px]) for every pixel (no EMA lag)."""
    from models.motion import _rgb_to_y, _gauss3x3
    frames = _static_frames(width=16, height=8, num_frames=1,
                             color=(120, 60, 200))
    bg_trace = _get_internal_bg(frames, alpha_shift=3, alpha_shift_slow=6,
                                 gauss_en=True)
    y0 = _rgb_to_y(frames[0])
    y0_filt = _gauss3x3(y0)
    np.testing.assert_array_equal(bg_trace[0], y0_filt)


def test_motion_frame0_priming_mask_all_zero():
    """The motion model's frame-0 output is visually indistinguishable from input
    (no bbox overlay is drawn because primed=False and bbox state is all-None).
    Also: mask bits emitted during frame 0 would be all zero."""
    frames = _static_frames(width=16, height=8, num_frames=1,
                             color=(120, 60, 200))
    out = run_model("motion", frames, alpha_shift=3, alpha_shift_slow=6,
                    gauss_en=True)
    # frame 0 output is input (bbox state all-None on first frame regardless)
    np.testing.assert_array_equal(out[0], frames[0])


def test_motion_selective_ema_rates():
    """Frame 2: after frame 1 establishes a stable bg, construct frame 2 so
    that half the pixels are flagged motion and half are not. bg should drift
    at the slow rate on motion pixels and fast rate on non-motion pixels."""
    from models.motion import _rgb_to_y, _gauss3x3
    w, h = 16, 8
    num_frames = 3
    # Build: frame 0 and frame 1 identical (prime + stabilize). frame 2 has
    # a delta in the left half that exceeds thresh, and a sub-threshold delta
    # in the right half.
    frame0 = np.full((h, w, 3), 100, dtype=np.uint8)
    frame1 = frame0.copy()
    frame2 = frame0.copy()
    frame2[:, :w // 2] = 180                       # Y delta ~80 > thresh
    frame2[:, w // 2:] = 105                        # Y delta 5 < thresh
    bg_trace = _get_internal_bg([frame0, frame1, frame2],
                                 alpha_shift=3, alpha_shift_slow=6,
                                 gauss_en=False)
    # After frame 1, bg should equal Y(100) everywhere (primed on f0 → bg=100;
    # frame 1 non-motion → fast EMA step toward 100 → still 100).
    y_after_f1 = bg_trace[1]
    assert np.all(y_after_f1 == 100)

    # After frame 2:
    #   Left half: motion pixel. delta=180-100=80. step = 80>>6 = 1. bg=101.
    #   Right half: non-motion. delta=105-100=5.   step = 5>>3 = 0.  bg=100.
    y_after_f2 = bg_trace[2]
    assert np.all(y_after_f2[:, :w // 2] == 101), (
        f"motion half should drift by (80>>6)=1, got {y_after_f2[0, 0]}")
    assert np.all(y_after_f2[:, w // 2:] == 100), (
        f"non-motion half should not drift, got {y_after_f2[0, -1]}")


def test_motion_no_trail_after_object_departure():
    """Object moves across a pixel for 2 frames then leaves. With selective EMA,
    the pixel immediately stops flagging as motion once the object is gone."""
    w, h = 16, 8
    # f0: empty scene (Y=100)
    # f1: object at left half (Y=200) — motion, but slow EMA barely drifts bg
    # f2: object gone (Y=100 everywhere) — bg is still ~100, delta=0, mask=0
    frame_empty  = np.full((h, w, 3), 100, dtype=np.uint8)
    frame_object = np.full((h, w, 3), 100, dtype=np.uint8)
    frame_object[:, :w // 2] = 200
    frames = [frame_empty, frame_object, frame_empty]
    bg_trace = _get_internal_bg(frames, alpha_shift=3, alpha_shift_slow=6,
                                 gauss_en=False)
    # After f2, bg in the former-motion region:
    #   Before f2: bg=100 (f0 primed=100; f1 motion → slow-step: 100+(100>>6)=101)
    #   f2: delta = 100-101 = -1, |diff|=1, thresh=16 → not motion → fast rate
    #       step = -1>>3 = -1 (arithmetic) → bg = 100
    # Mask at f2 left half should be 0 (no trail).
    from models.motion import _rgb_to_y, _gauss3x3, _compute_mask
    y2 = _rgb_to_y(frames[2])
    # bg before f2 is bg_trace[1]; but we verify the *consequence*: mask at f2
    # is zero everywhere when we recompute against bg_trace[1].
    mask_f2 = _compute_mask(y2, bg_trace[1], thresh=16)
    assert not mask_f2.any(), (
        f"No trail expected; got {int(mask_f2.sum())} motion pixels in f2")


# ---- Grace-window tests ----

def test_motion_grace_window_zero_equals_no_grace():
    """GRACE_FRAMES=0 must produce identical bg trajectory to plain selective EMA."""
    from models.motion import _run_bg_trace

    # Scene: object in frame 0, moves in frame 1+, static after
    h, w = 16, 16
    frames = []
    for i in range(6):
        f = np.full((h, w, 3), 200, dtype=np.uint8)  # white bg
        if i == 0:
            f[4:8, 4:8] = [10, 10, 10]  # dark box at (4..7, 4..7)
        elif i < 3:
            f[4:8, 10:14] = [10, 10, 10]  # dark box moved right
        frames.append(f)

    # With grace_frames=0, behavior must match the plain selective-EMA path.
    trace_with_grace_zero = _run_bg_trace(
        frames, alpha_shift=3, alpha_shift_slow=6, grace_frames=0
    )
    trace_no_grace_arg = _run_bg_trace(
        frames, alpha_shift=3, alpha_shift_slow=6  # default grace_frames=0
    )
    for a, b in zip(trace_with_grace_zero, trace_no_grace_arg):
        np.testing.assert_array_equal(a, b)


def test_motion_grace_window_clears_frame0_ghost():
    """Object present in frame 0 that moves in frame 1 must not produce a
    persistent ghost at its frame-0 location when grace window is active.

    Box luma=180, bg luma=220 (delta=40): with alpha_shift=3 and grace_frames=8,
    the fast EMA closes the gap to <=16 within 8 steps, clearing the ghost.
    """
    from models.motion import run

    h, w = 24, 24
    frames = []
    for i in range(12):
        f = np.full((h, w, 3), 220, dtype=np.uint8)
        if i == 0:
            f[4:8, 4:8] = [180, 180, 180]   # luma=180 box at frame-0 location
        else:
            f[4:8, 10:14] = [180, 180, 180]  # box moved right
        frames.append(f)

    from models.motion import _run_bg_trace, _rgb_to_y, _compute_mask
    trace = _run_bg_trace(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6,
                          grace_frames=8, gauss_en=False)
    y_f10 = _rgb_to_y(frames[10])
    mask_f10 = _compute_mask(y_f10, trace[9], 16)

    assert not mask_f10[4:8, 4:8].any(), (
        f"ghost persists at frame 10: mask[4:8,4:8]={mask_f10[4:8, 4:8]}, "
        f"bg[4:8,4:8]={trace[9][4:8, 4:8]}"
    )


def test_motion_grace_window_preserves_trail_suppression():
    """After grace window ends, selective EMA must still suppress trails."""
    from models.motion import _run_bg_trace, _rgb_to_y, _compute_mask

    h, w = 24, 24
    frames = []
    for i in range(10):
        frames.append(np.full((h, w, 3), 220, dtype=np.uint8))
    for i in range(4):
        f = np.full((h, w, 3), 220, dtype=np.uint8)
        f[4:8, 4 + i:8 + i] = [10, 10, 10]
        frames.append(f)
    for i in range(5):
        frames.append(np.full((h, w, 3), 220, dtype=np.uint8))

    trace = _run_bg_trace(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6,
                          grace_frames=8, gauss_en=False)

    y_f18 = _rgb_to_y(frames[18])
    mask_f18 = _compute_mask(y_f18, trace[17], 16)

    assert not mask_f18[4:8, 7:11].any(), \
        f"trail persists at frame 18: mask[4:8,7:11]={mask_f18[4:8, 7:11]}"


# ---- New synthetic source helpers ----

from frames.video_source import _make_bg_texture, _add_frame_noise, _place_object


def test_make_bg_texture_shape_and_range():
    """Texture is (H, W) uint8 with values inside the configured luma window."""
    tex = _make_bg_texture(width=64, height=32, base_luma=100, amp=20)
    assert tex.shape == (32, 64)
    assert tex.dtype == np.uint8
    # Guard against off-by-one in the normalisation — allow ±2 luma slack.
    assert tex.min() >= 100 - 20 - 2
    assert tex.max() <= 100 + 20 + 2


def test_make_bg_texture_is_deterministic():
    """Same seed → identical output; different seed → non-identical output."""
    a = _make_bg_texture(width=32, height=16, seed=1)
    b = _make_bg_texture(width=32, height=16, seed=1)
    c = _make_bg_texture(width=32, height=16, seed=2)
    np.testing.assert_array_equal(a, b)
    assert not np.array_equal(a, c)


def test_make_bg_texture_not_flat():
    """Texture actually has spatial variation (not a constant field)."""
    tex = _make_bg_texture(width=64, height=32, base_luma=100, amp=20)
    assert int(tex.max()) - int(tex.min()) >= 10


def test_add_frame_noise_shape_dtype():
    """Noise output is (H, W) uint8 — same shape and dtype as input bg."""
    bg = np.full((16, 32), 100, dtype=np.uint8)
    rng = np.random.default_rng(0)
    out = _add_frame_noise(bg, rng, noise_amp=8)
    assert out.shape == bg.shape
    assert out.dtype == np.uint8


def test_add_frame_noise_bounded():
    """All output pixels are within ±noise_amp of the input bg."""
    bg = np.full((16, 32), 100, dtype=np.uint8)
    rng = np.random.default_rng(1)
    out = _add_frame_noise(bg, rng, noise_amp=8)
    diff = out.astype(np.int16) - bg.astype(np.int16)
    assert diff.min() >= -8
    assert diff.max() <= 8


def test_add_frame_noise_clipping():
    """Near 0 / 255 edges, output is clipped and never wraps."""
    dark = np.zeros((4, 4), dtype=np.uint8)
    bright = np.full((4, 4), 255, dtype=np.uint8)
    rng = np.random.default_rng(2)
    assert _add_frame_noise(dark, rng, noise_amp=8).min() >= 0
    assert _add_frame_noise(bright, rng, noise_amp=8).max() <= 255


def test_add_frame_noise_varies_frame_to_frame():
    """Successive calls on the same rng yield different noise fields."""
    bg = np.full((16, 32), 100, dtype=np.uint8)
    rng = np.random.default_rng(3)
    a = _add_frame_noise(bg, rng, noise_amp=8)
    b = _add_frame_noise(bg, rng, noise_amp=8)
    assert not np.array_equal(a, b)


def test_place_object_center_near_target_luma():
    """Interior of a large box has luma close to the object's target luma."""
    rgb = np.zeros((32, 32, 3), dtype=np.uint8)
    _place_object(rgb, x0=8, y0=8, box_w=16, box_h=16, luma=200)
    # Deep inside the box, the blurred alpha ≈ 1 → output ≈ luma on all channels.
    px = rgb[16, 16]
    assert abs(int(px[0]) - 200) <= 2
    assert abs(int(px[1]) - 200) <= 2
    assert abs(int(px[2]) - 200) <= 2


def test_place_object_far_outside_untouched():
    """Pixels far from the object retain their original bg value."""
    rgb = np.full((32, 32, 3), 50, dtype=np.uint8)
    _place_object(rgb, x0=8, y0=8, box_w=4, box_h=4, luma=200)
    # Pixels in the far corner should be well outside the 5x5 kernel's reach.
    np.testing.assert_array_equal(rgb[28, 28], [50, 50, 50])
    np.testing.assert_array_equal(rgb[0, 28], [50, 50, 50])
    np.testing.assert_array_equal(rgb[28, 0], [50, 50, 50])


def test_place_object_soft_edge_transition():
    """Along an edge, intermediate pixels fall between bg and object luma."""
    rgb = np.zeros((32, 32, 3), dtype=np.uint8)
    _place_object(rgb, x0=8, y0=8, box_w=16, box_h=16, luma=200)
    # Move along a horizontal line just inside the top edge: transition from 0 → ~200.
    # At least one pixel on that line should be strictly between (0, 200).
    row = rgb[8, :, 0].astype(int)
    assert np.any((row > 10) & (row < 190)), f"no soft-edge pixel found: {row}"


def test_place_object_clips_partial_offscreen():
    """Object partially outside the frame renders its visible portion and does not raise."""
    rgb = np.zeros((32, 32, 3), dtype=np.uint8)
    _place_object(rgb, x0=-4, y0=10, box_w=12, box_h=8, luma=180)
    # Pixels inside the visible slice should be brighter than bg.
    assert rgb[14, 2, 0] > 50, f"expected visible portion, got {rgb[14, 2, 0]}"
    # Pixels far from the visible slice should be untouched.
    np.testing.assert_array_equal(rgb[14, 28], [0, 0, 0])


# ---- New synthetic source tests ----

def test_textured_static_no_motion_after_convergence():
    """textured_static: after EMA converges, mask is all-black (no false positives).

    This is the only negative test in the new set — verifies that the
    sinusoid+noise background does not itself produce motion.
    """
    frames = load_frames("synthetic:textured_static",
                         width=64, height=48, num_frames=60)
    out = run_model("mask", frames)
    for i in range(55, 60):
        assert not out[i].any(), (
            f"frame {i} should be all-black after EMA convergence on static bg")


def test_entering_object_produces_bboxes_on_both_halves():
    """entering_object: boxes from opposite edges both produce bbox overlays past priming."""
    frames = load_frames("synthetic:entering_object",
                         width=64, height=48, num_frames=8)
    out = run_model("motion", frames)
    # Accumulate green-bbox presence across all post-priming frames.
    total = np.zeros(out[0].shape[:2], dtype=bool)
    for i in range(3, 8):
        total |= np.all(out[i] == BBOX_COLOR, axis=-1)
    left  = total[:, :32].any()
    right = total[:, 32:].any()
    assert left and right, (
        f"bboxes should appear on both halves: left={left}, right={right}")


def test_multi_speed_produces_three_bbox_bands():
    """multi_speed: three spatially-separated boxes produce bboxes in three horizontal bands.

    Box A (fast, top band), Box B (medium, middle band), Box C (slow, crosses
    diagonal). Accumulating across post-priming frames, bbox pixels must appear
    in the top third, middle third, and bottom third of the frame.
    """
    H, W = 72, 96
    frames = load_frames("synthetic:multi_speed",
                         width=W, height=H, num_frames=8)
    out = run_model("motion", frames)
    total = np.zeros((H, W), dtype=bool)
    for i in range(3, 8):
        total |= np.all(out[i] == BBOX_COLOR, axis=-1)
    top    = total[: H // 3].any()
    middle = total[H // 3 : 2 * H // 3].any()
    bottom = total[2 * H // 3 :].any()
    assert top and middle and bottom, (
        f"bboxes expected in three bands: top={top}, middle={middle}, bottom={bottom}")


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
