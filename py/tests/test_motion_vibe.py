"""Unit tests for the ViBe re-implementation."""

import re
from pathlib import Path

import numpy as np
import pytest

from models.ops.vibe import ViBe
from profiles import DEFAULT_VIBE


# ---------------------------------------------------------------------------
# Task 30: PRNG_SEED static parity check
# ---------------------------------------------------------------------------

def test_sv_prng_seed_matches_python_default():
    """The SV parameter PRNG_SEED in axis_motion_detect_vibe.sv must equal
    vibe_prng_seed in DEFAULT_VIBE. Drift = every frame mismatches at frame 0."""
    sv_path = (Path(__file__).parent.parent.parent
               / "hw/ip/motion/rtl/axis_motion_detect_vibe.sv")
    src = sv_path.read_text()
    m = re.search(
        r"parameter\s+logic\s*\[31:0\]\s+PRNG_SEED\s*=\s*32'h([0-9A-Fa-f]+)",
        src,
    )
    assert m, "could not find PRNG_SEED parameter in axis_motion_detect_vibe.sv"
    sv_seed = int(m.group(1), 16)
    py_seed = DEFAULT_VIBE["vibe_prng_seed"]
    assert sv_seed == py_seed, (
        f"PRNG_SEED drift: SV=0x{sv_seed:08X}, Python=0x{py_seed:08X}. "
        "Update one to match the other."
    )


def test_sv_init_seed_magics_match_python():
    """The five INIT_MAGIC_N localparams in motion_core_vibe.sv must equal
    the INIT_SEED_MAGICS tuple in py/models/ops/vibe.py. Drift here causes
    init-bank divergence between SV and Python and breaks T2/T3 parity."""
    from models.ops.vibe import INIT_SEED_MAGICS

    sv_path = (Path(__file__).parent.parent.parent
               / "hw/ip/motion/rtl/motion_core_vibe.sv")
    src = sv_path.read_text()

    for i, expected in enumerate(INIT_SEED_MAGICS):
        m = re.search(
            rf"localparam\s+logic\s*\[31:0\]\s+INIT_MAGIC_{i}\s*=\s*32'h([0-9A-Fa-f]+)",
            src,
        )
        assert m, f"INIT_MAGIC_{i} not found in motion_core_vibe.sv"
        sv_val = int(m.group(1), 16)
        assert sv_val == expected, (
            f"INIT_MAGIC_{i} drift: SV=0x{sv_val:08X}, Python=0x{expected:08X}. "
            f"Update one to match the other."
        )


def _y_frame(value, h=4, w=4):
    """Make an h×w Y8 frame filled with `value`."""
    return np.full((h, w), value, dtype=np.uint8)


def test_init_scheme_c_shape_and_dtype():
    """Init produces (H, W, K) uint8 sample bank."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    frame_0 = _y_frame(128, h=4, w=4)
    v.init_from_frame(frame_0)
    assert v.samples.shape == (4, 4, 8)
    assert v.samples.dtype == np.uint8


def test_init_scheme_c_samples_within_noise_band():
    """Each slot of each pixel = current ± noise, range [-20, +20] (matches upstream)."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    frame_0 = _y_frame(128, h=4, w=4)
    v.init_from_frame(frame_0)
    # All samples within [128-20, 128+20] = [108, 148] (no clamping at this center value).
    assert v.samples.min() >= 108
    assert v.samples.max() <= 148
    # The window must actually be exercised — at 4×4×8 = 128 slots, expect spread > 16.
    assert int(v.samples.max()) - int(v.samples.min()) > 16, \
        "Sample spread too narrow to be ±20 noise — likely still ±8 implementation"


