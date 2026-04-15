# `axis_motion_detect` Architecture

## 1. Purpose and Scope

`axis_motion_detect` computes a 1-bit per-pixel motion mask by comparing the current frame's luma (Y8) against the corresponding pixel in the previous frame. It simultaneously passes the original RGB888 video through with latency-matched timing. It does **not** perform spatial filtering, multi-frame averaging, or morphological operations. Color-space conversion is delegated to an instantiated `rgb2ycrcb` submodule. The Y8 frame buffer lives in an external shared RAM connected via the module's memory port.

---

## 2. Module Hierarchy

```
axis_motion_detect (u_motion_detect)
└── rgb2ycrcb  (u_rgb2ycrcb)   — RGB888 → Y8, 1-cycle pipeline
```

---

## 3. Interface Specification

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | 320 | Active pixels per line |
| `V_ACTIVE` | 240 | Active lines per frame |
| `THRESH` | 16 | Unsigned luma-difference threshold; also serves as the minimum current-luma floor (see §4) |
| `RGN_BASE` | 0 | Base byte-address of the Y_PREV region in the shared RAM |
| `RGN_SIZE` | `H_ACTIVE×V_ACTIVE` | Byte size of the Y_PREV region (sanity-checked at elaboration) |

### Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `clk_i` | input | 1 | DSP clock (`clk_dsp`) |
| `rst_n_i` | input | 1 | Active-low synchronous reset |
| `s_axis_tdata_i` | input | 24 | RGB888 pixel input |
| `s_axis_tvalid_i` | input | 1 | AXI4-Stream valid |
| `s_axis_tready_o` | output | 1 | AXI4-Stream ready (= `vid_ready AND msk_ready`) |
| `s_axis_tlast_i` | input | 1 | End-of-line |
| `s_axis_tuser_i` | input | 1 | Start-of-frame |
| `m_axis_vid_tdata_o` | output | 24 | RGB888 video passthrough |
| `m_axis_vid_tvalid_o` | output | 1 | Video stream valid |
| `m_axis_vid_tready_i` | input | 1 | Video stream ready |
| `m_axis_vid_tlast_o` | output | 1 | Video end-of-line |
| `m_axis_vid_tuser_o` | output | 1 | Video start-of-frame |
| `m_axis_msk_tdata_o` | output | 1 | Motion mask bit |
| `m_axis_msk_tvalid_o` | output | 1 | Mask stream valid |
| `m_axis_msk_tready_i` | input | 1 | Mask stream ready |
| `m_axis_msk_tlast_o` | output | 1 | Mask end-of-line |
| `m_axis_msk_tuser_o` | output | 1 | Mask start-of-frame |
| `mem_rd_addr_o` | output | `$clog2(RGN_BASE+RGN_SIZE)` | RAM read address |
| `mem_rd_data_i` | input | 8 | RAM read data (valid 1 cycle after address) |
| `mem_wr_addr_o` | output | `$clog2(RGN_BASE+RGN_SIZE)` | RAM write address |
| `mem_wr_data_o` | output | 8 | RAM write data (`Y_cur`) |
| `mem_wr_en_o` | output | 1 | RAM write enable |

---

## 4. Datapath Description

### Algorithm (per accepted pixel)

```
Y_cur  = rgb2ycrcb(R, G, B).y         // 1-cycle pipeline inside rgb2ycrcb
Y_prev = mem_rd_data_i                 // RAM read, 1-cycle latency after mem_rd_addr_o
diff   = abs(Y_cur − Y_prev)
mask   = (diff > THRESH)

mem_wr_addr_o = RGN_BASE + pix_addr    // write Y_cur back at same address
mem_wr_data_o = Y_cur
mem_wr_en_o   = tvalid && tready       // only on actual acceptance
```

### Polarity-agnostic mask

The mask uses a pure frame-difference condition (`diff > THRESH`) with no brightness-polarity filter. Both arrival pixels (where the object now is) and departure pixels (where the object was) are flagged. This makes the mask work correctly for all scene types: bright-on-dark, dark-on-bright, gradients, and colour scenes.

