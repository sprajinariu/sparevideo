"""Deterministic Xorshift32 PRNG.

Mirrors the SV implementation that will live in axis_motion_detect_vibe.sv.
Same shifts (13, 17, 5), same masking discipline (32-bit unsigned).

Golden values pinned in py/tests/test_xorshift.py. Any change here MUST
update the SV mirror identically — TOLERANCE=0 verify depends on bit-exact
parity.
"""


def xorshift32(state: int) -> int:
    """Advance Xorshift32 state by one step, return the new state.

    Args:
        state: 32-bit unsigned PRNG state. Must be non-zero (0 is a fixed point).

    Returns:
        New 32-bit unsigned state.
    """
    state ^= (state << 13) & 0xFFFFFFFF
    state ^= (state >> 17)
    state ^= (state << 5) & 0xFFFFFFFF
    return state & 0xFFFFFFFF
