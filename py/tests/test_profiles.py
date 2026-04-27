"""Profile-dict ↔ sparevideo_pkg.sv cross-check.

The Python profile dicts in py/profiles.py must match the cfg_t localparams
in hw/top/sparevideo_pkg.sv field-for-field. Drift here causes silent
RTL/model divergence, which only shows up as a TOLERANCE=0 verify failure
buried under a noisy diff.
"""
from pathlib import Path

import pytest

from profiles import PROFILES

PKG_PATH = Path(__file__).resolve().parents[2] / "hw" / "top" / "sparevideo_pkg.sv"


def _sv_field(block: str, name: str) -> str:
    """Return the rhs of `name: <value>` inside an SV '{...}' assignment block.

    Tolerant of trailing commas and `// inline comments`.
    """
    for line in block.splitlines():
        line = line.split("//", 1)[0].strip().rstrip(",")
        if line.startswith(f"{name}:"):
            return line.split(":", 1)[1].strip()
    raise AssertionError(f"field {name!r} not found in block")


def _parse_int(sv: str) -> int:
    """Parse simple SV literals: decimal, 8'dNN, 24'hNNNNNN, 1'b0."""
    sv = sv.strip()
    if "'" in sv:
        _, rest = sv.split("'", 1)
        base, digits = rest[0], rest[1:]
        return int(digits, {"d": 10, "h": 16, "b": 2}[base])
    return int(sv)


EXPECTED_PROFILES = {"default", "default_hflip", "no_ema", "no_morph", "no_gauss", "no_gamma_cor"}


def test_profile_set_is_complete() -> None:
    """Catch accidental addition or removal of a profile.

    The parametrized parity test below derives its cases from PROFILES,
    so a deleted profile would silently lose coverage. This test asserts
    the profile set is exactly what we declared, independently.
    """
    assert set(PROFILES.keys()) == EXPECTED_PROFILES


@pytest.mark.parametrize("name", list(PROFILES.keys()))
def test_profile_matches_sv(name: str) -> None:
    sv_name = f"CFG_{name.upper()}"
    text = PKG_PATH.read_text()
    needle = f"localparam cfg_t {sv_name} = '"
    start = text.index(needle)
    block = text[start : text.index("};", start)]

    py_cfg = PROFILES[name]
    for field, py_val in py_cfg.items():
        sv_val = _parse_int(_sv_field(block, field))
        assert sv_val == int(py_val), (
            f"{sv_name}.{field}: SV={sv_val} Py={py_val}"
        )
