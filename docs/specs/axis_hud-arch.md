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

The HUD draws one line of text, 30 characters at 8×8 pixels each:

```
F:####  T:XXX  N:##  L:#####us
```

The HUD region is `(N_CHARS · 8) × 8` pixels at `(HUD_X0, HUD_Y0)` — at default origin `(8, 8)` with `N_CHARS = 30`, columns 8–247 × rows 8–15, which fits both 320×240 and 640×480 output frames.

Of the 30 cells, 16 hold static literal text (`F:`, `T:`, `N:`, `L:`, gap spaces, trailing `us`) and 14 are runtime-driven: 4 frame digits, 3 tag glyphs, 2 bbox digits, 5 latency digits. The 14 dynamic cells are recomputed once per frame from the latched sidebands.

### 4.2 Glyph addressing

The font ROM in `axis_hud_font_pkg` is `FONT_ROM[GLYPH][ROW]`, where `GLYPH` is a 6-bit index (digits 0–9, A–Z, `:`, space) and `ROW` selects one of 8 row patterns. Each row pattern is one byte, MSB = leftmost pixel.

For an output pixel inside the HUD region:

```
cell      = (col - HUD_X0) >> 3            // 0..N_CHARS-1
y_in_cell = row - HUD_Y0                   // 0..7
x_in_cell = (col - HUD_X0) & 7             // 0..7
fg_bit    = FONT_ROM[glyph_table[cell]][y_in_cell][7 - x_in_cell]
```

`glyph_table` is the per-frame glyph index table (§5.2).

### 4.3 Per-pixel render rule

`m_axis.tdata = (enable_i && in_hud_region && fg_bit) ? 24'hFF_FF_FF : s_axis.tdata`. Pixels outside the HUD region pass through unchanged. Inside, glyph foreground bits force white; glyph background bits still pass through, so the HUD has no rectangular backdrop.

---

## 5. Internal Architecture

### 5.1 Data flow overview

```
   ┌────────────────────────────────────────────────────────────────────┐
   │                              axis_hud                              │
   │                                                                    │
   │   s_axis ──► skid ─────────────────────────► render mux ──► m_axis │
   │              │                                  ▲                  │
   │              ▼                                  │                  │
   │       position counters ────────────────────────┤                  │
   │                                                 │                  │
   │   sideband ──► SOF latch ──► decimal-expand     │                  │
   │                                  │              │                  │
   │                                  ▼              │                  │
   │                            glyph_table ──► FONT_ROM (fg_bit)       │
   │                                                                    │
   └────────────────────────────────────────────────────────────────────┘
```

The datapath is a single-stage skid pipeline (the same pattern as `axis_gamma_cor`). The pixel takes one `clk_dsp` cycle to traverse the module. Sideband processing (latch, decimal expansion, glyph-table maintenance) runs in parallel and is decoupled from the per-pixel datapath: it completes during vertical blanking, well before the next SOF.

### 5.2 Glyph-index table

`glyph_table` is a flat 30-entry register array of 6-bit `glyph_idx_t` values (180 bits total). The 16 static literal cells (`F`, `:`, space, `T`, `N`, `L`, `U`, `S`, plus gap spaces) are written at reset and never change. The 14 dynamic cells (4 frame digits, 3 tag glyphs, 2 bbox digits, 5 latency digits) are rewritten once per frame at the end of decimal expansion.

### 5.3 Decimal expansion

Each numeric field is reduced to decimal digits by a subtract-10 FSM, walking digits least-significant-first. For each digit position: subtract 10 from `rem` while incrementing a counter, until `rem < 10`; the residue is the digit, the counter becomes the next-decade dividend. The digit is written into the corresponding `glyph_table` cell.

`rem` and the counter are 16 bits to fit the worst-case dividend (`latency_us = 65535`, requiring 6553 subtract-10 steps to extract the LSD). Across all three fields the FSM walks `4 + 2 + 5 = 11` digit positions; worst-case ~6600 cycles, dominated by the latency LSD — well inside v-blank (~280 kcycles at VGA timing).

`frame_num` is sampled live at the SOF edge (the sideband latch fires on the same edge, so latched and live values are equal); the other two fields read from their latched copies.

### 5.4 Render mux

The skid stage holds the most recently accepted input beat plus its framing bits and position. It advances when the downstream is ready or the stage is empty (`stage_advance = m_axis.tready || !pipe_valid_q`); `s_axis.tready` follows `stage_advance`.

The render mux is combinational off the registered skid and registered `glyph_table`: `m_axis.tdata = (enable_i && in_hud_region && fg_bit) ? 24'hFF_FF_FF : s_axis_data_q`. This keeps the FONT_ROM lookup between two flops.

---

## 6. Control Logic

### 6.1 FSMs

Three concurrent control blocks:

- **Position counters.** Track the column and row of the pixel currently on `s_axis`; the skid stage carries a snapshot for the pixel in the skid, which feeds the render path.
- **Sideband latch.** Latches `frame_num`, `bbox_count`, `ctrl_flow_tag`, `latency_us` on accepted input SOF and freezes them for the rest of the frame. Eliminates mid-frame flicker if the producer changes its sidebands mid-stream.
- **Decimal-expand FSM.** Two states (`D_IDLE`, `D_DECODE`) walk the three numeric fields least-significant-first via the subtract-10 loop in §5.3. SOF triggers the transition to `D_DECODE`, the FSM advances through `F_FRAME → F_BBOX → F_LAT` reseeding `rem` from each latched sideband, and returns to `D_IDLE` after the latency MSD. Completes well within v-blank.

### 6.2 Range handling

- **`bbox_count`** is clamped to 99 before expansion (the layout reserves only 2 digits). Larger inputs render as `99` with no overflow indication; the upstream owns any "saturated" signal.
- **`latency_us`** is not clamped — the 16-bit range fits the 5-digit field. The top-level producer is responsible for keeping its cycles-to-µs conversion in 16 bits.
- **`frame_num`** wraps modulo 10000 in display: values 10000..65535 are rendered as their value mod 10000.

### 6.3 `ctrl_flow_tag` decode

`ctrl_flow_tag_q` selects one of four glyph triples, written into the three tag-cells of `glyph_table`:

| Tag | Glyphs |
|-----|--------|
| `2'b00` | P A S |
| `2'b01` | M O T |
| `2'b10` | M S K |
| `2'b11` | C C L |

The decode runs once per frame in parallel with decimal expansion (no FSM step).

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