The trade-off is that the bounding box produced by `axis_bbox_reduce` encompasses both old and new object positions, making it slightly larger than the object by approximately one frame of displacement in each axis.

### Pixel address counter

`pix_addr` is a frame-relative counter reset on SOF (`tuser`) and incremented on every accepted pixel (`tvalid && tready`). The physical RAM address is `RGN_BASE + pix_addr`.

`mem_rd_addr_o` is driven combinationally to `RGN_BASE + pix_addr_next` (the address for the *next* pixel), so the read result is available at `mem_rd_data_i` 1 cycle later — exactly when the next pixel is being processed.

### RAM read/write discipline

The RAM uses read-first semantics on port A. When motion detect reads and writes the same address in the same cycle (the current pixel's address), port A returns the **old** value (previous frame's Y_cur). No external bypass logic is needed.

### Pipeline stages

```
Cycle C   : pixel N accepted; rgb2ycrcb MACs computed combinationally; mem_rd_addr_o issued
Cycle C+1 : y_cur registered; mem_rd_data_i arrives → diff computed → mask, vid registered
```

Total latency: **1 clock cycle** from accepted pixel to emitted pixel on vid/msk outputs.

### Backpressure

`s_axis_tready_o = m_axis_vid_tready_i AND m_axis_msk_tready_i`. A pipeline stall register (`pipe_stall`) is set when the output pipeline holds valid data but at least one downstream consumer deasserts ready. During stall:
- All pipeline registers are frozen (gated with `!pipe_stall`).
- `rgb2ycrcb` is fed from the held pipeline register rather than live `s_axis_tdata_i`.
- `mem_rd_addr_o` is held via a registered hold address.
- `mem_wr_en_o` is gated to zero — no repeat writes during stall.

---

## 5. State / Control Logic

There is no explicit FSM. Control is combinational backpressure logic (`pipe_stall`, `both_ready`), a pixel address counter, and gated pipeline registers.

| Signal | Meaning |
|--------|---------|
| `both_ready` | `m_axis_vid_tready_i && m_axis_msk_tready_i` |
| `pipe_stall` | `tvalid_pipe AND NOT both_ready` — pipeline has valid data but can't advance |
| `pix_addr` | Frame-relative pixel index, 0…`H_ACTIVE×V_ACTIVE−1` |

---

## 6. Timing

| Operation | Latency |
|-----------|---------|
| RGB → Y8 (`rgb2ycrcb`) | 1 clock cycle |
| RAM read | 1 clock cycle |
| Total pixel input → mask/vid output | 1 clock cycle |
| Throughput | 1 pixel / cycle (when `both_ready=1`) |

Frame 0: RAM is zero-initialized → all pixels read `Y_prev=0` → mask=1 for every non-black pixel → near-full-frame bbox. `axis_bbox_reduce` suppresses bbox output for the first 2 frames (priming period) to avoid this artifact.

---

## 7. Shared Types

None from `sparevideo_pkg` directly. Frame geometry parameters (`H_ACTIVE`, `V_ACTIVE`) match the package values when instantiated from `sparevideo_top`.

---

## 8. Known Limitations

- **No spatial smoothing**: a single noisy pixel produces a mask=1 bit. Erode/dilate filtering is deferred.
- **Fixed THRESH**: compile-time parameter. Runtime control requires promoting to an input port and a `sparevideo_csr` AXI-Lite register.
- **`Cr`/`Cb` unused**: `rgb2ycrcb` outputs `cb_o` and `cr_o`; only `y_o` is used. Lint waivers suppress `PINCONNECTEMPTY`/`UNUSEDSIGNAL`.
- **Single-buffered**: no double-buffering. Mid-frame RAM corruption by port B clients accessing the Y_PREV region during an active frame will produce incorrect mask bits. See the host-responsibility rule in [ram-arch.md](ram-arch.md).
- **Bbox oversizing**: the polarity-agnostic mask flags both arrival and departure pixels, so the bbox is slightly larger than the object by approximately the per-frame displacement. This is a deliberate trade-off for scene-type independence.
