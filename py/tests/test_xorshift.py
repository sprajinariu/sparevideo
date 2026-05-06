"""Golden-sequence test for the Xorshift32 PRNG.

This test pins the PRNG output bit-exactly. If it ever fails, the SV mirror
in axis_motion_detect_vibe will diverge from the Python ref → TOLERANCE=0
verify breaks. Do not modify the golden sequence without also updating the SV.
"""

from models.ops.xorshift import xorshift32


def test_xorshift32_seed_dead_beef_first_8():
    """First 8 advances of Xorshift32 from seed 0xDEADBEEF."""
    state = 0xDEADBEEF
    expected = [
        0x477D20B7,
        0x8E1D9142,
        0xBA8C2458,
        0xFEE0503B,
        0x680E0348,
        0xA48DB81B,
        0x6254EA5C,
        0x1CFDAFB3,
    ]
    seq = []
    for _ in range(8):
        state = xorshift32(state)
        seq.append(state)
    assert seq == expected, f"PRNG drift; got {[hex(s) for s in seq]}"


def test_xorshift32_returns_32bit():
    """Output must always fit in 32 bits."""
    state = 1
    for _ in range(1000):
        state = xorshift32(state)
        assert 0 <= state < (1 << 32), f"state {state:#x} not 32-bit"


def test_xorshift32_zero_state_is_a_fixed_point():
    """Zero is a known fixed point of Xorshift32 — must NEVER be used as seed."""
    assert xorshift32(0) == 0
