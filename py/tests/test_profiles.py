"""Profile-dict ↔ sparevideo_pkg.sv cross-check.

The Python profile dicts in py/profiles.py must match the cfg_t localparams
in hw/top/sparevideo_pkg.sv field-for-field. Drift here causes silent
RTL/model divergence, which only shows up as a TOLERANCE=0 verify failure
buried under a noisy diff.
"""
import re
from pathlib import Path

import pytest

from profiles import PROFILES

PKG_PATH = Path(__file__).resolve().parents[2] / "hw" / "top" / "sparevideo_pkg.sv"

# Fields that exist in py/profiles.py profiles but NOT in cfg_t.
# These drive Python-only ablations (see contract spec §3).
PYTHON_ONLY_FIELDS = frozenset({
    "vibe_init_scheme",
    "vibe_prng_seed",
    "vibe_coupled_rolls",
    "vibe_bg_init_lookahead_n",
})


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


def _cfg_t_field_names() -> set[str]:
    """Return the set of field names declared inside the cfg_t struct in sparevideo_pkg.sv."""
    text = PKG_PATH.read_text()
    # Extract the struct body between 'typedef struct packed {' and '} cfg_t;'
    m = re.search(r"typedef struct packed \{(.+?)\} cfg_t;", text, re.DOTALL)
    assert m, "cfg_t struct not found in sparevideo_pkg.sv"
    struct_body = m.group(1)
    # Match field names: optional width spec, then an identifier, then ';'
    # e.g. 'logic [7:0] motion_thresh;', 'int alpha_shift;', 'logic gauss_en;'
    field_names = re.findall(
        r"(?:logic(?:\s*\[.*?\])?|int|component_t|pixel_t)\s+(\w+)\s*;",
        struct_body,
    )
    return set(field_names)


EXPECTED_PROFILES = {
    "default", "default_hflip", "no_ema", "no_morph", "no_gauss",
    "no_gamma_cor", "no_scaler", "demo", "no_hud",
    "default_vibe", "vibe_k20", "vibe_no_diffuse", "vibe_no_gauss",
    "vibe_init_frame0", "vibe_init_external",
    "pbas_default", "pbas_lookahead",
    "pbas_default_raute4", "pbas_default_raute4_rcap",
}


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
        if field in PYTHON_ONLY_FIELDS:
            continue
        sv_raw = _sv_field(block, field)
        sv_val = _parse_int(sv_raw)
        assert sv_val == int(py_val), (
            f"{sv_name}.{field}: SV={sv_val} Py={py_val}"
        )


def test_python_only_fields_match_cfg_t_absence():
    """PYTHON_ONLY_FIELDS must equal exactly the keys in DEFAULT_VIBE
    that are NOT present in the SV cfg_t struct.
    Catches drift if a field migrates between RTL and Python without
    updating the allowlist."""
    from profiles import DEFAULT_VIBE
    sv_fields = _cfg_t_field_names()
    py_fields = set(DEFAULT_VIBE.keys())
    expected_python_only = py_fields - sv_fields
    assert PYTHON_ONLY_FIELDS == expected_python_only, (
        f"PYTHON_ONLY_FIELDS drift: "
        f"expected {expected_python_only}, got {PYTHON_ONLY_FIELDS}. "
        f"Either update the allowlist or move the field between RTL/Python."
    )