def test_init_scheme_c_clamps_at_edges():
    """Samples clamp to [0, 255] when current ± noise would overflow."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    # Frame value 0 → samples in [-20, +20] → clamped to [0, 20].
    v.init_from_frame(_y_frame(0))
    assert v.samples.min() == 0
    assert v.samples.max() <= 20

    # Frame value 255 → samples in [235, 275] → clamped to [235, 255].
    v2 = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
              init_scheme="c", prng_seed=0xDEADBEEF)
    v2.init_from_frame(_y_frame(255))
    assert v2.samples.min() >= 235
    assert v2.samples.max() == 255


def test_init_scheme_c_deterministic_from_seed():
    """Two ViBes with same seed produce identical sample banks."""
    a = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xCAFEBABE)
    b = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xCAFEBABE)
    a.init_from_frame(_y_frame(100))
    b.init_from_frame(_y_frame(100))
    assert np.array_equal(a.samples, b.samples)


def test_init_scheme_c_different_seeds_differ():
    """Different seeds produce different sample banks."""
    a = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xCAFEBABE)
    b = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    a.init_from_frame(_y_frame(100))
    b.init_from_frame(_y_frame(100))
    assert not np.array_equal(a.samples, b.samples)


def test_compute_mask_all_match_means_bg():
    """If all K samples equal the current frame, count=K → mask=0 (bg)."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 2, 2
    v.samples = np.full((2, 2, 8), 100, dtype=np.uint8)
    mask = v.compute_mask(_y_frame(100, h=2, w=2))
    assert mask.shape == (2, 2)
    assert mask.dtype == bool
    assert not mask.any(), "all pixels should be bg (mask=False)"


def test_compute_mask_no_match_means_motion():
    """If no samples are within R of current, count=0 → mask=1 (motion)."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 2, 2
    v.samples = np.full((2, 2, 8), 100, dtype=np.uint8)
    # Current = 200, samples = 100, diff = 100 > R=20 → no match → motion
    mask = v.compute_mask(_y_frame(200, h=2, w=2))
    assert mask.all(), "all pixels should be motion (mask=True)"


def test_compute_mask_one_match_below_min_match():
    """count=1, min_match=2 → mask=1 (motion)."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 1, 1
    # 1 sample at 100 (matches y=100 within R), 7 samples at 200 (don't match)
    v.samples = np.zeros((1, 1, 8), dtype=np.uint8)
    v.samples[0, 0, 0] = 100
    v.samples[0, 0, 1:] = 200
    mask = v.compute_mask(_y_frame(100, h=1, w=1))
    assert mask[0, 0], "1 match < min_match=2 → motion"


def test_compute_mask_two_matches_meets_min_match():
    """count=2, min_match=2 → mask=0 (bg)."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 1, 1
    v.samples = np.zeros((1, 1, 8), dtype=np.uint8)
    v.samples[0, 0, 0] = 100
    v.samples[0, 0, 1] = 100
    v.samples[0, 0, 2:] = 200
    mask = v.compute_mask(_y_frame(100, h=1, w=1))
    assert not mask[0, 0], "2 matches >= min_match=2 → bg"


def test_compute_mask_radius_strictly_less_than():
    """A sample exactly R away from current is NOT a match (strict <)."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 1, 1
    v.samples = np.full((1, 1, 8), 100, dtype=np.uint8)
    # Current = 120, samples = 100, |diff| = 20 = R → strict < → no match
    mask = v.compute_mask(_y_frame(120, h=1, w=1))
    assert mask[0, 0], "|diff|=R should NOT match (strict <)"


