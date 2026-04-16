# `axis_motion_detect` Architecture

## 1. Purpose and Scope

`axis_motion_detect` computes a 1-bit per-pixel motion mask by comparing the current frame's luma (Y8) against a per-pixel background model stored in the shared RAM. The background model is maintained as an exponential moving average (EMA) — each pixel's stored value tracks the temporal mean of that pixel's luma, smoothing out sensor noise and gradual lighting changes. It simultaneously passes the original RGB888 video through with latency-matched timing. It does **not** perform spatial filtering or morphological operations. Color-space conversion is delegated to an instantiated `rgb2ycrcb` submodule. The Y8 frame buffer lives in an external shared RAM connected via the module's memory port.

---

## 2. Module Hierarchy

```
axis_motion_detect (u_motion_detect)
├── axis_fork_pipe (u_fork)    — AXI4-Stream 1-to-2 fork with sideband pipeline
├── rgb2ycrcb      (u_rgb2y)   — RGB888 → Y8, 1-cycle pipeline
└── motion_core    (u_core)    — Combinational: abs-diff threshold + EMA update
```

`axis_fork_pipe` (in `hw/ip/axis/rtl/`) is a reusable module that manages per-output
acceptance tracking, pipeline stall gating, and sideband registers. It exports
`pipe_stall_o` and `beat_done_o` so the parent can gate the stall mux, memory
address hold, and write-back enable.

`motion_core` (in `hw/ip/motion/rtl/`) is a pure-combinational module with no
clock or state. It takes `y_cur` and `y_bg` as inputs and produces `mask_bit`
and `ema_update` as outputs.

`axis_motion_detect` is the glue: it instantiates the three submodules, owns the
pixel address counter, manages the RGB→Y stall mux, and wires the memory ports.

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
| **AXI4-Stream input (RGB888)** | | | |
| `s_axis_tdata_i` | input | 24 | RGB888 pixel input |
| `s_axis_tvalid_i` | input | 1 | AXI4-Stream valid |
| `s_axis_tready_o` | output | 1 | AXI4-Stream ready (= `NOT tvalid_pipe OR both_done`) |
| `s_axis_tlast_i` | input | 1 | End-of-line |
| `s_axis_tuser_i` | input | 1 | Start-of-frame |
| **AXI4-Stream output — video passthrough (RGB888)** | | | |
| `m_axis_vid_tdata_o` | output | 24 | RGB888 video passthrough |
| `m_axis_vid_tvalid_o` | output | 1 | Video stream valid |
| `m_axis_vid_tready_i` | input | 1 | Video stream ready |
| `m_axis_vid_tlast_o` | output | 1 | Video end-of-line |
| `m_axis_vid_tuser_o` | output | 1 | Video start-of-frame |
| **AXI4-Stream output — mask (1 bit)** | | | |
| `m_axis_msk_tdata_o` | output | 1 | Motion mask bit |
| `m_axis_msk_tvalid_o` | output | 1 | Mask stream valid |
| `m_axis_msk_tready_i` | input | 1 | Mask stream ready |
| `m_axis_msk_tlast_o` | output | 1 | Mask end-of-line |
| `m_axis_msk_tuser_o` | output | 1 | Mask start-of-frame |
| **Memory port (to shared RAM port A)** | | | |
| `mem_rd_addr_o` | output | `$clog2(RGN_BASE+RGN_SIZE)` | RAM read address |
| `mem_rd_data_i` | input | 8 | RAM read data (valid 1 cycle after address) |
| `mem_wr_addr_o` | output | `$clog2(RGN_BASE+RGN_SIZE)` | RAM write address |
| `mem_wr_data_o` | output | 8 | RAM write data (EMA-updated background value) |
| `mem_wr_en_o` | output | 1 | RAM write enable |

---

## 4. Concept Description

Background subtraction is a fundamental technique in video surveillance and motion detection. It maintains a model of the static background scene and detects motion by comparing each incoming pixel against this model. Pixels that differ significantly from the background are classified as foreground (motion).

The simplest background model stores the previous frame's raw pixel values. However, raw frame differencing is sensitive to sensor noise — random ±2–5 luma jitter between consecutive frames on a static scene triggers false positives when the threshold is set low enough to detect real motion.

This module uses an Exponential Moving Average (EMA) as the background model. The EMA updates the background estimate with a weighted blend of the old estimate and the new observation:

```
bg[n] = bg[n-1] + α · (y[n] - bg[n-1])
      = (1 - α) · bg[n-1] + α · y[n]
```

