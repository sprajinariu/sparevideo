# axis_hud Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the final pipeline-extensions block — `axis_hud`, an 8×8 bitmap text overlay drawn at the post-scaler tail. Every frame shows `F:####  T:XXX  N:##  L:#####us` at output coordinates `(8, 8)`: frame number, control-flow tag, CCL bbox count, and end-to-end input-SOF→HUD-input-SOF latency in µs. The block is runtime-bypassable via `cfg_t.hud_en`; with `hud_en=0` it is a zero-latency combinational passthrough.

**Architecture:** A new `axis_hud` module on `clk_dsp_i`, instantiated in `sparevideo_top` between `u_scale2x.m_axis` and `u_fifo_out.s_axis`. The HUD operates on the **output-resolution** stream so glyphs are never softened by bilinear interpolation. A small font ROM (38 glyphs × 8 bytes; digits + A–Z + `:` + ` `) holds 8×8 bitmaps. Per-pixel render: detect whether `(x,y)` falls in a glyph cell, look up the cell index → glyph index → ROM row → bit; the bit selects between FG (white) and the underlying RGB pixel (passthrough). Sidebands are latched at HUD-input-SOF and held for the whole frame to prevent mid-frame flicker. The four sidebands are produced at `sparevideo_top` level: `frame_num` (free-running counter, increments at every accepted SOF on `u_fifo_in.m_axis`), `bbox_count` (population count over `u_ccl_bboxes` valid lanes, capped at 99), `ctrl_flow_tag` (= `ctrl_flow_i`), and `latency_us` (cycles from input-SOF on `u_fifo_in.m_axis` to input-SOF on `u_hud.s_axis`, multiplied by 10 ns and divided by 1000 with an iterative-divide FSM that runs once per frame during v-blank). The latency is a sim-deterministic-but-pipeline-dependent quantity, so the SV TB writes a per-frame sidecar (`dv/data/hud_latency.txt`) that the Python reference model consumes; the model's other three values it computes itself (frame index, ctrl_flow string, len of valid CCL bboxes). The Python model `py/models/ops/hud.py` composes after the scaler in `models.run_model`, gated by the new `cfg_t.hud_en` field.

**Tech Stack:** SystemVerilog (Verilator 5 synthesis subset — no SVA, no classes, `axis_if` interfaces), Python 3 (numpy + Pillow already in `.venv/`), FuseSoC core files, Makefile parameter propagation through `cfg_t`/`CFG_*` profiles.

**Prerequisites:** All earlier pipeline-extensions blocks (`axis_window3x3`, `axis_morph3x3_open`, `axis_hflip`, `axis_gamma_cor`, `axis_scale2x`) are merged on `main` (see `docs/plans/old/`). Branch from `origin/main` per CLAUDE.md "one branch per plan" — branch name `feat/axis-hud`.

---

## File Structure

**New files:**
- `hw/ip/hud/hud.core` — FuseSoC CAPI=2 core for the new IP.
- `hw/ip/hud/rtl/axis_hud.sv` — the module (~250 lines).
- `hw/ip/hud/rtl/axis_hud_font_pkg.sv` — font ROM constants (`FONT_ROM[38][8]`, glyph-index encode `glyph_idx_t`).
- `hw/ip/hud/tb/tb_axis_hud.sv` — unit TB (`drv_*` pattern).
- `docs/specs/axis_hud-arch.md` — architecture doc.
- `py/models/ops/hud.py` — Python reference model.
- `py/models/ops/hud_font.py` — Python mirror of the font ROM (kept in lockstep with `axis_hud_font_pkg.sv`).
- `py/tests/test_hud.py` — unit tests for the Python model.
- `py/gen_hud_font.py` — one-shot script that emits both `axis_hud_font_pkg.sv` and `hud_font.py` from a single source-of-truth glyph table; checked into git so the SV/Py pair never drifts.

**Modified files:**
- `hw/top/sparevideo_pkg.sv` — add `hud_en` field to `cfg_t`; add `hud_en: 1'b1` to every `CFG_*` profile; add new `CFG_NO_HUD` profile (mirrors `CFG_DEFAULT` with `hud_en=1'b0`).
- `hw/top/sparevideo_top.sv` — declare a new `hud_to_pix_out` interface bundle; instantiate `u_hud` between `u_scale2x.m_axis` and `u_fifo_out.s_axis`; rewire `u_fifo_out.s_axis` to `hud_to_pix_out`. Add a `frame_num`/`bbox_count`/`latency_us` capture block on `clk_dsp_i`. Open `dv/data/hud_latency.txt` and `$fwrite` one line per frame at HUD-input-SOF (this is the sidecar the Python model reads).
- `dv/sv/tb_sparevideo.sv` — extend the `CFG_NAME` resolution `case` chain with `"no_hud"`; nothing else (the SV writes `hud_latency.txt` directly inside `sparevideo_top`).
- `dv/sim/Makefile` — add `IP_HUD_RTL` + `IP_HUD_FONT_PKG`; add `test-ip-hud` target; thread `axis_hud.sv` and `axis_hud_font_pkg.sv` into `RTL_SRCS` and `clean`.
- `Makefile` (top) — extend `--cfg` advertised values to include `no_hud`; add `test-ip-hud` target; persist nothing extra (HUD is gated by the existing `CFG=` profile).
- `py/profiles.py` — add `hud_en=True` to `DEFAULT`; add `NO_HUD` profile mirroring `DEFAULT` with `hud_en=False`; register `"no_hud"` in `PROFILES`.
- `py/models/__init__.py` — accept `hud_en` kwarg; if true, post-process at the very tail with `_hud(...)`. The HUD model reads per-frame metadata: `frame_num` from index, `ctrl_flow_tag` from the dispatch arg, `bbox_count` from the CCL model output (re-run cheaply or pull from a future cached path), and `latency_us` from `dv/data/hud_latency.txt` (env-var path override for tests).
- `py/harness.py` — pass `ctrl_flow` into `run_model` so the HUD model can render the tag; nothing else.
- `py/tests/test_profiles.py` — automatically re-validates after the new `hud_en` field is added (no edit needed; the parity test reads `cfg_t` field names from `sparevideo_pkg.sv`).
- `README.md` — add `axis_hud` to the IP block table; mention the new `no_hud` profile under build options; mention `hud_latency.txt` sidecar under the simulation outputs.
- `CLAUDE.md` — add `hw/ip/hud/rtl/` to the "Project Structure" list; add `CFG=no_hud` example to "Build Commands"; add `axis_hud` to the motion-pipeline lessons-learned section noting the HUD-after-scaler choice and the per-frame sideband-latch rule.
- `docs/specs/sparevideo-top-arch.md` — add `axis_hud` to the post-scaler tail in the block diagram and document the four sideband sources.

**No changes required:** `hw/top/sparevideo_if.sv` (existing `axis_if` covers the stage), every existing per-block IP / TB, `py/frames/`, `py/viz/`, every other Python model, the FIFO-depth audit (HUD has 1-cycle latency and does not change rates).

---

## Task 1: Capture pre-HUD regression goldens

**Purpose:** lock in byte-perfect baseline output of every (ctrl_flow × profile) pairing **before** any package or top-level changes. After integration in Task 9, running with `CFG=no_hud` (the new profile that disables only the HUD) must reproduce every baseline byte-for-byte.

**Files:**
- Create (local, gitignored): `renders/golden/<ctrl_flow>__<profile>__pre-hud.bin` (8 files: 4 flows × 2 profiles `default`, `default_hflip`).

- [ ] **Step 1: Run baselines, capture output**

```bash
mkdir -p renders/golden
for FLOW in passthrough motion mask ccl_bbox; do
  for PROF in default default_hflip; do
    make run-pipeline CTRL_FLOW=$FLOW CFG=$PROF SOURCE="synthetic:moving_box" \
                      WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary
    cp dv/data/output.bin renders/golden/${FLOW}__${PROF}__pre-hud.bin
  done
done
```

Expected: each `make run-pipeline` invocation exits 0; `verify` reports PASS on all 8 frames; 8 binary files exist, each `12 + 640*480*3*8 = 7,372,812` bytes (since CFG_DEFAULT has scaler_en=1 → 640×480 output).

- [ ] **Step 2: Sanity-check goldens**

```bash
ls -l renders/golden/*__pre-hud.bin | wc -l
xxd renders/golden/passthrough__default__pre-hud.bin | head -1
```

Expected: `8`. First 12 bytes decode as `(0x280, 0x1E0, 0x8) = (640, 480, 8)` (little-endian uint32 width/height/frames).

*(Do not commit — `renders/` is gitignored. Goldens are deleted in Task 14.)*

---

## Task 2: Architecture doc

**Files:**
- Create: `docs/specs/axis_hud-arch.md`

- [ ] **Step 1: Write the arch doc**

Use the `hardware-arch-doc` skill. Required sections (sized to roughly mirror `docs/specs/axis_gamma_cor-arch.md`):

1. **Purpose** — 8×8 bitmap text overlay at the post-scaler tail of the proc_clk pipeline, drawing `F:####  T:XXX  N:##  L:#####us` at output coordinates `(8, 8)`. Runtime-bypassable via `enable_i`.
2. **Module Hierarchy** — leaf module; instantiated as `u_hud` in `sparevideo_top` between `u_scale2x.m_axis` and `u_fifo_out.s_axis`. Imports `axis_hud_font_pkg` for the font ROM.
3. **Interface Specification**
   - **Parameters:**
     - `H_ACTIVE` (default `sparevideo_pkg::H_ACTIVE_OUT_2X`; the **output** width — HUD operates post-scaler).
     - `V_ACTIVE` (default `sparevideo_pkg::V_ACTIVE_OUT_2X`; the **output** height).
     - `HUD_X0` (default `8`), `HUD_Y0` (default `8`) — top-left origin in output coordinates.
     - `N_CHARS` (default `30`) — fixed glyph count of the layout string.
   - **Ports:** `clk_i`, `rst_n_i`, `enable_i`, sidebands `frame_num_i[15:0]`, `bbox_count_i[7:0]`, `ctrl_flow_tag_i[1:0]`, `latency_us_i[15:0]`, `s_axis` (`axis_if.rx`, DATA_W=24, USER_W=1), `m_axis` (`axis_if.tx`, DATA_W=24, USER_W=1).