def test_self_update_only_on_bg_pixels():
    """Self-update never modifies samples at pixels classified motion."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=1, phi_diffuse=16,  # phi=1 → always fire
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 2, 2
    v.samples = np.full((2, 2, 8), 100, dtype=np.uint8)
    # Pixel (0,0) is bg (matches), (0,1) is motion (way out of range)
    frame = np.array([[100, 250], [100, 100]], dtype=np.uint8)
    mask = v.compute_mask(frame)
    assert mask[0, 1] and not mask[0, 0]
    samples_before = v.samples.copy()
    v._apply_self_update(frame, mask)
    # (0,1) motion pixel: samples unchanged
    assert np.array_equal(samples_before[0, 1], v.samples[0, 1])
    # (0,0) bg pixel: at least one slot replaced with 100 (was already 100; stable)
    # but rate counter should have advanced — verify via follow-up test


def test_self_update_deterministic_at_fixed_seed():
    """Two runs with same seed produce identical post-update samples."""
    def run():
        v = ViBe(K=8, R=20, min_match=2, phi_update=1, phi_diffuse=16,
                 init_scheme="c", prng_seed=0xDEADBEEF)
        v.H, v.W = 2, 2
        v.samples = np.full((2, 2, 8), 100, dtype=np.uint8)
        frame = _y_frame(105, h=2, w=2)
        mask = v.compute_mask(frame)
        v._apply_self_update(frame, mask)
        return v.samples.copy()
    a = run()
    b = run()
    assert np.array_equal(a, b)


def test_self_update_writes_current_value():
    """When self-update fires, the chosen slot becomes the current pixel value."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=1, phi_diffuse=16,  # always fire
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 1, 1
    v.samples = np.full((1, 1, 8), 100, dtype=np.uint8)
    frame = _y_frame(105, h=1, w=1)  # within R=20 of 100 → bg
    mask = v.compute_mask(frame)
    assert not mask[0, 0]
    v._apply_self_update(frame, mask)
    # Exactly one slot should now be 105 (the rest still 100)
    assert (v.samples[0, 0] == 105).sum() == 1
    assert (v.samples[0, 0] == 100).sum() == 7


def test_diffusion_only_on_bg_pixels():
    """Diffusion never propagates from pixels classified motion."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=1,  # always fire
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 3, 3
    v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
    # Mark all pixels motion → no diffusion writes anywhere
    frame = _y_frame(250, h=3, w=3)
    mask = np.ones((3, 3), dtype=bool)
    samples_before = v.samples.copy()
    v._apply_diffusion(frame, mask)
    assert np.array_equal(samples_before, v.samples)


def test_diffusion_writes_to_in_bounds_neighbor():
    """A center bg pixel firing diffusion writes to one of its 8 neighbors."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=1,  # always fire
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 3, 3
    v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
    # Only center pixel is bg; corners and edges marked motion to keep them silent
    mask = np.ones((3, 3), dtype=bool)
    mask[1, 1] = False
    frame = _y_frame(105, h=3, w=3)  # center pixel value 105
    v._apply_diffusion(frame, mask)
    # Exactly one neighbor of (1,1) — i.e., one cell among (0,0)..(2,2) excluding (1,1)
    # — should have one of its 8 slots = 105.
    diffs_to_105 = (v.samples == 105)
    # The center pixel's own slots are unchanged (diffusion writes to neighbors)
    assert not diffs_to_105[1, 1].any()
    # Total writes of value 105 in the 3x3: exactly 1
    assert diffs_to_105.sum() == 1


def test_diffusion_excludes_center():
    """The 8-neighbor selector NEVER writes to (0,0) — diffusion is to neighbors only."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=1,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 3, 3
    v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
    mask = np.ones((3, 3), dtype=bool)
    mask[1, 1] = False
    # Run many trials with varying seeds — none should ever write 105 to (1,1)'s slots
    for seed_mod in range(10):
        v.prng_state = 0xDEADBEEF ^ seed_mod
        v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
        v._apply_diffusion(_y_frame(105, h=3, w=3), mask)
        assert (v.samples[1, 1] == 100).all(), f"center modified at seed_mod={seed_mod}"


def test_diffusion_clamped_at_image_boundaries():
    """Diffusion targets are clamped to in-bounds; no array-OOB on edge pixels."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=1,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 3, 3
    v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
    # Top-left corner pixel is bg; rest are motion
    mask = np.ones((3, 3), dtype=bool)
    mask[0, 0] = False
    # Should not raise even though some 8-neighbor offsets go off the top-left edge
    v._apply_diffusion(_y_frame(105, h=3, w=3), mask)


