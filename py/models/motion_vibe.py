"""Motion control-flow reference model — ViBe bg variant.

Same head/tail as models/motion.py (RGB→Y, gauss, morph_clean, CCL,
overlay) but the bg-subtraction block is ViBe instead of EMA. Wired in
when the active profile sets `bg_model = BG_MODEL_VIBE = 1`.

Frame-0 priming convention matches the EMA path: mask is all-zero on
frame 0, no bboxes drawn. From frame 1 onward the ViBe bank produces
masks normally. See models/_vibe_mask.py for the shared producer.

Also exports `compute_lookahead_median_bank`, the in-process equivalent of
`py/gen_vibe_init_rom.py`, used for parity testing and as the single source
of truth for the lookahead-median bank algorithm.
"""
from __future__ import annotations

import numpy as np

from models._vibe_mask import produce_masks_vibe
from models.ccl import run_ccl
from models.motion import (
    N_OUT, N_LABELS_INT, MIN_COMPONENT_PIXELS, MAX_CHAIN_DEPTH,
    PRIME_FRAMES, _draw_bboxes, _rgb_to_y,
)
from models.ops.bg_init import compute_bg_estimate
from models.ops.morph_open import morph_open
from models.ops.morph_close import morph_close
from models.ops.vibe import INIT_SEED_MAGICS
from models.ops.xorshift import xorshift32

# Domain-separation constant: XOR'd with the user seed before advancing
# the ROM-generator PRNG so its state never collides with the RTL's
# self-init stream (which starts directly from the seed).
_ROM_SEED_DOMAIN_OFFSET = 0x4F495E11


def run(
    frames: list[np.ndarray],
    *,
    morph_open_en: bool = True,
    morph_close_en: bool = True,
    morph_close_kernel: int = 3,
    **vibe_kwargs,
) -> list[np.ndarray]:
    """Motion ctrl_flow under ViBe bg.

    Reuses motion.py constants and _draw_bboxes for parity with the EMA
    output convention. Per-frame steps:
      1. produce_masks_vibe → raw mask
      2. morph_open  (if enabled)
      3. morph_close (if enabled)
      4. run_ccl on the cleaned mask → bboxes (1-frame delay vs EMA path)
      5. _draw_bboxes(prev frame's bboxes, current rgb frame)
    """
    if not frames:
        return []

    # ViBe needs the unfiltered RGB stack; the helper handles gauss internally.
    raw_masks = produce_masks_vibe(frames, **vibe_kwargs)

    cleaned: list[np.ndarray] = []
    for m in raw_masks:
        c = m
        if morph_open_en:
            c = morph_open(c)
        if morph_close_en:
            c = morph_close(c, kernel=morph_close_kernel)
        cleaned.append(c)

    bboxes_state = [None] * N_OUT
    outputs: list[np.ndarray] = []
    for i, frame in enumerate(frames):
        out = _draw_bboxes(frame, bboxes_state)
        new_bboxes = run_ccl(
            [cleaned[i]],
            n_out=N_OUT,
            n_labels_int=N_LABELS_INT,
            min_component_pixels=MIN_COMPONENT_PIXELS,
            max_chain_depth=MAX_CHAIN_DEPTH,
        )[0]
        primed_for_bbox = (i >= PRIME_FRAMES)
        bboxes_state = new_bboxes if primed_for_bbox else [None] * N_OUT
        outputs.append(out)

    return outputs


def compute_lookahead_median_bank(
    rgb_frames: list[np.ndarray],
    *,
    k: int,
    lookahead_n: int,
    seed: int,
    bg_init_mode: str = "median",
    bg_init_imrm_tau: int = 20,
    bg_init_imrm_iters: int = 3,
    bg_init_mvtw_k: int = 24,
    bg_init_mam_delta: int = 8,
    bg_init_mam_dilate: int = 2,
) -> np.ndarray:
    """Compute the ViBe sample bank from a lookahead-median of RGB frames.

    Mirrors the algorithm in ``py/gen_vibe_init_rom.py`` exactly so the two
    implementations can be parity-tested against each other.

    Algorithm:
      1. Convert each RGB frame to luma Y using project coefficients
         (77*R + 150*G + 29*B) >> 8 — matches ``_rgb_to_y`` / ``rgb2ycrcb.sv``.
      2. Compute the per-pixel BG estimate over the first ``lookahead_n``
         frames (0 = all frames). Method is selected by ``bg_init_mode``:
         "median" (default, paper-canonical), "imrm", "mvtw", or "mam".
         See py/models/ops/bg_init.py.
      3. Seed a base as ``(seed ^ _ROM_SEED_DOMAIN_OFFSET) & 0xFFFFFFFF`` to
         avoid colliding with the RTL's self-init PRNG stream.  Construct
         N = ceil(K / 4) parallel Xorshift32 streams, each seeded as
         ``(base ^ INIT_SEED_MAGICS[i]) & 0xFFFFFFFF``.
      4. For each pixel (raster scan order), advance ALL N streams once each.
         Concatenate the resulting state words into a noise pool; slice K bytes.
         Apply noise = ``(byte % 41) - 20`` to the median luma, clamp [0, 255].

    Args:
        rgb_frames: List of (H, W, 3) uint8 RGB frames.  Must be non-empty.
        k:          Number of ViBe sample slots.  Typically 8 or 20.
        lookahead_n: Number of leading frames to median over.
                     0 is a sentinel meaning "all available frames".
        seed:       ViBe PRNG seed (``vibe_prng_seed`` from the profile).

    Returns:
        (H, W, K) uint8 array — the initialised sample bank.
    """
    if not rgb_frames:
        raise ValueError("rgb_frames must be non-empty")

    # Stack luma frames.
    y_stack = np.stack([_rgb_to_y(f) for f in rgb_frames], axis=0)  # (N, H, W)
    n_total = y_stack.shape[0]
    n = n_total if lookahead_n == 0 else int(lookahead_n)
    if not (1 <= n <= n_total):
        raise ValueError(
            f"lookahead_n={lookahead_n} out of range [1, {n_total}]"
        )

    # Per-pixel BG estimate over the lookahead window → (H, W) uint8.
    median = compute_bg_estimate(
        y_stack[:n],
        mode=bg_init_mode,
        imrm_tau=bg_init_imrm_tau,
        imrm_iters=bg_init_imrm_iters,
        mvtw_k=bg_init_mvtw_k,
        mam_delta=bg_init_mam_delta,
        mam_dilate=bg_init_mam_dilate,
    )
    h, w = median.shape

    # Domain-separated base seed (avoids collision with self-init PRNG state).
    base = (seed ^ _ROM_SEED_DOMAIN_OFFSET) & 0xFFFFFFFF

    # Parallel streams — same construction as ViBe._init_scheme_c.
    n_streams = (k + 3) // 4
    states = [(base ^ INIT_SEED_MAGICS[i]) & 0xFFFFFFFF for i in range(n_streams)]
    for i, s in enumerate(states):
        if s == 0:
            raise ValueError(
                f"compute_lookahead_median_bank stream {i} would be zero")

    bank = np.zeros((h, w, k), dtype=np.uint8)
    for r in range(h):
        for c in range(w):
            for i in range(n_streams):
                states[i] = xorshift32(states[i])
            y_val = int(median[r, c])
            for slot in range(k):
                stream_idx = slot // 4
                byte_idx   = slot % 4
                byte       = (states[stream_idx] >> (8 * byte_idx)) & 0xFF
                noise      = (byte % 41) - 20
                val        = y_val + noise
                bank[r, c, slot] = 0 if val < 0 else (255 if val > 255 else val)
    return bank