4. **Concept Description** — the HUD sees the post-scaler stream pixel-by-pixel with `(col, row)` counters reset on SOF. For each pixel, if `row ∈ [HUD_Y0, HUD_Y0+8)` and `col ∈ [HUD_X0, HUD_X0+N_CHARS*8)`, it is in the HUD region. The HUD region is partitioned into `N_CHARS` cells of width 8. The cell index `c = (col - HUD_X0) >> 3` selects a glyph from a per-frame **glyph-index table** (32 4-bit slots — the layout has 30 glyphs but a power-of-two array is cheaper). Glyph index → `FONT_ROM[glyph_idx][row - HUD_Y0]` returns one byte; the relevant bit is `byte[7 - ((col - HUD_X0) & 7)]`. If the bit is 1 the output pixel is FG (`24'hFF_FF_FF`); if 0 the output pixel is the input pixel (passthrough). Outside the HUD region, output is the input pixel.
5. **Internal Architecture**
   - 5.1 ASCII diagram of the datapath: input AXIS → 1-cycle skid (`stage_advance` like `axis_gamma_cor`) → render mux → output AXIS. Sideband latch is in parallel.
   - 5.2 The 30-cell glyph-index table is a `glyph_idx_t [N_CHARS]` array (`glyph_idx_t = logic [5:0]`, encoding 0..37). The table layout is fixed at synthesis except for the 4 frame#, 3 tag, 2 bbox#, and 5 latency# digit cells, which are recomputed at SOF from the latched sideband values.
   - 5.3 Decimal expansion of `frame_num[15:0]`, `bbox_count[6:0]`, `latency_us[15:0]` is by an iterative divide-by-10 FSM running once per frame during v-blank (no fast path needed — V_BLANK ≥ 16 lines × H_TOTAL ≫ 64 cycles for the worst case). The FSM completes well before the next SOF.
   - 5.4 Output-pixel render is purely combinational off the latched glyph-index table; the only sequential state is the 1-cycle pipeline register (skid) and the `(col, row)` counters.
6. **Control Logic**
   - 6.1 Three FSMs: (a) `(col, row)` counter (advances on `s_axis.tvalid && s_axis.tready`; resets on SOF); (b) sideband latch (latches all four sideband values at SOF); (c) decimal-expand FSM (idle → busy on SOF; emits one digit per cycle for 4+2+5 = 11 cycles; updates the digit-cell slots of the glyph-index table; back to idle).
   - 6.2 The `bbox_count` is **clamped to 99** before decimal expansion: if `bbox_count_i > 99`, two `9` digits are written and a high-order tilde is not drawn (acceptable for the 2-digit field).
   - 6.3 The `ctrl_flow_tag` is decoded by a 4-entry ROM into three glyph indices (`PAS`, `MOT`, `MSK`, `CCL`).
7. **Timing** — 1 cycle of pipeline latency (1-deep skid, identical pattern to `axis_gamma_cor`). Per-frame setup: 11 cycles to expand frame#/bbox#/latency digits during v-blank.
8. **Shared Types** — uses `pixel_t` and `component_t` from `sparevideo_pkg`. Defines `glyph_idx_t = logic [5:0]` in `axis_hud_font_pkg`.
9. **Known Limitations** — `bbox_count` >99 saturates at 99; `frame_num` >9999 wraps in display only (RTL counter is 16-bit modular); `latency_us` >99999 saturates at 99999. Layout is fixed at synthesis; no runtime reposition. Glyph set is fixed at synthesis (digits + A–Z + `:` + ` `; lowercase not supported).
10. **References** — `sparevideo-top-arch.md`, `docs/plans/2026-04-23-pipeline-extensions-design.md` §3.6, `docs/specs/axis_gamma_cor-arch.md` (skid pattern reference).

- [ ] **Step 2: Commit the arch doc**

```bash
git add docs/specs/axis_hud-arch.md
git commit -m "docs(hud): axis_hud architecture spec"
```

---

## Task 3: Add `hud_en` field to `cfg_t` and `CFG_NO_HUD` profile

**Files:**
- Modify: `hw/top/sparevideo_pkg.sv` (add to `cfg_t` packed struct + every `CFG_*` profile literal).
- Modify: `dv/sv/tb_sparevideo.sv` (extend `CFG_NAME` resolution case chain).
- Modify: `py/profiles.py` (add `hud_en` key + `NO_HUD` profile).

- [ ] **Step 1: Add `hud_en` to `cfg_t`**

Edit `hw/top/sparevideo_pkg.sv`. In the `cfg_t` struct definition (around line 85), append below `scaler_en`:

```systemverilog
        logic       scaler_en;           // 2x bilinear upscaler at output tail
        logic       hud_en;              // 8x8 bitmap HUD overlay at post-scaler tail
        pixel_t     bbox_color;          // overlay colour
```

(The existing field above `bbox_color` is `scaler_en`; insert `hud_en` between them.)

- [ ] **Step 2: Add `hud_en: 1'b1` to every existing `CFG_*` literal**

In each of `CFG_DEFAULT`, `CFG_DEFAULT_HFLIP`, `CFG_NO_EMA`, `CFG_NO_MORPH`, `CFG_NO_GAUSS`, `CFG_NO_GAMMA_COR`, `CFG_NO_SCALER`, insert `hud_en: 1'b1,` between `scaler_en` and `bbox_color`. Example (after the change for `CFG_DEFAULT`):

```systemverilog
        gamma_en:          1'b1,
        scaler_en:         1'b1,
        hud_en:            1'b1,
        bbox_color:        24'h00_FF_00
    };
```

Repeat verbatim for all 7 existing profiles.

- [ ] **Step 3: Add `CFG_NO_HUD` profile**

Append below `CFG_NO_SCALER`:

```systemverilog
    // HUD bitmap overlay bypassed (post-scaler tail is identity passthrough).
    // Byte-identical to CFG_DEFAULT for every pixel outside the HUD region.
    localparam cfg_t CFG_NO_HUD = '{
        motion_thresh:     8'd16,
        alpha_shift:       3,
        alpha_shift_slow:  6,
        grace_frames:      0,
        grace_alpha_shift: 1,
        gauss_en:          1'b1,
        morph_en:          1'b1,
        hflip_en:          1'b0,
        gamma_en:          1'b1,
        scaler_en:         1'b1,
        hud_en:            1'b0,
        bbox_color:        24'h00_FF_00
    };
```

- [ ] **Step 4: Wire `CFG_NO_HUD` into the TB resolution chain**

Edit `dv/sv/tb_sparevideo.sv:50-57`. Insert a new ternary above the trailing `CFG_DEFAULT`:

```systemverilog
    localparam sparevideo_pkg::cfg_t CFG =
        (CFG_NAME == "default_hflip") ? sparevideo_pkg::CFG_DEFAULT_HFLIP :
        (CFG_NAME == "no_ema")        ? sparevideo_pkg::CFG_NO_EMA        :
        (CFG_NAME == "no_morph")      ? sparevideo_pkg::CFG_NO_MORPH      :
        (CFG_NAME == "no_gauss")      ? sparevideo_pkg::CFG_NO_GAUSS      :
        (CFG_NAME == "no_gamma_cor")  ? sparevideo_pkg::CFG_NO_GAMMA_COR  :
        (CFG_NAME == "no_scaler")     ? sparevideo_pkg::CFG_NO_SCALER     :
        (CFG_NAME == "no_hud")        ? sparevideo_pkg::CFG_NO_HUD        :
                                        sparevideo_pkg::CFG_DEFAULT;
```

Edit the `CFG_NAME` validation `initial` block (lines 124–132) to append the `"no_hud"` case alongside the other valid names.

- [ ] **Step 5: Mirror in `py/profiles.py`**

Edit `py/profiles.py`:

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
    scaler_en=True,
    hud_en=True,
    bbox_color=0x00_FF_00,
)
```

(Insert `hud_en=True,` between `scaler_en=True,` and `bbox_color`.)

Add `NO_HUD` and register it:

```python
# HUD bitmap overlay bypassed.
NO_HUD: ProfileT = dict(DEFAULT, hud_en=False)

PROFILES: dict[str, ProfileT] = {
    "default":       DEFAULT,
    "default_hflip": DEFAULT_HFLIP,
    "no_ema":        NO_EMA,
    "no_morph":      NO_MORPH,
    "no_gauss":      NO_GAUSS,
    "no_gamma_cor":  NO_GAMMA_COR,
    "no_scaler":     NO_SCALER,
    "no_hud":        NO_HUD,
}
```

- [ ] **Step 6: Run the parity test (`test_profiles.py`) — must pass before going further**

Run: `cd py && python -m pytest tests/test_profiles.py -v`
Expected: PASS — the test reads `cfg_t` field names from `sparevideo_pkg.sv` and confirms every Python profile dict has the same keys.

- [ ] **Step 7: Run the existing CFG=no_scaler regression to confirm no fields broke**

Run: `make run-pipeline CTRL_FLOW=motion CFG=no_scaler MODE=binary`
Expected: PASS. (Note: `CFG_NO_HUD` is not yet wired into RTL — `hud_en` is just a field nobody reads. This step proves the cfg_t extension didn't break anything.)

- [ ] **Step 8: Commit**

```bash
git add hw/top/sparevideo_pkg.sv dv/sv/tb_sparevideo.sv py/profiles.py
git commit -m "cfg(hud): add hud_en field to cfg_t and CFG_NO_HUD profile"
```

---

## Task 4: Generator script + font ROM source-of-truth

**Purpose:** keep the SV font ROM (`axis_hud_font_pkg.sv`) and the Python font (`hud_font.py`) in lockstep by generating both from one Python source.

**Files:**
- Create: `py/gen_hud_font.py` — checked-in generator.
- Create: `hw/ip/hud/rtl/axis_hud_font_pkg.sv` — generated SV package (initially generated, then committed).
- Create: `py/models/ops/hud_font.py` — generated Python font (initially generated, then committed).

- [ ] **Step 1: Write the generator script**

Create `py/gen_hud_font.py`:

```python
#!/usr/bin/env python3
"""Source-of-truth glyph table for axis_hud. Emits both
hw/ip/hud/rtl/axis_hud_font_pkg.sv and py/models/ops/hud_font.py from a
single dict. Run after editing GLYPHS; commit both regenerated files
alongside the source change.

Glyph index encoding:
  0..9  -> '0'..'9'
  10..35 -> 'A'..'Z'
  36 -> ':'
  37 -> ' '
"""
from pathlib import Path

# 8x8 glyphs as 8-byte tuples, MSB = leftmost pixel.
# IBM-style 8x8 — drawn by hand; only the characters used by the HUD layout
# need to be filled. Unused entries (most letters) are zero, keeping the
# ROM dense and the test surface small.
def _g(*rows):
    assert len(rows) == 8 and all(0 <= r < 256 for r in rows)
    return tuple(rows)

