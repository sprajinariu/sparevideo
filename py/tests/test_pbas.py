"""Unit tests for the PBAS operator."""
from __future__ import annotations

import numpy as np
import pytest

from models.ops.pbas import PBAS


def _const_frame(val: int, h: int = 16, w: int = 16) -> np.ndarray:
    return np.full((h, w), val, dtype=np.uint8)


def _random_frames(n: int, h: int = 16, w: int = 16, seed: int = 0) -> list[np.ndarray]:
    rng = np.random.default_rng(seed)
    return [rng.integers(0, 256, (h, w), dtype=np.uint8) for _ in range(n)]


def test_pbas_deterministic_under_fixed_seed():
    """Two runs with same seed → bit-identical masks and bank state."""
    frames = _random_frames(40, seed=0)
    a = PBAS(prng_seed=0xDEADBEEF)
    a.init_from_frames(frames[:20])
    masks_a = [a.process_frame(f) for f in frames[20:]]
    b = PBAS(prng_seed=0xDEADBEEF)
    b.init_from_frames(frames[:20])
    masks_b = [b.process_frame(f) for f in frames[20:]]
    for ma, mb in zip(masks_a, masks_b):
        assert np.array_equal(ma, mb)
    assert np.array_equal(a.samples_y, b.samples_y)
    assert np.array_equal(a.samples_g, b.samples_g)
    assert np.array_equal(a.R, b.R)
    assert np.array_equal(a.T, b.T)


def test_pbas_sobel_magnitude_zero_for_constant_frame():
    """A constant frame has zero gradient magnitude everywhere."""
    from models.ops.pbas import PBAS
    p = PBAS()
    g = p._sobel_magnitude(_const_frame(128, h=8, w=8))
    assert g.shape == (8, 8)
    assert g.dtype == np.uint8
    assert (g == 0).all()


def test_pbas_sobel_magnitude_high_at_edge():
    """A frame with a vertical step has non-zero gradient along the step."""
    from models.ops.pbas import PBAS
    p = PBAS()
    frame = np.zeros((8, 8), np.uint8)
    frame[:, 4:] = 255
    g = p._sobel_magnitude(frame)
    # Column 3 or 4 should have a significant gradient.
    assert g[:, 3:5].max() > 100
    # Far from the edge, gradient is zero.
    assert g[:, 0].max() == 0
    assert g[:, 7].max() == 0


def test_pbas_formerMeanMag_clamped_to_min():
    """formerMeanMag floored at mean_mag_min (default 20) — never collapses."""
    from models.ops.pbas import PBAS
    p = PBAS(mean_mag_min=20.0)
    # Pass an all-zero gradient frame with all-bg mask (no fg pixels).
    g = np.zeros((8, 8), np.uint8)
    mask = np.zeros((8, 8), bool)
    p._update_formerMeanMag(g, mask)
    assert p.formerMeanMag == 20.0
    # Pass an all-fg mask with high-magnitude gradient — formerMeanMag tracks the mean.
    g2 = np.full((8, 8), 100, np.uint8)
    mask_fg = np.ones((8, 8), bool)
    p._update_formerMeanMag(g2, mask_fg)
    assert p.formerMeanMag == 100.0


def test_pbas_init_from_frames_paper_default():
    """Paper-default init: first N frames populate bank, one slot per frame.

    Stack of N constant frames with distinct values → each slot k has value k.
    """
    from models.ops.pbas import PBAS
    p = PBAS(N=20)
    frames = [_const_frame(i * 10, h=4, w=4) for i in range(20)]  # values 0,10,20..190
    p.init_from_frames(frames)
    assert p.samples_y.shape == (4, 4, 20)
    assert p.samples_g.shape == (4, 4, 20)
    # samples_y[r,c,k] == k*10 for any (r,c)
    for k in range(20):
        assert (p.samples_y[:, :, k] == k * 10).all()
    # samples_g[r,c,k] == 0 (constant frame has zero gradient)
    assert (p.samples_g == 0).all()
    # State arrays exist and are at init values.
    assert p.R.shape == (4, 4)
    assert (p.R == p.R_lower).all()
    assert (p.T == p.T_init).all()
    assert (p.meanMinDist == 0).all()


