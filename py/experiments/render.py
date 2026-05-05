"""Phase 0 visualization: side-by-side mask comparison grids and per-frame
mask-coverage curve plots.
"""

from typing import Dict, List, Tuple

import numpy as np
from PIL import Image
import matplotlib
matplotlib.use("Agg")  # headless
import matplotlib.pyplot as plt


def _mask_to_rgb(mask: np.ndarray) -> np.ndarray:
    """Render a bool mask as a magenta-on-black RGB image for visibility."""
    rgb = np.zeros((*mask.shape, 3), dtype=np.uint8)
    rgb[mask] = (255, 0, 255)
    return rgb


def render_grid(
    input_frames: List[np.ndarray],
    rows: List[Tuple[str, List[np.ndarray]]],
    out_path: str,
    every_n: int = 8,
) -> None:
    """Render a 2-D grid PNG: rows = methods (input + each labelled mask sequence),
    columns = frames sampled every `every_n`.

    Args:
        input_frames: list of (H, W, 3) uint8 RGB frames.
        rows: list of (label, masks) tuples, one tuple per method.
        out_path: output PNG path.
        every_n: sample every N frames for the grid (controls width).
    """
    n_total = len(input_frames)
    indices = list(range(0, n_total, every_n))
    if indices[-1] != n_total - 1:
        indices.append(n_total - 1)
    n_cols = len(indices)
    n_rows = 1 + len(rows)  # input + each method row
    H, W = input_frames[0].shape[:2]
    pad = 4

    grid = np.full(
        ((H + pad) * n_rows + pad, (W + pad) * n_cols + pad, 3),
        32, dtype=np.uint8,
    )

    for col, frame_idx in enumerate(indices):
        x = pad + col * (W + pad)
        # Input row
        grid[pad:pad + H, x:x + W] = input_frames[frame_idx]
        # Method rows
        for row_i, (_, masks) in enumerate(rows):
            y = pad + (row_i + 1) * (H + pad)
            grid[y:y + H, x:x + W] = _mask_to_rgb(masks[frame_idx])

    Image.fromarray(grid).save(out_path)


def render_coverage_curves(
    curves: Dict[str, np.ndarray],
    out_path: str,
    title: str = "",
) -> None:
    """Plot per-frame mask-coverage curves, one line per method.

    Args:
        curves: dict mapping method label → (N,) float coverage array.
        out_path: output PNG path.
        title: figure title.
    """
    fig, ax = plt.subplots(figsize=(10, 4))
    for label, curve in curves.items():
        ax.plot(curve, label=label)
    ax.set_xlabel("frame")
    ax.set_ylabel("mask coverage (fraction motion)")
    ax.set_title(title)
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=100)
    plt.close(fig)
