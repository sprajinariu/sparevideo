"""3x3 / 5x5 morphological closing (dilate then erode) with edge replication.

Mirrors the future axis_morph_clean RTL close stage: dilation by a square
structuring element followed by erosion by the same SE, EDGE_REPLICATE
border policy at all four borders (scipy mode='nearest').
"""

import numpy as np
from scipy.ndimage import grey_dilation, grey_erosion


def morph_close(mask: np.ndarray, *, kernel: int) -> np.ndarray:
    """Apply a square morphological closing to a 2D boolean mask.

    Args:
        mask: (H, W) boolean array. True = foreground.
        kernel: 3 or 5. The structuring element is a kernel x kernel square.

    Returns:
        (H, W) boolean array — mask after dilation then erosion.
    """
    if kernel not in (3, 5):
        raise ValueError(f"kernel must be 3 or 5, got {kernel}")
    if mask.dtype != bool:
        raise TypeError(f"morph_close expects bool mask, got {mask.dtype}")
    u8 = mask.astype(np.uint8)
    dilated = grey_dilation(u8,      size=(kernel, kernel), mode='nearest')
    eroded  = grey_erosion (dilated, size=(kernel, kernel), mode='nearest')
    return eroded.astype(bool)
