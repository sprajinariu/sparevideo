# `axis_motion_detect` Architecture

## 1. Purpose and Scope

`axis_motion_detect` computes a 1-bit per-pixel motion mask by comparing the current frame's luma (Y8) against a per-pixel background model stored in the shared RAM. The background model is maintained as an exponential moving average (EMA) — each pixel's stored value tracks the temporal mean of that pixel's luma, smoothing out sensor noise and gradual lighting changes. It simultaneously passes the original RGB888 video through with latency-matched timing. It does **not** perform spatial filtering or morphological operations. Color-space conversion is delegated to an instantiated `rgb2ycrcb` submodule. The Y8 frame buffer lives in an external shared RAM connected via the module's memory port.

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
| `ALPHA_SHIFT` | 3 | EMA smoothing factor as a bit-shift: alpha = 1 / (1 << ALPHA_SHIFT). Default 3 → alpha = 1/8. Higher values = slower background adaptation. When 0, the EMA reduces to raw-frame write-back (bg_new = Y_cur) |
| `RGN_BASE` | 0 | Base byte-address of the background model region in the shared RAM |
| `RGN_SIZE` | `H_ACTIVE×V_ACTIVE` | Byte size of the background model region (sanity-checked at elaboration) |

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
| `mem_wr_data_o` | output | 8 | RAM write data (EMA-updated background value) |
| `mem_wr_en_o` | output | 1 | RAM write enable |

---

## 4. Datapath Description

### Algorithm (per accepted pixel)

```
Y_cur  = rgb2ycrcb(R, G, B).y         // 1-cycle pipeline inside rgb2ycrcb
bg     = mem_rd_data_i                 // RAM read, 1-cycle latency after mem_rd_addr_o
diff   = abs(Y_cur − bg)
mask   = (diff > THRESH)

// EMA background update — write smoothed estimate back to RAM
delta      = Y_cur − bg               // signed 9-bit
ema_step   = delta >>> ALPHA_SHIFT     // arithmetic right-shift (sign-preserving)
ema_update = bg + ema_step[7:0]        // new background value

mem_wr_addr_o = RGN_BASE + pix_addr
mem_wr_data_o = ema_update             // EMA-smoothed background, not raw Y_cur
mem_wr_en_o   = tvalid && tready       // only on actual acceptance
```

When `ALPHA_SHIFT = 0`, `ema_step = delta` and `ema_update = Y_cur`, so the module reduces to raw previous-frame write-back.

### EMA background model

The RAM stores a temporally smoothed estimate of each pixel's luma rather than the raw value from the last frame. This provides two benefits over raw frame differencing:

1. **Noise suppression:** Sensor noise causes pixel values to jitter ±2-5 luma levels between consecutive frames on a static scene. With EMA (alpha=1/8), the background converges to the mean of the jitter, keeping `|Y_cur - bg|` well below threshold for static pixels.

2. **Gradual lighting adaptation:** Slow brightness changes (clouds, time of day) are tracked by the EMA. The background drifts toward the new lighting level over `~1/alpha` frames, preventing full-frame false positives from sudden illumination transitions.

### EMA computation signals

```systemverilog
logic signed [8:0] ema_delta;     // Y_cur - bg, signed 9-bit
logic signed [8:0] ema_step;      // delta >>> ALPHA_SHIFT (arithmetic right-shift)
logic        [7:0] ema_update;    // new background value

assign ema_delta  = {1'b0, y_cur} - {1'b0, mem_rd_data_i};
assign ema_step   = ema_delta >>> ALPHA_SHIFT;
assign ema_update = mem_rd_data_i + ema_step[7:0];
```

These signals are combinational, computed after the pipeline register stage where both `y_cur` and `mem_rd_data_i` are valid. The write-back `mem_wr_data_o <= ema_update` stores the EMA-smoothed background value.

### Polarity-agnostic mask

The mask uses a pure frame-difference condition (`diff > THRESH`) with no brightness-polarity filter. Both arrival pixels (where the object now is) and departure pixels (where the object was) are flagged. This makes the mask work correctly for all scene types: bright-on-dark, dark-on-bright, gradients, and colour scenes.

The trade-off is that the bounding box produced by `axis_bbox_reduce` encompasses both old and new object positions, making it slightly larger than the object by approximately one frame of displacement in each axis.

### Pixel address counter

`pix_addr` is a frame-relative counter reset on SOF (`tuser`) and incremented on every accepted pixel (`tvalid && tready`). The physical RAM address is `RGN_BASE + pix_addr`.

`mem_rd_addr_o` is driven combinationally to `RGN_BASE + pix_addr_next` (the address for the *next* pixel), so the read result is available at `mem_rd_data_i` 1 cycle later — exactly when the next pixel is being processed.

### RAM read/write discipline

The RAM uses read-first semantics on port A. When motion detect reads and writes the same address in the same cycle (the current pixel's address), port A returns the **old** value (previous frame's background estimate). No external bypass logic is needed.

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

Frame 0: RAM is zero-initialized → all pixels read `bg=0` → mask=1 for every non-black pixel → near-full-frame bbox. `axis_bbox_reduce` suppresses bbox output for the first 2 frames (priming period) to avoid this artifact. The EMA converges from zero toward the actual scene luma over `~1/alpha` frames.

EMA convergence: After a step change in a pixel's value, the background converges toward the new value over approximately `1/alpha = 1 << ALPHA_SHIFT` frames. With the default `ALPHA_SHIFT=3` (alpha=1/8), a pixel that steps from 100 to 200 will have its background reach ~200 after ~16 frames. Motion is detected (mask=1) for the first several frames until `|Y_cur - bg|` drops below `THRESH`. This is the intended behavior — transient objects are detected, then absorbed into the background.

**Why not raw-frame priming?** Writing raw `y_cur` to RAM on frame 0 was evaluated but rejected. While it fills the background model instantly, any foreground object present in frame 0 gets its luma written into the background. When the object moves, the departure ghost persists for `~1/alpha` frames — much worse than the EMA warm-up from zero. With EMA from zero, the background only moves `y_cur >> ALPHA_SHIFT` toward the object per frame, so departure ghosts from the initial convergence clear quickly.

---

## 7. Shared Types

None from `sparevideo_pkg` directly. Frame geometry parameters (`H_ACTIVE`, `V_ACTIVE`) match the package values when instantiated from `sparevideo_top`.

---

## 8. Known Limitations

- **No spatial smoothing**: a single noisy pixel produces a mask=1 bit. Erode/dilate filtering is deferred.
- **Fixed THRESH**: compile-time parameter. Runtime control requires promoting to an input port and a `sparevideo_csr` AXI-Lite register.
- **Fixed ALPHA_SHIFT**: compile-time parameter. Different scenes may benefit from different adaptation rates; runtime control would require the same CSR promotion as THRESH.
- **`Cr`/`Cb` unused**: `rgb2ycrcb` outputs `cb_o` and `cr_o`; only `y_o` is used. Lint waivers suppress `PINCONNECTEMPTY`/`UNUSEDSIGNAL`.
- **Single-buffered**: no double-buffering. Mid-frame RAM corruption by port B clients accessing the background model region during an active frame will produce incorrect mask bits. See the host-responsibility rule in [ram-arch.md](ram-arch.md).
- **Bbox oversizing**: the polarity-agnostic mask flags both arrival and departure pixels, so the bbox is slightly larger than the object by approximately the per-frame displacement. This is a deliberate trade-off for scene-type independence.
- **EMA rounding bias**: the arithmetic right-shift truncates toward negative infinity, introducing a small systematic bias. For typical video luma values this is negligible (sub-LSB after a few frames).