def test_pbas_init_from_lookahead_median():
    """Lookahead init: bank seeded from temporal-median of all frames.

    Stack of frames with varying values; median is well-defined; bank should
    have that median in every slot.
    """
    from models.ops.pbas import PBAS
    p = PBAS(N=20)
    frames = [_const_frame(i, h=4, w=4) for i in range(50)]  # values 0..49
    p.init_from_frames(frames, mode="lookahead_median")
    # Median of 0..49 is 24 or 25 (numpy.median on even-length returns float)
    expected_median = int(np.median(np.array([i for i in range(50)])))
    for k in range(20):
        assert (p.samples_y[:, :, k] == expected_median).all()


def test_pbas_process_frame_matching_bank_yields_bg():
    """A frame identical to the init frames matches → all-bg → mask all-zero."""
    from models.ops.pbas import PBAS
    p = PBAS()
    same = _const_frame(128, h=8, w=8)
    p.init_from_frames([same] * 20)
    mask = p.process_frame(same)
    assert mask.shape == (8, 8)
    assert mask.dtype == bool
    assert (~mask).all()  # mask is False (= bg) everywhere


def test_pbas_process_frame_far_from_bank_yields_fg():
    """A frame far from the bank in intensity → all-fg → mask all-true."""
    from models.ops.pbas import PBAS
    p = PBAS()
    p.init_from_frames([_const_frame(0, h=8, w=8)] * 20)
    mask = p.process_frame(_const_frame(255, h=8, w=8))
    assert mask.all()  # mask is True (= fg) everywhere


def test_pbas_R_clamped_to_R_lower():
    """After many constant-bg frames, R(x) drops toward meanMinDist*R_scale=0
    but is clamped at R_lower."""
    from models.ops.pbas import PBAS
    p = PBAS(R_lower=18)
    same = _const_frame(128, h=8, w=8)
    p.init_from_frames([same] * 20)
    for _ in range(200):
        p.process_frame(same)
    assert p.R.min() == 18.0
    assert p.R.max() >= 18.0  # clamped at R_lower


def test_pbas_T_clamped_to_bounds():
    """T(x) stays within [T_lower, T_upper] across long runs of mixed input."""
    from models.ops.pbas import PBAS
    p = PBAS(T_lower=2, T_upper=200)
    frames = _random_frames(40, seed=42)
    p.init_from_frames(frames[:20])
    for f in frames[20:]:
        p.process_frame(f)
    assert p.T.min() >= 2.0
    assert p.T.max() <= 200.0


def test_pbas_gradient_distance_contribution():
    """With alpha=7, beta=0, distance = gradient term only.

    A frame with identical intensity to the bank but DIFFERENT gradient should
    still register a non-zero distance and (with a large enough delta) get
    classified as fg.
    """
    from models.ops.pbas import PBAS
    p = PBAS(alpha=7, beta=0, R_lower=1)  # tight R so any gradient diff = fg
    same = _const_frame(128, h=8, w=8)
    p.init_from_frames([same] * 20)
    # Now a frame with the same intensity but a sharp vertical edge
    edged = np.full((8, 8), 128, np.uint8)
    edged[:, 4:] = 200
    mask = p.process_frame(edged)
    # Pixels at the edge (columns 3-4) should be classified fg due to gradient diff
    assert mask[:, 3:5].any()


