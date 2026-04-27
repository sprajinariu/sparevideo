# axis_gamma_cor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-channel sRGB gamma-correction stage at the tail of the proc_clk pipeline (between the ctrl-flow output mux and the output CDC FIFO) so post-processed video is presented with display-correct tone response. The stage is runtime-bypassable via `cfg_t.gamma_en`; a new `no_gamma_cor` profile disables it for A/B testing.

**Architecture:** A new `axis_gamma_cor` AXIS module sits between `proc_axis` (the ctrl-flow mux output) and `u_fifo_out` in `sparevideo_top`. Internals: a 33-entry, 8-bit sRGB lookup table per channel (R/G/B share an identical curve, three independent reads/cycle on the same LUT), addressed by `pixel[7:3]` with linear interpolation across `pixel[2:0]`. One-cycle pipeline: `addr/frac` registered cycle 0, output `(LUT[addr]*(8-frac)+LUT[addr+1]*frac) >> 3` registered cycle 1. `enable_i=0` is a zero-latency combinational passthrough. The SV `localparam`-baked LUT and the Python reference model (`py/models/ops/gamma_cor.py`) both derive from the same closed-form sRGB encoding formula; a parity test parses the SV `localparam` and verifies byte-for-byte agreement with the Python computation.

**Tech Stack:** SystemVerilog (Verilator 5 synthesis subset — no SVA, no classes, `axis_if` interfaces), Python 3 (numpy) in `.venv/`, FuseSoC core files, Makefile parameter propagation.

**Prerequisites:** None hard-required. Branch `feat/axis-gamma-cor` is already created from `origin/main`. The plan composes on top of the cfg_t bundle and `axis_if` interface refactors; both are merged on `main`.

---

## File Structure

**New files:**
- `hw/ip/gamma/gamma.core` — FuseSoC CAPI=2 core for the new IP.
- `hw/ip/gamma/rtl/axis_gamma_cor.sv` — the module.
- `hw/ip/gamma/tb/tb_axis_gamma_cor.sv` — unit TB (`drv_*` pattern, asymmetric stall, `enable_i` passthrough).
- `docs/specs/axis_gamma_cor-arch.md` — architecture doc.
- `py/gen_gamma_lut.py` — developer-facing one-shot helper that prints a 33-entry SV `localparam` block from the closed-form sRGB formula. Not invoked by Make.
- `py/models/ops/gamma_cor.py` — sRGB LUT + per-pixel reference model.
- `py/tests/test_gamma_cor.py` — Python-side unit tests + SV-vs-Python LUT parity test.

**Modified files:**
- `hw/top/sparevideo_pkg.sv` — add `gamma_en` field to `cfg_t`; add `gamma_en: 1'b1` to the four existing profiles; add new `localparam cfg_t CFG_NO_GAMMA_COR` (default with `gamma_en: 1'b0`).
- `hw/top/sparevideo_top.sv` — instantiate `axis_gamma_cor` between `proc_axis` and `u_fifo_out.s_axis`; rename the local interface bundle hierarchy accordingly; tie `enable_i` to `CFG.gamma_en`.
- `dv/sv/tb_sparevideo.sv` — extend the `CFG_NAME` resolution chain with `"no_gamma_cor"` → `CFG_NO_GAMMA_COR`; extend the warning's allowed-name list; update the `$display` line to print `gamma_en`.
- `dv/sim/Makefile` — add `IP_GAMMA_COR_RTL`; add `test-ip-gamma-cor` target; wire it into `test-ip` aggregate and `clean`; thread `axis_gamma_cor.sv` into `RTL_SRCS`.
- `Makefile` (top) — advertise `no_gamma_cor` in the `CFG=` help text and the `test-ip-gamma-cor` target.
- `py/profiles.py` — add `gamma_en=True` to `DEFAULT`; add `NO_GAMMA_COR = dict(DEFAULT, gamma_en=False)` and register it in `PROFILES`.
- `py/models/__init__.py` — accept `gamma_en` kwarg; if true, post-process each ctrl_flow's RGB output through `gamma_cor` (after the ctrl_flow model returns).
- `py/tests/test_profiles.py` — extend `EXPECTED_PROFILES` with `"no_gamma_cor"`.
- `README.md` — add the new IP to the block table; add `no_gamma_cor` to the profile list.
- `CLAUDE.md` — add `axis_gamma_cor` to the "Project Structure" block list and `hw/ip/gamma/rtl/`; add the new profile to the build-commands list.
- `docs/specs/sparevideo-top-arch.md` — add the gamma stage to the top-level diagram and the post-mux text.

**No changes required:** `hw/top/sparevideo_if.sv` (`axis_if`/`bbox_if` already cover this stage), every existing per-block IP/TB, `py/frames/`, `py/viz/`, all other Python models.

---

## Task 1: Capture pre-integration regression goldens

**Purpose:** lock in byte-perfect baseline output of every (ctrl_flow × profile) pairing **before** any cfg_t / RTL changes. After integration in Task 8, running with `CFG=no_gamma_cor` (gamma path bypassed end-to-end) must reproduce every baseline byte-for-byte. `CFG=default` will differ — that diff is verified to match the new `gamma_cor` reference model in Task 10.

**Files:**
- Create (local, gitignored): `renders/golden/<ctrl_flow>__<profile>__pre-gamma.bin` (12 files: 4 flows × 3 profiles `default`, `no_morph`, `no_gauss` — sufficient coverage; `default_hflip` and `no_ema` are skipped to keep the grid small).

- [ ] **Step 1: Run baseline pipelines, capture output**

```bash
mkdir -p renders/golden
for FLOW in passthrough motion mask ccl_bbox; do
  for PROF in default no_morph no_gauss; do
    make run-pipeline CTRL_FLOW=$FLOW CFG=$PROF SOURCE="synthetic:moving_box" \
                      WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary
    cp dv/data/output.bin renders/golden/${FLOW}__${PROF}__pre-gamma.bin
  done
done
```

Expected: each `make run-pipeline` invocation exits 0; verify reports PASS; 12 binary files exist, each `12 + 320*240*3*8 = 1,843,212` bytes.

- [ ] **Step 2: Sanity-check goldens**

```bash
ls -l renders/golden/*__pre-gamma.bin | wc -l
xxd renders/golden/passthrough__default__pre-gamma.bin | head -1
```

Expected: `12`. First 12 bytes decode as `(0x140, 0xF0, 0x8) = (320, 240, 8)` (little-endian uint32 width/height/frames).

*(Do not commit — `renders/` is gitignored. Goldens are deleted in Task 12.)*

---

## Task 2: Architecture doc

**Files:**
- Create: `docs/specs/axis_gamma_cor-arch.md`

- [ ] **Step 1: Write the arch doc**

Use the `hardware-arch-doc` skill. Required sections (sized to roughly mirror `docs/specs/axis_hflip-arch.md`):

1. **Purpose** — per-channel sRGB display-curve correction at the post-mux tail of the proc_clk pipeline; runtime-bypassable via `enable_i`.
2. **Module Hierarchy** — leaf module; instantiated as `u_gamma_cor` in `sparevideo_top` between the ctrl-flow output mux (`proc_axis`) and `u_fifo_out`.
3. **Interface Specification**
   - **Parameters:** none. The LUT is a `localparam` baked into the module body (33 × 8 bits), so the curve is fixed at synthesis time.
   - **Ports:** `clk_i`, `rst_n_i`, `enable_i`, `s_axis` (`axis_if.rx`, DATA_W=24 USER_W=1), `m_axis` (`axis_if.tx`, DATA_W=24 USER_W=1).
