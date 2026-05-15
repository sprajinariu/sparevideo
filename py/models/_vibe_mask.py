"""Private helper — produce per-frame motion masks via the ViBe operator.

Single source of truth used by motion_vibe / mask_vibe / ccl_bbox_vibe.
Mirrors the structure of motion.compute_motion_masks (which uses EMA),
swapping the bg block for a `models.ops.vibe.ViBe` instance.

Frame-0 convention depends on the init scheme:
  vibe_bg_init_external == 0  (frame-0 self-init):
    Frame 0 is consumed by the bank-priming pass; the output mask is
    all-zero (matches the EMA hard-init convention — no detection possible
    while the bank is being written).
  vibe_bg_init_external == 1  (lookahead-median external init):
    The bank is pre-seeded before frame 0 arrives, so frame 0 is processed
    normally by the comparators.  The RTL sets init_phase=0 in this mode;
    the Python model must do the same.  Frame 0 therefore produces a real
    mask, not an all-zero placeholder.
"""
from __future__ import annotations

import numpy as np

from models.motion import _gauss3x3, _rgb_to_y
from models.ops.vibe import ViBe


def produce_masks_vibe(
    frames: list[np.ndarray],
    *,
    vibe_K: int,
    vibe_R: int,
    vibe_min_match: int,
    vibe_phi_update: int,
    vibe_phi_diffuse: int,
    vibe_init_scheme: int,
    vibe_prng_seed: int,
    vibe_coupled_rolls: bool,
    vibe_bg_init_external: int,
    vibe_bg_init_lookahead_n: int,
    vibe_bg_init_mode: int = 0,          # 0=median, 1=imrm, 2=mvtw, 3=mam
    vibe_bg_init_imrm_tau: int = 20,
    vibe_bg_init_imrm_iters: int = 3,
    vibe_bg_init_mvtw_k: int = 24,
    vibe_bg_init_mam_delta: int = 8,
    vibe_bg_init_mam_dilate: int = 2,
    vibe_demote_en: bool = False,
    vibe_demote_K_persist: int = 30,
    vibe_demote_kernel: int = 3,
    vibe_demote_consistency_thresh: int = 1,
    gauss_en: bool = True,
    **_ignored,
) -> list[np.ndarray]:
    """Return per-frame uint8 motion masks (True/False as 0/1) under ViBe."""
    if not frames:
        return []

    # Pre-compute the Y stack (gaussian-filtered if enabled).
    y_stack = []
    for f in frames:
        y = _rgb_to_y(f)
        y_stack.append(_gauss3x3(y) if gauss_en else y)
    y_arr = np.stack(y_stack, axis=0)  # (N, H, W) uint8

    init_scheme = {0: "a", 1: "b", 2: "c"}[vibe_init_scheme]
    v = ViBe(
        K=vibe_K,
        R=vibe_R,
        min_match=vibe_min_match,
        phi_update=vibe_phi_update,
        phi_diffuse=vibe_phi_diffuse,
        init_scheme=init_scheme,
        prng_seed=vibe_prng_seed,
        coupled_rolls=vibe_coupled_rolls,
        demote_en=vibe_demote_en,
        demote_K_persist=vibe_demote_K_persist,
        demote_kernel=vibe_demote_kernel,
        demote_consistency_thresh=vibe_demote_consistency_thresh,
    )

    # Init.
    if vibe_bg_init_external == 0:       # frame0 self-init
        # Frame-0 luma is used to seed the bank (scheme-c noise via runtime PRNG).
        # The runtime PRNG is advanced ceil(K/4) times per pixel during init —
        # matching the RTL's frame-0 init_phase path exactly.
        v.init_from_frame(y_arr[0])
    elif vibe_bg_init_external == 1:     # lookahead-median external init
        # The RTL loads the bank from an externally-generated ROM
        # (gen_vibe_init_rom.py / compute_lookahead_median_bank).  That ROM uses:
        #   - raw luma (no Gaussian, regardless of gauss_en)
        #   - a domain-separated PRNG seed (vibe_prng_seed ^ ROM_OFFSET)
        # so the bank is the same whether gauss_en is True or False.
        # The RTL's runtime PRNG therefore starts from PRNG_SEED without any
        # init-phase advances — the two PRNG streams (ROM noise and runtime)
        # are completely independent.
        #
        # Python must match: use compute_lookahead_median_bank (raw luma,
        # domain-separated PRNG) to get the bank values, inject them into the
        # ViBe object directly (bypassing any runtime-PRNG advance), and leave
        # the ViBe PRNG at vibe_prng_seed so frame-0 processing starts from
        # the same state as the RTL.
        # Lazy import to avoid circular import (motion_vibe → _vibe_mask → motion_vibe).
        from models.motion_vibe import compute_lookahead_median_bank  # noqa: PLC0415
        n = vibe_bg_init_lookahead_n  # 0 = all frames (compute_lookahead_median_bank sentinel)
        _MODE_NAMES = {0: "median", 1: "imrm", 2: "mvtw", 3: "mam"}
        bank = compute_lookahead_median_bank(
            rgb_frames=frames,
            k=vibe_K,
            lookahead_n=n,
            seed=vibe_prng_seed,
            bg_init_mode=_MODE_NAMES[int(vibe_bg_init_mode)],
            bg_init_imrm_tau=int(vibe_bg_init_imrm_tau),
            bg_init_imrm_iters=int(vibe_bg_init_imrm_iters),
            bg_init_mvtw_k=int(vibe_bg_init_mvtw_k),
            bg_init_mam_delta=int(vibe_bg_init_mam_delta),
            bg_init_mam_dilate=int(vibe_bg_init_mam_dilate),
        )
        h_b, w_b, _ = bank.shape
        v.H = h_b
        v.W = w_b
        v.samples = bank
        # Demote state — init_from_frame normally sets these; the external-init
        # path bypasses it, so initialise explicitly here to match the canonical
        # priming state (fg_count=0, prev_final_bg=all-True).
        v.fg_count = np.zeros((h_b, w_b), dtype=np.uint8)
        v.prev_final_bg = np.ones((h_b, w_b), dtype=bool)
        # v.prng_state is already vibe_prng_seed (set in ViBe.__init__) — no change needed.
    else:
        raise ValueError(f"unknown vibe_bg_init_external {vibe_bg_init_external}")

    # Per-frame mask production.
    # External-init (vibe_bg_init_external==1): bank is pre-seeded before frame 0,
    # so process all frames starting from frame 0 (RTL init_phase=0 in this mode).
    # Frame-0 self-init (vibe_bg_init_external==0): frame 0 was consumed by priming;
    # output an all-zero placeholder for frame 0 to match the EMA convention, then
    # process frames 1..N-1.
    h, w = y_arr.shape[1:]
    if vibe_bg_init_external == 1:
        masks: list[np.ndarray] = []
        for i in range(y_arr.shape[0]):
            masks.append(v.process_frame(y_arr[i]))
    else:
        masks = [np.zeros((h, w), dtype=bool)]
        for i in range(1, y_arr.shape[0]):
            masks.append(v.process_frame(y_arr[i]))
    return masks