GLYPHS = {
    '0': _g(0x3C,0x66,0x6E,0x76,0x66,0x66,0x3C,0x00),
    '1': _g(0x18,0x38,0x18,0x18,0x18,0x18,0x7E,0x00),
    '2': _g(0x3C,0x66,0x06,0x0C,0x30,0x60,0x7E,0x00),
    '3': _g(0x3C,0x66,0x06,0x1C,0x06,0x66,0x3C,0x00),
    '4': _g(0x0C,0x1C,0x3C,0x6C,0x7E,0x0C,0x0C,0x00),
    '5': _g(0x7E,0x60,0x7C,0x06,0x06,0x66,0x3C,0x00),
    '6': _g(0x1C,0x30,0x60,0x7C,0x66,0x66,0x3C,0x00),
    '7': _g(0x7E,0x06,0x0C,0x18,0x30,0x30,0x30,0x00),
    '8': _g(0x3C,0x66,0x66,0x3C,0x66,0x66,0x3C,0x00),
    '9': _g(0x3C,0x66,0x66,0x3E,0x06,0x0C,0x38,0x00),
    'A': _g(0x18,0x3C,0x66,0x66,0x7E,0x66,0x66,0x00),
    'B': _g(0x7C,0x66,0x66,0x7C,0x66,0x66,0x7C,0x00),
    'C': _g(0x3C,0x66,0x60,0x60,0x60,0x66,0x3C,0x00),
    'D': _g(0x78,0x6C,0x66,0x66,0x66,0x6C,0x78,0x00),
    'E': _g(0x7E,0x60,0x60,0x78,0x60,0x60,0x7E,0x00),
    'F': _g(0x7E,0x60,0x60,0x78,0x60,0x60,0x60,0x00),
    'G': _g(0x3C,0x66,0x60,0x6E,0x66,0x66,0x3C,0x00),
    'H': _g(0x66,0x66,0x66,0x7E,0x66,0x66,0x66,0x00),
    'I': _g(0x3C,0x18,0x18,0x18,0x18,0x18,0x3C,0x00),
    'J': _g(0x1E,0x0C,0x0C,0x0C,0x0C,0x6C,0x38,0x00),
    'K': _g(0x66,0x6C,0x78,0x70,0x78,0x6C,0x66,0x00),
    'L': _g(0x60,0x60,0x60,0x60,0x60,0x60,0x7E,0x00),
    'M': _g(0x63,0x77,0x7F,0x6B,0x63,0x63,0x63,0x00),
    'N': _g(0x66,0x76,0x7E,0x7E,0x6E,0x66,0x66,0x00),
    'O': _g(0x3C,0x66,0x66,0x66,0x66,0x66,0x3C,0x00),
    'P': _g(0x7C,0x66,0x66,0x7C,0x60,0x60,0x60,0x00),
    'Q': _g(0x3C,0x66,0x66,0x66,0x6A,0x6C,0x36,0x00),
    'R': _g(0x7C,0x66,0x66,0x7C,0x78,0x6C,0x66,0x00),
    'S': _g(0x3C,0x66,0x60,0x3C,0x06,0x66,0x3C,0x00),
    'T': _g(0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0x00),
    'U': _g(0x66,0x66,0x66,0x66,0x66,0x66,0x3C,0x00),
    'V': _g(0x66,0x66,0x66,0x66,0x66,0x3C,0x18,0x00),
    'W': _g(0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0x00),
    'X': _g(0x66,0x66,0x3C,0x18,0x3C,0x66,0x66,0x00),
    'Y': _g(0x66,0x66,0x66,0x3C,0x18,0x18,0x18,0x00),
    'Z': _g(0x7E,0x06,0x0C,0x18,0x30,0x60,0x7E,0x00),
    ':': _g(0x00,0x18,0x18,0x00,0x18,0x18,0x00,0x00),
    ' ': _g(0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00),
}

# Index order locked: digits, A-Z, ':', ' '.
ORDER = list("0123456789") + list("ABCDEFGHIJKLMNOPQRSTUVWXYZ") + [':', ' ']
assert len(ORDER) == 38

ROOT = Path(__file__).resolve().parent.parent

def emit_sv():
    lines = []
    lines.append("// AUTO-GENERATED by py/gen_hud_font.py — do not hand-edit.")
    lines.append("// Edit GLYPHS in py/gen_hud_font.py and re-run, then commit both files.")
    lines.append("")
    lines.append("package axis_hud_font_pkg;")
    lines.append("")
    lines.append("    typedef logic [5:0] glyph_idx_t;")
    lines.append("")
    lines.append("    // Glyph slots (must match ORDER in py/gen_hud_font.py)")
    for i, ch in enumerate(ORDER):
        name = ch if ch.isalnum() else ('COLON' if ch == ':' else 'SPACE')
        lines.append(f"    localparam glyph_idx_t G_{name} = 6'd{i};")
    lines.append("")
    lines.append(f"    localparam int N_GLYPHS = {len(ORDER)};")
    lines.append("    localparam logic [7:0] FONT_ROM [N_GLYPHS][8] = '{")
    for i, ch in enumerate(ORDER):
        rows = GLYPHS[ch]
        body = ", ".join(f"8'h{r:02X}" for r in rows)
        comma = "," if i < len(ORDER) - 1 else ""
        comment = ch if ch != ' ' else 'SPACE'
        lines.append(f"        '{{{body}}}{comma}  // {i:2d} = '{comment}'")
    lines.append("    };")
    lines.append("")
    lines.append("endpackage")
    lines.append("")
    (ROOT / "hw/ip/hud/rtl/axis_hud_font_pkg.sv").write_text("\n".join(lines))

def emit_py():
    lines = []
    lines.append("\"\"\"AUTO-GENERATED by py/gen_hud_font.py — do not hand-edit.\"\"\"")
    lines.append("")
    lines.append("ORDER = " + repr(ORDER))
    lines.append("")
    lines.append("# Glyph index by character.")
    lines.append("GLYPH_IDX = {ch: i for i, ch in enumerate(ORDER)}")
    lines.append("")
    lines.append("# 8x8 bitmaps; MSB = leftmost pixel.")
    lines.append("FONT_ROM = [")
    for ch in ORDER:
        rows = GLYPHS[ch]
        body = ", ".join(f"0x{r:02X}" for r in rows)
        comment = ch if ch != ' ' else 'SPACE'
        lines.append(f"    ({body}),  # '{comment}'")
    lines.append("]")
    lines.append("")
    (ROOT / "py/models/ops/hud_font.py").write_text("\n".join(lines))

if __name__ == "__main__":
    emit_sv()
    emit_py()
    print(f"wrote {ROOT}/hw/ip/hud/rtl/axis_hud_font_pkg.sv")
    print(f"wrote {ROOT}/py/models/ops/hud_font.py")
```

- [ ] **Step 2: Run the generator and inspect the outputs**

```bash
mkdir -p hw/ip/hud/rtl
. .venv/bin/activate
python py/gen_hud_font.py
```

Expected: two new files, each a few hundred lines. Verify the SV file syntax is well-formed by `head -30 hw/ip/hud/rtl/axis_hud_font_pkg.sv`.

- [ ] **Step 3: Commit**

```bash
git add py/gen_hud_font.py hw/ip/hud/rtl/axis_hud_font_pkg.sv py/models/ops/hud_font.py
git commit -m "hud(font): add generator + font ROM (SV pkg + Python mirror)"
```

---

## Task 5: Python reference model — passthrough first, then HUD region render

**Files:**
- Create: `py/models/ops/hud.py`
- Create: `py/tests/test_hud.py`

- [ ] **Step 1: Write a failing test for the passthrough case**

Create `py/tests/test_hud.py`:

```python
import numpy as np
from models.ops.hud import hud


def test_hud_outside_region_is_passthrough():
    # 64x64 RGB frame of solid grey
    frame = np.full((64, 64, 3), 100, dtype=np.uint8)
    out = hud(frame, frame_num=0, ctrl_flow_tag="MOT", bbox_count=0, latency_us=0,
              hud_x0=8, hud_y0=8, n_chars=30)
    # Pixels outside the HUD region (rows 0..7, 16..63 OR cols 0..7, 248..63) must be unchanged.
    # (Rows 8..15 cols 8..247 are the HUD region; for n_chars=30 the right edge is 8+240=248.)
    assert (out[0:8, :] == 100).all()
    assert (out[16:, :] == 100).all()
    assert (out[8:16, 0:8] == 100).all()
```

- [ ] **Step 2: Run the test, expect failure**

```bash
cd py && python -m pytest tests/test_hud.py::test_hud_outside_region_is_passthrough -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'models.ops.hud'`.

- [ ] **Step 3: Implement the model — passthrough only first**

Create `py/models/ops/hud.py`:

```python
"""HUD bitmap overlay reference model. Mirrors axis_hud RTL bit-for-bit."""
from __future__ import annotations
import numpy as np
from models.ops.hud_font import FONT_ROM, GLYPH_IDX

FG = np.array([255, 255, 255], dtype=np.uint8)

CTRL_TAG_MAP = {
    "passthrough": "PAS",
    "motion":      "MOT",
    "mask":        "MSK",
    "ccl_bbox":    "CCL",
}


def _decimals(value: int, width: int) -> str:
    """Right-justified zero-padded decimal of `value`, saturated to 10**width-1."""
    cap = 10 ** width - 1
    v = max(0, min(value, cap))
    return f"{v:0{width}d}"


def _layout(frame_num: int, ctrl_flow_tag: str, bbox_count: int, latency_us: int) -> str:
    """30-char layout: 'F:####  T:XXX  N:##  L:#####us'."""
    f = _decimals(frame_num, 4)
    t = ctrl_flow_tag[:3].ljust(3, ' ').upper()
    n = _decimals(bbox_count, 2)
    l = _decimals(latency_us, 5)
    s = f"F:{f}  T:{t}  N:{n}  L:{l}us"
    assert len(s) == 30, f"layout len {len(s)} != 30: {s!r}"
    return s


def hud(frame: np.ndarray, *, frame_num: int, ctrl_flow_tag: str,
        bbox_count: int, latency_us: int,
        hud_x0: int = 8, hud_y0: int = 8, n_chars: int = 30) -> np.ndarray:
    out = frame.copy()
    layout = _layout(frame_num, ctrl_flow_tag, bbox_count, latency_us)
    H, W = frame.shape[:2]
    for c in range(n_chars):
        ch = layout[c]
        gi = GLYPH_IDX.get(ch, GLYPH_IDX[' '])
        rom = FONT_ROM[gi]
        for ry in range(8):
            y = hud_y0 + ry
            if y < 0 or y >= H:
                continue
            row_byte = rom[ry]
            for rx in range(8):
                x = hud_x0 + c * 8 + rx
                if x < 0 or x >= W:
                    continue
                bit = (row_byte >> (7 - rx)) & 1
                if bit:
                    out[y, x] = FG
    return out