where `α = 1 / (1 << ALPHA_SHIFT)` is the adaptation rate. The EMA acts as a first-order IIR low-pass filter with time constant `τ ≈ 1/α` frames. This provides two key benefits over raw frame differencing:

1. **Noise suppression**: sensor noise is averaged out over `1/α` frames, keeping `|y[n] - bg[n]|` well below the detection threshold for static pixels.
2. **Gradual lighting adaptation**: slow brightness changes (clouds, time of day) are tracked by the EMA, preventing full-frame false positives from illumination drift.

The motion threshold comparison uses absolute difference (`|y_cur - bg| > THRESH`), making it **polarity-agnostic**: both arrival pixels (where a moving object now is) and departure pixels (where it was) are flagged as motion. This ensures correct detection regardless of the brightness relationship between object and background (bright-on-dark, dark-on-bright, or colour scenes). The trade-off is that the downstream bounding box encompasses both old and new object positions, making it slightly larger than the object by approximately one frame of displacement.

In hardware, the EMA multiplication by `α = 1/(1 << ALPHA_SHIFT)` is implemented as an arithmetic right-shift, requiring no multiplier. When `ALPHA_SHIFT = 0`, the EMA degenerates to raw frame write-back (`bg_new = y_cur`).

**Why not raw-frame priming?** Writing raw `y_cur` to RAM on frame 0 was evaluated but rejected. While it fills the background model instantly, any foreground object present in frame 0 gets its luma committed to the background. When the object moves, the departure ghost persists for `~1/alpha` frames — much worse than the EMA warm-up from zero. With EMA from zero, the background only moves `y_cur >> ALPHA_SHIFT` toward the object per frame, so departure ghosts from the initial convergence clear quickly.

---

## 5. Internal Architecture

### Per-pixel algorithm

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

### EMA computation signals (`motion_core`)

The threshold comparison and EMA update are encapsulated in `motion_core` (`hw/ip/motion/rtl/`), a pure-combinational module:

```systemverilog
// motion_core ports:
//   y_cur_i, y_bg_i  →  mask_bit_o, ema_update_o

// Internal signals:
logic [7:0]        diff       = abs(y_cur_i - y_bg_i);
logic              mask_bit_o = (diff > THRESH);
logic signed [8:0] ema_delta  = {1'b0, y_cur_i} - {1'b0, y_bg_i};
logic signed [8:0] ema_step   = ema_delta >>> ALPHA_SHIFT;
logic        [7:0] ema_update_o = y_bg_i + ema_step[7:0];
```

These signals are evaluated after the pipeline register stage where both `y_cur` and `mem_rd_data_i` are valid. The write-back `mem_wr_data_o <= ema_update` stores the EMA-smoothed background value.

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

### Backpressure — AXI4-Stream 1-to-2 fork (`axis_fork_pipe`)

The fork logic is encapsulated in `axis_fork_pipe` (`hw/ip/axis/rtl/`), a reusable module implementing **per-output acceptance tracking** (pattern from verilog-axis `axis_broadcast`). Each output's `tvalid` is independently gated: once a consumer accepts the current beat, its `tvalid` deasserts while the other consumer's `tvalid` remains asserted until it also accepts. The pipeline advances only when both outputs have been consumed (either in the same cycle or across separate cycles).

```
a_done    = a_accepted OR m_a_tready_i
b_done    = b_accepted OR m_b_tready_i
both_done = a_done AND b_done

m_a_tvalid_o    = pipe_valid AND NOT a_accepted
m_b_tvalid_o    = pipe_valid AND NOT b_accepted

s_axis_tready_o = NOT pipe_valid OR both_done
pipe_stall_o    = pipe_valid AND NOT both_done
beat_done_o     = pipe_valid AND both_done
```

The `a_accepted` / `b_accepted` registers reset to 0 on the cycle that `beat_done` is asserted (the beat is fully consumed and the pipeline advances). `axis_motion_detect` uses the exported control signals during a stall:
- All pipeline registers are frozen (gated with `!pipe_stall_o` inside `axis_fork_pipe`).
- `rgb2ycrcb` is fed from the held pipeline data (`pipe_tdata_o`) rather than live `s_axis_tdata_i`.
- `mem_rd_addr_o` is held via a registered hold address (`pix_addr_hold`).
- `mem_wr_en_o` is driven by `beat_done_o`, ensuring exactly one write per pixel.

### Resource cost

