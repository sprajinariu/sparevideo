"""Test that gen_vibe_init_rom.py produces a bank byte-equivalent to
the Python ref's in-process lookahead-median init."""
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

# Locate repo root (two levels up from this file: py/tests/ → py/ → repo root).
REPO_ROOT = Path(__file__).parent.parent.parent

from frames.video_source import generate_synthetic
from frames.frame_io import write_frames
from profiles import PROFILES


@pytest.mark.parametrize("k", [8, 20])
def test_rom_matches_ref_bank(tmp_path, k):
    width, height, n_frames = 32, 16, 30
    profile = dict(PROFILES["default_vibe"])
    profile["vibe_K"] = k
    seed = profile["vibe_prng_seed"]

    rgb_frames = generate_synthetic("moving_box", width, height, n_frames)
    input_bin = tmp_path / "input.bin"
    write_frames(str(input_bin), rgb_frames, mode="binary")

    output_mem = tmp_path / "init_bank.mem"

    # Generate ROM via CLI (run from repo root so relative imports work).
    subprocess.check_call(
        [
            sys.executable,
            str(REPO_ROOT / "py" / "gen_vibe_init_rom.py"),
            "--input",       str(input_bin),
            "--output",      str(output_mem),
            "--width",       str(width),
            "--height",      str(height),
            "--k",           str(k),
            "--lookahead-n", "0",
            "--seed",        str(seed),
        ],
        cwd=str(REPO_ROOT),
    )

    # Independently compute the bank in-process.
    from models.motion_vibe import compute_lookahead_median_bank
    expected_bank = compute_lookahead_median_bank(
        rgb_frames, k=k, lookahead_n=0, seed=seed,
    )
    # expected_bank shape: (height, width, k), dtype uint8

    # Parse the .mem file.
    actual = _parse_mem_file(output_mem, width, height, k)
    assert np.array_equal(actual, expected_bank), (
        f"K={k}: mismatched bank bytes at "
        f"{np.argwhere(actual != expected_bank)[:5].tolist()}"
    )


def _parse_mem_file(path, w, h, k):
    """Parse $readmemh hex format, return (h, w, k) uint8 array.

    Each data line is exactly 2*k hex characters long, MSB-first:
    first 2 chars = slot[k-1], last 2 chars = slot[0].
    Lines starting with '//' are comments and are skipped.
    """
    hex_chars_per_pixel = 2 * k
    bank = np.zeros((h, w, k), dtype=np.uint8)
    idx = 0
    with open(path) as f:
        for line in f:
            line = line.split("//")[0].strip()
            if not line:
                continue
            if len(line) != hex_chars_per_pixel:
                raise ValueError(
                    f"line {idx}: expected {hex_chars_per_pixel} hex chars, got {len(line)!r}"
                )
            y, x = divmod(idx, w)
            for slot in range(k):
                # MSB-first: first 2 hex chars = slot[k-1], last 2 = slot[0].
                start = (k - 1 - slot) * 2
                bank[y, x, slot] = int(line[start : start + 2], 16)
            idx += 1
    assert idx == w * h, f"expected {w * h} pixels in .mem, got {idx}"
    return bank
