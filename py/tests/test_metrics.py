"""Unit tests for Phase 0 metrics."""

import numpy as np

from experiments.metrics import (
    mask_coverage,
    coverage_curve,
    ghost_convergence_frame,
    run_ema_baseline,
)


def test_mask_coverage_all_motion():
    m = np.ones((10, 10), dtype=bool)
    assert mask_coverage(m) == 1.0


def test_mask_coverage_all_bg():
    m = np.zeros((10, 10), dtype=bool)
    assert mask_coverage(m) == 0.0


def test_mask_coverage_half():
    m = np.zeros((10, 10), dtype=bool)
    m[:5] = True
    assert mask_coverage(m) == 0.5


def test_coverage_curve_shape():
    masks = [np.zeros((4, 4), dtype=bool) for _ in range(5)]
    masks[2][:] = True
    curve = coverage_curve(masks)
    assert curve.shape == (5,)
    assert curve[0] == 0.0
    assert curve[2] == 1.0


def test_ghost_convergence_frame_obvious_decay():
    """A coverage curve that drops below threshold at frame 7 returns 7."""
    # Simulate a ghost decaying linearly from 30% to 0% over 10 frames
    curve = np.linspace(0.30, 0.0, 10)
    # Threshold of 0.05: first frame below 0.05 is when curve drops to ~0.05
    # 0.30 + i*(-0.30/9) < 0.05 → i > (0.30-0.05)*9/0.30 = 7.5 → frame 8
    frame = ghost_convergence_frame(curve, threshold=0.05)
    assert frame == 8


def test_ghost_convergence_frame_never_converges():
    """A coverage curve that never drops below threshold returns -1."""
    curve = np.full(20, 0.50)
    assert ghost_convergence_frame(curve, threshold=0.05) == -1


def test_ema_baseline_smoke():
    """run_ema_baseline produces masks of correct shape — smoke test only."""
    frames = [np.full((8, 8), 128, dtype=np.uint8) for _ in range(5)]
    masks = run_ema_baseline(frames)
    assert len(masks) == 5
    assert all(m.shape == (8, 8) and m.dtype == bool for m in masks)


def test_render_grid_writes_png(tmp_path):
    """render_grid produces a non-empty PNG file at the given path."""
    from experiments.render import render_grid
    H, W, N = 16, 16, 4
    inputs = [np.full((H, W, 3), v, dtype=np.uint8) for v in [50, 100, 150, 200]]
    masks_a = [np.zeros((H, W), dtype=bool) for _ in range(N)]
    masks_b = [np.ones((H, W), dtype=bool) for _ in range(N)]
    masks_c = [np.zeros((H, W), dtype=bool) for _ in range(N)]
    out = tmp_path / "grid.png"
    render_grid(inputs, [("ours", masks_a), ("upstream", masks_b), ("ema", masks_c)],
                out_path=str(out))
    assert out.exists()
    assert out.stat().st_size > 0


def test_render_curve_writes_png(tmp_path):
    """render_coverage_curves produces a non-empty PNG file."""
    from experiments.render import render_coverage_curves
    curves = {"ours": np.array([0.5, 0.3, 0.1, 0.0]),
              "upstream": np.array([0.5, 0.4, 0.2, 0.05]),
              "ema": np.array([0.5, 0.4, 0.4, 0.35])}
    out = tmp_path / "curve.png"
    render_coverage_curves(curves, out_path=str(out), title="test")
    assert out.exists()
    assert out.stat().st_size > 0


def test_run_source_returns_metrics(tmp_path):
    """run_source on a synthetic produces a metrics dict and writes outputs."""
    from experiments.run_phase0 import run_source
    out_dir = tmp_path / "run"
    metrics = run_source(
        source="synthetic:moving_box",
        num_frames=8,
        K=8, R=20, min_match=2,
        phi_update=16, phi_diffuse=16,
        init_scheme="c",
        prng_seed=0xDEADBEEF,
        out_dir=str(out_dir),
    )
    assert "coverage_curve_ours" in metrics
    assert "coverage_curve_ema" in metrics
    assert metrics["coverage_curve_ours"].shape == (8,)
    assert (out_dir / "grid.png").exists()
    assert (out_dir / "coverage.png").exists()
