# `vga_controller` Architecture

## 1. Purpose and Scope

`vga_controller` accepts a streaming RGB888 pixel input via a ready/valid handshake, generates VGA horizontal and vertical timing, and drives RGB + hsync/vsync outputs. It consumes exactly one pixel per active-region clock cycle and outputs zero-valued RGB during blanking intervals. It does **not** scale, crop, or reformat the pixel data; it does not buffer frames; it does not generate pixel data (test patterns are in `pattern_gen.sv`).

---

## 2. Module Hierarchy

`vga_controller` is a leaf module — no submodules.

---

## 3. Interface Specification

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | 640 | Active pixels per line |
| `H_FRONT_PORCH` | 16 | Horizontal front porch (pixel clocks) |
| `H_SYNC_PULSE` | 96 | Horizontal sync pulse width (pixel clocks) |
| `H_BACK_PORCH` | 48 | Horizontal back porch (pixel clocks) |
| `V_ACTIVE` | 480 | Active lines per frame |
| `V_FRONT_PORCH` | 10 | Vertical front porch (lines) |
| `V_SYNC_PULSE` | 2 | Vertical sync pulse height (lines) |
| `V_BACK_PORCH` | 33 | Vertical back porch (lines) |

Defaults correspond to 640×480 @ 60 Hz on a 25 MHz pixel clock.

### Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `clk_i` | input | 1 | Pixel clock |
| `rst_n_i` | input | 1 | Active-low synchronous reset — held until first SOF in `sparevideo_top` |
| `pixel_data_i` | input | 24 | `{R[7:0], G[7:0], B[7:0]}` |
| `pixel_valid_i` | input | 1 | Upstream has pixel data available |
| `pixel_ready_o` | output | 1 | Controller is in active region and can accept a pixel |
| `frame_start_o` | output | 1 | 1-cycle pulse at the first active pixel of each frame |
| `line_start_o` | output | 1 | 1-cycle pulse at the first active pixel of each line |
| `vga_hsync_o` | output | 1 | Horizontal sync, active-low |
| `vga_vsync_o` | output | 1 | Vertical sync, active-low |
| `vga_r_o` | output | 8 | Red (0 during blanking) |
| `vga_g_o` | output | 8 | Green (0 during blanking) |
| `vga_b_o` | output | 8 | Blue (0 during blanking) |

---

## 4. Datapath Description

### Counters

- `h_count`: horizontal counter, 0…`H_TOTAL−1`. Increments every clock. Wraps at `H_TOTAL−1`.
- `v_count`: vertical counter, 0…`V_TOTAL−1`. Increments each time `h_count` wraps. Wraps at `V_TOTAL−1`.

Derived timing constants (localparams):
```
H_TOTAL      = H_ACTIVE + H_FRONT_PORCH + H_SYNC_PULSE + H_BACK_PORCH
V_TOTAL      = V_ACTIVE + V_FRONT_PORCH + V_SYNC_PULSE + V_BACK_PORCH
H_SYNC_START = H_ACTIVE + H_FRONT_PORCH
H_SYNC_END   = H_SYNC_START + H_SYNC_PULSE
V_SYNC_START = V_ACTIVE + V_FRONT_PORCH
V_SYNC_END   = V_SYNC_START + V_SYNC_PULSE
```

### Active region

`active = (h_count < H_ACTIVE) && (v_count < V_ACTIVE)` — combinational.

`pixel_ready_o = active` — the controller accepts exactly one pixel per active-region cycle.

### Sync generation

`vga_hsync_o` is asserted (low) when `h_count ∈ [H_SYNC_START, H_SYNC_END)`.  
`vga_vsync_o` is asserted (low) when `v_count ∈ [V_SYNC_START, V_SYNC_END)`.  
Both are registered.

### RGB output

During active region: `vga_{r,g,b}_o <= pixel_data_i[23:16/15:8/7:0]` — registered.  
During blanking: `vga_{r,g,b}_o <= 8'h00` — registered.

---

## 5. Control Logic

No FSM. The only state is `h_count` and `v_count`. All other outputs are combinational or directly registered from counter comparisons.

---

## 6. Timing

| Event | Latency |
|-------|---------|
| `pixel_data_i` → `vga_{r,g,b}_o` | 1 cycle (registered) |
| `h_count` → `vga_hsync_o` | 1 cycle (registered) |
| Pixels consumed per frame | `H_ACTIVE × V_ACTIVE` |
| Idle clocks per frame | `H_TOTAL × V_TOTAL − H_ACTIVE × V_ACTIVE` |

The idle cycles (blanking) are when `pixel_ready_o = 0`. The upstream must tolerate this back-pressure by either having the output FIFO absorb the burst or by pacing its input to match the long-term consumption rate (VGA timing rate). `sparevideo_top` uses a 32-entry output FIFO for this purpose.

---

## 7. Shared Types

None from `sparevideo_pkg`. VGA timing parameters are passed through from the top-level package.

---

## 8. Known Limitations

- **No `tuser`/`tlast` input**: the controller does not track frame/line boundaries in the pixel stream — it relies entirely on its own internal counters. If the pixel stream goes out of sync with the VGA counters (e.g., missing pixels due to underrun), the display tears silently. The `assert_no_output_underrun` SVA in `sparevideo_top` catches this at sim time.
- **`rst_n_i` held externally**: `sparevideo_top` keeps `rst_n_i` deasserted until the first SOF pixel exits the output FIFO (`vga_started` logic). If the VGA controller is reset mid-stream (e.g., mid-frame), the counters restart from 0 immediately, causing a partial frame of corruption.
- **`frame_start_o` / `line_start_o` unused in top level**: these outputs are available for upstream flow-control or debug but are currently tied off.