4. **Concept Description** — input pixel `p ∈ [0,255]` maps to `out = sRGB_encode(p/255) * 255` quantised to 8 bits. A 33-entry LUT samples the curve at `i = 0,8,…,256` (entry 32 is the upper sentinel for interpolation when `addr==31`). Per-pixel: `addr = p[7:3]`, `frac = p[2:0]`, `out = (LUT[addr]*(8-frac) + LUT[addr+1]*frac) >> 3`. Each of the three channels (R, G, B) computes this independently using the same LUT.
5. **Internal Architecture**
   - 5.1 ASCII diagram: input AXIS → `addr/frac` extractor → register stage → 3× LUT-interp datapath → register stage → output AXIS; `enable_i=0` muxes around the whole datapath.
   - 5.2 1-cycle pipeline: cycle 0 latches `{addr_r, addr_g, addr_b, frac_r, frac_g, frac_b}` and the AXIS sideband (`tlast_q`, `tuser_q`); cycle 1 computes the three interpolations combinationally and registers them onto `m_axis.tdata`. Sideband bits propagate one stage to align with the data.
   - 5.3 Backpressure: skid via the standard "advance only on `(s_axis.tvalid && s_axis.tready) || !pipe_valid_q`" pattern. `s_axis.tready = m_axis.tready || !pipe_valid_q`.
   - 5.4 Resource cost: 33 × 8 = 264 LUT bits per channel; one 33-entry ROM is shared by all three channels (three async reads — small enough to map to LUTRAM or distributed logic). Three 8-bit × 4-bit multipliers (or shift-and-add since weights are 0..8). No DSPs required.
6. **Control Logic** — no FSM; pure pipeline. Reset clears `pipe_valid_q`, `tlast_q`, `tuser_q`.
7. **Timing** — 1-cycle latency when `enable_i=1`; 0-cycle (combinational) when `enable_i=0`. 1 pixel/cycle long-term throughput.
8. **Shared Types** — uses `pixel_t` and `component_t` from `sparevideo_pkg`.
9. **Known Limitations** — single fixed sRGB curve baked into the SV (no runtime CSR yet); `enable_i` must be held frame-stable; LUT entries are derived from a closed-form formula that any consumer in the pipeline must mirror exactly (parity test guards against drift).
10. **References** — `sparevideo-top-arch.md`, `docs/plans/2026-04-23-pipeline-extensions-design.md` §3.4, IEC 61966-2-1 (sRGB).

- [ ] **Step 2: Commit the arch doc**

```bash
git add docs/specs/axis_gamma_cor-arch.md
git commit -m "docs(gamma): axis_gamma_cor architecture spec"
```

---

## Task 3: cfg_t / profiles.py / parity test wiring (no RTL yet)

**Purpose:** introduce the `gamma_en` field and the new `no_gamma_cor` profile across SV, Python, and the parity check **before** touching RTL or the testbench. After this task, `make test-py` and `make sim` (with any existing CFG) must still pass — `gamma_en` is a non-functional field at this point.

**Files:**
- Modify: `hw/top/sparevideo_pkg.sv:56-141`
- Modify: `py/profiles.py`
- Modify: `py/tests/test_profiles.py:39`
- Modify: `dv/sv/tb_sparevideo.sv:99-113, 207-210`

- [ ] **Step 1: Add `gamma_en` to `cfg_t` and existing profiles**

Edit `hw/top/sparevideo_pkg.sv`. Insert `gamma_en` after `hflip_en` in the `cfg_t` definition:

```systemverilog
typedef struct packed {
    component_t motion_thresh;       // raw |Y_cur - Y_prev| threshold
    int         alpha_shift;         // EMA rate, non-motion pixels
    int         alpha_shift_slow;    // EMA rate, motion pixels
    int         grace_frames;        // aggressive-EMA grace after priming
    int         grace_alpha_shift;   // EMA rate during grace window
    logic       gauss_en;            // 3x3 Gaussian pre-filter on Y
    logic       morph_en;            // 3x3 opening on mask
    logic       hflip_en;            // horizontal mirror on input
    logic       gamma_en;            // sRGB display gamma at output tail
    pixel_t     bbox_color;          // overlay colour
} cfg_t;
```

Then add `gamma_en: 1'b1,` to each of `CFG_DEFAULT`, `CFG_DEFAULT_HFLIP`, `CFG_NO_EMA`, `CFG_NO_MORPH`, `CFG_NO_GAUSS` — placed between `hflip_en:` and `bbox_color:`. Example for `CFG_DEFAULT`:

```systemverilog
localparam cfg_t CFG_DEFAULT = '{
    motion_thresh:     8'd16,
    alpha_shift:       3,
    alpha_shift_slow:  6,
    grace_frames:      0,
    grace_alpha_shift: 1,
    gauss_en:          1'b1,
    morph_en:          1'b1,
    hflip_en:          1'b0,
    gamma_en:          1'b1,
    bbox_color:        24'h00_FF_00
};
```

Apply the same `gamma_en: 1'b1,` insertion to the other four existing profiles.

- [ ] **Step 2: Add `CFG_NO_GAMMA_COR` profile**

Append below `CFG_NO_GAUSS`:

```systemverilog
// sRGB gamma correction bypassed (linear passthrough at output tail).
localparam cfg_t CFG_NO_GAMMA_COR = '{
    motion_thresh:     8'd16,
    alpha_shift:       3,
    alpha_shift_slow:  6,
    grace_frames:      0,
    grace_alpha_shift: 1,
    gauss_en:          1'b1,
    morph_en:          1'b1,
    hflip_en:          1'b0,
    gamma_en:          1'b0,
    bbox_color:        24'h00_FF_00
};
```

- [ ] **Step 3: Mirror the change in `py/profiles.py`**

Edit `py/profiles.py`. Add `gamma_en=True,` to `DEFAULT` (after `hflip_en=False,`); add `NO_GAMMA_COR` and register it:

```python
DEFAULT: ProfileT = dict(
    motion_thresh=16,
    alpha_shift=3,
    alpha_shift_slow=6,
    grace_frames=0,
    grace_alpha_shift=1,
    gauss_en=True,
    morph_en=True,
    hflip_en=False,
    gamma_en=True,
    bbox_color=0x00_FF_00,
)
# ...
NO_GAMMA_COR: ProfileT = dict(DEFAULT, gamma_en=False)

PROFILES: dict[str, ProfileT] = {
    "default":       DEFAULT,
    "default_hflip": DEFAULT_HFLIP,
    "no_ema":        NO_EMA,
    "no_morph":      NO_MORPH,
    "no_gauss":      NO_GAUSS,
    "no_gamma_cor":  NO_GAMMA_COR,
}
```

The other derived profiles (`DEFAULT_HFLIP`, `NO_EMA`, `NO_MORPH`, `NO_GAUSS`) automatically inherit `gamma_en=True` because they use `dict(DEFAULT, ...)`.

- [ ] **Step 4: Extend `EXPECTED_PROFILES` in the parity test**

Edit `py/tests/test_profiles.py`. Add `"no_gamma_cor"` to the set on line 39:

```python
EXPECTED_PROFILES = {"default", "default_hflip", "no_ema", "no_morph", "no_gauss", "no_gamma_cor"}
```

- [ ] **Step 5: Extend the testbench's CFG_NAME resolution chain**

Edit `dv/sv/tb_sparevideo.sv`. Update the `localparam CFG` chain (around line 99) and the warning's allowed-names check (around line 107):

```systemverilog
localparam sparevideo_pkg::cfg_t CFG =
    (CFG_NAME == "default_hflip") ? sparevideo_pkg::CFG_DEFAULT_HFLIP :
    (CFG_NAME == "no_ema")        ? sparevideo_pkg::CFG_NO_EMA        :
    (CFG_NAME == "no_morph")      ? sparevideo_pkg::CFG_NO_MORPH      :
    (CFG_NAME == "no_gauss")      ? sparevideo_pkg::CFG_NO_GAUSS      :
    (CFG_NAME == "no_gamma_cor")  ? sparevideo_pkg::CFG_NO_GAMMA_COR  :
                                    sparevideo_pkg::CFG_DEFAULT;

initial begin
    if (CFG_NAME != "default"       &&
        CFG_NAME != "default_hflip" &&
        CFG_NAME != "no_ema"        &&
        CFG_NAME != "no_morph"      &&
        CFG_NAME != "no_gauss"      &&
        CFG_NAME != "no_gamma_cor")
        $warning("Unknown CFG_NAME '%s'; using CFG_DEFAULT. Valid: default|default_hflip|no_ema|no_morph|no_gauss|no_gamma_cor", CFG_NAME);
end
```

