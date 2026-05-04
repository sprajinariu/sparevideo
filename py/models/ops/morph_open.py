"""3x3 morphological opening (erode then dilate) with edge replication.

Matches axis_morph3x3_erode/axis_morph3x3_dilate RTL (sub-stages of axis_morph_clean): 3x3 square structuring element, EDGE_REPLICATE
border policy at all four borders, single pass.
"""

import numpy as np
from scipy.ndimage import grey_erosion, grey_dilation


def morph_open(mask: np.ndarray) -> np.ndarray:
    """Apply 3x3 opening to a 2D boolean mask.

    Args:
        mask: (H, W) boolean array. True = foreground.

    Returns:
        (H, W) boolean array — mask after erosion then dilation.
    """
    if mask.dtype != bool:
        raise TypeError(f"morph_open expects bool mask, got {mask.dtype}")
    u8 = mask.astype(np.uint8)
    eroded  = grey_erosion (u8, size=(3, 3), mode='nearest')
    dilated = grey_dilation(eroded, size=(3, 3), mode='nearest')
    return dilated.astype(bool)