The module consumes one `rgb2ycrcb` instance (9 multipliers + 24 FFs), the `motion_core` combinational logic (one 8-bit subtractor, one absolute-value, one comparator, one 9-bit arithmetic shift, one 8-bit adder), and the `axis_fork_pipe` pipeline registers (~50 bits of sideband + 2 acceptance FFs). RAM consumption is external (shared `ram` module). The pixel address counter adds `$clog2(H_ACTIVE × V_ACTIVE)` bits of registered state.

---

## 6. State / Control Logic

There is no explicit FSM. Fork acceptance tracking and pipeline stall logic live inside `axis_fork_pipe`. `axis_motion_detect` owns the pixel address counter, stall mux, memory address hold, and write-back gating.

| Signal | Location | Meaning |
|--------|----------|---------|
| `a_accepted` | `axis_fork_pipe` | Registered flag — output A accepted the current beat in a prior cycle |
| `b_accepted` | `axis_fork_pipe` | Registered flag — output B accepted the current beat in a prior cycle |
| `pipe_stall_o` | `axis_fork_pipe` | `pipe_valid AND NOT both_done` — pipeline stalled |
| `beat_done_o` | `axis_fork_pipe` | `pipe_valid AND both_done` — beat fully consumed |
| `pix_addr` | `axis_motion_detect` | Frame-relative pixel index, 0…`H_ACTIVE×V_ACTIVE−1` |
| `pix_addr_hold` | `axis_motion_detect` | Registered hold address — keeps `mem_rd_addr_o` stable during stall |
| `idx_pipe` | `axis_motion_detect` | Pixel address pipeline — tracks address through stages for write-back |

---

## 7. Timing

| Operation | Latency |
|-----------|---------|
| RGB → Y8 (`rgb2ycrcb`) | 1 clock cycle |
| RAM read | 1 clock cycle |
| Total pixel input → mask/vid output | 1 clock cycle |
| Throughput | 1 pixel / cycle (when `both_ready=1`) |

Frame 0: RAM is zero-initialized → all pixels read `bg=0` → mask=1 for every non-black pixel → near-full-frame bbox. `axis_bbox_reduce` suppresses bbox output for the first 2 frames (priming period) to avoid this artifact. The EMA converges from zero toward the actual scene luma over `~1/alpha` frames.

EMA convergence: After a step change in a pixel's value, the background converges toward the new value over approximately `1/alpha = 1 << ALPHA_SHIFT` frames. With the default `ALPHA_SHIFT=3` (alpha=1/8), a pixel that steps from 100 to 200 will have its background reach ~200 after ~16 frames. Motion is detected (mask=1) for the first several frames until `|Y_cur - bg|` drops below `THRESH`. This is the intended behavior — transient objects are detected, then absorbed into the background.

---

## 8. Shared Types

None from `sparevideo_pkg` directly. Frame geometry parameters (`H_ACTIVE`, `V_ACTIVE`) match the package values when instantiated from `sparevideo_top`.

---

## 9. Known Limitations

- **No spatial smoothing**: a single noisy pixel produces a mask=1 bit. Erode/dilate filtering is deferred.
- **Fixed THRESH**: compile-time parameter. Runtime control requires promoting to an input port and a `sparevideo_csr` AXI-Lite register.
- **Fixed ALPHA_SHIFT**: compile-time parameter. Different scenes may benefit from different adaptation rates; runtime control would require the same CSR promotion as THRESH.
- **`Cr`/`Cb` unused**: `rgb2ycrcb` outputs `cb_o` and `cr_o`; only `y_o` is used. Lint waivers suppress `PINCONNECTEMPTY`/`UNUSEDSIGNAL`.
- **Single-buffered**: no double-buffering. Mid-frame RAM corruption by port B clients accessing the background model region during an active frame will produce incorrect mask bits. See the host-responsibility rule in [ram-arch.md](ram-arch.md).
- **Bbox oversizing**: the polarity-agnostic mask flags both arrival and departure pixels, so the bbox is slightly larger than the object by approximately the per-frame displacement. This is a deliberate trade-off for scene-type independence.
- **EMA rounding bias**: the arithmetic right-shift truncates toward negative infinity, introducing a small systematic bias. For typical video luma values this is negligible (sub-LSB after a few frames).

---

## 10. References

- [Background subtraction — Wikipedia](https://en.wikipedia.org/wiki/Background_subtraction)
- [Exponential moving average — Wikipedia](https://en.wikipedia.org/wiki/Exponential_smoothing)
- [OpenCV Background Subtraction tutorial](https://docs.opencv.org/4.x/d1/dc5/tutorial_background_subtraction.html)