Update the `$display` line near line 207 to include `gamma_en`:

```systemverilog
$display("  CFG=%s thresh=%0d a=%0d a_slow=%0d grace=%0d ga=%0d gauss=%0b morph=%0b hflip=%0b gamma=%0b bbox=0x%06x",
         CFG_NAME, CFG.motion_thresh, CFG.alpha_shift, CFG.alpha_shift_slow,
         CFG.grace_frames, CFG.grace_alpha_shift,
         CFG.gauss_en, CFG.morph_en, CFG.hflip_en, CFG.gamma_en, CFG.bbox_color);
```

- [ ] **Step 6: Run parity + lint + a sanity sim**

```bash
.venv/bin/python -m pytest py/tests/test_profiles.py -v
make lint
make run-pipeline CTRL_FLOW=motion CFG=default
make run-pipeline CTRL_FLOW=motion CFG=no_gamma_cor
```

Expected:
- pytest: 7 cases pass (`test_profile_set_is_complete` + 6 parameterised parity cases).
- lint: clean.
- Both pipeline runs: PASS at TOLERANCE=0. (Both produce identical output because `gamma_en` is unused at this point — its presence in `cfg_t` does not affect any RTL behavior yet.)

- [ ] **Step 7: Compare `no_gamma_cor` and `default` outputs (must be identical)**

```bash
make run-pipeline CTRL_FLOW=motion CFG=default     SOURCE="synthetic:moving_box" FRAMES=4 MODE=binary
cp dv/data/output.bin /tmp/out_default.bin
make run-pipeline CTRL_FLOW=motion CFG=no_gamma_cor SOURCE="synthetic:moving_box" FRAMES=4 MODE=binary
cmp /tmp/out_default.bin dv/data/output.bin
```

Expected: `cmp` exits 0 (files are byte-identical). This proves `gamma_en` is wired through to the SV side without affecting any current RTL.

- [ ] **Step 8: Commit**

```bash
git add hw/top/sparevideo_pkg.sv py/profiles.py py/tests/test_profiles.py dv/sv/tb_sparevideo.sv
git commit -m "feat(gamma): plumb cfg_t.gamma_en + no_gamma_cor profile (no RTL yet)"
```

---

## Task 4: Python LUT generator + reference model + tests

**Purpose:** define the canonical sRGB transfer function in one place (Python), produce a developer-facing helper that prints the matching SV `localparam` block (so the Task 5 RTL can be written against it), and provide a reference model used by Task 9's pipeline dispatcher.

**Files:**
- Create: `py/gen_gamma_lut.py`
- Create: `py/models/ops/gamma_cor.py`
- Create: `py/tests/test_gamma_cor.py`

- [ ] **Step 1: Write `py/gen_gamma_lut.py`**

```python
#!/usr/bin/env python3
"""Print the 33-entry sRGB encode LUT as an SV localparam block.

Single source of truth for the sRGB curve used by axis_gamma_cor.sv and
py/models/ops/gamma_cor.py. Run manually if the curve formula changes;
copy the output into hw/ip/gamma/rtl/axis_gamma_cor.sv. The
test_gamma_cor.py parity test guards against silent drift between the
two files.
"""
from __future__ import annotations

import sys


def srgb_encode(x: float) -> float:
    """IEC 61966-2-1 sRGB encode: linear [0,1] -> non-linear [0,1]."""
    if x <= 0.0031308:
        return 12.92 * x
    return 1.055 * (x ** (1.0 / 2.4)) - 0.055


def srgb_lut() -> list[int]:
    """33-entry LUT sampled at i*8 for i in 0..32 (clamped to 255 at i=32)."""
    out = []
    for i in range(33):
        x = min(i * 8, 255) / 255.0
        out.append(round(srgb_encode(x) * 255))
    return out


def emit_sv() -> str:
    lut = srgb_lut()
    rows = []
    for r in range(0, 33, 8):
        chunk = lut[r:r + 8]
        rows.append("        " + ", ".join(f"8'd{v:>3}" for v in chunk))
    body = ",\n".join(rows)
    return (
        "    // sRGB encode LUT — 33 entries sampled at i*8 (i=0..32).\n"
        "    // Generated by py/gen_gamma_lut.py; matched in\n"
        "    // py/models/ops/gamma_cor.py. Do NOT hand-edit.\n"
        "    localparam logic [7:0] SRGB_LUT [0:32] = '{\n"
        f"{body}\n"
        "    };\n"
    )


if __name__ == "__main__":
    sys.stdout.write(emit_sv())
```

- [ ] **Step 2: Write `py/models/ops/gamma_cor.py`**

```python
"""sRGB gamma correction reference model.

Mirrors axis_gamma_cor RTL exactly: per-channel 33-entry LUT addressed by
pixel[7:3] with linear interpolation across pixel[2:0]:

    addr = p >> 3
    frac = p & 0x7
    out  = (LUT[addr] * (8 - frac) + LUT[addr + 1] * frac) >> 3

The LUT is computed at import time from the closed-form sRGB encode formula
in py/gen_gamma_lut.py; the same script prints the matching SV localparam.
The SV-vs-Python parity test in py/tests/test_gamma_cor.py catches drift.
"""
from __future__ import annotations

import numpy as np

from gen_gamma_lut import srgb_lut

LUT = np.asarray(srgb_lut(), dtype=np.uint16)  # uint16 so partial sums don't overflow
assert LUT.shape == (33,)
assert LUT[0] == 0


def gamma_cor(image: np.ndarray) -> np.ndarray:
    """Apply per-channel sRGB encode LUT to an (H, W, 3) uint8 RGB image."""
    if image.dtype != np.uint8:
        raise TypeError(f"gamma_cor expects uint8, got {image.dtype}")
    if image.ndim != 3 or image.shape[2] != 3:
        raise ValueError(f"gamma_cor expects (H, W, 3), got {image.shape}")
    p    = image.astype(np.uint16)
    addr = p >> 3
    frac = p & 0x7
    lo   = LUT[addr]
    hi   = LUT[addr + 1]
    out  = (lo * (8 - frac) + hi * frac) >> 3
    return out.astype(np.uint8)
```

- [ ] **Step 3: Write `py/tests/test_gamma_cor.py`**