```

- [ ] **Step 4: Run the test, expect pass**

```bash
cd py && python -m pytest tests/test_hud.py::test_hud_outside_region_is_passthrough -v
```

Expected: PASS.

- [ ] **Step 5: Add a glyph-render test**

Append to `py/tests/test_hud.py`:

```python
def test_hud_renders_F_glyph_at_origin():
    # Make a 32x32 black frame; ask the HUD to render only the 'F' digit at (8,8).
    frame = np.zeros((32, 32, 3), dtype=np.uint8)
    out = hud(frame, frame_num=0, ctrl_flow_tag="MOT", bbox_count=0, latency_us=0,
              hud_x0=8, hud_y0=8, n_chars=1)
    # First glyph in layout is 'F'. The 'F' bitmap row 0 is 0x7E = 0b01111110.
    # That means cols (8..14) are FG, col 15 is BG. Row 7 of 'F' is 0x00 (all BG).
    cell = out[8:16, 8:16]
    # Row 0: cols 1..6 white, others black.
    assert (cell[0, 1:7] == FG).all()
    assert (cell[0, 0] == 0).all()
    assert (cell[0, 7] == 0).all()
    # Row 7: all black.
    assert (cell[7] == 0).all()
```

- [ ] **Step 6: Run, expect pass**

```bash
cd py && python -m pytest tests/test_hud.py -v
```

Expected: 2 PASS.

- [ ] **Step 7: Add a sideband-mapping test**

Append:

```python
def test_hud_layout_string_format():
    from models.ops.hud import _layout
    assert _layout(42, "MOT", 5, 1234) == "F:0042  T:MOT  N:05  L:01234us"
    # Saturation
    assert _layout(99999, "PAS", 200, 999999) == "F:9999  T:PAS  N:99  L:99999us"
    # Truncated tag
    assert _layout(0, "MASK", 0, 0)[:14] == "F:0000  T:MAS "
```

- [ ] **Step 8: Run all tests**

```bash
cd py && python -m pytest tests/test_hud.py -v
```

Expected: 3 PASS.

- [ ] **Step 9: Commit**

```bash
git add py/models/ops/hud.py py/tests/test_hud.py
git commit -m "model(hud): add Python reference model + unit tests"
```

---

## Task 6: Compose HUD into the model dispatcher (gated by `hud_en`)

**Purpose:** integrate the HUD model at the very tail of `models.run_model` so `make verify` already exercises it (with `hud_latency_us=0` for now, which works as long as RTL is also driving 0 — but the RTL is not yet built; this task's verification is end-to-end through the model alone).

**Files:**
- Modify: `py/models/__init__.py`
- Modify: `py/harness.py` (pass `ctrl_flow` into the kwargs so HUD model can render the tag)
- Create: `py/models/ops/_hud_metadata.py` — small helper that loads `dv/data/hud_latency.txt` (path overridable via `HUD_LATENCY_FILE` env var); also computes `bbox_count` per frame from the CCL model output.

- [ ] **Step 1: Write a test that the dispatcher applies the HUD when `hud_en=True`**

Append to `py/tests/test_hud.py`:

```python
def test_dispatcher_applies_hud_when_enabled(monkeypatch, tmp_path):
    # Force the latency file to a deterministic stub.
    lat_file = tmp_path / "hud_latency.txt"
    lat_file.write_text("100\n200\n")
    monkeypatch.setenv("HUD_LATENCY_FILE", str(lat_file))

    from models import run_model
    frames = [np.zeros((32, 32, 3), dtype=np.uint8) for _ in range(2)]
    out = run_model("passthrough", frames,
                    motion_thresh=16, alpha_shift=3, alpha_shift_slow=6,
                    grace_frames=0, grace_alpha_shift=1,
                    gauss_en=True, morph_en=True, hflip_en=False,
                    gamma_en=False, scaler_en=False, hud_en=True,
                    bbox_color=0x00FF00)
    # HUD region (rows 8..15) must contain at least one white pixel from the 'F' glyph.
    assert (out[0][8:16, 8:16] == 255).any()
    # Outside, still black.
    assert (out[0][:8, :] == 0).all()
```

- [ ] **Step 2: Run, expect failure**

```bash
cd py && python -m pytest tests/test_hud.py::test_dispatcher_applies_hud_when_enabled -v
```

Expected: FAIL — dispatcher doesn't apply HUD yet.

- [ ] **Step 3: Implement the metadata helper**

Create `py/models/ops/_hud_metadata.py`:

```python
"""Per-frame metadata for the HUD model. Reads latency_us from a sidecar
file written by sparevideo_top during simulation."""
from __future__ import annotations
import os
from pathlib import Path

DEFAULT_PATH = "dv/data/hud_latency.txt"


def load_latencies(num_frames: int) -> list[int]:
    """One latency per frame, in microseconds. If the file is missing or short,
    pads with zeros (useful for unit tests and sw-dry-run paths)."""
    path = os.environ.get("HUD_LATENCY_FILE", DEFAULT_PATH)
    p = Path(path)
    if not p.exists():
        return [0] * num_frames
    raw = [int(x.strip()) for x in p.read_text().splitlines() if x.strip()]
    if len(raw) < num_frames:
        raw = raw + [0] * (num_frames - len(raw))
    return raw[:num_frames]
```

- [ ] **Step 4: Wire HUD into `models/__init__.py`**

Edit `py/models/__init__.py`:

```python
from models.ops.gamma_cor   import gamma_cor as _gamma_cor
from models.ops.hflip       import hflip      as _hflip
from models.ops.scale2x     import scale2x    as _scale2x
from models.ops.hud         import hud        as _hud, CTRL_TAG_MAP
from models.ops._hud_metadata import load_latencies as _load_latencies
from models.passthrough     import run as _run_passthrough
from models.motion          import run as _run_motion
from models.mask            import run as _run_mask
from models.ccl_bbox        import run as _run_ccl_bbox
from models.bbox_counts     import bbox_counts_per_frame as _bbox_counts_for  # see Step 4a

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
    hflip_en  = kwargs.pop("hflip_en", False)
    gamma_en  = kwargs.pop("gamma_en", False)
    scaler_en = kwargs.pop("scaler_en", False)
    hud_en    = kwargs.pop("hud_en", False)
    in_frames = [_hflip(f) for f in frames] if hflip_en else frames
    out = _MODELS[ctrl_flow](in_frames, **kwargs)
    if gamma_en:
        out = [_gamma_cor(f) for f in out]
    if scaler_en:
        out = [_scale2x(f) for f in out]
    if hud_en:
        n = len(out)
        latencies = _load_latencies(n)
        bbox_counts = _bbox_counts_for(ctrl_flow, in_frames, **{k: v for k, v in kwargs.items()
                                                                if k in {"motion_thresh","alpha_shift",
                                                                         "alpha_shift_slow","grace_frames",
                                                                         "grace_alpha_shift","gauss_en",
                                                                         "morph_en"}})
        tag = CTRL_TAG_MAP.get(ctrl_flow, "???")
        out = [_hud(f, frame_num=i, ctrl_flow_tag=tag,
                    bbox_count=bbox_counts[i], latency_us=latencies[i])
               for i, f in enumerate(out)]
    return out
```

- [ ] **Step 4a: Implement the helper `py/models/bbox_counts.py`**

The CCL entry point in this repo is `models.ccl.run_ccl(masks, ...)`. It returns a list of length `len(masks)`, where each element is a list of N_OUT bboxes (some `None`). The HUD's `bbox_count` is the per-frame count of non-`None` slots. We have to first compute the post-morph mask (since the SV CCL runs on the morph-cleaned mask). Use the same mask-derivation that `motion.py` uses internally, factored out as a shared helper. Concrete sketch:

```python
"""Per-frame bbox-count helper for the HUD model. Mirrors the count the SV
emits via popcount over u_ccl_bboxes.valid[]."""
from __future__ import annotations
import numpy as np
from models.ccl import run_ccl
from models.motion import _luma, _ema_step, _build_mask  # if these helpers exist; else inline
from models.ops.morph_open import morph_open

# Match sparevideo_pkg constants
N_OUT = 8
N_LABELS_INT = 64
MIN_COMPONENT_PIXELS = 16


def bbox_counts_per_frame(ctrl_flow: str, frames, *, motion_thresh, alpha_shift,
                           alpha_shift_slow, grace_frames, grace_alpha_shift,
                           gauss_en, morph_en, **_ignored) -> list[int]:
    if ctrl_flow in ("passthrough", "mask"):
        return [0] * len(frames)
    # Build per-frame masks via the same path used by motion.run/ccl_bbox.run.
    # If motion.py doesn't expose a public mask helper, compute inline:
    masks = _compute_motion_masks(frames, motion_thresh, alpha_shift,
                                  alpha_shift_slow, grace_frames,
                                  grace_alpha_shift, gauss_en)
    if morph_en:
        masks = [morph_open(m) for m in masks]
    bboxes_per_frame = run_ccl(masks, n_out=N_OUT,
                               n_labels_int=N_LABELS_INT,
                               min_component_pixels=MIN_COMPONENT_PIXELS)
    return [sum(1 for b in bb if b is not None) for bb in bboxes_per_frame]


def _compute_motion_masks(frames, motion_thresh, alpha_shift, alpha_shift_slow,
                           grace_frames, grace_alpha_shift, gauss_en) -> list:
    """Inline-only if motion.py does not already export a helper. Implementation
    must mirror motion.py's mask-derivation exactly. See motion.py:run() — the
    mask is computed from |Y_cur - Y_prev| > THRESH after optional Gaussian and
    selective EMA. Factor that block out into a top-level helper in motion.py
    in this same task and call it from here."""
    raise NotImplementedError("factor mask derivation out of motion.py:run()")