def test_process_frame_returns_mask():
    """process_frame returns a bool mask of the right shape."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.init_from_frame(_y_frame(128, h=4, w=4))
    mask = v.process_frame(_y_frame(128, h=4, w=4))
    assert mask.shape == (4, 4)
    assert mask.dtype == bool


def test_process_frame_static_scene_settles_to_bg():
    """A static scene streams as all-bg after a few frames."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.init_from_frame(_y_frame(128, h=8, w=8))
    # After init, the same frame should be classified almost entirely bg.
    # (Init scheme c places all samples within ±8 of the value 128, well within R=20.)
    mask = v.process_frame(_y_frame(128, h=8, w=8))
    assert mask.sum() == 0, "static scene should be all-bg immediately after init"


def test_process_frame_motion_detected():
    """A pixel value change of 100 → motion."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.init_from_frame(_y_frame(128, h=4, w=4))
    moved = _y_frame(128, h=4, w=4)
    moved[1:3, 1:3] = 240  # diff > R
    mask = v.process_frame(moved)
    assert mask[1:3, 1:3].all()
    assert not mask[0, 0]


def test_process_frame_deterministic_full_run():
    """Two ViBes with same seed produce identical mask sequences across N frames."""
    def run():
        v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
                 init_scheme="c", prng_seed=0xDEADBEEF)
        v.init_from_frame(_y_frame(128, h=8, w=8))
        masks = []
        for _ in range(10):
            masks.append(v.process_frame(_y_frame(128, h=8, w=8)).copy())
        return np.stack(masks)
    a, b = run(), run()
    assert np.array_equal(a, b)


def test_init_scheme_b_degenerate_stack():
    """Scheme b: every slot of every pixel = current pixel value."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="b", prng_seed=0xDEADBEEF)
    f = _y_frame(100, h=4, w=4)
    v.init_from_frame(f)
    expected = np.broadcast_to(f[..., None], (4, 4, 8))
    assert np.array_equal(v.samples, expected)


def test_init_scheme_a_neighborhood_draws_in_range():
    """Scheme a: each slot pulls from one of the 9 cells of the 3×3 neighborhood."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="a", prng_seed=0xDEADBEEF)
    # 4×4 frame with distinct values per pixel — verify each sample came from
    # a 3×3 neighborhood cell of its target pixel.
    np.random.seed(42)
    f = np.random.randint(0, 256, size=(4, 4), dtype=np.uint8)
    v.init_from_frame(f)
    # Build the set of valid values at each pixel = union of its 3×3 neighborhood
    for r in range(4):
        for c in range(4):
            valid = set()
            for dr in (-1, 0, +1):
                for dc in (-1, 0, +1):
                    nr, nc = r + dr, c + dc
                    if 0 <= nr < 4 and 0 <= nc < 4:
                        valid.add(int(f[nr, nc]))
            for k in range(8):
                assert int(v.samples[r, c, k]) in valid, \
                    f"pixel ({r},{c}) slot {k} = {v.samples[r,c,k]} not in {valid}"


def test_diffusion_disabled_when_phi_diffuse_zero():
    """phi_diffuse=0 means diffusion is fully disabled — no neighbor writes."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=0,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 3, 3
    v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
    mask = np.zeros((3, 3), dtype=bool)  # all bg → diffusion would normally fire
    samples_before = v.samples.copy()
    v._apply_diffusion(_y_frame(105, h=3, w=3), mask)
    assert np.array_equal(samples_before, v.samples), "samples must be unchanged"