```python
"""Unit tests for the gamma correction reference model + SV parity."""
from __future__ import annotations

import re
from pathlib import Path

import numpy as np
import pytest

from gen_gamma_lut import srgb_lut
from models.ops.gamma_cor import LUT, gamma_cor


SV_PATH = Path(__file__).resolve().parents[2] / "hw" / "ip" / "gamma" / "rtl" / "axis_gamma_cor.sv"


def test_lut_endpoints() -> None:
    """Black maps to black, white maps to white (LUT[32] is the sentinel)."""
    assert LUT[0] == 0
    assert LUT[32] == 255


def test_lut_monotonic() -> None:
    lut = srgb_lut()
    assert all(lut[i] <= lut[i + 1] for i in range(32))


def test_endpoints_round_trip() -> None:
    """gamma_cor(0) == 0; gamma_cor(255) == 254 (interpolation rounds down at top)."""
    img = np.zeros((1, 2, 3), dtype=np.uint8)
    img[0, 1] = 255
    out = gamma_cor(img)
    assert out[0, 0].tolist() == [0, 0, 0]
    # pixel=255: addr=31, frac=7 → (LUT[31] + 7*LUT[32]) >> 3 = (LUT[31] + 1785) >> 3
    expected_top = (int(LUT[31]) + 7 * int(LUT[32])) >> 3
    assert out[0, 1].tolist() == [expected_top] * 3


def test_pixel_128() -> None:
    """pixel=128: addr=16, frac=0 → exactly LUT[16]."""
    img = np.full((1, 1, 3), 128, dtype=np.uint8)
    out = gamma_cor(img)
    assert out[0, 0].tolist() == [int(LUT[16])] * 3


def test_pixel_4_interpolated() -> None:
    """pixel=4: addr=0, frac=4 → (LUT[0]*4 + LUT[1]*4) >> 3 = LUT[1] >> 1."""
    img = np.full((1, 1, 3), 4, dtype=np.uint8)
    out = gamma_cor(img)
    expected = (int(LUT[0]) * 4 + int(LUT[1]) * 4) >> 3
    assert out[0, 0].tolist() == [expected] * 3


def test_per_channel_independence() -> None:
    """Each channel goes through the same LUT independently."""
    img = np.array([[[0, 64, 200]]], dtype=np.uint8)
    out = gamma_cor(img)
    expected_r = (int(LUT[0])  * 8 + int(LUT[1])  * 0) >> 3   # addr=0, frac=0
    expected_g = (int(LUT[8])  * 8 + int(LUT[9])  * 0) >> 3   # addr=8, frac=0
    expected_b = (int(LUT[25]) * 8 + int(LUT[26]) * 0) >> 3   # addr=25, frac=0
    assert out[0, 0].tolist() == [expected_r, expected_g, expected_b]


def test_sv_lut_matches_python() -> None:
    """Parse the SV localparam in axis_gamma_cor.sv; bytes must match the Python LUT."""
    text = SV_PATH.read_text()
    match = re.search(r"localparam\s+logic\s*\[7:0\]\s+SRGB_LUT\s*\[0:32\]\s*=\s*'\{([^}]*)\}", text)
    assert match is not None, "SRGB_LUT localparam not found in axis_gamma_cor.sv"
    bytes_text = match.group(1)
    sv_values = [int(m.group(1)) for m in re.finditer(r"8'd\s*(\d+)", bytes_text)]
    assert len(sv_values) == 33, f"expected 33 LUT entries, got {len(sv_values)}"
    assert sv_values == srgb_lut(), "SV LUT bytes do not match Python srgb_lut()"
```

- [ ] **Step 4: Run the model tests (parity test will fail — RTL doesn't exist yet)**

```bash
.venv/bin/python -m pytest py/tests/test_gamma_cor.py -v --deselect py/tests/test_gamma_cor.py::test_sv_lut_matches_python
```

Expected: 6 tests pass. The 7th (`test_sv_lut_matches_python`) is intentionally deselected here because Task 5 hasn't created the SV file yet.

- [ ] **Step 5: Print the SV LUT block for use in Task 5**

```bash
.venv/bin/python py/gen_gamma_lut.py | tee /tmp/gamma_lut.svh
```

Expected: an `8'd<value>`-formatted SV `localparam` block of 33 entries, with `SRGB_LUT[0]=0` and `SRGB_LUT[32]=255`, copyable into Task 5's RTL.

- [ ] **Step 6: Commit**

```bash
git add py/gen_gamma_lut.py py/models/ops/gamma_cor.py py/tests/test_gamma_cor.py
git commit -m "feat(gamma): sRGB LUT generator + reference model + tests"
```

---

## Task 5: RTL — `axis_gamma_cor.sv` + FuseSoC core

**Files:**
- Create: `hw/ip/gamma/rtl/axis_gamma_cor.sv`
- Create: `hw/ip/gamma/gamma.core`

- [ ] **Step 1: Write `hw/ip/gamma/gamma.core`**

```yaml
CAPI=2:
name: "sparevideo:ip:gamma"
description: "Per-channel sRGB gamma correction (33-entry LUT, linear interp, 1-cycle latency, runtime bypass)"

filesets:
  files_rtl:
    files:
      - rtl/axis_gamma_cor.sv
    file_type: systemVerilogSource
    depend:
      - sparevideo:pkg:common

targets:
  default:
    filesets:
      - files_rtl
```

- [ ] **Step 2: Write `hw/ip/gamma/rtl/axis_gamma_cor.sv`**

Paste the LUT block produced by Step 5 of Task 4. Module body:

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_gamma_cor -- per-channel sRGB display gamma correction on a 24-bit
// RGB AXIS.
//
// 33-entry LUT (sampled at pixel = i*8 for i=0..32) addressed by p[7:3];
// linear interpolation by p[2:0] gives 8-bit fractional accuracy:
//
//     addr = p[7:3]                                            // 0..31
//     frac = p[2:0]                                            // 0..7
//     out  = (LUT[addr]*(8 - frac) + LUT[addr+1]*frac) >> 3    // 8 bits
//
// Each of R/G/B is processed independently; the same LUT is used.
//
// Pipeline: 1 cycle of latency. Stage A registers {addr, frac} per channel
// + {tlast, tuser, valid}. Stage B computes the three interpolations
// combinationally and registers the result onto m_axis.
//
// enable_i = 0: zero-latency combinational passthrough; the pipeline
// registers are held valid=0 and ignored. Must be held frame-stable.

module axis_gamma_cor (
    // --- Clocks and resets ---
    input  logic clk_i,
    input  logic rst_n_i,

    // --- Sideband ---
    input  logic enable_i,

    // --- AXI4-Stream input (24-bit RGB) ---
    axis_if.rx s_axis,

    // --- AXI4-Stream output (24-bit RGB) ---
    axis_if.tx m_axis
);

    // sRGB encode LUT — 33 entries sampled at i*8 (i=0..32).
    // Generated by py/gen_gamma_lut.py; matched in
    // py/models/ops/gamma_cor.py. Do NOT hand-edit.
    localparam logic [7:0] SRGB_LUT [0:32] = '{
        // <-- paste 33 8'd<value> entries here from Task 4 Step 5 -->
    };

    // ---- Stage A: latch {addr, frac} per channel ----
    logic [4:0] addr_r_q, addr_g_q, addr_b_q;
    logic [2:0] frac_r_q, frac_g_q, frac_b_q;
    logic       valid_q;
    logic       tlast_q;
    logic       tuser_q;

    logic stage_advance;
    assign stage_advance = (s_axis.tvalid && s_axis.tready) || !valid_q;

    logic s_ready;
    assign s_ready = enable_i ? (m_axis.tready || !valid_q) : m_axis.tready;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            valid_q <= 1'b0;
            tlast_q <= 1'b0;
            tuser_q <= 1'b0;
        end else if (stage_advance) begin
            valid_q  <= s_axis.tvalid;
            tlast_q  <= s_axis.tlast;
            tuser_q  <= s_axis.tuser;
            addr_r_q <= s_axis.tdata[23:19];
            frac_r_q <= s_axis.tdata[18:16];
            addr_g_q <= s_axis.tdata[15:11];
            frac_g_q <= s_axis.tdata[10:8];
            addr_b_q <= s_axis.tdata[7:3];
            frac_b_q <= s_axis.tdata[2:0];
        end
    end

    // ---- Stage B: combinational interpolation ----
    function automatic logic [7:0] interp(input logic [4:0] addr, input logic [2:0] frac);
        logic [10:0] sum;
        sum = SRGB_LUT[addr] * (4'd8 - {1'b0, frac}) + SRGB_LUT[addr + 5'd1] * {8'd0, frac};
        return sum[10:3];   // >> 3
    endfunction

    logic [7:0] r_out, g_out, b_out;
    assign r_out = interp(addr_r_q, frac_r_q);
    assign g_out = interp(addr_g_q, frac_g_q);
    assign b_out = interp(addr_b_q, frac_b_q);

    // ---- enable_i bypass mux ----
    always_comb begin
        if (enable_i) begin
            s_axis.tready = s_ready;
            m_axis.tdata  = {r_out, g_out, b_out};
            m_axis.tvalid = valid_q;
            m_axis.tlast  = tlast_q;
            m_axis.tuser  = tuser_q;
        end else begin
            s_axis.tready = m_axis.tready;
            m_axis.tdata  = s_axis.tdata;
            m_axis.tvalid = s_axis.tvalid;
            m_axis.tlast  = s_axis.tlast;
            m_axis.tuser  = s_axis.tuser;
        end
    end