```

**Acceptance gate for this helper:** when called with the same args as the SV TB (`CFG=default` profile fields), `bbox_counts_per_frame("motion", frames, ...)` returns the same list as `[popcount(u_ccl_bboxes.valid) per frame]` would in SV. Validate by reading `dv/data/hud_latency.txt` and comparing to no signal (latency-only) — but bbox counts are validated end-to-end by Task 12 since any mismatch breaks the HUD-region pixel compare at TOLERANCE=0.

**Note on bbox-count framing convention:** the SV `bbox_count` snapshot at HUD-input-SOF reflects the bboxes axis_ccl emitted at the *previous* frame's EOF (CCL output is consumed by overlay one frame later). The Python helper must match this off-by-one — pre-shift the list by one position with `[0] + bbox_counts_per_frame(...)[:-1]` if the integration test (Task 12) reveals the framing is wrong. Resolve before merging.

- [ ] **Step 5: Run the dispatcher test**

```bash
cd py && python -m pytest tests/test_hud.py::test_dispatcher_applies_hud_when_enabled -v
```

Expected: PASS.

- [ ] **Step 6: Re-run the full Python test suite to confirm no regressions**

```bash
cd py && python -m pytest tests/ -v
```

Expected: PASS for everything (test_profiles already validated; other tests don't pass `hud_en` so they default to False).

- [ ] **Step 7: Commit**

```bash
git add py/models/__init__.py py/models/ops/_hud_metadata.py py/tests/test_hud.py
git commit -m "model(hud): integrate HUD at tail of run_model dispatcher"
```

---

## Task 7: RTL skeleton — passthrough mode, sideband port surface

**Purpose:** create `axis_hud.sv` with the full port surface and a working `enable_i=0` passthrough. No glyph render yet — this lands the integration hook so the unit TB can be wired up alongside.

**Files:**
- Create: `hw/ip/hud/rtl/axis_hud.sv`
- Create: `hw/ip/hud/hud.core`

- [ ] **Step 1: Write the FuseSoC core file**

Create `hw/ip/hud/hud.core`:

```yaml
CAPI=2:
name: "sparevideo:ip:hud"
description: "8x8 bitmap text overlay (frame#/ctrl-flow/bbox-count/latency µs); 1-cycle latency, runtime bypass"

filesets:
  files_rtl:
    files:
      - rtl/axis_hud_font_pkg.sv
      - rtl/axis_hud.sv
    file_type: systemVerilogSource
    depend:
      - sparevideo:pkg:common

targets:
  default:
    filesets:
      - files_rtl
```

- [ ] **Step 2: Create the RTL skeleton (passthrough mode only)**

Create `hw/ip/hud/rtl/axis_hud.sv`:

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_hud — 8x8 bitmap text overlay on a 24-bit RGB AXIS at the post-scaler tail.
//
// Renders 30 characters at output coordinates (HUD_X0, HUD_Y0):
//   "F:####  T:XXX  N:##  L:#####us"
//
// Sideband ports are latched at HUD-input-SOF and held for the whole frame.
// Frame number, bbox count, and latency are decimal-expanded by an iterative
// divide-by-10 FSM running once per frame during v-blank.
//
// enable_i = 0: zero-latency combinational passthrough.

module axis_hud
    import sparevideo_pkg::*;
    import axis_hud_font_pkg::*;
#(
    parameter int H_ACTIVE = sparevideo_pkg::H_ACTIVE_OUT_2X,
    parameter int V_ACTIVE = sparevideo_pkg::V_ACTIVE_OUT_2X,
    parameter int HUD_X0   = 8,
    parameter int HUD_Y0   = 8,
    parameter int N_CHARS  = 30
) (
    input  logic clk_i,
    input  logic rst_n_i,
    input  logic enable_i,

    input  logic [15:0] frame_num_i,
    input  logic [7:0]  bbox_count_i,
    input  logic [1:0]  ctrl_flow_tag_i,
    input  logic [15:0] latency_us_i,

    axis_if.rx s_axis,
    axis_if.tx m_axis
);

    // ---- enable_i=0 zero-latency passthrough ------------------------
    // This skeleton has only the bypass; full glyph render is added in Task 8.
    always_comb begin
        s_axis.tready = m_axis.tready;
        m_axis.tdata  = s_axis.tdata;
        m_axis.tvalid = s_axis.tvalid;
        m_axis.tlast  = s_axis.tlast;
        m_axis.tuser  = s_axis.tuser;
    end

    // Touch unused signals so Verilator does not warn while the
    // glyph-render path is still being implemented.
    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused;
    assign _unused = enable_i | (|frame_num_i) | (|bbox_count_i)
                   | (|ctrl_flow_tag_i) | (|latency_us_i)
                   | (H_ACTIVE != 0) | (V_ACTIVE != 0)
                   | (HUD_X0 != 0)   | (HUD_Y0 != 0)   | (N_CHARS != 0);
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
```

- [ ] **Step 3: Lint the new RTL**

```bash
verilator --lint-only -Ihw/top -Ihw/ip/hud/rtl \
  hw/top/sparevideo_pkg.sv hw/top/sparevideo_if.sv \
  hw/ip/hud/rtl/axis_hud_font_pkg.sv hw/ip/hud/rtl/axis_hud.sv
```

Expected: zero warnings, zero errors.

- [ ] **Step 4: Commit**

```bash
git add hw/ip/hud/hud.core hw/ip/hud/rtl/axis_hud.sv
git commit -m "rtl(hud): axis_hud skeleton (passthrough + sideband port surface)"
```

---

## Task 8: RTL — full glyph render path