def test_init_scheme_c_supports_K20():
    """K=20 (non-power-of-2) is now allowed."""
    v = ViBe(K=20, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.init_from_frame(_y_frame(128, h=4, w=4))
    assert v.samples.shape == (4, 4, 20)


def test_compute_mask_K20_basic():
    """K=20: count threshold still works correctly."""
    v = ViBe(K=20, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 1, 1
    # All 20 slots = 100, current = 100 → all match → bg
    v.samples = np.full((1, 1, 20), 100, dtype=np.uint8)
    mask = v.compute_mask(_y_frame(100, h=1, w=1))
    assert not mask[0, 0]
    # All 20 slots = 100, current = 200 → no match → motion
    mask = v.compute_mask(_y_frame(200, h=1, w=1))
    assert mask[0, 0]


def test_self_update_K20_writes_in_range():
    """K=20: self-update slot index is always in [0, 20)."""
    v = ViBe(K=20, R=20, min_match=2, phi_update=1, phi_diffuse=16,  # always fire
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 4, 4
    v.samples = np.full((4, 4, 20), 100, dtype=np.uint8)
    frame = _y_frame(105, h=4, w=4)
    mask = v.compute_mask(frame)
    v._apply_self_update(frame, mask)
    # No crash → ok. Verify at least one update happened (16 pixels x always-fire → 16 updates)
    assert (v.samples == 105).sum() == 16


def test_diffusion_K20_writes_in_range():
    """K=20: diffusion slot index is always in [0, 20)."""
    v = ViBe(K=20, R=20, min_match=2, phi_update=16, phi_diffuse=1,  # diffusion always fire
             init_scheme="c", prng_seed=0xDEADBEEF)
    v.H, v.W = 4, 4
    v.samples = np.full((4, 4, 20), 100, dtype=np.uint8)
    frame = _y_frame(105, h=4, w=4)
    mask = np.zeros((4, 4), dtype=bool)  # all bg → diffusion fires
    v._apply_diffusion(frame, mask)
    # No crash and some diffusion writes happened
    assert (v.samples == 105).sum() > 0


def test_coupled_rolls_fires_self_and_neighbor_together():
    """coupled_rolls=True: when fire happens on a bg pixel, both self and
    neighbor get the current value written. With phi_update=1 (always fire)
    on a 3x3 image with only the center bg-classified, exactly 2 sample-bank
    writes happen: 1 at center (self-update) + 1 at a neighbor."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=1, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF, coupled_rolls=True)
    v.H, v.W = 3, 3
    v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
    mask = np.ones((3, 3), dtype=bool)
    mask[1, 1] = False  # only center is bg
    frame = _y_frame(105, h=3, w=3)
    v.process_frame_unused = None  # placeholder; we test internals directly
    v._apply_update_coupled(frame, mask)
    # Exactly 2 writes of value 105 in the 3x3 sample bank: one at center, one at a neighbor.
    writes_at_center = (v.samples[1, 1] == 105).sum()
    total_writes = (v.samples == 105).sum()
    assert writes_at_center == 1, f"expected 1 self-update at center, got {writes_at_center}"
    assert total_writes == 2, f"expected 2 total writes (self + 1 neighbor), got {total_writes}"


def test_coupled_rolls_no_update_on_motion_pixel():
    """coupled_rolls=True: motion-classified pixels never fire updates."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=1, phi_diffuse=16,  # always fire when bg
             init_scheme="c", prng_seed=0xDEADBEEF, coupled_rolls=True)
    v.H, v.W = 3, 3
    v.samples = np.full((3, 3, 8), 100, dtype=np.uint8)
    mask = np.ones((3, 3), dtype=bool)  # all motion → no updates
    frame = _y_frame(105, h=3, w=3)
    samples_before = v.samples.copy()
    v._apply_update_coupled(frame, mask)
    assert np.array_equal(samples_before, v.samples), "no writes on all-motion frame"


def test_coupled_rolls_dispatch_in_process_frame():
    """process_frame routes to coupled path when coupled_rolls=True; mask shape preserved."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF, coupled_rolls=True)
    v.init_from_frame(_y_frame(128, h=8, w=8))
    mask = v.process_frame(_y_frame(128, h=8, w=8))
    assert mask.shape == (8, 8)
    assert mask.dtype == bool


def test_init_scheme_c_k20_slots_not_degenerate():
    """K=20 init must produce noisy values for ALL slots, including k≥8.

    Regression test for the prior slot-degenerate bug: under the old 4-bit-lane
    code, slots k=8..19 all collapsed to `clamp(y - 8, 0, 255)` because
    `(state >> (4*k)) & 0xF == 0` for any k ≥ 8 on a 32-bit state.
    """
    v = ViBe(K=20, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    frame_0 = _y_frame(128, h=4, w=4)
    v.init_from_frame(frame_0)
    # Slots k=8..19 must NOT all be the same value (the prior bug made them all 120).
    high_slots = v.samples[:, :, 8:]  # (H, W, 12)
    unique_in_high = np.unique(high_slots)
    assert unique_in_high.size > 4, \
        f"K=20 slots k=8..19 are degenerate (only {unique_in_high.size} unique values) — regression of prior bug"


def test_init_scheme_c_noise_covers_full_range():
    """Across a 64×64 init at K=8, observed noise covers ≥ 90% of [-20, +20]."""
    v = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    # Use mid-range (128) to avoid clamping, large grid for statistical coverage.
    frame_0 = _y_frame(128, h=64, w=64)
    v.init_from_frame(frame_0)
    noises = v.samples.astype(int) - 128  # recover signed noise per slot
    expected_values = set(range(-20, 21))  # 41 values
    observed = set(int(n) for n in np.unique(noises))
    coverage = len(observed & expected_values) / len(expected_values)
    assert coverage >= 0.90, \
        f"Noise coverage only {coverage:.2%} of [-20, +20] — distribution too narrow"
    # Sanity: nothing observed outside the band.
    assert min(observed) >= -20 and max(observed) <= 20, \
        f"Noise out of band: {min(observed)}..{max(observed)}"


def test_init_from_frames_single_frame_matches_init_from_frame():
    """N=1 stack → median is the single frame → result must match init_from_frame."""
    frame = _y_frame(120, h=4, w=4)
    stack = frame[None, ...]  # (1, 4, 4) uint8

    a = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    a.init_from_frame(frame)

    b = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    b.init_from_frames(stack, lookahead_n=1)

    assert np.array_equal(a.samples, b.samples), \
        "init_from_frames(N=1) must produce identical bank to init_from_frame"


def test_init_from_frames_median_equivalence():
    """N>1 stack → init_from_frames must equal init_from_frame applied to
    the per-pixel median of the stack (with same seed/scheme)."""
    rng = np.random.default_rng(seed=42)
    stack = rng.integers(0, 256, size=(7, 6, 8), dtype=np.uint8)
    median = np.median(stack, axis=0).astype(np.uint8)

    a = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    a.init_from_frame(median)

    b = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    b.init_from_frames(stack, lookahead_n=None)  # use all 7 frames

    assert np.array_equal(a.samples, b.samples), \
        "init_from_frames(N=all) must match init_from_frame on the median"


def test_init_from_frames_partial_window():
    """lookahead_n < N uses only the first lookahead_n frames for the median."""
    # Frames 0..2 are filled with 100, frames 3..5 are filled with 200.
    # median over first 3 frames = 100, median over all 6 = ~150.
    f_lo = _y_frame(100, h=4, w=4)
    f_hi = _y_frame(200, h=4, w=4)
    stack = np.stack([f_lo, f_lo, f_lo, f_hi, f_hi, f_hi], axis=0)

    a = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    a.init_from_frame(_y_frame(100, h=4, w=4))

    b = ViBe(K=8, R=20, min_match=2, phi_update=16, phi_diffuse=16,
             init_scheme="c", prng_seed=0xDEADBEEF)
    b.init_from_frames(stack, lookahead_n=3)

    assert np.array_equal(a.samples, b.samples), \
        "init_from_frames(lookahead_n=3) must median over only frames[:3]"
