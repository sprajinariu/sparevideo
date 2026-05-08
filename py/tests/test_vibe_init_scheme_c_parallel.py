"""Parallel-stream init scheme c: independent Xorshift32 streams for init noise.

Each lane gets one byte from a distinct stream; streams are seeded as
PRNG_SEED ^ MAGIC_i for fixed magic constants. Bit-exact regression test —
locks in the magic constants and stream allocation.
"""
import numpy as np
import pytest
from models.ops.vibe import ViBe
from models.ops.xorshift import xorshift32


SEED = 0xDEADBEEF
MAGIC_0 = 0x00000000           # base stream uses SEED unchanged
MAGIC_1 = 0x9E3779B9
MAGIC_2 = 0xD1B54A32
MAGIC_3 = 0xCAFEBABE
MAGIC_4 = 0x12345678
MAGICS = (MAGIC_0, MAGIC_1, MAGIC_2, MAGIC_3, MAGIC_4)


def _expected_bank_for_constant_y(k: int, y: int, h: int, w: int) -> np.ndarray:
    """Compute expected K-slot bank for a constant-Y frame using parallel streams."""
    n_streams = (k + 3) // 4
    states = [(SEED ^ MAGICS[i]) & 0xFFFFFFFF for i in range(n_streams)]
    bank = np.zeros((h, w, k), dtype=np.uint8)
    for r in range(h):
        for c in range(w):
            for i in range(n_streams):
                states[i] = xorshift32(states[i])
            for slot in range(k):
                stream_idx = slot // 4
                byte_idx   = slot % 4
                byte       = (states[stream_idx] >> (8 * byte_idx)) & 0xFF
                noise      = (byte % 41) - 20
                v = y + noise
                bank[r, c, slot] = max(0, min(255, v))
    return bank


@pytest.mark.parametrize("k", [4, 8, 20])
def test_init_scheme_c_parallel_streams(k):
    """Init bank for a constant-Y frame matches the parallel-stream construction."""
    h, w, y = 8, 12, 100
    frame_0 = np.full((h, w), y, dtype=np.uint8)

    v = ViBe(K=k, prng_seed=SEED, init_scheme="c")
    v.init_from_frame(frame_0)

    expected = _expected_bank_for_constant_y(k, y, h, w)
    np.testing.assert_array_equal(v.samples, expected)