**Files:**
- Modify: `hw/ip/hud/rtl/axis_hud.sv` (replace the skeleton's combinational passthrough with the full datapath; keep the `enable_i=0` bypass).

- [ ] **Step 1: Replace the module body with the full implementation**

Edit `hw/ip/hud/rtl/axis_hud.sv`. Replace everything from the `// ---- enable_i=0 ...` comment to `endmodule` with:

```systemverilog
    // ---- Sideband latch (held frame-stable from SOF) ---------------
    logic [15:0] frame_num_q;
    logic [7:0]  bbox_count_q;
    logic [1:0]  ctrl_flow_tag_q;
    logic [15:0] latency_us_q;

    // ---- (col, row) counters --------------------------------------
    localparam int COL_W = $clog2(H_ACTIVE + 1);
    localparam int ROW_W = $clog2(V_ACTIVE + 1);
    logic [COL_W-1:0] col;
    logic [ROW_W-1:0] row;

    logic beat;
    assign beat = s_axis.tvalid && s_axis.tready;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            col <= '0;
            row <= '0;
        end else if (beat) begin
            if (s_axis.tuser) begin
                col <= '0;
                row <= '0;
            end else if (s_axis.tlast) begin
                col <= '0;
                row <= row + 1'b1;
            end else begin
                col <= col + 1'b1;
            end
        end
    end

    // ---- Sideband latch on accepted SOF beat ----------------------
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            frame_num_q     <= '0;
            bbox_count_q    <= '0;
            ctrl_flow_tag_q <= '0;
            latency_us_q    <= '0;
        end else if (beat && s_axis.tuser) begin
            frame_num_q     <= frame_num_i;
            bbox_count_q    <= (bbox_count_i > 8'd99) ? 8'd99 : bbox_count_i;
            ctrl_flow_tag_q <= ctrl_flow_tag_i;
            latency_us_q    <= (latency_us_i > 16'd99999) ? 16'd99999 : latency_us_i;
        end
    end

    // ---- Decimal-expand FSM ---------------------------------------
    // Runs after sideband latch; emits 4 (frame#) + 2 (bbox) + 5 (latency)
    // = 11 digit values. Total cycles: ~33 (3 cycles per /10 step using a
    // simple subtract-10 iteration; comfortably within v-blank).
    typedef enum logic [1:0] { D_IDLE, D_FRAME, D_BBOX, D_LAT } d_state_e;
    d_state_e d_state;
    logic [15:0] d_val;
    logic [3:0]  d_idx;          // digit position within current field

    logic [3:0] dig_frame [4];   // MSD..LSD
    logic [3:0] dig_bbox  [2];
    logic [3:0] dig_lat   [5];

    // Iterative-divide FSM using a local remainder + counter. Small and
    // once-per-frame; readability wins over throughput here.
    logic [15:0] rem;
    logic [3:0]  cnt;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            d_state <= D_IDLE;
            d_idx   <= '0;
            rem     <= '0;
            cnt     <= '0;
            for (int i = 0; i < 4; i++) dig_frame[i] <= '0;
            for (int i = 0; i < 2; i++) dig_bbox [i] <= '0;
            for (int i = 0; i < 5; i++) dig_lat  [i] <= '0;
        end else begin
            unique case (d_state)
                D_IDLE: begin
                    if (beat && s_axis.tuser) begin
                        d_state <= D_FRAME;
                        d_idx   <= 4'd3;          // start at LSD
                        rem     <= frame_num_i;
                        cnt     <= '0;
                    end
                end
                D_FRAME: begin
                    // Subtract-10 digit extraction: count the quotient with cnt;
                    // when rem<10, rem is the digit and cnt is the next-decade
                    // value to chew on for the next digit position.
                    if (rem >= 16'd10) begin
                        rem <= rem - 16'd10;
                        cnt <= cnt + 1'b1;
                    end else begin
                        dig_frame[d_idx] <= rem[3:0];
                        rem <= {12'd0, cnt};   // quotient becomes new dividend
                        cnt <= '0;
                        if (d_idx == 4'd0) begin
                            d_state <= D_BBOX;
                            d_idx   <= 4'd1;
                            rem     <= {8'd0, bbox_count_q};
                        end else begin
                            d_idx <= d_idx - 1'b1;
                        end
                    end
                end
                D_BBOX: begin
                    if (rem >= 16'd10) begin
                        rem <= rem - 16'd10;
                        cnt <= cnt + 1'b1;
                    end else begin
                        dig_bbox[d_idx[0]] <= rem[3:0];
                        rem <= {12'd0, cnt};
                        cnt <= '0;
                        if (d_idx == 4'd0) begin
                            d_state <= D_LAT;
                            d_idx   <= 4'd4;
                            rem     <= latency_us_q;
                        end else begin
                            d_idx <= d_idx - 1'b1;
                        end
                    end
                end
                D_LAT: begin
                    if (rem >= 16'd10) begin
                        rem <= rem - 16'd10;
                        cnt <= cnt + 1'b1;
                    end else begin
                        dig_lat[d_idx[2:0]] <= rem[3:0];
                        rem <= {12'd0, cnt};
                        cnt <= '0;
                        if (d_idx == 4'd0) d_state <= D_IDLE;
                        else               d_idx   <= d_idx - 1'b1;
                    end
                end
                default: d_state <= D_IDLE;
            endcase
        end
    end

    // ---- Layout / glyph-index table -------------------------------
    // Layout: "F:####  T:XXX  N:##  L:#####us"
    //          0  4    8 11    16 18    22  27 28 29
    // Indices: F=0  :=1  d0=2..5  sp=6,7  T=8  :=9  t0..t2=10..12  sp=13,14
    //          N=15 :=16 b0..b1=17,18  sp=19,20  L=21 :=22 l0..l4=23..27  u=28 s=29
    glyph_idx_t glyph [N_CHARS];

    // Tag glyphs (look up 3 letters from the 2-bit tag).
    glyph_idx_t tag_glyph [3];
    always_comb begin
        unique case (ctrl_flow_tag_q)
            sparevideo_pkg::CTRL_PASSTHROUGH:   tag_glyph = '{ G_P, G_A, G_S };
            sparevideo_pkg::CTRL_MOTION_DETECT: tag_glyph = '{ G_M, G_O, G_T };
            sparevideo_pkg::CTRL_MASK_DISPLAY:  tag_glyph = '{ G_M, G_S, G_K };
            sparevideo_pkg::CTRL_CCL_BBOX:      tag_glyph = '{ G_C, G_C, G_L };
            default:                            tag_glyph = '{ G_SPACE, G_SPACE, G_SPACE };
        endcase
    end

    // Static + dynamic slots assembled combinationally.
    always_comb begin
        glyph[ 0] = G_F;
        glyph[ 1] = G_COLON;
        glyph[ 2] = glyph_idx_t'(dig_frame[0]);
        glyph[ 3] = glyph_idx_t'(dig_frame[1]);
        glyph[ 4] = glyph_idx_t'(dig_frame[2]);
        glyph[ 5] = glyph_idx_t'(dig_frame[3]);
        glyph[ 6] = G_SPACE;
        glyph[ 7] = G_SPACE;
        glyph[ 8] = G_T;
        glyph[ 9] = G_COLON;
        glyph[10] = tag_glyph[0];
        glyph[11] = tag_glyph[1];
        glyph[12] = tag_glyph[2];
        glyph[13] = G_SPACE;
        glyph[14] = G_SPACE;
        glyph[15] = G_N;
        glyph[16] = G_COLON;
        glyph[17] = glyph_idx_t'(dig_bbox[0]);
        glyph[18] = glyph_idx_t'(dig_bbox[1]);
        glyph[19] = G_SPACE;
        glyph[20] = G_SPACE;
        glyph[21] = G_L;
        glyph[22] = G_COLON;
        glyph[23] = glyph_idx_t'(dig_lat[0]);
        glyph[24] = glyph_idx_t'(dig_lat[1]);
        glyph[25] = glyph_idx_t'(dig_lat[2]);
        glyph[26] = glyph_idx_t'(dig_lat[3]);
        glyph[27] = glyph_idx_t'(dig_lat[4]);
        glyph[28] = G_U;
        glyph[29] = G_S;
    end

    // ---- Per-pixel render -----------------------------------------
    logic in_band_y;
    logic in_band_x;
    logic [4:0] cell;          // 0..29
    logic [2:0] cell_x;
    logic [2:0] cell_y;
    logic [7:0] rom_row;
    logic       glyph_bit;

    always_comb begin
        in_band_y = (row >= ROW_W'(HUD_Y0)) && (row < ROW_W'(HUD_Y0 + 8));
        in_band_x = (col >= COL_W'(HUD_X0)) && (col < COL_W'(HUD_X0 + N_CHARS*8));
        cell      = 5'((col - COL_W'(HUD_X0)) >> 3);
        cell_x    = 3'((col - COL_W'(HUD_X0)) & 3'h7);
        cell_y    = 3'(row - ROW_W'(HUD_Y0));
        rom_row   = FONT_ROM[glyph[cell]][cell_y];
        glyph_bit = rom_row[7 - cell_x];
    end

    // ---- Output mux -----------------------------------------------
    logic in_hud_region;
    assign in_hud_region = in_band_y && in_band_x;

    always_comb begin
        if (enable_i) begin
            s_axis.tready = m_axis.tready;
            m_axis.tvalid = s_axis.tvalid;
            m_axis.tlast  = s_axis.tlast;
            m_axis.tuser  = s_axis.tuser;
            m_axis.tdata  = (in_hud_region && glyph_bit) ? 24'hFF_FF_FF
                                                         : s_axis.tdata;
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

Note on the placeholder `place_digit` function above: it's vestigial in the iterative-FSM approach (the FSM does the work directly with `rem`/`cnt`). Either delete it before lint, or remove it and the comment block referencing it. The decade walkdown via `rem <= {12'd0, cnt}` after each digit captures the quotient that becomes the next `rem`.

- [ ] **Step 2: Lint the module standalone**

```bash
verilator --lint-only -Ihw/top -Ihw/ip/hud/rtl \
  hw/top/sparevideo_pkg.sv hw/top/sparevideo_if.sv \
  hw/ip/hud/rtl/axis_hud_font_pkg.sv hw/ip/hud/rtl/axis_hud.sv
```

Expected: zero warnings, zero errors.

- [ ] **Step 3: Commit**

```bash
git add hw/ip/hud/rtl/axis_hud.sv
git commit -m "rtl(hud): full glyph render path + decimal-expand FSM"
```

---

## Task 9: Top-level integration — sideband sources + instantiate `u_hud`

**Files:**
- Modify: `hw/top/sparevideo_top.sv` (declare new bundle, instantiate `u_hud`, build sideband sources, write per-frame `hud_latency.txt`).
- Modify: `dv/sim/Makefile` (add font pkg + axis_hud.sv to `RTL_SRCS`).

- [ ] **Step 1: Add the font pkg + axis_hud to dv/sim/Makefile RTL_SRCS**

Edit `dv/sim/Makefile:1-21`. Insert two new lines in the same alphabetical-ish order as gamma/scaler:

```make
           ../../hw/ip/scaler/rtl/axis_scale2x.sv \
           ../../hw/ip/hud/rtl/axis_hud_font_pkg.sv \
           ../../hw/ip/hud/rtl/axis_hud.sv \
           ../../hw/ip/window/rtl/axis_window3x3.sv \
```

- [ ] **Step 2: Declare the new bundle and frame counter in `sparevideo_top.sv`**

Edit `hw/top/sparevideo_top.sv`. Below the existing `scale2x_to_pix_out` declaration (around `:447`), add:

```systemverilog
    // Tail bundle between u_hud.m_axis and u_fifo_out.s_axis.
    axis_if #(.DATA_W(24), .USER_W(1)) hud_to_pix_out ();

    // ---- HUD sideband sources (clk_dsp domain) --------------------
    // (a) frame_num: increments at every accepted SOF on u_fifo_in.m_axis.
    logic [15:0] hud_frame_num_q;
    logic        in_sof_seen;
    assign in_sof_seen = pix_in_to_hflip.tvalid && pix_in_to_hflip.tready
                      && pix_in_to_hflip.tuser;

    always_ff @(posedge clk_dsp_i) begin
        if (!rst_dsp_n_i) hud_frame_num_q <= '0;
        else if (in_sof_seen) hud_frame_num_q <= hud_frame_num_q + 1'b1;
    end

    // (b) bbox_count: popcount over u_ccl_bboxes valid lanes, capped at 99
    //     by axis_hud itself (so the count itself stays full-width 8-bit).
    logic [7:0] hud_bbox_count;
    always_comb begin
        int unsigned acc = 0;
        for (int i = 0; i < N_OUT_TOP; i++)
            if (u_ccl_bboxes.valid[i]) acc = acc + 1;
        hud_bbox_count = 8'(acc);
    end

    // (c) ctrl_flow_tag: ctrl_flow_i is already on clk_dsp domain (quasi-static).
    //     Pass through directly.

    // (d) latency_us: cycles from input-SOF (at u_fifo_in.m_axis) to
    //     HUD-input-SOF (at scale2x_to_pix_out i.e. u_hud.s_axis), all on
    //     clk_dsp_i. Per-frame measurement; iterative divide once per frame.
    logic [31:0] cyc_counter;
    always_ff @(posedge clk_dsp_i) begin
        if (!rst_dsp_n_i) cyc_counter <= '0;
        else              cyc_counter <= cyc_counter + 1'b1;
    end

    logic [31:0] t_in_q;
    always_ff @(posedge clk_dsp_i) begin
        if (!rst_dsp_n_i) t_in_q <= '0;
        else if (in_sof_seen) t_in_q <= cyc_counter;
    end

    // u_hud.s_axis is `scale2x_to_pix_out`. SOF on its bus marks HUD-input-SOF.
    logic hud_in_sof_seen;
    assign hud_in_sof_seen = scale2x_to_pix_out.tvalid && scale2x_to_pix_out.tready
                          && scale2x_to_pix_out.tuser;

    logic [15:0] hud_latency_us_q;
    always_ff @(posedge clk_dsp_i) begin
        if (!rst_dsp_n_i) hud_latency_us_q <= '0;
        else if (hud_in_sof_seen) begin
            // 10 ns per cycle / 1000 = /100 → divide by 100 with one mult+shift
            // approximation: us = (delta * 41) >> 12 ≈ delta / 100. Error < 0.4%
            // for delta < 2^16 cycles. Saturate to 16 bits.
            logic [31:0] delta;
            logic [31:0] us;
            delta = cyc_counter - t_in_q;
            us    = (delta * 32'd41) >> 12;
            hud_latency_us_q <= (us > 32'd65535) ? 16'd65535 : us[15:0];
        end
    end
```

- [ ] **Step 3: Instantiate `u_hud` and rewire FIFO**

Find the existing `axis_async_fifo_ifc u_fifo_out` instantiation (around `:496-510`) and rewire `s_axis` from `scale2x_to_pix_out` to the new `hud_to_pix_out`. Above that instantiation, add:

```systemverilog
    axis_hud #(
        .H_ACTIVE (H_ACTIVE_OUT),
        .V_ACTIVE (V_ACTIVE_OUT),
        .HUD_X0   (8),
        .HUD_Y0   (8),
        .N_CHARS  (30)
    ) u_hud (
        .clk_i           (clk_dsp_i),
        .rst_n_i         (rst_dsp_n_i),
        .enable_i        (CFG.hud_en),
        .frame_num_i     (hud_frame_num_q),
        .bbox_count_i    (hud_bbox_count),
        .ctrl_flow_tag_i (ctrl_flow_i),
        .latency_us_i    (hud_latency_us_q),
        .s_axis          (scale2x_to_pix_out),
        .m_axis          (hud_to_pix_out)
    );
```

Then change `u_fifo_out`'s `.s_axis(scale2x_to_pix_out)` to `.s_axis(hud_to_pix_out)`.

- [ ] **Step 4: Add the `hud_latency.txt` sidecar writer**

Below the new HUD instantiation, add a Verilator-only file-writer:

```systemverilog
`ifdef VERILATOR
    // Per-frame latency log consumed by py/models/ops/_hud_metadata.py.
    int hud_latency_fd;
    initial begin
        hud_latency_fd = $fopen("dv/data/hud_latency.txt", "w");
        if (hud_latency_fd == 0)
            $display("WARN: could not open dv/data/hud_latency.txt for writing");
    end

    always_ff @(posedge clk_dsp_i) begin
        if (rst_dsp_n_i && hud_in_sof_seen && hud_latency_fd != 0)
            $fwrite(hud_latency_fd, "%0d\n", hud_latency_us_q);
    end

    final if (hud_latency_fd != 0) $fclose(hud_latency_fd);
`endif
```

- [ ] **Step 5: Lint at the top level**

```bash
make lint
```

Expected: zero warnings, zero errors.

- [ ] **Step 6: Run with CFG=no_hud — must reproduce Task 1 goldens byte-for-byte**

```bash
for FLOW in passthrough motion mask ccl_bbox; do
  for PROF in default default_hflip; do
    # Use the no_hud variant of each profile. default → no_hud; default_hflip
    # has no _no_hud sibling, so override hud_en at-the-instance: easier to
    # just compare against the existing CFG=no_hud baseline using the default
    # tree, accepting that hflip variant only validates with default_hflip.
    NO_HUD_CFG="no_hud"
    [ "$PROF" = "default_hflip" ] && NO_HUD_CFG="default_hflip"  # no _no_hud variant; HUD will draw
    make run-pipeline CTRL_FLOW=$FLOW CFG=$NO_HUD_CFG SOURCE="synthetic:moving_box" \
                      WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary
    # Compare only when HUD was disabled.
    if [ "$NO_HUD_CFG" = "no_hud" ]; then
      cmp dv/data/output.bin renders/golden/${FLOW}__${PROF}__pre-hud.bin \
        || { echo "REGRESSION: ${FLOW}__${PROF} differs from pre-HUD golden"; exit 1; }
    fi
    echo "OK: ${FLOW}__${PROF} (cfg=${NO_HUD_CFG})"
  done
done
```

Expected: every `cmp` against the `no_hud` golden returns 0 (byte-identical). The `default_hflip` runs are not compared here — they're a smoke check that CFG=default_hflip still finishes (HUD is drawn but not yet validated against the model; Task 12 covers that).

- [ ] **Step 7: Commit**

```bash
git add hw/top/sparevideo_top.sv dv/sim/Makefile
git commit -m "top(hud): instantiate axis_hud + sideband sources + latency sidecar"
```

---

## Task 10: Unit testbench for `axis_hud`

**Files:**
- Create: `hw/ip/hud/tb/tb_axis_hud.sv`
- Modify: `dv/sim/Makefile` (add `IP_HUD_RTL`, `IP_HUD_FONT_PKG`, `test-ip-hud` target).
- Modify: `Makefile` (top: add `test-ip-hud` aliasing target).

- [ ] **Step 1: Add Make targets**

Edit `dv/sim/Makefile`. After the `IP_SCALE2X_RTL` declaration (around line 110), add:

```make
IP_HUD_FONT_PKG     = ../../hw/ip/hud/rtl/axis_hud_font_pkg.sv
IP_HUD_RTL          = ../../hw/ip/hud/rtl/axis_hud.sv
```

In the `.PHONY` line, append `test-ip-hud`. Update the `test-ip` aggregate to include `test-ip-hud`. Add the recipe near the other per-block targets:

```make
# --- axis_hud ---
test-ip-hud:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_hud --Mdir obj_tb_axis_hud \
	  ../../hw/top/sparevideo_pkg.sv ../../hw/top/sparevideo_if.sv \
	  $(IP_HUD_FONT_PKG) $(IP_HUD_RTL) ../../hw/ip/hud/tb/tb_axis_hud.sv
	obj_tb_axis_hud/Vtb_axis_hud
```

In the `clean` recipe, append `obj_tb_axis_hud` to the `rm -rf` list.

Edit top-level `Makefile`. Add:

```make
test-ip-hud:
	$(MAKE) -C dv/sim test-ip-hud SIMULATOR=$(SIMULATOR)
```

And declare it in `.PHONY` and `help`.

- [ ] **Step 2: Write the unit TB**

Create `hw/ip/hud/tb/tb_axis_hud.sv`:

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Unit testbench for axis_hud. Tests the full HUD region render against
// hand-computed expectations by streaming a 320x16 black input frame
// (just enough rows to cover HUD_Y0..HUD_Y0+7) and capturing the output.
//
// T1 -- enable_i=0 passthrough: output == input.
// T2 -- enable_i=1, render F-glyph at (8,8): row 8, cols 9..14 white;
//        row 8, col 8/15 black; row 15 (top of glyph 'F' bottom row) black.
// T3 -- enable_i=1, downstream stall mid-line: data integrity preserved.

`timescale 1ns / 1ps

module tb_axis_hud;
    localparam int CLK_PERIOD = 10;
    localparam int H = 320;
    localparam int V = 16;

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

    axis_hud #(
        .H_ACTIVE (H),
        .V_ACTIVE (V),
        .HUD_X0   (8),
        .HUD_Y0   (8),
        .N_CHARS  (30)
    ) dut (
        .clk_i           (clk),
        .rst_n_i         (rst_n),
        .enable_i        (enable),
        .frame_num_i     (16'd42),
        .bbox_count_i    (8'd5),
        .ctrl_flow_tag_i (sparevideo_pkg::CTRL_MOTION_DETECT),
        .latency_us_i    (16'd1234),
        .s_axis          (s_axis),
        .m_axis          (m_axis)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // Capture every output beat into a 2D array.
    logic [23:0] cap [V][H];
    int          cap_row, cap_col;

    always_ff @(posedge clk) begin
        if (rst_n && m_axis.tvalid && m_axis.tready) begin
            cap[cap_row][cap_col] <= m_axis.tdata;
            if (m_axis.tlast) begin
                cap_row <= cap_row + 1;
                cap_col <= 0;
            end else begin
                cap_col <= cap_col + 1;
            end
        end
    end

    task automatic drive_frame;
        for (int r = 0; r < V; r++) begin
            for (int c = 0; c < H; c++) begin
                drv_tdata  = 24'h00_00_00;
                drv_tvalid = 1'b1;
                drv_tlast  = (c == H-1);
                drv_tuser  = (r == 0 && c == 0);
                @(posedge clk);
                while (!s_axis.tready) @(posedge clk);
            end
        end
        drv_tvalid = 1'b0;
        drv_tlast  = 1'b0;
        drv_tuser  = 1'b0;
    endtask

    initial begin
        cap_row = 0; cap_col = 0;
        enable  = 1'b0;
        #(CLK_PERIOD*3); rst_n = 1'b1; #(CLK_PERIOD*2);

        // --- T1: passthrough ---
        $display("T1: enable=0 passthrough");
        drive_frame();
        for (int i = 0; i < 8; i++) @(posedge clk);
        if (cap[8][9] !== 24'h00_00_00) $fatal(1, "T1 FAIL: HUD overlay leaked");

        // Reset capture and DUT for T2
        cap_row = 0; cap_col = 0;
        rst_n = 1'b0; #(CLK_PERIOD*2); rst_n = 1'b1; #(CLK_PERIOD*2);

        // --- T2: glyph render ---
        $display("T2: enable=1, expect 'F' glyph at (8..15, 8..15)");
        enable = 1'b1;
        drive_frame();
        for (int i = 0; i < 32; i++) @(posedge clk);  // FSM finishes
        // Row 8 (HUD top), cols 9..14 = FG (0xFFFFFF) for 'F' top byte 0x7E.
        for (int c = 9; c <= 14; c++)
            if (cap[8][c] !== 24'hFF_FF_FF)
                $fatal(1, "T2 FAIL: row 8 col %0d should be FG got %06h", c, cap[8][c]);
        if (cap[8][8] !== 24'h00_00_00) $fatal(1, "T2 FAIL: row 8 col 8 should be BG");
        if (cap[8][15] !== 24'h00_00_00) $fatal(1, "T2 FAIL: row 8 col 15 should be BG");
        // Row 15 (HUD bottom row of the glyph cell): F glyph row 7 = 0x00, all BG.
        for (int c = 8; c <= 15; c++)
            if (cap[15][c] !== 24'h00_00_00)
                $fatal(1, "T2 FAIL: row 15 col %0d should be BG", c);

        // --- T3: tready stall ---
        $display("T3: enable=1, mid-frame downstream stall");
        cap_row = 0; cap_col = 0;
        rst_n = 1'b0; #(CLK_PERIOD*2); rst_n = 1'b1; #(CLK_PERIOD*2);
        fork
            drive_frame();
            begin
                for (int i = 0; i < 80; i++) @(posedge clk);
                #1 drv_m_tready = 1'b0;
                for (int i = 0; i < 5; i++) @(posedge clk);
                #1 drv_m_tready = 1'b1;
            end
        join
        for (int i = 0; i < 32; i++) @(posedge clk);
        // Same expectations as T2 — stall must not corrupt data.
        for (int c = 9; c <= 14; c++)
            if (cap[8][c] !== 24'hFF_FF_FF)
                $fatal(1, "T3 FAIL: row 8 col %0d should be FG", c);

        $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
```

- [ ] **Step 3: Run the unit TB**

```bash
make test-ip-hud
```

Expected: `ALL TESTS PASSED`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add hw/ip/hud/tb/tb_axis_hud.sv dv/sim/Makefile Makefile
git commit -m "test(hud): unit TB for axis_hud (passthrough + glyph render + stall)"
```

---

## Task 11: Revise architecture doc against the as-built RTL

**Purpose:** Task 2 wrote `axis_hud-arch.md` as a forward-looking spec. After Tasks 7–10 the RTL is implemented and verified by the unit TB, so the implementation is ground truth. Walk the spec line-by-line against `hw/ip/hud/rtl/axis_hud.sv` and update the doc to describe what was actually built — close any gap left by ad-hoc choices made during implementation (port name tweaks, FSM state-count differences, latch-cycle off-by-ones, saturation thresholds, lint-driven rewordings).

**Files:**
- Modify: `docs/specs/axis_hud-arch.md`

- [ ] **Step 1: Diff each arch-doc section against the RTL**

Use the `hardware-arch-doc` skill. Walk the doc top-to-bottom and check each claim against the source:

| Section | What to verify against the RTL |
|---------|-------------------------------|
| 3 — Interface Specification | Parameter names, defaults, port names, port widths exactly match `axis_hud.sv` and the package import list (`axis_hud_font_pkg`). |
| 4 — Concept Description | The mux condition `(in_band_y && in_band_x && glyph_bit) → FG, else passthrough` matches the actual `always_comb` at the bottom of the module. |
| 5.1 — ASCII diagram | Skid-pattern stage count and signal names match the RTL (e.g. is there one pipeline register or did implementation add a second?). |
| 5.2 — Glyph-index table | Static slots in the spec must match the `glyph[0..29]` always_comb assignments verbatim. |
| 5.3 — Decimal-expand FSM | State count, cycle budget, and digit-position indexing match the actual `D_IDLE/D_FRAME/D_BBOX/D_LAT` walk. The cycle estimate "11 cycles" is wrong if the iterative-subtract approach landed (it's higher — update). |
| 6 — Control Logic | The FSM list ((a) col/row counter, (b) sideband latch, (c) decimal-expand) matches what's in the file. |
| 7 — Timing | Latency claim "1 cycle" must match the actual mux output — if the implementation went combinational with no skid, update to 0; if it added a skid, confirm 1. |
| 9 — Known Limitations | Saturation thresholds (`bbox_count` ≤99, `latency_us` ≤99999) match the RTL constants. |

- [ ] **Step 2: Edit the doc to match reality**

Apply targeted edits — do not rewrite. Each change should be a one- or two-line tweak that aligns the doc with what the source says. Common patterns:

- A spec section says "0-cycle latency" but the RTL has a skid → change to "1 cycle".
- The spec says `N_CHARS = 30` but the implementation took the parameter default differently → reconcile.
- The decimal FSM has more states than the spec listed → list the new states.
- A risk callout that turned out to be moot (e.g. asymmetric stall is fully absorbed by the skid) → strike it; add a note that the unit TB verifies it.

If during the diff you find a *bug* in the RTL (the spec is right and the RTL is wrong), do **not** patch the spec — fix the RTL, re-run `make test-ip-hud`, and only then re-examine the spec.

- [ ] **Step 3: Commit**

```bash
git add docs/specs/axis_hud-arch.md
git commit -m "docs(hud): revise arch spec against as-built RTL"
```

---

## Task 12: Integration regression — full pipeline with HUD enabled

**Purpose:** prove RTL output matches the Python reference model byte-for-byte for all `(ctrl_flow × profile)` combinations with `hud_en=1`. This requires the SV-written `hud_latency.txt` to match what the model reads.

- [ ] **Step 1: Run the matrix**

```bash
for FLOW in passthrough motion mask ccl_bbox; do
  for PROF in default default_hflip no_hud no_morph no_gauss no_gamma_cor no_scaler; do
    echo "=== CTRL_FLOW=$FLOW CFG=$PROF ==="
    make run-pipeline CTRL_FLOW=$FLOW CFG=$PROF \
                      SOURCE="synthetic:moving_box" \
                      WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary || exit 1
  done
done
```

Expected: every run reports `PASS: 8 frames verified (model=$FLOW, tolerance=0)`.

- [ ] **Step 2: Repeat on a different source (`thin_moving_line`) to exercise rare bbox counts**

```bash
make run-pipeline CTRL_FLOW=motion CFG=default \
                  SOURCE="synthetic:thin_moving_line" \
                  WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary
```

Expected: PASS.

- [ ] **Step 3: If a `cmp` mismatch is found, debug**

If verification fails on any combination:
1. Run `xxd dv/data/output.bin | head -5` and `xxd renders/expected.bin | head -5` (you may need to dump the model output via a small script using `models.run_model`) — confirm whether the diff is in the HUD region (rows 8..15, cols 8..247 in the 640×480 output) or elsewhere.
2. If diff is in the HUD region: check `dv/data/hud_latency.txt` is being written and read.
3. If diff is outside the HUD region: that's a Task-9 bug (sideband sources affecting the data path) — bisect with `make sim-waves`.

- [ ] **Step 4: Commit any fixes**

```bash
git add -p
git commit -m "fix(hud): <root cause>"   # only if needed
```

---

## Task 13: Documentation updates

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `docs/specs/sparevideo-top-arch.md`

- [ ] **Step 1: README — add `axis_hud` to the IP block table and `no_hud` to profile options**

Locate the IP block table in `README.md` and append a row:
- `hw/ip/hud/` — `axis_hud` text overlay (8×8 bitmap, frame# / ctrl-flow / bbox count / latency µs).

Locate the build-options section and append `no_hud` to the `CFG=` profile list.

Add a one-line note that `dv/data/hud_latency.txt` is a per-frame sidecar written by the SV TB and consumed by `py/models/ops/hud.py`.

- [ ] **Step 2: CLAUDE.md — Project Structure + Build Commands**

In `CLAUDE.md`'s "Project Structure" list, add:
- `hw/ip/hud/rtl/` — Bitmap text overlay (axis_hud + axis_hud_font_pkg).

In "Build Commands" / "CFG profile selection" example block, add `make run-pipeline CFG=no_hud`.

In the "Adding a tuning knob" callout, no change (the rule already covers cfg_t fields).

- [ ] **Step 3: sparevideo-top-arch.md — pipeline diagram**

Insert `axis_hud` between `axis_scale2x` and the output CDC FIFO in the block diagram. Add a paragraph documenting the four sideband sources (frame counter, popcount over `bboxes.valid`, `ctrl_flow_i` passthrough, latency cycle counter with `*41>>12` ≈ /100 conversion). Document the latency measurement boundary (input-SOF at `u_fifo_in.m_axis` → HUD-input-SOF at `scale2x_to_pix_out`); note the output CDC adds extra cycles not reflected in `LAT`.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md docs/specs/sparevideo-top-arch.md
git commit -m "docs(hud): README + CLAUDE.md + top arch updates"
```

---

## Task 14: Final cleanup, lint, and merge prep

- [ ] **Step 1: Final lint and full regression**

```bash
make lint
cd py && python -m pytest tests/ -v && cd ..
make test-ip
make run-pipeline CTRL_FLOW=motion CFG=default SOURCE="synthetic:moving_box" \
                  WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary
```

Expected: all green.

- [ ] **Step 2: Delete pre-HUD goldens**

```bash
rm -rf renders/golden
```

- [ ] **Step 3: Move the design + plan into `docs/plans/old/`**

```bash
mv docs/plans/2026-04-29-axis-hud-plan.md docs/plans/old/2026-04-29-axis-hud-plan.md
git add -A
git commit -m "chore(plans): archive axis-hud plan"
```

- [ ] **Step 4: Squash branch commits per CLAUDE.md "Squash at plan completion"**

```bash
git fetch origin
git rebase -i origin/main
# In the editor, mark all commits except the first as 'squash'.
# Edit the combined message to:
#   feat(hud): add axis_hud bitmap text overlay
#
#   Adds the final pipeline-extensions block — an 8x8 bitmap HUD that
#   overlays frame#/ctrl-flow/bbox-count/latency-µs at the post-scaler
#   tail. Runtime-bypassable via cfg_t.hud_en. Includes Python reference
#   model, font ROM generator, unit TB, and full integration regression.
```

- [ ] **Step 5: Open the PR**

```bash
git push -u origin feat/axis-hud
gh pr create --title "feat: axis_hud bitmap text overlay" --body "$(cat <<'EOF'
## Summary
- Final block from the pipeline-extensions design (docs/plans/2026-04-23-pipeline-extensions-design.md §3.6)
- 8x8 bitmap HUD at post-scaler tail; runtime-bypassable via cfg_t.hud_en
- Sidebands: frame#, ctrl-flow tag, CCL bbox count, latency µs (sidecar-shared with Python model)

## Test plan
- [ ] make lint
- [ ] make test-ip (incl. test-ip-hud)
- [ ] cd py && pytest tests/
- [ ] make run-pipeline matrix: 4 ctrl_flows × 8 profiles (default, default_hflip, no_ema, no_morph, no_gauss, no_gamma_cor, no_scaler, no_hud)
- [ ] Verify CFG=no_hud is byte-identical to pre-HUD goldens (Task 9 Step 6)
EOF
)"
```

Expected: PR URL printed.

---

## Self-review notes

- **Spec coverage:** every bullet in `docs/plans/2026-04-23-pipeline-extensions-design.md §3.6` has a task — port surface (Task 7), sideband latching at SOF (Task 8 Step 1), font ROM (Task 4), layout (Task 8), ctrl_flow tag ROM (Task 8 Step 1, `tag_glyph` always_comb), latency measurement (Task 9 Step 2 cycle counter + iterative-divide approximation), HUD-after-scaler placement (Task 9), spec-vs-RTL reconciliation (Task 11). Risk F1 from the design (LAT excludes output-side CDC) is documented in Task 13 Step 3.
- **Why a generated font:** keeping the SV ROM and the Python ROM in lockstep was the highest-risk bug surface (RTL/model co-bug — design risk H1). The generator (Task 4) is the mitigation.
- **Why a latency sidecar:** the alternative (computing latency analytically in Python) would tightly couple the model to FIFO depths, scaler startup phase, and the v-blank duration. The sidecar is one file write per frame at SOF; the Python model reads it via `_load_latencies`. This keeps the model spec-driven for *what* is rendered (frame#, ctrl-flow tag, bbox count) and consults the SV for *the one* sim-runtime quantity (latency µs).
- **Why HUD lives in `clk_dsp_i`, not `clk_pix_out_i`:** matches the design decision (§2 "All new stages live in clk_dsp"), keeps every sideband in the same clock domain (no CDC for `frame_num` / `bbox_count` / `ctrl_flow_tag` / `latency_us`), and the modest extra path through the output CDC FIFO is already required by the existing post-scaler tail.
- **`bbox_count` clamp at 99:** documented as a known limitation in the arch doc (Task 2). The two-digit field cannot represent more, and the design's `bbox_count_i[7:0]` ⇒ 0..255 input range is wider than the renderable range deliberately, so clamping in the HUD is the right place.
- **Edge cases handled:** `frame_num` wraparound at 65536 (display only — counter is modular); `bbox_count > 99` saturates; `latency_us > 99999` saturates; `ctrl_flow_tag` outside the 4 known values renders as three spaces (defensive default in `tag_glyph` always_comb).
- **`make help` / advertised `CFG=` values:** the top Makefile already lists profiles; Task 3 Step 1 + Task 13 Step 1 add `no_hud` everywhere it appears.

## Execution Handoff

Plan complete and saved to `docs/plans/2026-04-29-axis-hud-plan.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