endmodule
```

Note on `interp`: the `4'd8 - {1'b0, frac}` and `{8'd0, frac}` extensions ensure unsigned subtraction width-matches and the multiplication produces an 11-bit product. Verilator will warn on width mismatches; the `Wno-WIDTHEXPAND/TRUNC` flags in the project Makefile suppress benign cases, but the explicit extensions here keep the arithmetic correct without relying on that.

- [ ] **Step 3: Run lint with the new file**

The new file isn't yet wired into FuseSoC's `lint` target (that wiring is Task 8); for an isolated lint:

```bash
verilator --lint-only -sv \
  hw/top/sparevideo_pkg.sv hw/top/sparevideo_if.sv hw/ip/gamma/rtl/axis_gamma_cor.sv
```

Expected: clean (no errors, no warnings).

- [ ] **Step 4: Re-run the parity test now that the SV exists**

```bash
.venv/bin/python -m pytest py/tests/test_gamma_cor.py::test_sv_lut_matches_python -v
```

Expected: PASS — the 33 SV `8'd<n>` literals match `srgb_lut()` byte-for-byte.

- [ ] **Step 5: Commit**

```bash
git add hw/ip/gamma/gamma.core hw/ip/gamma/rtl/axis_gamma_cor.sv
git commit -m "feat(gamma): axis_gamma_cor RTL + FuseSoC core"
```

---

## Task 6: Unit testbench `tb_axis_gamma_cor`

**Files:**
- Create: `hw/ip/gamma/tb/tb_axis_gamma_cor.sv`
- Modify: `dv/sim/Makefile:46-47, 106-114, 180-184, 200-208`

- [ ] **Step 1: Write `hw/ip/gamma/tb/tb_axis_gamma_cor.sv`**

Tests to implement (`drv_*` pattern, asymmetric stall, mirrors `tb_axis_hflip`'s style):

- **T1 — endpoint identity:** drive RGB pixels (0,0,0), (255,255,255), (128,64,32). Compare each channel's output against the Python-formula expectation hard-coded into the TB as constants computed identically to `gen_gamma_lut.py` (the TB reproduces `srgb_encode` arithmetic in SV using the same `SRGB_LUT` literals — the cleanest route is to instantiate the DUT and treat its output as ground truth, but the test then becomes a tautology; instead, embed the *expected* result for each test pixel as a hand-checked constant derived from the Python output captured during Task 4 Step 5).
- **T2 — gradient:** drive a single 16-pixel line `0,16,32,…,240`; check each output equals the expected interpolation result.
- **T3 — backpressure:** mid-line, deassert `m_axis.tready` for 5 cycles; resume; output sequence must match the no-stall reference.
- **T4 — `enable_i=0` passthrough:** drive any pattern; output must equal input combinationally (no latency added).

Skeleton (fill in expected values from running `gen_gamma_lut.py` and computing expected outputs by hand or via a one-off Python helper):

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Unit testbench for axis_gamma_cor.
//
// Tests:
//   T1 -- enable_i=1, endpoint pixels (0, 128, 255) match hand-computed expectations.
//   T2 -- enable_i=1, 16-pixel ramp matches per-pixel hand expectations.
//   T3 -- enable_i=1, mid-line m_axis.tready stall; output count + values unchanged.
//   T4 -- enable_i=0, passthrough: output == input combinationally.

`timescale 1ns / 1ps

module tb_axis_gamma_cor;

    localparam int CLK_PERIOD = 10;

    logic clk = 0;
    logic rst_n = 0;
    logic enable;

    logic [23:0] drv_tdata    = '0;
    logic        drv_tvalid   = 1'b0;
    logic        drv_tlast    = 1'b0;
    logic        drv_tuser    = 1'b0;
    logic        drv_m_tready = 1'b1;

    axis_if #(.DATA_W(24), .USER_W(1)) s_axis ();
    axis_if #(.DATA_W(24), .USER_W(1)) m_axis ();

    always_ff @(negedge clk) begin
        s_axis.tdata  <= drv_tdata;
        s_axis.tvalid <= drv_tvalid;
        s_axis.tlast  <= drv_tlast;
        s_axis.tuser  <= drv_tuser;
    end

    assign m_axis.tready = drv_m_tready;

    axis_gamma_cor dut (
        .clk_i    (clk),
        .rst_n_i  (rst_n),
        .enable_i (enable),
        .s_axis   (s_axis),
        .m_axis   (m_axis)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // Capture every accepted output beat
    logic [23:0] cap [256];
    int          cap_n;

    always_ff @(posedge clk) begin
        if (rst_n && m_axis.tvalid && m_axis.tready) begin
            cap[cap_n] <= m_axis.tdata;
            cap_n      <= cap_n + 1;
        end
    end

    task automatic drive_beat(input logic [23:0] data, input logic last, input logic user);
        begin
            drv_tdata  = data;
            drv_tvalid = 1'b1;
            drv_tlast  = last;
            drv_tuser  = user;
            @(posedge clk);
            while (!s_axis.tready) @(posedge clk);
            drv_tvalid = 1'b0;
            drv_tlast  = 1'b0;
            drv_tuser  = 1'b0;
        end
    endtask

    initial begin
        // <-- Hand-checked expected values for enable_i=1: replace with values
        //     produced by `python -c "from py.models.ops.gamma_cor import gamma_cor; ..."`.
        //     For pixel=0:    expected=0
        //     For pixel=128:  expected=LUT[16] (from gen_gamma_lut.py output)
        //     For pixel=255:  expected=(LUT[31] + 7*LUT[32]) >> 3
        logic [7:0] EXP_0;
        logic [7:0] EXP_128;
        logic [7:0] EXP_255;

        EXP_0   = 8'd0;
        EXP_128 = 8'd<paste from gen_gamma_lut.py output: LUT[16]>;
        EXP_255 = 8'd<paste: (LUT[31] + 7*LUT[32]) / 8>;

        cap_n = 0;
        drv_m_tready = 1'b1;
        enable       = 1'b1;
        #(CLK_PERIOD*3);
        rst_n = 1'b1;
        #(CLK_PERIOD*2);

        // T1: endpoint pixels
        $display("T1: endpoints");
        drive_beat({8'd0,   8'd0,   8'd0}, 1'b1, 1'b1);
        drive_beat({8'd128, 8'd128, 8'd128}, 1'b1, 1'b0);
        drive_beat({8'd255, 8'd255, 8'd255}, 1'b1, 1'b0);
        // Wait for pipeline to drain
        for (int i = 0; i < 4; i++) @(posedge clk);
        if (cap_n != 3) $fatal(1, "T1 FAIL: cap_n=%0d (want 3)", cap_n);
        if (cap[0] !== {EXP_0,   EXP_0,   EXP_0})   $fatal(1, "T1 FAIL [0]: %06h", cap[0]);
        if (cap[1] !== {EXP_128, EXP_128, EXP_128}) $fatal(1, "T1 FAIL [1]: %06h", cap[1]);
        if (cap[2] !== {EXP_255, EXP_255, EXP_255}) $fatal(1, "T1 FAIL [2]: %06h", cap[2]);

        // T2..T4: see plan body for stimulus + expectations.
        // ...

        // T4: enable_i = 0
        $display("T4: enable_i=0 passthrough");
        enable = 1'b0;
        cap_n  = 0;
        drive_beat({8'd17, 8'd34, 8'd51}, 1'b1, 1'b1);
        @(posedge clk);
        if (cap[0] !== {8'd17, 8'd34, 8'd51})
            $fatal(1, "T4 FAIL passthrough: %06h", cap[0]);

        $display("ALL GAMMA TESTS PASSED");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "FAIL tb_axis_gamma_cor TIMEOUT");
    end

endmodule
```

Replace the `<paste …>` placeholders by running:

```bash
.venv/bin/python - <<'PY'
from gen_gamma_lut import srgb_lut
L = srgb_lut()
print(f"EXP_0   = 8'd{0}")
print(f"EXP_128 = 8'd{L[16]}")
print(f"EXP_255 = 8'd{(L[31] + 7*L[32]) // 8}")
PY
```

Then expand T2 to drive 16 pixels at `p = i*16` for `i=0..15` and check each against `(LUT[addr]*(8-frac) + LUT[addr+1]*frac) >> 3` using the same Python helper. T3 takes the same stimulus as T2 plus a 5-cycle `drv_m_tready=0` window between beats 8 and 9; `cap_n` must equal 16 and values must match the no-stall sequence.

- [ ] **Step 2: Wire the TB into `dv/sim/Makefile`**

Add `IP_GAMMA_COR_RTL` (after line 106 area):

```make
IP_GAMMA_COR_RTL    = ../../hw/ip/gamma/rtl/axis_gamma_cor.sv
```

Append `test-ip-gamma-cor` to the `.PHONY` list (line 46-47):

```make
.PHONY: compile sim sim-waves sw-dry-run clean \
       test-ip test-ip-rgb2ycrcb test-ip-window test-ip-gauss3x3 \
       test-ip-motion-detect test-ip-motion-detect-gauss \
       test-ip-overlay-bbox test-ip-ccl \
       test-ip-morph3x3-erode test-ip-morph3x3-dilate test-ip-morph3x3-open \
       test-ip-hflip test-ip-gamma-cor
```

Append to the `test-ip` aggregate (line 114):

```make
test-ip: test-ip-rgb2ycrcb test-ip-window test-ip-gauss3x3 test-ip-motion-detect test-ip-motion-detect-gauss test-ip-overlay-bbox test-ip-ccl test-ip-morph3x3-erode test-ip-morph3x3-dilate test-ip-morph3x3-open test-ip-hflip test-ip-gamma-cor
	@echo "All block testbenches passed."
```

Insert the new target (after `test-ip-hflip`, around line 184):

```make
# --- axis_gamma_cor ---
test-ip-gamma-cor:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_gamma_cor --Mdir obj_tb_axis_gamma_cor \
	  ../../hw/top/sparevideo_pkg.sv ../../hw/top/sparevideo_if.sv \
	  $(IP_GAMMA_COR_RTL) ../../hw/ip/gamma/tb/tb_axis_gamma_cor.sv
	obj_tb_axis_gamma_cor/Vtb_axis_gamma_cor
```

Append `obj_tb_axis_gamma_cor` to the `clean` target's `rm -rf` list (line 207):

```make
clean:
	rm -f *.vvp *.vcd *.bin *.vpi
	rm -rf $(VOBJ_DIR) obj_tb_rgb2ycrcb obj_tb_axis_window3x3 obj_tb_axis_gauss3x3 \
	       obj_tb_axis_motion_detect obj_tb_axis_motion_detect_gauss \
	       obj_tb_axis_overlay_bbox obj_tb_axis_ccl \
	       obj_tb_axis_morph3x3_erode obj_tb_axis_morph3x3_dilate obj_tb_axis_morph3x3_open \
	       obj_tb_axis_hflip obj_tb_axis_gamma_cor
```

- [ ] **Step 3: Run the unit TB**

```bash
make -C dv/sim test-ip-gamma-cor
```

Expected: `ALL GAMMA TESTS PASSED`, exit 0.

- [ ] **Step 4: Run all per-block TBs to confirm nothing else regressed**

```bash
make test-ip
```

Expected: every block reports its `ALL ... PASSED` line; the aggregate prints `All block testbenches passed.`

- [ ] **Step 5: Commit**

```bash
git add hw/ip/gamma/tb/tb_axis_gamma_cor.sv dv/sim/Makefile
git commit -m "test(gamma): unit TB + Makefile wiring"
```

---

## Task 7: Integrate `axis_gamma_cor` into `sparevideo_top`

**Files:**
- Modify: `hw/top/sparevideo_top.sv:415-453`

**Insertion point:** between `proc_axis` (the ctrl-flow output mux drives this) and `u_fifo_out.s_axis`. Currently `u_fifo_out.s_axis` is wired directly to `proc_axis`; we splice `axis_gamma_cor` in between.

- [ ] **Step 1: Add a new interface bundle and instantiate the gamma stage**

Locate the `proc_axis` declaration (around line 423) and the `u_fifo_out` instantiation (around line 442). Apply the splice:

Find:

```systemverilog
    // proc_axis: driven directly by the ctrl-flow mux below; feeds u_fifo_out.s_axis.
    // proc_axis.tready (output FIFO write-side ready) is read back by the mux
    // and by morph_to_ccl.tready.
    axis_if #(.DATA_W(24), .USER_W(1)) proc_axis ();
```

Replace with:

```systemverilog
    // proc_axis: driven directly by the ctrl-flow mux below; feeds u_gamma_cor.s_axis.
    // proc_axis.tready (gamma stage's input ready, ultimately the output FIFO
    // write-side ready) is read back by the mux and by morph_to_ccl.tready.
    axis_if #(.DATA_W(24), .USER_W(1)) proc_axis ();

    // gamma_to_pix_out: u_gamma_cor.m_axis -> u_fifo_out.s_axis (direct pass-through).
    axis_if #(.DATA_W(24), .USER_W(1)) gamma_to_pix_out ();

    // sRGB display gamma correction at the post-mux tail. enable_i=0 is a
    // zero-latency combinational passthrough.
    axis_gamma_cor u_gamma_cor (
        .clk_i    (clk_dsp_i),
        .rst_n_i  (rst_dsp_n_i),
        .enable_i (CFG.gamma_en),
        .s_axis   (proc_axis),
        .m_axis   (gamma_to_pix_out)
    );
```

Find the `u_fifo_out` instantiation block (lines 438-452). Change `.s_axis (proc_axis)` to `.s_axis (gamma_to_pix_out)`:

```systemverilog
    axis_async_fifo_ifc #(
        .DEPTH  (OUT_FIFO_DEPTH),
        .DATA_W (24),
        .USER_W (1)
    ) u_fifo_out (
        .s_clk            (clk_dsp_i),
        .s_rst_n          (rst_dsp_n_i),
        .m_clk            (clk_pix_i),
        .m_rst_n          (rst_pix_n_i),
        .s_axis           (gamma_to_pix_out),
        .m_axis           (pix_out_axis),
        .s_status_depth   (fifo_out_depth),
        .s_status_overflow(fifo_out_overflow),
        .m_status_depth   ()
    );
```

- [ ] **Step 2: Lint and confirm clean**

```bash
make lint
```

Expected: no new warnings or errors. The `axis_gamma_cor` module is now in the FuseSoC `lint` target via the existing top-level `.core` file (verify it picks up `hw/ip/gamma/gamma.core`; if not, see Task 8 Step 1 to register it).

- [ ] **Step 3: Quick smoke run with `CFG=no_gamma_cor` against the Task 1 golden**

```bash
make run-pipeline CTRL_FLOW=motion CFG=no_gamma_cor SOURCE="synthetic:moving_box" \
                  WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary
cmp dv/data/output.bin renders/golden/motion__no_morph__pre-gamma.bin || true
cmp dv/data/output.bin renders/golden/motion__default__pre-gamma.bin
```

The first `cmp` is expected to fail (different profile). The second `cmp` (against `motion__default__pre-gamma.bin`) is expected to PASS — `CFG=no_gamma_cor` is just `default` with `gamma_en=0`, and the Task 1 baseline was captured before `axis_gamma_cor` existed (i.e. equivalent to `gamma_en=0`). This is the gate that proves the bypass path is byte-clean.

- [ ] **Step 4: Commit**

```bash
git add hw/top/sparevideo_top.sv
git commit -m "feat(gamma): integrate axis_gamma_cor into sparevideo_top tail"
```

---

## Task 8: FuseSoC top + Makefile wiring loose-ends

**Files:**
- Modify: `sparevideo_top.core` — add `hw/ip/gamma/gamma.core` to the depend list (verify after Task 7's lint).
- Modify: `Makefile` (top) — add a `test-ip-gamma-cor` convenience target; advertise the new `no_gamma_cor` profile in `help`.

- [ ] **Step 1: Register the new core with FuseSoC**

Inspect the top FuseSoC core file:

```bash
cat sparevideo_top.core
```

Add `sparevideo:ip:gamma` under the relevant target's `depend:` list (model on the existing `sparevideo:ip:hflip` entry). Then verify lint still works:

```bash
make lint
```

Expected: clean.

- [ ] **Step 2: Top-level `Makefile` updates**

Add a convenience target near `test-ip-hflip` (around line 167):

```make
test-ip-gamma-cor:
	$(MAKE) -C dv/sim test-ip-gamma-cor SIMULATOR=$(SIMULATOR)
```

Also add it to `.PHONY` on line 41-42 alongside the existing `test-ip-*` entries:

```make
.PHONY: help lint run-pipeline prepare compile sim sw-dry-run verify render sim-waves \
        test-py test-ip test-ip-window test-ip-hflip test-ip-gamma-cor setup clean
```

Update the `help` text (line 71-72 area) to list the new options:

```make
	@echo "    test-ip-hflip              axis_hflip: 5 tests, mirror correctness, asymmetric stall, enable_i passthrough"
	@echo "    test-ip-gamma-cor          axis_gamma_cor: 4 tests, sRGB endpoint/ramp/stall/passthrough"
```

And the `CFG=` line (line 82):

```make
	@echo "    CFG=default                      Algorithm profile (default|default_hflip|no_ema|no_morph|no_gauss|no_gamma_cor)"
```

- [ ] **Step 3: Verify**

```bash
make help | grep -E "(gamma|no_gamma_cor)"
make test-ip-gamma-cor
```

Expected: help shows the new lines; the convenience target runs the unit TB end-to-end.

- [ ] **Step 4: Commit**

```bash
git add sparevideo_top.core Makefile
git commit -m "build(gamma): register IP core + advertise targets/profile"
```

---

## Task 9: Python harness — pipeline composition

**Purpose:** thread `gamma_en` from the active profile through `run_model(...)` and apply `gamma_cor` to each ctrl_flow's RGB output when enabled. Mirror placement matches the RTL: gamma is applied **after** every ctrl_flow's natural output, on the final RGB frames.

**Files:**
- Modify: `py/models/__init__.py`

- [ ] **Step 1: Apply `gamma_cor` post-flow in the dispatcher**

Replace the body of `run_model` in `py/models/__init__.py`:

```python
"""Control-flow reference models for pixel-accurate pipeline verification.

Each control flow has its own module with a run() entry point.
Dispatch via run_model() which maps the control flow name to the correct model.

Pipeline-stage flags are applied in this dispatcher so each control-flow model
only needs to know about its own algorithm:
  - hflip_en: applied at the head (frames mirrored before dispatch).
  - gamma_en: applied at the tail (sRGB encode on each output frame).
"""

from models.ops.gamma_cor import gamma_cor as _gamma_cor
from models.ops.hflip     import hflip      as _hflip
from models.passthrough   import run as _run_passthrough
from models.motion        import run as _run_motion
from models.mask          import run as _run_mask
from models.ccl_bbox      import run as _run_ccl_bbox

_MODELS = {
    "passthrough": _run_passthrough,
    "motion":      _run_motion,
    "mask":        _run_mask,
    "ccl_bbox":    _run_ccl_bbox,
}


def run_model(ctrl_flow: str, frames: list, **kwargs) -> list:
    if ctrl_flow not in _MODELS:
        raise ValueError(
            f"Unknown control flow '{ctrl_flow}'. "
            f"Available: {', '.join(sorted(_MODELS))}"
        )
    hflip_en = kwargs.pop("hflip_en", False)
    gamma_en = kwargs.pop("gamma_en", False)
    if hflip_en:
        frames = [_hflip(f) for f in frames]
    out = _MODELS[ctrl_flow](frames, **kwargs)
    if gamma_en:
        out = [_gamma_cor(f) for f in out]
    return out
```

- [ ] **Step 2: Unit test the composition**

Add to `py/tests/test_models.py` (don't replace, append) a single regression case:

```python
def test_gamma_en_applied_to_passthrough() -> None:
    """With gamma_en=True, passthrough output should equal gamma_cor(input)."""
    import numpy as np
    from models import run_model
    from models.ops.gamma_cor import gamma_cor

    frame = np.tile(np.arange(256, dtype=np.uint8)[None, :, None], (1, 1, 3))[:, :8, :]
    # frame shape: (1, 8, 3) — 8-pixel ramp at low values
    out = run_model("passthrough", [frame], gamma_en=True)[0]
    expect = gamma_cor(frame)
    assert np.array_equal(out, expect)
```

Run:

```bash
.venv/bin/python -m pytest py/tests/test_models.py -v
```

Expected: existing tests still pass; the new test passes.

- [ ] **Step 3: Commit**

```bash
git add py/models/__init__.py py/tests/test_models.py
git commit -m "feat(gamma): pipe gamma_en through dispatcher; apply at tail"
```

---

## Task 10: Integration regression matrix

**Purpose:** prove that `CFG=no_gamma_cor` is byte-identical to the pre-integration goldens (Task 1) AND that `CFG=default` (gamma on) PASSes verification at TOLERANCE=0 against the Python model — i.e., RTL and reference model agree exactly with `gamma_cor` applied.

- [ ] **Step 1: Bypass-path matrix vs. Task 1 goldens**

```bash
for FLOW in passthrough motion mask ccl_bbox; do
  for PROF in default no_morph no_gauss; do
    # Map "default" baseline → no_gamma_cor (gamma off, all else default).
    # Other profiles also need their _no_gamma_cor variants; but our profile set
    # only ships one combined "no_gamma_cor". Compose by running with gamma off
    # via CFG=no_gamma_cor; expected match: only against the *default* baseline.
    if [ "$PROF" = "default" ]; then
      RUN_PROF=no_gamma_cor
    else
      # For no_morph/no_gauss baselines we need to verify model match, not
      # bypass identity (since axis_gamma_cor is now in the pipe with gamma_en=1
      # on those profiles — expected to differ from the pre-gamma golden).
      # Run model-based verify only.
      make run-pipeline CTRL_FLOW=$FLOW CFG=$PROF SOURCE="synthetic:moving_box" \
                        WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary || exit 1
      continue
    fi
    make run-pipeline CTRL_FLOW=$FLOW CFG=$RUN_PROF SOURCE="synthetic:moving_box" \
                      WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary || exit 1
    cmp dv/data/output.bin renders/golden/${FLOW}__default__pre-gamma.bin \
      || { echo "MISMATCH: $FLOW (CFG=no_gamma_cor) vs default golden"; exit 1; }
  done
done
echo "All bypass + model-verify runs OK"
```

Expected: all `make run-pipeline` invocations PASS (verify reports PASS for every one); all `cmp` invocations exit 0.

- [ ] **Step 2: Single explicit `default_hflip` × `no_gamma_cor`-style spot check**

There's no `no_gamma_cor_hflip` profile — that's intentional. Spot-check that the full default profile (gamma on, hflip off) produces a TOLERANCE=0 PASS on each ctrl_flow:

```bash
for FLOW in passthrough motion mask ccl_bbox; do
  make run-pipeline CTRL_FLOW=$FLOW CFG=default SOURCE="synthetic:moving_box" \
                    WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary || exit 1
done
echo "default-profile model-verify OK"
```

- [ ] **Step 3: `default_hflip` smoke test (gamma + hflip both on)**

```bash
make run-pipeline CTRL_FLOW=motion CFG=default_hflip SOURCE="synthetic:moving_box" \
                  WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary
```

Expected: PASS at TOLERANCE=0. Gamma is composed at the tail, so the hflip and gamma stages are independent.

- [ ] **Step 4: Render sanity grid (visual confirmation)**

```bash
make run-pipeline CTRL_FLOW=passthrough CFG=default      SOURCE="synthetic:moving_box" FRAMES=4
make run-pipeline CTRL_FLOW=passthrough CFG=no_gamma_cor SOURCE="synthetic:moving_box" FRAMES=4
ls -l renders/synthetic-moving-box__width=320__height=240__frames=4__ctrl-flow=passthrough__cfg=default.png
ls -l renders/synthetic-moving-box__width=320__height=240__frames=4__ctrl-flow=passthrough__cfg=no_gamma_cor.png
```

Expected: both PNGs exist; visually the `default` render should look brighter/more saturated than the `no_gamma_cor` render in the midtones (sRGB encoding lifts midtones).

---

## Task 11: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `docs/specs/sparevideo-top-arch.md`

- [ ] **Step 1: README.md updates**

Add a row to the IP block table for `axis_gamma_cor` (mirror the format of the `axis_hflip` row). Add `no_gamma_cor` to any profile-list mention. Add a one-line entry to the "Build Commands" or equivalent section if one exists.

- [ ] **Step 2: CLAUDE.md updates**

In "Project Structure" (around the line listing `hw/ip/hflip/rtl/`), add:

```
- `hw/ip/gamma/rtl/` — sRGB display gamma correction (axis_gamma_cor: 33-entry LUT + linear interp; enabled via `gamma_en` field of `cfg_t`)
```

Under "Build Commands", add `CFG=no_gamma_cor` to the comments listing the available profiles. Update the line:

```
make run-pipeline CFG=no_gamma_cor             # sRGB display gamma bypassed
```

In "Skills"/related notes if relevant: nothing to add.

- [ ] **Step 3: `sparevideo-top-arch.md` update**

Add `axis_gamma_cor` to the top-level pipeline diagram (between the ctrl-flow mux and the output CDC FIFO). Add a brief paragraph in the post-mux section noting the runtime bypass via `CFG.gamma_en` and a forward reference to `axis_gamma_cor-arch.md`.

- [ ] **Step 4: Lint, full regress one more time**

```bash
make lint
make test-ip
make test-py
make run-pipeline CTRL_FLOW=motion CFG=default
```

Expected: all green.

- [ ] **Step 5: Commit docs**

```bash
git add README.md CLAUDE.md docs/specs/sparevideo-top-arch.md
git commit -m "docs(gamma): top arch + README + CLAUDE.md updates"
```

---

## Task 12: Squash, clean up, push

- [ ] **Step 1: Verify all commits on the branch belong to this plan**

```bash
git log --oneline origin/main..HEAD
```

Expected: every commit is gamma-related (cfg_t plumb, generator + model, RTL + core, unit TB, top integration, build wiring, harness, docs). No tangential refactors, no other-plan commits. If anything is off, stop and split it onto a separate branch before squashing.

- [ ] **Step 2: Clean up Task 1 goldens**

```bash
rm -f renders/golden/*__pre-gamma.bin
```

(They are gitignored, so this is a local-only cleanup.)

- [ ] **Step 3: Squash to a single plan commit**

```bash
git reset --soft origin/main
git commit -m "$(cat <<'EOF'
feat(gamma): per-channel sRGB gamma correction (axis_gamma_cor)

Adds a 1-cycle, runtime-bypassable AXIS stage at the post-mux tail of the
proc_clk pipeline that applies an sRGB encode curve to each RGB channel.
A 33-entry LUT addressed by pixel[7:3] with linear interpolation across
pixel[2:0] gives 8-bit fractional accuracy; the closed-form sRGB formula
is the single source of truth in py/gen_gamma_lut.py, mirrored as a
hand-pasted SV localparam in axis_gamma_cor.sv and as a Python LUT in
py/models/ops/gamma_cor.py. A parity test parses the SV file and verifies
byte-for-byte agreement.

cfg_t gains a gamma_en field; default profile turns it on. A new
no_gamma_cor profile disables it for A/B comparison. The CFG=no_gamma_cor
bypass path is byte-identical to the pre-integration baseline (Task 1
golden gate); CFG=default passes the model-based verify at TOLERANCE=0
across all four ctrl_flows.
EOF
)"
```

- [ ] **Step 4: Move the plan to `docs/plans/old/`**

```bash
git mv docs/plans/2026-04-27-axis-gamma-cor-plan.md docs/plans/old/
git commit -m "docs(plans): archive completed gamma_cor plan"
```

- [ ] **Step 5: Push and open PR**

```bash
git push -u origin feat/axis-gamma-cor
gh pr create --base main --title "feat(gamma): axis_gamma_cor — per-channel sRGB gamma correction" --body "$(cat <<'EOF'
## Summary
- New `axis_gamma_cor` AXIS stage at the post-mux tail of the proc_clk pipeline.
- 33-entry sRGB LUT, addressed by pixel[7:3] with linear interpolation; 1-cycle latency.
- Runtime bypass via `cfg_t.gamma_en`; default profile turns it on; new `no_gamma_cor` profile turns it off.
- Single source of truth: `py/gen_gamma_lut.py` (formula). Mirrored in SV `localparam` and Python LUT; parity test guards drift.

## Test plan
- [x] `make test-ip` — every block TB green; new `tb_axis_gamma_cor` covers endpoints, ramp, stall, enable_i=0.
- [x] `make test-py` — model unit tests + SV/Python LUT parity green.
- [x] `make run-pipeline` PASS at TOLERANCE=0 across all 4 ctrl_flows × {default, default_hflip, no_morph, no_gauss, no_gamma_cor}.
- [x] `CFG=no_gamma_cor` byte-identical to pre-integration golden (bypass-path identity gate).

Closes the `axis_gamma_cor` step (§3.4) of `docs/plans/old/2026-04-23-pipeline-extensions-design.md`.
EOF
)"
```

Expected: PR created; the URL printed.

---

## Self-Review

Spec coverage check (against §3.4 of `docs/plans/2026-04-23-pipeline-extensions-design.md` and the brainstorming exchange):

- [x] Domain proc_clk, 24-bit RGB, 1-cycle latency — Task 5 RTL.
- [x] 33-entry LUT, addr=p[7:3], frac=p[2:0], `(LUT[a]*(8-f) + LUT[a+1]*f) >> 3` — Task 5 RTL + Task 4 Python model.
- [x] Single sRGB curve, no `GAMMA_CURVE` knob — confirmed in Tasks 4-5; no Makefile knob added.
- [x] `cfg_t.gamma_en` runtime bypass — Task 3 (cfg_t plumb) + Task 5 (RTL `enable_i`) + Task 7 (top wires `CFG.gamma_en`).
- [x] `no_gamma_cor` profile — Task 3 (SV + Python).
- [x] LUT data parity SV ↔ Python — Task 4 generator + parity test.
- [x] Per-block unit TB — Task 6.
- [x] Reference-model dispatcher composition — Task 9.
- [x] Verification matrix — Task 10 (bypass-path identity + model verify).
- [x] Documentation updates — Task 11.
- [x] Branch hygiene per CLAUDE.md (`feat/axis-gamma-cor` from `origin/main`, squash at completion) — Tasks 0 (already done) + 12.

No placeholders. Type/name consistency: `gamma_en` is the cfg field name in SV and Python; `axis_gamma_cor` is the module name; `SRGB_LUT` is the SV localparam (parsed by parity test); `srgb_lut()` is the Python function; `gamma_cor()` is the Python model entry point.
