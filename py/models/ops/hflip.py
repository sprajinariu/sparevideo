"""Horizontal flip (hflip) reference model.

Matches axis_hflip RTL: per-row reversal of pixel order, no inter-frame state,
no edge handling needed (single-axis index reversal).
"""

import numpy as np


def hflip(image: np.ndarray) -> np.ndarray:
    """Return a left-to-right mirror of `image`.

    Args:
        image: (H, W) or (H, W, C) numpy array of any dtype.

    Returns:
        New array with axis-1 reversed; input is not mutated.
    """
    return np.ascontiguousarray(np.flip(image, axis=1))
