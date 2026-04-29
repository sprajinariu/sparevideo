# `axis_hud` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
  - [4.1 Layout string and HUD region](#41-layout-string-and-hud-region)
  - [4.2 Glyph addressing](#42-glyph-addressing)
  - [4.3 Per-pixel render rule](#43-per-pixel-render-rule)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Data flow overview](#51-data-flow-overview)
  - [5.2 Glyph-index table](#52-glyph-index-table)
  - [5.3 Decimal expansion](#53-decimal-expansion)
  - [5.4 Render mux](#54-render-mux)
- [6. Control Logic](#6-control-logic)
  - [6.1 FSMs](#61-fsms)
  - [6.2 `bbox_count` saturation](#62-bbox_count-saturation)
  - [6.3 `ctrl_flow_tag` decode](#63-ctrl_flow_tag-decode)
- [7. Timing](#7-timing)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

`axis_hud` overlays a fixed-layout 8×8 bitmap text "heads-up display" on a 24-bit RGB AXI4-Stream video output. The HUD draws the string `F:####  T:XXX  N:##  L:#####us` at output coordinates `(8, 8)`, where `####` is the current frame number, `XXX` is a three-letter control-flow tag, `##` is the bounding-box count, and `#####` is a per-frame end-to-end latency in microseconds. The four runtime values arrive on dedicated sideband ports and are latched at the HUD's input start-of-frame so they are stable for the entire frame they annotate. The block is runtime-bypassable via `enable_i`; when disabled the output is data-equivalent to the input (with the same 1-cycle skid latency as the enabled path).

For where this module sits in the surrounding system, see [`sparevideo-top-arch.md`](sparevideo-top-arch.md).

---

## 2. Module Hierarchy

`axis_hud` is a leaf module. It is instantiated in `sparevideo_top` as `u_hud` between `u_scale2x.m_axis` and `u_fifo_out.s_axis` — i.e. at the post-scaler tail of the `clk_dsp` pipeline, immediately before the output CDC FIFO. It imports `axis_hud_font_pkg` for the 8×8 glyph ROM and the `glyph_idx_t` type.

```
sparevideo_top
├── … (motion / CCL / overlay / gamma / scaler) …
├── axis_scale2x       (u_scale2x)   — 2× spatial upscale (when CFG.scaler_en=1)
├── axis_hud           (u_hud)       — this module (post-scaler tail)
└── axis_async_fifo    (u_fifo_out)  — CDC clk_dsp → clk_pix
```

---

## 3. Interface Specification

### 3.1 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | `sparevideo_pkg::H_ACTIVE_OUT_2X` | Active output width in pixels. The HUD operates **post-scaler**, so this is the scaled output width (e.g. 640 when the 2× scaler is enabled). |
| `V_ACTIVE` | `sparevideo_pkg::V_ACTIVE_OUT_2X` | Active output height in pixels. |
| `HUD_X0`   | `8`  | X coordinate of the HUD region's top-left corner, in output pixel coordinates. |
| `HUD_Y0`   | `8`  | Y coordinate of the HUD region's top-left corner. |
| `N_CHARS`  | `30` | Number of 8-pixel-wide glyph cells in the HUD region. Fixed by the layout string `F:####  T:XXX  N:##  L:#####us` (30 visible characters including separators). |

The caller must guarantee `HUD_X0 + N_CHARS · 8 ≤ H_ACTIVE` and `HUD_Y0 + 8 ≤ V_ACTIVE`. Out-of-range placement is not detected by the module — the HUD region simply gets clipped at the active-frame edges with no error indication.

### 3.2 Ports

| Signal | Direction | Type | Description |
|--------|-----------|------|-------------|
| `clk_i`            | input  | `logic`             | `clk_dsp`, rising edge |
| `rst_n_i`          | input  | `logic`             | Active-low synchronous reset |
| `enable_i`         | input  | `logic`             | Block enable. `0` makes `m_axis.tdata` equal the registered `s_axis.tdata` (still 1 cycle of skid latency, no HUD overlay). Must be held frame-stable. |
| `frame_num_i`      | input  | `logic [15:0]`      | Frame counter; rendered as 4 decimal digits. Wraps modulo 10000 in display only. |
| `bbox_count_i`     | input  | `logic [7:0]`       | Bounding-box count for the current frame; rendered as 2 decimal digits. Saturated to 99 before display. |
| `ctrl_flow_tag_i`  | input  | `logic [1:0]`       | Encoded active control flow: `0=PAS`, `1=MOT`, `2=MSK`, `3=CCL`. |
| `latency_us_i`     | input  | `logic [15:0]`      | Pipeline end-to-end latency in microseconds for the current frame; rendered as 5 decimal digits. Saturated to 99999. |
| `s_axis`           | input  | `axis_if.rx`        | Input RGB stream (DATA_W=24, USER_W=1; `tdata[23:16]`=R, `tdata[15:8]`=G, `tdata[7:0]`=B; `tuser`=SOF; `tlast`=EOL). |
| `m_axis`           | output | `axis_if.tx`        | Output RGB stream with HUD composited on top (DATA_W=24, USER_W=1). Same framing convention as `s_axis`. |

All four sideband values are sampled together at the HUD's own input start-of-frame (the cycle on which `s_axis.tvalid && s_axis.tready && s_axis.tuser` is true) and held for the duration of that frame. The producer of these sidebands is `sparevideo_top`; the contract is that they are valid by the time SOF reaches the HUD's input.

---

## 4. Concept Description

### 4.1 Layout string and HUD region

The HUD draws a single line of text:

```
F:####  T:XXX  N:##  L:#####us
```

The string is 30 visible characters long (`N_CHARS = 30`). Each character occupies an 8×8 cell. The HUD region is a rectangle of size `(N_CHARS · 8) × 8` pixels with its top-left corner at `(HUD_X0, HUD_Y0)`. With the default origin `(8, 8)` and `N_CHARS = 30`, the region spans columns 8–247 and rows 8–15. This fits within both the 320×240 (`scaler_en=0`) and 640×480 (`scaler_en=1`) output frames.

Cell positions inside the layout are fixed at synthesis. The 30 cells decompose as:

- 2 cells for `F:`, 4 cells for the frame number digits, 2 cells of space.
- 2 cells for `T:`, 3 cells for the tag, 2 cells of space.
- 2 cells for `N:`, 2 cells for the bbox-count digits, 2 cells of space.
- 2 cells for `L:`, 5 cells for the latency digits, 2 cells for `us`.

Of the 30 cells, 16 are static text (`F`, `:`, ` `, `T`, `:`, ` `, ` `, `N`, `:`, ` `, ` `, `L`, `:`, `u`, `s`, plus the leading space in each gap) and 14 are runtime-driven (4 frame digits, 3 tag glyphs, 2 bbox digits, 5 latency digits). The 14 dynamic positions are recomputed once per frame from the latched sideband values.

### 4.2 Glyph addressing

The font ROM lives in `axis_hud_font_pkg` as `FONT_ROM[GLYPH][ROW] -> 8-bit row pattern`, where `GLYPH` is a 6-bit `glyph_idx_t` (encoding 0..37: digits 0–9, letters A–Z, `:`, space) and `ROW` is the 0..7 row inside the cell. Each row pattern is one byte; bit 7 (MSB) is the leftmost pixel and bit 0 is the rightmost.

For an output pixel at column `col` and row `row` that falls inside the HUD region:

```
cell_idx   = (col - HUD_X0) >> 3                    // which cell, 0..N_CHARS-1
glyph_idx  = glyph_table[cell_idx]                  // 6-bit index into FONT_ROM
y_in_cell  = row - HUD_Y0                           // 0..7
x_in_cell  = (col - HUD_X0) & 3'b111                // 0..7
row_byte   = FONT_ROM[glyph_idx][y_in_cell]
fg_bit     = row_byte[7 - x_in_cell]
```

`glyph_table` is the per-frame glyph-index table maintained by the HUD (see §5.2).

### 4.3 Per-pixel render rule

For every pixel on `s_axis`:

```
in_hud_y    = (row >= HUD_Y0)         && (row < HUD_Y0 + 8)
in_hud_x    = (col >= HUD_X0)         && (col < HUD_X0 + N_CHARS · 8)
in_hud      = enable_i && in_hud_y && in_hud_x

m_axis.tdata = (in_hud && fg_bit) ? 24'hFF_FF_FF : s_axis.tdata
```

Pixels outside the HUD region pass through unchanged. Inside the region, glyph foreground bits are forced to white (`24'hFF_FF_FF`); glyph background bits also pass through, so the HUD does not paint a rectangular backdrop.

---

## 5. Internal Architecture

### 5.1 Data flow overview

```
                  ┌────────────────────────────────────────────────────────────┐
                  │                       axis_hud                             │
                  │                                                            │
                  │  ┌──────────────┐                                          │
   s_axis  ──────►│  │     skid     │──────────► render mux ──────► m_axis     │
                  │  └──────┬───────┘                ▲                         │
                  │         │                        │                         │
                  │         ▼                        │                         │
                  │    counter FSM ─────────────────►│                         │
                  │                                  │                         │
                  │  sideband ──► SOF latch ──► decimal-expand FSM             │
                  │                                  │                         │
                  │                                  ▼                         │
                  │                            glyph_table                     │
                  │                                  │                         │
                  │                                  ▼                         │
                  │                            FONT_ROM ───────────────────────┘
                  └────────────────────────────────────────────────────────────┘
```

The datapath is a single-stage skid pipeline (the same pattern as `axis_gamma_cor`). The pixel takes one `clk_dsp` cycle to traverse the module. Sideband processing (latch, decimal expansion, glyph-table maintenance) runs in parallel and is decoupled from the per-pixel datapath: it completes during vertical blanking, well before the next SOF.

### 5.2 Glyph-index table

The glyph-index table is a flat array `glyph_idx_t glyph_table [0:N_CHARS-1]` with `glyph_idx_t = logic [5:0]` (defined in `axis_hud_font_pkg`). 30 entries × 6 bits = 180 bits of register storage.

Cells corresponding to static literal characters (`F`, `:`, space, `T`, `N`, `L`, `U`, `S`) are written at reset and never change; cells corresponding to the 14 dynamic positions (4 frame digits, 3 tag glyphs, 2 bbox digits, 5 latency digits) are rewritten once per frame at the conclusion of decimal expansion.

### 5.3 Decimal expansion

Each numeric field (`frame_num`, `bbox_count`, `latency_us`) is reduced to its decimal digits by an iterative subtract-10 FSM. For each field the FSM walks the digits least-significant first:

1. Repeatedly subtract 10 from a working register `rem` and increment a digit counter `cnt` until `rem < 10`. `rem` is then the current digit; `cnt` is the next-decade dividend.
2. Write `rem[3:0]` into the corresponding cell of `glyph_table` (rightmost-digit cell first, walking left).
3. Reload `rem` from `cnt`, clear `cnt`, and advance to the next digit position.

After the field's most-significant digit has been written, the FSM advances to the next field. `frame_num_i` is sampled live at the SOF edge (the same edge on which the sideband latch fires); the other two fields are read from their latched copies (`bbox_count_q`, `latency_us_q`).

`rem` and `cnt` are both `logic [15:0]` so they accommodate the worst-case dividend (`latency_us_q = 65535`, which needs 6553 subtract-10 iterations to extract the LSD).

Across all three fields the FSM walks `4 + 2 + 5 = 11` digit positions. Worst-case cost is on the order of 6600 cycles (dominated by the latency LSD), well within the v-blank budget (~280k cycles at standard VGA timing and 100 MHz `clk_dsp`).

### 5.4 Render mux

The skid stage holds the most recently accepted input beat (`s_axis_data_q`) along with its framing bits (`tlast_q`, `tuser_q`, `pipe_valid_q`) and its position (`col_pipe_q`, `row_pipe_q` — see §6.1(a)). It advances when the downstream is ready or the stage is empty:

```
stage_advance  = m_axis.tready || !pipe_valid_q;
s_axis.tready  = stage_advance;
```

The render mux is purely combinational off the registered skid stage and the registered `glyph_table`:

```
m_axis.tdata = (enable_i && in_hud_region && fg_bit) ? 24'hFF_FF_FF : s_axis_data_q;
```

This keeps the FONT_ROM lookup between two flops — registered position and `glyph_table` on the input side, the downstream consumer's input register on the output side.

---

## 6. Control Logic

### 6.1 FSMs

Three concurrent control blocks coexist:

**(a) Position counters.** `col_in_q` / `row_in_q` track the position of the pixel currently on `s_axis`. After each accepted beat they update to point at the *next* input pixel; from the reset value (0,0) this naturally identifies the first SOF beat as (0,0). The skid's companions `col_pipe_q` / `row_pipe_q` snapshot `col_in_q` / `row_in_q` at the moment the pixel is latched into the skid, so they reflect the position of the pixel currently in the skid stage and feed the render path.

**(b) Sideband latch.** A single set of registers `frame_num_q`, `bbox_count_q`, `ctrl_flow_tag_q`, `latency_us_q` holds the per-frame values. The latch fires when the input SOF beat is accepted (`s_axis.tvalid && s_axis.tready && s_axis.tuser`) and freezes thereafter for the rest of the frame. This is what eliminates mid-frame flicker if the producer changes its sideband mid-stream.

**(c) Decimal-expand FSM.** Two states drive extraction of all three numeric fields. A 2-bit `field_q` selector identifies which field is currently being expanded.

| State | Meaning | Transition |
|-------|---------|------------|
| `D_IDLE` | Awaiting next SOF | `→ D_DECODE` at the SOF edge (`beat && s_axis.tuser`). Same edge: `field_q <= F_FRAME` and `rem` is seeded from the live `frame_num_i` (the sideband latch fires on the same edge, so the latched and live values are equal). |
| `D_DECODE` | Walking the digits of the field selected by `field_q`, least-significant first, via the subtract-10 loop in §5.3. | After the field's MSD has been written: `field_q` advances `F_FRAME → F_BBOX → F_LAT`, with `rem` reseeded from the corresponding latched sideband. After the LSD of `F_LAT` has been written, `→ D_IDLE`. |

The FSM completes well within v-blank.

### 6.2 `bbox_count` saturation

`bbox_count_i[7:0]` has a range of 0..255 but the layout reserves only two digit cells. Before decimal expansion, the value is clamped:

```
bbox_count_clamped = (bbox_count_i > 8'd99) ? 8'd99 : bbox_count_i;
```

When the input exceeds 99, both digit cells are forced to glyph `9`. This is acceptable for the 2-digit field; the upstream is responsible for any additional indication that a true overflow occurred.

`latency_us_i` is **not** internally clamped. The 16-bit input range (0..65535) fits within the 5-cell field naturally, so no saturation is needed in this block. The producer in `sparevideo_top` (`hud_latency_us_q`) is responsible for clamping its `cycles × 41 >> 12 ≈ µs` conversion to 16 bits if the cycle delta is large enough to overflow the result; that is a top-level concern, not an `axis_hud` concern.

`frame_num_i` is **not** clamped. The 16-bit counter wraps modulo 10000 in display only — values above 9999 wrap and are still rendered as 4 digits.

### 6.3 `ctrl_flow_tag` decode

`ctrl_flow_tag_q[1:0]` indexes a 4-entry combinational ROM into three glyph indices, written into the three tag-glyph cells of `glyph_table`:

| `tag` | Cells (high → low) |
|-------|--------------------|
| `2'b00` | `P`, `A`, `S` |
| `2'b01` | `M`, `O`, `T` |
| `2'b10` | `M`, `S`, `K` |
| `2'b11` | `C`, `C`, `L` |

The decode happens once per frame, in parallel with decimal expansion (no FSM step required). Each letter maps to its `glyph_idx_t` value via the encoding in `axis_hud_font_pkg`.

---

## 7. Timing

| Metric | Value |
|--------|-------|
| Per-pixel latency | 1 `clk_dsp` cycle (single-deep skid) |
| Long-term throughput | 1 pixel / `clk_dsp` cycle |
| `s_axis.tready` deassertion | 1 cycle after downstream stall (`stage_advance = m_axis.tready \|\| !pipe_valid_q`; see §5.4) |
| Per-frame setup | ≤ ~110 cycles (11 digit positions × ≤ 10 subtract-10 steps), runs in v-blank |

The latency reported by `latency_us_i` is a measurement contract on the producer side; the boundary it covers is documented in §9.

---

## 8. Shared Types

| Type | Source | Usage |
|------|--------|-------|
| `pixel_t`     | `sparevideo_pkg` | Type of `m_axis.tdata` and `s_axis.tdata` (24-bit packed RGB). |
| `component_t` | `sparevideo_pkg` | Type of each 8-bit RGB channel (used internally where individual channels are referenced). |
| `glyph_idx_t` | `axis_hud_font_pkg` | `logic [5:0]`; encodes 0..37 (digits 0–9, letters A–Z, `:`, space). Type of every entry in `glyph_table` and the index dimension of `FONT_ROM`. |

---

## 9. Known Limitations

- **`bbox_count` saturates at 99.** Inputs above 99 render as `99`; the HUD does not draw an overflow indicator.
- **`latency_us` not internally clamped.** The 16-bit input range (0..65535) fits within the 5-cell field; the producer at `sparevideo_top` is responsible for any range management of its cycle counter conversion.
- **`frame_num` wraps modulo 10000 in display.** The 16-bit counter itself is modular; values 10000..65535 render as their decimal value modulo 10000.
- **Layout is fixed at synthesis.** No runtime reposition of the HUD origin, no runtime layout-string change, no per-cell colour. `HUD_X0`, `HUD_Y0`, and `N_CHARS` are compile-time parameters.
- **Glyph set is fixed at synthesis.** Digits 0–9, uppercase A–Z, colon, and space are supported. The font ROM contains no lowercase letters; the layout uses uppercase `U` and `S` for the trailing `US` suffix accordingly.
- **Foreground colour is fixed at white** (`24'hFF_FF_FF`); no per-cell or per-frame colour control.
- **`enable_i` must be held frame-stable.** Toggling mid-frame yields a torn frame (top half with HUD, bottom without, or vice versa). Producers should change `enable_i` only during v-blank.
- **Sideband validity contract.** `frame_num_i`, `bbox_count_i`, `ctrl_flow_tag_i`, and `latency_us_i` must be valid on the cycle the HUD's input SOF beat is accepted. Earlier or later updates within the same frame are ignored by the latch and have no effect until the next SOF.
- **Latency measurement boundary.** `latency_us_i` reflects proc-clock SOF-in to HUD-input SOF only; it excludes the output-side CDC and VGA-controller delay. The full pixel-to-display latency is a few cycles greater than the displayed value.
- **No completion flag on the digit-expand FSM.** The render mux reads `dig_frame` / `dig_bbox` / `dig_lat` combinationally while the FSM writes them in place. For typical inputs the FSM finishes well before the HUD becomes visible (row 8). For max-range inputs (e.g. `latency_us = 65535` ≈ 7k cycles to expand the LSD) the writes can land inside the visible HUD row, causing glyph tearing on that frame. A new SOF that arrives while the FSM is still busy is silently dropped — that frame renders the previous frame's digits.

---

## 10. References

- [`sparevideo-top-arch.md`](sparevideo-top-arch.md) — Top-level pipeline; placement of `axis_hud` between `u_scale2x` and `u_fifo_out`, and the source of the four sideband signals.
- [`axis_gamma_cor-arch.md`](axis_gamma_cor-arch.md) — Skid-pipeline pattern this module reuses (1-cycle latency, `enable_i` bypass, sideband-free pixel datapath).