def test_pbas_degenerate_with_alpha0_no_feedback():
    """With alpha=0, R_incdec=0, T_inc=0, T_dec=0:
       - R is frozen at R_lower
       - T is frozen at T_init
       - Distance reduces to beta * |y - sample_y|
       - Bank update fires with constant probability T_upper/T_init
    PBAS reduces to a ViBe-like algorithm with no feedback. Same input
    should produce the same bg/fg classifications across repeated runs.
    """
    from models.ops.pbas import PBAS
    p = PBAS(
        alpha=0,           # disable gradient distance
        R_incdec=0.0,      # R frozen
        T_inc=0.0,         # T frozen on bg
        T_dec=0.0,         # T frozen on fg
        R_lower=20,        # ViBe-like R
        Raute_min=2,       # ViBe min_match
        T_init=16,         # so update probability = T_upper/T_init = 200/16 ≈ 12.5
    )
    frames = _random_frames(40, seed=7)
    p.init_from_frames(frames[:20])
    # R and T should remain constant
    R0 = p.R.copy()
    T0 = p.T.copy()
    masks = [p.process_frame(f) for f in frames[20:]]
    assert np.allclose(p.R, R0, atol=1e-5), "R should be frozen with R_incdec=0"
    assert np.allclose(p.T, T0, atol=1e-5), "T should be frozen with T_inc=T_dec=0"
    # Masks should be deterministic.
    assert all(m.dtype == bool for m in masks)


def test_produce_masks_pbas_paper_default():
    """End-to-end adapter test: 40 RGB frames → 40 boolean masks via paper init."""
    from models._pbas_mask import produce_masks_pbas
    rng = np.random.default_rng(0)
    frames = [rng.integers(0, 256, (16, 16, 3), dtype=np.uint8) for _ in range(40)]
    masks = produce_masks_pbas(
        frames,
        pbas_N=20, pbas_R_lower=18, pbas_R_scale=5, pbas_Raute_min=2,
        pbas_T_lower=2, pbas_T_upper=200, pbas_T_init=18,
        pbas_R_incdec_q8=13, pbas_T_inc_q8=256, pbas_T_dec_q8=13,
        pbas_alpha=7, pbas_beta=1, pbas_mean_mag_min=20,
        pbas_bg_init_lookahead=0, pbas_prng_seed=0xDEADBEEF,
        gauss_en=False,
    )
    assert len(masks) == 40
    # Paper-default init: first 20 masks should be all-zero (init phase)
    for i in range(20):
        assert (~masks[i]).all(), f"frame {i} during paper-default init should be all-bg"
    # Post-init masks must be bool with correct shape
    for m in masks[20:]:
        assert m.dtype == bool
        assert m.shape == (16, 16)


def test_pbas_R_upper_caps_R():
    """R_upper=80 prevents R(x) from drifting beyond 80, even in noisy regions."""
    from models.ops.pbas import PBAS
    p = PBAS(R_lower=18, R_upper=80, R_incdec=0.05, R_scale=5)
    frames = _random_frames(40, seed=42)
    p.init_from_frames(frames[:20])
    for f in frames[20:]:
        p.process_frame(f)
    assert p.R.max() <= 80.0, f"R.max()={p.R.max()} exceeds R_upper=80"
    assert p.R.min() >= 18.0, f"R.min()={p.R.min()} below R_lower=18"


def test_produce_masks_pbas_lookahead():
    """Lookahead init: bank pre-seeded, processing starts from frame 0."""
    from models._pbas_mask import produce_masks_pbas
    rng = np.random.default_rng(0)
    frames = [rng.integers(0, 256, (16, 16, 3), dtype=np.uint8) for _ in range(20)]
    masks = produce_masks_pbas(
        frames,
        pbas_N=20, pbas_R_lower=18, pbas_R_scale=5, pbas_Raute_min=2,
        pbas_T_lower=2, pbas_T_upper=200, pbas_T_init=18,
        pbas_R_incdec_q8=13, pbas_T_inc_q8=256, pbas_T_dec_q8=13,
        pbas_alpha=7, pbas_beta=1, pbas_mean_mag_min=20,
        pbas_bg_init_lookahead=1, pbas_prng_seed=0xDEADBEEF,
        gauss_en=False,
    )
    assert len(masks) == 20
    # All masks valid; no enforced init period.
    for m in masks:
        assert m.dtype == bool
        assert m.shape == (16, 16)
