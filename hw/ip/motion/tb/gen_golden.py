#!/usr/bin/env python3
"""Generate golden files for tb_axis_motion_detect_vibe Test 2/2b (K=8), Test 3 (K=20),
and Test 4 (external-init ghost suppression).

Usage:
  python gen_golden.py          # generate K=8 golden files (Test 2/2b)
  python gen_golden.py --k 20   # generate K=20 golden files (Test 3)
  python gen_golden.py --k 8    # same as default
  python gen_golden.py --test4  # generate Test 4 init bank (.mem)

K=8 outputs:
  hw/ip/motion/tb/golden/test2_input.bin
      12-byte header (W, H, N_FRAMES as LE uint32) + N_FRAMES * W * H * 3
      raw RGB bytes (raster order, one byte per channel).

  hw/ip/motion/tb/golden/test2_ghost_box_disappear.bin
      12-byte header (W, H, N_FRAMES as LE uint32) + N_FRAMES * W * H
      mask bytes (0 = bg, 1 = motion), raster order.

K=20 outputs:
  hw/ip/motion/tb/golden/test3_k20_input.bin            (same pattern, same seed)
  hw/ip/motion/tb/golden/test3_k20_ghost_box_disappear.bin

  Printed to stdout:
      Ghost ROI coordinates (used to select the coverage region in Test 2b/3b).
      Per-frame coverage inside the ghost ROI.
      avg_early  = mean(coverage[10:30])
      avg_late   = mean(coverage[150:200])
      ratio      = avg_late / avg_early
      threshold  = 1.25 * ratio   (paste this value into the TB)

Test 4 outputs (--test4):
  hw/ip/motion/tb/golden/test4_input.bin
      Same format as test2_input.bin but for T4_FRAMES frames.
  hw/ip/motion/tb/golden/test4_init_bank.mem
      $readmemh-compatible hex file (K slots per pixel, raster order).
      Generated via lookahead-median over the first 30 frames.

Parameters match the RTL defaults:
  WIDTH=32, HEIGHT=16, GAUSS_EN=0, PRNG_SEED=0xDEADBEEF
  vibe_bg_init_external=0  (frame-0 self-init, NOT lookahead-median)
  vibe_coupled_rolls=True  (one PRNG advance/pixel, coupled update+diffusion)
"""

import argparse
import struct
import sys
from pathlib import Path

import numpy as np

# --- resolve project root so we can import py/ packages ----------------------
_REPO_ROOT = Path(__file__).resolve().parents[4]  # hw/ip/motion/tb/gen_golden.py -> repo root
sys.path.insert(0, str(_REPO_ROOT / "py"))

from frames.video_source import load_frames
from models._vibe_mask import produce_masks_vibe
from models.motion_vibe import compute_lookahead_median_bank

# ---------------------------------------------------------------------------
# Constants — must match TB parameters
# ---------------------------------------------------------------------------
WIDTH     = 32
HEIGHT    = 16
N_FRAMES  = 200
GAUSS_EN  = False

# Test 4 constants
T4_FRAMES        = 60    # frames to drive into the DUT in Test 4
T4_LOOKAHEAD_N   = 30   # frames to median over for init bank
T4_K             = 8    # K=8 (same as default profile)
T4_PRNG_SEED     = 0xDEADBEEF

# Ghost ROI from _gen_ghost_box_disappear (width/4 x height/4, centred):
#   box_w = WIDTH // 4 = 8
#   box_h = HEIGHT // 4 = 4
#   cx    = (WIDTH  - box_w) // 2 = 12
#   cy    = (HEIGHT - box_h) // 2 = 6
GHOST_BOX_W = WIDTH  // 4     # 8
GHOST_BOX_H = HEIGHT // 4     # 4
GHOST_CX    = (WIDTH  - GHOST_BOX_W) // 2   # 12
GHOST_CY    = (HEIGHT - GHOST_BOX_H) // 2   # 6

# ---------------------------------------------------------------------------
# Output paths
# ---------------------------------------------------------------------------
GOLDEN_DIR = Path(__file__).parent / "golden"


