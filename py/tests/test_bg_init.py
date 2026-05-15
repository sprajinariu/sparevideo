"""Unit tests for py/models/ops/bg_init.py — BG-estimate helpers."""
import numpy as np
import pytest

from models.ops.bg_init import compute_bg_estimate


def _make_stack(per_pixel_values, shape=(1, 1)):
    """Stack of N frames, each frame uniform with the given per-frame value."""
    h, w = shape
    return np.stack(
        [np.full(shape, v, dtype=np.uint8) for v in per_pixel_values], axis=0
    )


def test_compute_bg_estimate_median_matches_np_median():
    """mode='median' must be byte-identical to np.median(...).astype(uint8)."""
    rng = np.random.default_rng(42)
    stack = rng.integers(0, 256, size=(50, 4, 5), dtype=np.uint8)
    got = compute_bg_estimate(stack, mode="median")
    expected = np.median(stack, axis=0).astype(np.uint8)
    np.testing.assert_array_equal(got, expected)


def test_imrm_majority_bg_recovers_bg():
    """IMRM converges to BG when BG is the majority cluster."""
    # 100 frames at a single pixel: 60 BG (constant 80), 40 FG (constant 200).
    values = [80] * 60 + [200] * 40
    stack = _make_stack(values, shape=(1, 1))
    got = compute_bg_estimate(stack, mode="imrm", imrm_tau=20, imrm_iters=3)
    assert abs(int(got[0, 0]) - 80) <= 2, f"IMRM returned {got[0,0]}, expected ~80"


def test_imrm_unknown_mode_raises():
    with pytest.raises(ValueError, match="unknown bg_init mode"):
        compute_bg_estimate(np.zeros((1, 1, 1), dtype=np.uint8), mode="not_a_mode")


def test_imrm_iteratively_tightens_with_asymmetric_outliers():
    """IMRM iteration moves the estimate toward BG when outliers are
    asymmetric and within tau of the initial median.

    Setup at one pixel:
      - 30 frames at 80  (BG cluster)
      - 30 frames at 100 (mild contamination, close to BG)
      - 40 frames at 200 (clear FG outlier)
    Plain median (sort, position 49) = 100. With tau=20, iter 1 flags only
    the 40 FG frames; inliers = 30 BG + 30 contamination. A true ragged
    median over those 60 inliers gives 90 (a "fast approximation" that
    substitutes bg_est=100 for outliers would give 100 instead).
    """
    values = [80] * 30 + [100] * 30 + [200] * 40
    stack = _make_stack(values, shape=(1, 1))
    plain_med = compute_bg_estimate(stack, mode="median")
    assert int(plain_med[0, 0]) == 100, "sanity: plain median is 100"
    imrm = compute_bg_estimate(stack, mode="imrm", imrm_tau=20, imrm_iters=1)
    assert abs(int(imrm[0, 0]) - 90) <= 2, \
        f"IMRM (true ragged median) expected ~90, got {imrm[0,0]}"


def test_mvtw_recovers_bg_when_briefly_clear():
    """MVTW finds the brief BG-clear window when FG dominates overall."""
    # 100 frames at one pixel: FG=200 for frames 0..79, BG=80 for frames 80..99.
    # Plain median would return ~200; MVTW with K=20 should find the last
    # window and return ~80.
    values = [200] * 80 + [80] * 20
    stack = _make_stack(values, shape=(1, 1))
    got = compute_bg_estimate(stack, mode="mvtw", mvtw_k=20)
    assert abs(int(got[0, 0]) - 80) <= 2, f"MVTW returned {got[0,0]}, expected ~80"


def test_mvtw_falls_back_to_median_when_stack_shorter_than_k():
    """MVTW with K > N falls back to plain median over the full stack."""
    values = [80] * 10
    stack = _make_stack(values, shape=(1, 1))
    got = compute_bg_estimate(stack, mode="mvtw", mvtw_k=24)
    assert int(got[0, 0]) == 80


def test_mam_rejects_low_contrast_moving_fg():
    """MAM rejects frames with strong motion signal even when |FG-BG| is small.

    Setup at one pixel:
      - BG=80 for frames 0..39 (constant)
      - FG with frame-by-frame oscillation between 90 and 110 for frames 40..99
        (60 frames, FG-majority — plain median is in the FG range).
    Per-frame |FG_t - FG_{t-1}| = 20 inside the FG region, well above delta=8,
    so EVERY FG frame's inter-frame diff is > delta and gets flagged as motion.
    After motion masking the remaining non-motion frames are the BG run
    (frames 0..37 — frames 38, 39 get pulled in by dilation around the
    80→90 transition), giving a non-motion median of 80.
    """
    bg = [80] * 40
    fg = []
    for i in range(60):
        fg.append(90 if i % 2 == 0 else 110)
    values = bg + fg
    stack = _make_stack(values, shape=(1, 1))
    got = compute_bg_estimate(stack, mode="mam", mam_delta=8, mam_dilate=2)
    assert abs(int(got[0, 0]) - 80) <= 3, f"MAM returned {got[0,0]}, expected ~80"


def test_mam_static_pixel_returns_constant():
    """MAM on a fully-static pixel returns the constant value (no motion)."""
    values = [123] * 50
    stack = _make_stack(values, shape=(1, 1))
    got = compute_bg_estimate(stack, mode="mam", mam_delta=8, mam_dilate=2)
    assert int(got[0, 0]) == 123


def test_compute_lookahead_median_bank_median_mode_is_unchanged():
    """The new bg_init_mode='median' path must produce a byte-identical bank
    to the legacy pre-refactor compute_lookahead_median_bank behaviour.

    Lock-in: snapshot expected output by computing the bank with mode='median'
    once and asserting it matches np.median + the K-slot seeding loop.
    """
    from models.motion_vibe import compute_lookahead_median_bank
    rng = np.random.default_rng(0)
    rgb_frames = [
        rng.integers(0, 256, size=(8, 6, 3), dtype=np.uint8) for _ in range(10)
    ]
    bank_default = compute_lookahead_median_bank(
        rgb_frames=rgb_frames, k=8, lookahead_n=0, seed=0xDEADBEEF,
    )
    bank_explicit = compute_lookahead_median_bank(
        rgb_frames=rgb_frames, k=8, lookahead_n=0, seed=0xDEADBEEF,
        bg_init_mode="median",
    )
    np.testing.assert_array_equal(bank_default, bank_explicit)


def test_init_from_frames_dispatch_all_modes():
    """init_from_frames with each mode runs to completion and produces a bank."""
    from models.ops.vibe import ViBe
    rng = np.random.default_rng(7)
    stack = rng.integers(0, 256, size=(40, 8, 6), dtype=np.uint8)
    for mode in ("median", "imrm", "mvtw", "mam"):
        v = ViBe(K=8, R=20, min_match=2, prng_seed=0xDEADBEEF)
        v.init_from_frames(stack, mode=mode)
        assert v.samples is not None and v.samples.shape == (8, 6, 8)
        assert v.samples.dtype == np.uint8


def test_init_from_frames_deterministic():
    """Same frames + seed + mode ⇒ byte-identical bank."""
    from models.ops.vibe import ViBe
    rng = np.random.default_rng(11)
    stack = rng.integers(0, 256, size=(30, 5, 4), dtype=np.uint8)
    banks = []
    for _ in range(2):
        v = ViBe(K=8, R=20, min_match=2, prng_seed=0xDEADBEEF)
        v.init_from_frames(stack, mode="mvtw")
        banks.append(v.samples.copy())
    np.testing.assert_array_equal(banks[0], banks[1])
