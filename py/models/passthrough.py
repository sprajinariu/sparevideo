"""Passthrough control flow reference model.

The passthrough pipeline is identity — output equals input with no processing.
"""

import numpy as np


def run(frames, **kwargs):
    """Return copies of the input frames (identity model).

    Args:
        frames: List of numpy arrays (H, W, 3), dtype uint8, RGB order.

    Returns:
        List of numpy arrays identical to input.
    """
    return [f.copy() for f in frames]