def write_bin_header(f, width: int, height: int, n_frames: int) -> None:
    """Write 12-byte LE uint32 header: (width, height, n_frames)."""
    f.write(struct.pack("<III", width, height, n_frames))


def run(k: int) -> None:
    """Generate golden files for the given K value and print coverage stats."""
    GOLDEN_DIR.mkdir(parents=True, exist_ok=True)

    # File paths depend on K.
    if k == 8:
        input_bin   = GOLDEN_DIR / "test2_input.bin"
        golden_mask = GOLDEN_DIR / "test2_ghost_box_disappear.bin"
        test_label  = "Test 2/2b"
    else:
        input_bin   = GOLDEN_DIR / f"test3_k{k}_input.bin"
        golden_mask = GOLDEN_DIR / f"test3_k{k}_ghost_box_disappear.bin"
        test_label  = f"Test 3 (K={k})"

    # Profile parameters — matching RTL axis_motion_detect_vibe defaults
    # for the given K; all other fields are K-independent.
    vibe_params = dict(
        vibe_K                   = k,
        vibe_R                   = 20,
        vibe_min_match           = 2,
        vibe_phi_update          = 16,
        vibe_phi_diffuse         = 16,
        vibe_init_scheme         = 2,          # scheme "c" (noise-based)
        vibe_prng_seed           = 0xDEADBEEF,
        vibe_coupled_rolls       = True,
        vibe_bg_init_external    = 0,          # 0 = frame-0 self-init
        vibe_bg_init_lookahead_n = 0,          # unused when vibe_bg_init_external=0
        gauss_en                 = GAUSS_EN,
    )

    # --- 1. Generate input frames -------------------------------------------
    print(f"[{test_label}] Generating {N_FRAMES} frames of "
          f"synthetic:ghost_box_disappear at {WIDTH}x{HEIGHT} ...")
    frames = load_frames(
        "synthetic:ghost_box_disappear",
        width=WIDTH,
        height=HEIGHT,
        num_frames=N_FRAMES,
    )
    assert len(frames) == N_FRAMES, f"Expected {N_FRAMES} frames, got {len(frames)}"

    # --- 2. Write input RGB binary file for the TB --------------------------
    print(f"[{test_label}] Writing input file: {input_bin}")
    with open(input_bin, "wb") as f:
        write_bin_header(f, WIDTH, HEIGHT, N_FRAMES)
        for frame in frames:
            assert frame.shape == (HEIGHT, WIDTH, 3), \
                f"Unexpected frame shape {frame.shape}"
            f.write(frame.tobytes())  # RGB, row-major

    # --- 3. Run Python ViBe reference model ---------------------------------
    print(f"[{test_label}] Running Python ViBe reference model (K={k}) ...")
    masks = produce_masks_vibe(frames, **vibe_params)
    assert len(masks) == N_FRAMES, f"Expected {N_FRAMES} masks, got {len(masks)}"

    # --- 4. Write golden mask binary file -----------------------------------
    print(f"[{test_label}] Writing golden mask file: {golden_mask}")
    with open(golden_mask, "wb") as f:
        write_bin_header(f, WIDTH, HEIGHT, N_FRAMES)
        for mask in masks:
            assert mask.shape == (HEIGHT, WIDTH), \
                f"Unexpected mask shape {mask.shape}"
            f.write(mask.astype(np.uint8).tobytes())

    # --- 5. Coverage analysis -----------------------------------------------
    print(f"\n--- [{test_label}] Ghost ROI coverage analysis ---")
    print(f"Ghost ROI: rows [{GHOST_CY}:{GHOST_CY+GHOST_BOX_H}], "
          f"cols [{GHOST_CX}:{GHOST_CX+GHOST_BOX_W}]")
    print(f"Ghost ROI size: {GHOST_BOX_W}×{GHOST_BOX_H} = "
          f"{GHOST_BOX_W * GHOST_BOX_H} pixels")

    roi_area = GHOST_BOX_W * GHOST_BOX_H
    coverages = []
    for mask in masks:
        roi = mask[GHOST_CY:GHOST_CY + GHOST_BOX_H,
                   GHOST_CX:GHOST_CX + GHOST_BOX_W]
        cov = float(roi.sum()) / roi_area
        coverages.append(cov)

    # Print per-frame summary (every 10th frame for brevity)
    print("\nPer-frame ROI coverage (every 10th frame):")
    for i in range(0, N_FRAMES, 10):
        print(f"  frame {i:3d}: {coverages[i]:.4f}")

    # Early window: frames 10..29; Late window: frames 150..199
    early_slice = coverages[10:30]
    late_slice  = coverages[150:200]

    avg_early = float(np.mean(early_slice))
    avg_late  = float(np.mean(late_slice))

    print(f"\navg_early (frames 10-29):  {avg_early:.6f}")
    print(f"avg_late  (frames 150-199): {avg_late:.6f}")

    if avg_early <= 0.0:
        print("WARNING: avg_early == 0.0 — ghost ROI has zero coverage in early window.")
        print("  Coverage decay test cannot compute a meaningful ratio.")
        ratio     = float("nan")
        threshold = float("nan")
    else:
        ratio     = avg_late / avg_early
        threshold = 1.25 * ratio

    print(f"\nratio      = avg_late / avg_early = {ratio:.6f}")
    print(f"threshold  = 1.25 * ratio         = {threshold:.6f}")

    tb_name = "tb_axis_motion_detect_vibe.sv" if k == 8 \
              else f"tb_axis_motion_detect_vibe_k{k}.sv"
    test_name = "Test 2b" if k == 8 else f"Test 3b (K={k})"
    print()
    print(f"==> Paste the following into {tb_name} {test_name}:")
    print(f"    // Measured ratio avg_late/avg_early = {ratio:.6f}")
    print(f"    // (avg_early frames 10-29 = {avg_early:.6f}, "
          f"avg_late frames 150-199 = {avg_late:.6f})")
    print(f"    // Threshold = 1.25 * measured_ratio")
    print(f"    localparam real T{'2' if k==8 else '3'}bThreshold = {threshold:.6f};")
    print()
    print("Done.")


def _write_mem(out_path, bank: "np.ndarray", k: int) -> None:
    """Write a $readmemh-compatible hex file from a (H, W, K) uint8 bank.

    Format: one line per pixel (raster scan, top-left first).
    Each line is 2*K hex chars, MSB-first:
        chars [0:1]         = slot[K-1]  (highest-index sample)
        chars [2*K-2:2*K-1] = slot[0]   (lowest-index sample)
    Matches the SV concatenation ``{slot[K-1], ..., slot[0]}``.
    """
    h, w, _k = bank.shape
    assert _k == k
    with open(out_path, "w") as f:
        f.write("// generated by hw/ip/motion/tb/gen_golden.py --test4\n")
        f.write(f"// width={w} height={h} K={k} "
                f"seed=0x{T4_PRNG_SEED:08X} lookahead_n={T4_LOOKAHEAD_N}\n")
        for r in range(h):
            for c in range(w):
                # MSB-first: slot[K-1] in the most-significant bytes.
                hex_str = "".join(
                    f"{bank[r, c, k - 1 - slot]:02x}" for slot in range(k)
                )
                f.write(hex_str + "\n")


def run_test4() -> None:
    """Generate Test 4 golden files: init bank (.mem) + input frames (.bin).

    Produces:
      golden/test4_input.bin       — T4_FRAMES frames of ghost_box_disappear
      golden/test4_init_bank.mem   — lookahead-median bank from first 30 frames
    """
    import numpy as np  # local import to mirror run()

    GOLDEN_DIR.mkdir(parents=True, exist_ok=True)

    input_bin  = GOLDEN_DIR / "test4_input.bin"
    bank_mem   = GOLDEN_DIR / "test4_init_bank.mem"

    print(f"[Test 4] Generating {T4_FRAMES} frames of "
          f"synthetic:ghost_box_disappear at {WIDTH}x{HEIGHT} ...")
    frames = load_frames(
        "synthetic:ghost_box_disappear",
        width=WIDTH,
        height=HEIGHT,
        num_frames=T4_FRAMES,
    )
    assert len(frames) == T4_FRAMES, f"Expected {T4_FRAMES} frames, got {len(frames)}"

    # --- Write input RGB binary for the TB ----------------------------------
    print(f"[Test 4] Writing input file: {input_bin}")
    with open(input_bin, "wb") as f:
        write_bin_header(f, WIDTH, HEIGHT, T4_FRAMES)
        for frame in frames:
            assert frame.shape == (HEIGHT, WIDTH, 3)
            f.write(frame.tobytes())

    # --- Compute lookahead-median bank --------------------------------------
    print(f"[Test 4] Computing lookahead-median bank "
          f"(K={T4_K}, lookahead_n={T4_LOOKAHEAD_N}) ...")
    bank = compute_lookahead_median_bank(
        frames,
        k=T4_K,
        lookahead_n=T4_LOOKAHEAD_N,
        seed=T4_PRNG_SEED,
    )
    assert bank.shape == (HEIGHT, WIDTH, T4_K), \
        f"Unexpected bank shape {bank.shape}"

    # --- Write .mem file ----------------------------------------------------
    print(f"[Test 4] Writing init bank: {bank_mem}")
    _write_mem(bank_mem, bank, T4_K)

    # --- Coverage analysis on frame-1 ghost ROI using external-init ViBe ---
    # With VIBE_BG_INIT_EXTERNAL=1, init_phase=0 in the RTL, so frame-0 is
    # processed normally: red box pixels don't match the background bank →
    # mask=1 (correct motion detection).  The Python model now matches this
    # behaviour (it processes frame 0 normally when vibe_bg_init_external==1).
    # The ghost check must therefore use frame 1 (the first frame after the
    # box disappears).
    #
    # Python model frame-1 with external-init: bank holds background (black);
    # black background pixels match → mask=0 → coverage=0.  Confirmed below.
    print(f"[Test 4] Running Python ViBe reference with external-init bank ...")
    masks = produce_masks_vibe(
        frames,
        vibe_K                   = T4_K,
        vibe_R                   = 20,
        vibe_min_match           = 2,
        vibe_phi_update          = 16,
        vibe_phi_diffuse         = 16,
        vibe_init_scheme         = 2,
        vibe_prng_seed           = T4_PRNG_SEED,
        vibe_coupled_rolls       = True,
        vibe_bg_init_external    = 1,          # use lookahead-median bank
        vibe_bg_init_lookahead_n = T4_LOOKAHEAD_N,
        gauss_en                 = GAUSS_EN,
    )

    roi_area = GHOST_BOX_W * GHOST_BOX_H
    frame1_roi = masks[1][GHOST_CY:GHOST_CY + GHOST_BOX_H,
                           GHOST_CX:GHOST_CX + GHOST_BOX_W]
    cov1 = float(frame1_roi.sum()) / roi_area

    print(f"\n--- [Test 4] Ghost ROI coverage analysis ---")
    print(f"Ghost ROI: rows [{GHOST_CY}:{GHOST_CY+GHOST_BOX_H}], "
          f"cols [{GHOST_CX}:{GHOST_CX+GHOST_BOX_W}]")
    print(f"Frame-1 ghost ROI coverage (Python model): {cov1:.6f}")
    print(f"  (frame-0 mask forced to 0 by Python model convention)")
    print(f"  (RTL frame-0 has high coverage — red box correctly detected as motion)")
    print(f"Threshold (T4):                             0.010000 (1%)")
    if cov1 < 0.01:
        print("==> PASS: frame-1 ghost coverage below 1% threshold")
    else:
        print("==> WARNING: frame-1 ghost coverage ABOVE 1% threshold — check init bank")

    print()
    print("Done.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate ViBe TB golden files")
    parser.add_argument("--k", type=int, default=8,
                        help="ViBe K parameter (default: 8, also supports 20)")
    parser.add_argument("--test4", action="store_true",
                        help="Generate Test 4 files (external-init bank + input frames)")
    args = parser.parse_args()
    if args.test4:
        run_test4()
    else:
        if args.k not in (8, 20):
            parser.error(f"--k must be 8 or 20, got {args.k}")
        run(args.k)


if __name__ == "__main__":
    main()
