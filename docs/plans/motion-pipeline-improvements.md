# Motion Detection Pipeline Improvements

## Context

The current motion pipeline in `sparevideo` uses basic frame differencing: per-pixel `abs(Y_cur - Y_prev) > THRESH` produces a raw 1-bit mask, which feeds a single bounding-box reducer and rectangle overlay. This is functional but noisy (salt-and-pepper false positives from sensor/quantization noise), fragile (fixed threshold, no adaptation to lighting changes), and limited (single object only). The goal is to identify concrete blocks we can add — each as an independent AXI4-Stream stage — to improve detection quality, ordered by impact-to-effort ratio.

### What is the "mask" and what does the pipeline actually produce?

The pipeline processes two parallel streams from the same input video:

1. **The video path (RGB, 24-bit per pixel):** The original RGB pixels pass through the pipeline unchanged — this is the image the user sees on the VGA output. It is never modified by the motion detection logic itself; it's just carried along with matched latency so it arrives at the overlay stage at the same time as the motion decision.

2. **The mask path (1-bit per pixel):** For every pixel in the video, the pipeline produces a single bit that answers: **"did this pixel change compared to the background?"** A `1` means yes (motion detected at this pixel), a `0` means no (this pixel looks the same as the background model).

The mask is a binary image the same size as the video (320x240), transmitted as an AXI4-Stream of 1-bit values, one per pixel, in the same raster order as the video. Visually, if you could see the mask, it would look like this:

```
Original scene:              Motion mask:

  ┌──────────────────┐        ┌──────────────────┐
  │                  │        │                  │
  │     ██████       │        │     ░░░░░░       │
  │     █ cat █      │        │     ░░░░░░       │   ░ = 1 (motion)
  │     ██████       │        │     ░░░░░░       │   (blank) = 0 (no motion)
  │           moving→│        │     ░░░░░░       │
  │                  │        │                  │
  │  static wall     │        │                  │
  └──────────────────┘        └──────────────────┘
```

The mask is **not displayed** to the user. It is an intermediate signal consumed by the downstream stages:

- **`axis_bbox_reduce`** (current) scans the mask and finds the tightest rectangle that encloses all the `1` pixels — the bounding box. It outputs just 4 numbers: `{min_x, max_x, min_y, max_y}`.
- **`axis_overlay_bbox`** takes those 4 numbers and draws a green rectangle at those coordinates onto the *video* path. This is what the user actually sees on the VGA output — the original video with a green box around the motion.

So the full pipeline's job is: **video in → detect which pixels changed → find the bounding box of those pixels → draw a rectangle on the video → video out**. The mask is the intermediate "which pixels changed" answer that connects the detection step to the bounding-box step. All five proposed improvement blocks are about making that mask *cleaner* (fewer false positives, fewer false negatives) and *more useful* (multiple bounding boxes instead of one).

---

### Does mask latency need to be matched on the RGB video path?

**No.** The mask and video paths are consumed by **different modules** that don't synchronize per-pixel with each other:

```
axis_motion_detect
    ├──► vid (RGB, 24-bit AXIS) ──────────────────────────► axis_overlay_bbox ──► RGB out
    │                                                            ▲
    └──► msk (1-bit AXIS) ──► [morph, etc.] ──► axis_bbox_reduce
                                                     │
                                                     └──► bbox sideband (4 coords, latched at EOF)
```

The reason latency doesn't matter:

1. **`axis_bbox_reduce` is a pure sink.** It sets `tready = 1` unconditionally — it never stalls the mask stream and never stalls the video stream. It consumes mask pixels as they arrive and accumulates min/max coordinates internally. It has no per-pixel output that needs to align with anything.

2. **The bbox is latched at end-of-frame, used during the *next* frame.** When the last pixel of frame N arrives (EOF), `axis_bbox_reduce` latches the accumulated `{min_x, max_x, min_y, max_y}` into its output registers. These registers are stable for the entire duration of frame N+1. `axis_overlay_bbox` reads them as a static sideband while it processes frame N+1's video pixels. So the bbox from frame N is drawn on frame N+1's video — there's an inherent 1-frame delay by design.

3. **Adding stages to the mask path (morphology, CCL) just delays when the EOF-latch happens within the frame.** If morphology adds ~4 lines of latency, the bbox latches ~4 lines later — but still well within the same frame. The bbox is still ready before frame N+1's first pixel arrives at the overlay. The video path doesn't need any compensating delay because it never synchronizes per-pixel with the bbox latch.

**Where latency *does* matter:** Inside `axis_motion_detect` itself, the vid and msk outputs must be cycle-aligned because they share the same backpressure signal (`both_ready = vid_tready && msk_tready`). This is already handled by the internal sideband pipeline (`tdata_pipe`, `tvalid_pipe`). If the Gaussian pre-filter (block 2) is added *internally* to the motion detector, `PIPE_STAGES` must increase to match the Gaussian's latency — but this is internal bookkeeping, not a concern for the external pipeline.

**In summary:** You can freely add stages to the mask path between `axis_motion_detect`'s mask output and `axis_bbox_reduce` (or `axis_ccl`) without touching the video path. The only constraint is that all mask-path stages complete processing within one frame period, which at 320x240 @ 60fps = 16.7ms is easily satisfied (even 100 lines of latency at 100 MHz is only 320 µs).

### Could the bbox be drawn on the *same* frame it was computed from?

Yes, but the cost is a **full RGB frame buffer** (225 KB), and it imposes hard constraints on the pipeline.

**Why the current design uses a 1-frame delay:**

The pipeline is streaming — pixels arrive in raster order (top-left to bottom-right). The bounding box `{min_x, max_x, min_y, max_y}` is not fully known until the *last pixel* of the frame has been processed, because the bottommost motion pixel could be on the last row. But the overlay module needs to know the bbox coordinates *while outputting pixels*, including pixels at the top of the frame — which were output long before the bottom was scanned.

```
Time ──────────────────────────────────────────────────►

Frame N video pixels arriving:
  row 0:  ████████████████████  ← overlay needs bbox NOW, but...
  row 1:  ████████████████████
  ...
  row 100:     ░░░░░░           ← ...motion starts here (min_y = 100)
  row 180:     ░░░░░░           ← ...motion ends here (max_y = 180)
  ...
  row 239: ████████████████████  ← bbox fully known only NOW (EOF)
```

The overlay needs to draw the top edge of the rectangle at row 100 — but row 100's video pixel was output ~140 lines ago. It's gone. You can't go back and stamp a green pixel onto a pixel that already left the pipeline.

**What same-frame overlay would require:**

The video pixels must be **held back** until the bbox is known. Two approaches:

**Approach A — Full frame buffer (store-and-forward):**

Buffer the entire frame's RGB video, wait for the mask path to finish and produce the bbox, then replay the buffered video through the overlay with the now-known coordinates.

```
vid pixels ──► [frame buffer RAM] ──► (wait for bbox) ──► axis_overlay_bbox ──► RGB out
                  225 KB                                        ▲
msk pixels ──► [morph] ──► [bbox_reduce] ──────────────────────┘
```

Cost:
- **225,280 bytes of RAM** (320 x 240 x 24 bits / 8 = 230,400 bytes, or ~225 KB). The current entire shared RAM is 76,800 bytes — this triples the total RAM budget. On a small FPGA this may consume all available BRAM.
- **1-frame latency on the video output** — the frame must be fully buffered before playback begins, so the VGA output is delayed by one frame period (16.7ms at 60fps). The user still sees the same visual delay as the current 1-frame-delayed bbox — the delay just moves from "bbox lags by 1 frame" to "entire video lags by 1 frame." The net visual result is identical: the green rectangle appears around motion that happened ~16.7ms ago.
- **Read/write port pressure**: The frame buffer needs to be written at the input rate and read at the output rate simultaneously. This requires a true dual-port RAM (1R + 1W), consuming port bandwidth. If the mask-path processing takes longer than the frame period, the next frame's writes would collide with the current frame's reads — requiring ping-pong double-buffering (2x the RAM = 450 KB).

**Approach B — Two-pass over the same frame:**

Process the mask in a first pass to compute the bbox, then re-scan the input to produce overlaid video. This requires either:
- Buffering the full input frame (same as approach A), or
- Receiving the frame twice from the source (requires the source to replay, which VGA-timed sources cannot do)

This doesn't save anything over approach A.

**Approach C — Partial overlay (draw only the bottom edge retroactively):**

A hybrid where the pipeline streams video normally but buffers only enough lines to draw the *top* horizontal edge of the bbox. The left/right vertical edges and bottom edge can be drawn in real-time as the scanner reaches them, because by the time you reach row `min_y`, you already know `min_x` and `max_x` (they were computed from rows 0..min_y). But you don't know `min_y` itself until you've seen it — which means the top edge was already scanned past.

This saves no RAM in the general case because `min_y` could be row 0 (if motion is at the top of the frame), requiring a full-frame buffer anyway. The only saving is if you accept that the top edge of the bbox is never drawn on the current frame — but then you have an incomplete rectangle, which is visually worse than a 1-frame-delayed complete rectangle.

**Why the 1-frame delay is the right tradeoff:**

| | Same-frame bbox | 1-frame delayed bbox (current) |
|---|---|---|
| RAM cost | +225 KB (frame buffer) | 0 (free) |
| Visual latency | 16.7ms (frame buffer delay) | 16.7ms (bbox from prev frame) |
| Perceived delay | Identical to human eye | Identical to human eye |
| Pipeline complexity | Significantly higher | Simple streaming |
| Port pressure | Extra dual-port RAM | None |

The visual result is the same — at 60fps, a 1-frame delay is 16.7ms, which is imperceptible. The only scenario where same-frame matters is very low frame rates (e.g., 1 fps security camera), where a 1-second bbox lag would be noticeable. At 60fps, the 225 KB RAM cost buys nothing the user can see.

The current 1-frame delay design is the standard approach used by essentially all streaming video pipelines for this reason.

---

## Candidate Blocks (priority order)

### 1. EMA Background Model (replace raw previous-frame storage)

**What:** Replace the current "store raw Y, diff against it" with an exponential moving average: `bg[i] <= bg[i] + ((Y_cur - bg[i]) >>> ALPHA_SHIFT)`. The diff then becomes `abs(Y_cur - bg[i]) > THRESH`.

**Why highest priority:** Same RAM cost (1 frame of Y8 = 76,800 bytes already allocated), ~5 extra lines of RTL in `axis_motion_detect`, no new line buffers, no new pipeline stages.

**Why EMA is better than raw previous-frame:**

The current approach compares frame N against frame N-1. This has two problems:

1. **Sensor noise causes false positives.** A camera's pixel values jitter by ±2-5 luma levels between consecutive frames even on a perfectly static scene (thermal noise, quantization, AGC). With `THRESH=16`, a pixel that reads 100 in frame N-1 and 105 in frame N isn't flagged — but the *next* comparison is 105 vs whatever frame N+1 produces. The noise is random and uncorrelated frame-to-frame, so the effective noise floor is the full jitter range. With EMA (alpha=1/8), the background converges to the *mean* of the jitter. A pixel jittering ±5 around 100 will have `bg ≈ 100`, and the diff `|105 - 100| = 5` stays well below threshold. The noise is averaged out rather than propagated.

2. **Gradual lighting changes cause false negatives or massive transients.** If a cloud slowly dims a scene by 20 luma levels over 60 frames, the raw approach sees `|Y_cur - Y_prev| ≈ 0.33` per frame — below threshold, so no motion is flagged (correct). But if the cloud passes quickly and causes a 20-level jump in 1 frame, *every* pixel triggers as motion (false positive — the entire frame lights up). With EMA, the background tracks the lighting change smoothly: each frame it moves 1/8 of the way toward the new value. After 8-10 frames the background has mostly caught up, so only the first few frames see a transient. The raw approach never catches up — it always compares against the *previous single frame*, which either perfectly tracks (masking slow change) or is completely wrong (one-frame jump).

In short: raw previous-frame is a memory-less comparison that treats every frame-to-frame difference as signal. EMA builds a *model* of what "normal" looks like for each pixel, so only deviations from the norm trigger motion.

**Data flow — how this uses existing memory:**

The current pipeline already does a read-modify-write cycle on the shared `ram` port A for every pixel:
1. **Read:** `mem_rd_addr_o = RGN_BASE + pix_addr` → RAM returns `Y_prev` (the raw luma of the same pixel from the previous frame)
2. **Compare:** `abs(Y_cur - Y_prev) > THRESH`
3. **Write-back:** `mem_wr_data_o = y_cur` (overwrites with raw current luma)

The EMA change only touches step 3. Instead of writing back raw `y_cur`, we compute:
```
delta     = y_cur - mem_rd_data_i;          // signed 9-bit
ema_update = mem_rd_data_i + (delta >>> ALPHA_SHIFT);  // arithmetic right-shift
mem_wr_data_o = ema_update[7:0];
```
The read address, write address, and RAM port wiring stay identical. No new storage is needed — the same 76,800-byte region now holds the running average instead of the raw previous frame. The RAM is still accessed once-per-pixel through the existing port A (1R1W), so there is no port contention.

**Placement — where in the pipeline and why it must go there:**

This is not a new pipeline stage — it modifies the *internals* of `axis_motion_detect`. Specifically, the change lives in the write-back datapath at [axis_motion_detect.sv:197-207](hw/ip/motion/rtl/axis_motion_detect.sv#L197-L207), where `mem_wr_data_o` is assigned. The read path, the comparison logic, and all AXIS interfaces stay untouched.

The EMA sits logically between the "read background from RAM" and "write background to RAM" steps. It cannot be placed anywhere else because it is an in-place update of the per-pixel background value stored in the shared RAM. It is *not* an AXIS stage — it has no stream input or output of its own. It simply changes what value gets written back to the frame buffer after each pixel is processed.

```
Inside axis_motion_detect, current flow:

  rgb2ycrcb → y_cur ──────────────────┐
                                      ├─ diff = abs(y_cur - mem_rd_data)
  RAM read (bg/Y_prev) ──────────────┘        │
                                               ├─ mask_bit = (diff > THRESH)
                                               │
  RAM write ◄── y_cur (raw)     ← CHANGE IS HERE: replace with EMA update
```

The write-back must happen at the same pipeline stage as the comparison (after `y_cur` and `mem_rd_data` are both available), because it needs both values to compute the update. Moving it earlier is impossible (values not ready); moving it later would require an extra pipeline register and a second write port.

**Implementation:** Modify the write-back path in [axis_motion_detect.sv](hw/ip/motion/rtl/axis_motion_detect.sv). Instead of writing raw `y_cur`, compute the EMA update and write that. Add an `ALPHA_SHIFT` parameter (default 3, meaning alpha=1/8). The read path is unchanged — `mem_rd_data` already provides the "background" value.

**References:**
- [fpgarelated.com — Running Average](https://www.fpgarelated.com/showarticle/917.php) — FPGA-friendly trick: alpha as power-of-2 shift
- [OpenResearchInstitute/lowpass_ema](https://github.com/OpenResearchInstitute/lowpass_ema) — VHDL EMA filter (CERN-OHL-W-2.0)
- Paper: "Implementation of Running Average Background Subtraction Algorithm in FPGA" (IJCA Vol 73 No 21) — complete Verilog on Spartan-6

---

### 2. Gaussian Pre-Filter (3x3 on Y channel, before differencing)

**What:** A 3x3 Gaussian blur applied to the Y channel before the frame-diff comparison. Implemented as a new AXI4-Stream module with a 2-line-buffer sliding window.

**Why:** Reduces pixel-level noise before the threshold comparison, which directly reduces speckle in the motion mask.

**The convolution operation in detail:**

A 2D convolution slides a small weight matrix (the "kernel") over every pixel in the image. For each pixel, it multiplies the pixel and its neighbors by the corresponding kernel weights, sums the products, and writes the result. The output pixel is a weighted average of its neighborhood.

For a 3x3 Gaussian kernel, the weights approximate a 2D Gaussian bell curve (sigma ≈ 0.85):

```
Kernel K (integer approximation):       Normalized (divide by sum = 16):

  [1  2  1]                                [1/16  2/16  1/16]
  [2  4  2]                                [2/16  4/16  2/16]
  [1  2  1]                                [1/16  2/16  1/16]
```

For a pixel at position (r, c) with the 3x3 window of Y values:

```
  Y[r-1,c-1]  Y[r-1,c]  Y[r-1,c+1]
  Y[r  ,c-1]  Y[r  ,c]  Y[r  ,c+1]
  Y[r+1,c-1]  Y[r+1,c]  Y[r+1,c+1]
```

The output is:

```
Y_out = (1*Y[r-1,c-1] + 2*Y[r-1,c] + 1*Y[r-1,c+1]
       + 2*Y[r  ,c-1] + 4*Y[r  ,c] + 2*Y[r  ,c+1]
       + 1*Y[r+1,c-1] + 2*Y[r+1,c] + 1*Y[r+1,c+1]) >> 4
```

**Why this kernel is hardware-friendly:** All weights are powers of 2 (1, 2, 4). The multiplications become bit-shifts:
- `*1` = no shift (just wire)
- `*2` = left-shift by 1 (just wiring, no logic)
- `*4` = left-shift by 2 (just wiring)

So the entire convolution is 9 terms added together, where each term is either the raw value, the value shifted left by 1, or the value shifted left by 2. The final `>> 4` (divide by 16) is also just wiring — drop the bottom 4 bits. No DSP multipliers needed. The adder tree for 9 inputs of ~12 bits each is about 8 adders.

**Edge handling:** At image borders (first/last row, first/last column), the 3x3 window extends outside the image. The standard approach for a streaming pipeline is to **replicate the border pixel** — clamp the window coordinates so out-of-bounds reads return the nearest valid pixel. In practice this means:
- First row: the "row above" line buffer output is replaced by the current row's value
- Last column: the column shift register holds the last pixel value
- This is a simple mux on the window inputs, controlled by row/col counters

**Parameterization — line width:**

The line buffer depth is the only thing that depends on image width. The module should take `H_ACTIVE` as a parameter (just like the existing motion modules do):

```systemverilog
module axis_gauss3x3 #(
    parameter int H_ACTIVE = 320
) ( ... );
```

If the line buffers are implemented as **shift registers** (FF chains or SRL primitives), the depth is set by `H_ACTIVE` at elaboration time. This works for any line width — 320, 640, 1280, etc. — but the resource cost scales linearly: `2 * H_ACTIVE * 8` FFs. For small resolutions (320) this is fine; for 1920 (1080p) it's 30,720 FFs, which is too many for shift registers and should use BRAM instead.

If the line buffers are implemented as **BRAM FIFOs**, the depth is also parameterized by `H_ACTIVE`. A single 18Kb block RAM holds 2,048 bytes, so:
- 320px: 640 bytes → fits in 1 BRAM (plenty of room)
- 640px: 1,280 bytes → fits in 1 BRAM
- 1920px: 3,840 bytes → needs 2 BRAMs

The BRAM approach scales to any practical resolution without resource explosion. The tradeoff: BRAM FIFOs add a read latency of 1 cycle and need a read/write address counter, but the logic is trivial.

**Recommendation:** Use a parameter `H_ACTIVE` for the line depth, and implement the line buffers as simple dual-port BRAM. This gives one module that works at any resolution. No need for pre-selected width options — the parameter handles it at synthesis time. The rest of the module (window registers, adder tree, edge muxes) is width-independent.

**Could the kernel size also be parameterized?** In theory yes — a 5x5 Gaussian needs 4 line buffers instead of 2, and a 25-element adder tree instead of 9. But the kernel *weights* change with size, which means the shift amounts change. A truly generic NxN convolver would need a weight LUT, which adds complexity for little benefit. The practical approach is to pick from a small set:
- **3x3** (2 line buffers, 9 adds): good default, minimal blur, cheapest
- **5x5** (4 line buffers, 25 adds): stronger smoothing, roughly 2.5x the resource cost
- **7x7** (6 line buffers, 49 adds): heavy blur, rarely needed for motion detection

These could be separate modules (`axis_gauss3x3`, `axis_gauss5x5`) or a single module with a `KERNEL_SIZE` parameter that selects between pre-defined weight sets using a generate block. The 3x3 is almost certainly sufficient for 320x240 motion detection — a 5x5 would blur away small-object motion at this resolution.

**Data flow — why 2 line buffers, and why they're separate from the shared RAM:**

A 3x3 convolution needs 3 rows of the image visible simultaneously. Pixels arrive in raster order (left-to-right, top-to-bottom), so at any given column position `c` on row `r`, the filter needs pixels at rows `{r-2, r-1, r}` all at column `c`. The current row (`r`) is the live pixel arriving on the AXI4-Stream. The two previous rows are stored in line buffers:

```
Line buffer 0 (320 x 8-bit): holds row r-2 (oldest)
Line buffer 1 (320 x 8-bit): holds row r-1
Live stream:                   row r (current pixel)
```

As each pixel arrives, it shifts into line buffer 1, the old head of line buffer 1 shifts into line buffer 0, and the old head of line buffer 0 falls out. A 3-deep column shift register on each row's output produces the 3x3 window:

```
 [r-2,c-2] [r-2,c-1] [r-2,c]   ← from line buffer 0 + 2 FFs
 [r-1,c-2] [r-1,c-1] [r-1,c]   ← from line buffer 1 + 2 FFs
 [r  ,c-2] [r  ,c-1] [r  ,c]   ← from live stream   + 2 FFs
```

**Why these are NOT in the shared `ram`:** The line buffers need parallel read access — all 3 rows must be readable on the same clock cycle to feed the convolution. The shared `ram` has only 2 ports (A and B), and port A is already used by the motion detector for the Y8 frame buffer. Line buffers are also tiny (2 x 320 = 640 bytes) and benefit from being implemented as either:
- **Shift-register FFs** (if the synthesizer infers SRL primitives, e.g. Xilinx SRL16/SRL32) — zero BRAM cost, uses LUT fabric
- **Small BRAM FIFOs** (simple dual-port, 1R1W each) — each line buffer uses one port to write the new pixel and one port to read the old pixel at the head, which is fine because each buffer is an independent memory

Either way, they are local to the `axis_gauss3x3` module and do not interact with the shared RAM at all. The shared RAM stores *frame-persistent* data (the background model, 76,800 bytes, one full frame); line buffers store *transient* data (just 2 rows of the current frame, discarded after use).

**Resource cost:** 2 line buffers x 320 bytes = 640 bytes. Implementation as shift-register FFs: 640 x 8 = 5,120 FFs (likely inferred as SRL primitives, so ~320 LUTs on Xilinx). As BRAM: fits in a single 18Kb block RAM. Plus 9 x 8-bit window registers (72 FFs) and the convolution adder tree.

**Placement — where in the pipeline and why it must go there:**

The Gaussian filter operates on the continuous 8-bit Y (luma) signal. It must be placed *after* RGB-to-Y conversion and *before* the frame-diff comparison. There are two viable insertion points:

**Option A — Internal to `axis_motion_detect` (preferred):**

Currently inside `axis_motion_detect`, the `rgb2ycrcb` submodule produces `y_cur` which feeds directly into the diff comparison at [axis_motion_detect.sv:190-192](hw/ip/motion/rtl/axis_motion_detect.sv#L190-L192). The Gaussian filter is inserted on that internal wire:

```
Inside axis_motion_detect, with Gaussian added:

  rgb2ycrcb → y_cur_raw ──► [axis_gauss3x3] ──► y_cur_smooth ──┐
                                                                 ├─ diff = abs(y_cur_smooth - mem_rd_data)
  RAM read (bg) ────────────────────────────────────────────────┘
                                                                 ├─ mask_bit = (diff > THRESH)
  RAM write ◄── EMA(y_cur_smooth, mem_rd_data)
```

This keeps the external AXIS interface of `axis_motion_detect` unchanged — the top-level wiring in `sparevideo_top` doesn't need to change at all. The Gaussian becomes an internal submodule, instantiated alongside `rgb2ycrcb`.

The pipeline latency of `axis_motion_detect` increases by ~1 line (320 cycles at 1 pixel/clock) because the Gaussian needs to fill its first line buffer before producing output. The sideband pipeline (`tdata_pipe`, `tvalid_pipe`, etc.) must be extended by the same number of stages to keep the RGB passthrough latency-matched with the mask output. This is a straightforward change — increase `PIPE_STAGES` and let the existing pipeline shift-register grow.

**Option B — External AXIS stage before `axis_motion_detect`:**

A standalone `axis_gauss3x3` module placed between the input async FIFO and `axis_motion_detect` in `sparevideo_top`. This would smooth the *RGB* data before it enters the motion detector, but that's wasteful — we'd either smooth all 3 channels (3x the line buffer cost) or need to split Y out early. This approach also means `axis_motion_detect` receives pre-smoothed video, which affects the RGB passthrough (the overlaid video would show the blurred image, not the original).

**Option A is preferred** because:
1. Only the Y channel is smoothed (1 line buffer set, not 3)
2. The RGB passthrough carries the original sharp video
3. No changes to `sparevideo_top` wiring
4. The Gaussian is encapsulated as an implementation detail of the motion detector

**Why it cannot go after the threshold:** The threshold converts the continuous diff into a 1-bit binary mask. Once that information is quantized to 1 bit, spatial smoothing is meaningless — you'd be averaging 0s and 1s, which is neither Gaussian blur nor morphological filtering. Spatial smoothing must happen on the continuous-valued signal.

**Why it cannot go before `rgb2ycrcb`:** RGB-to-Y is a per-pixel operation with no spatial dependency. Smoothing before or after color conversion is mathematically similar, but smoothing after is cheaper (1 channel instead of 3) and avoids blurring the RGB passthrough.

**Implementation:** New module `axis_gauss3x3` in `hw/ip/motion/rtl/`. Takes an 8-bit AXI4-Stream input (Y channel), outputs smoothed 8-bit Y. Instantiated inside `axis_motion_detect` between `rgb2ycrcb` output and the diff comparison.

**References:**
- [sistenix.com — 2D Convolution Tutorial](https://sistenix.com/sobel.html) — SystemVerilog sliding window module with line buffers, directly adaptable
- [ykqiu/image-processing](https://github.com/ykqiu/image-processing) — Verilog Gaussian filter with line-FIFO architecture
- [Gowtham1729/Image-Processing](https://github.com/Gowtham1729/Image-Processing) — Verilog 3x3 convolution (Apache 2.0)
- [damdoy/fpga_image_processing](https://github.com/damdoy/fpga_image_processing) — Gaussian blur for ice40, Verilator-tested

---

### 3. Morphological Opening (erode then dilate on binary mask)

**What:** Two new AXI4-Stream stages inserted between the threshold output (mask) and `axis_bbox_reduce`: a 3x3 erosion followed by a 3x3 dilation. For binary images, erosion = AND of 3x3 neighborhood, dilation = OR of 3x3 neighborhood. This "opening" operation removes isolated noise pixels while preserving real motion blobs.

**Why:** Even with Gaussian pre-filtering and EMA, some isolated mask pixels will remain. Erosion kills any pixel not surrounded by other motion pixels; dilation then restores the shape of real blobs that survived erosion. This is the standard cleanup step in every serious motion detection pipeline.

**Data flow — same sliding-window concept as Gaussian, but 1-bit wide:**

The architecture is identical to block 2 (line buffers + 3x3 window), but since the mask is 1-bit instead of 8-bit, everything is drastically smaller:

```
Erosion stage:
  Line buffer 0 (320 x 1-bit): row r-2 of mask
  Line buffer 1 (320 x 1-bit): row r-1 of mask
  Live stream:                   row r (current mask pixel)
  Window: 3x3 = 9 bits → output = AND of all 9 bits

Dilation stage (chained after erosion):
  Line buffer 2 (320 x 1-bit): row r-2 of eroded mask
  Line buffer 3 (320 x 1-bit): row r-1 of eroded mask
  Live stream:                   eroded row r
  Window: 3x3 = 9 bits → output = OR of all 9 bits
```

Each 320-bit line buffer is just 40 bytes — small enough to be a shift register (320 FFs, or ~20 SRL16s on Xilinx). Total for both stages: 4 line buffers x 320 bits = 1,280 FFs (or ~80 SRL16 LUTs). The "compute" is a single 9-input AND gate (erosion) or 9-input OR gate (dilation) — effectively free.

**Why separate from shared RAM:** Same reasoning as block 2 — these are transient 2-row buffers, not frame-persistent storage. They need simultaneous 3-row access. At 40 bytes per buffer there is zero reason to route them through the shared RAM; FFs or SRL primitives are the natural fit.

**The two stages can be one module or two.** If combined into `axis_morph_open`, internally it's just two copies of the same line-buffer + window logic chained together. The first produces the eroded stream, the second dilates it. Total pipeline latency: ~2 lines per stage = ~4 line-periods (~1,280 pixels at 320px/line).

**Resource cost:** 1,280 FFs (or ~80 LUTs as SRLs) + 18 window FFs + 2 logic gates. Negligible.

**Placement — where in the pipeline and why it must go there:**

The morphological opening operates on the 1-bit binary mask. It must be placed *after* thresholding (which produces the mask) and *before* the bounding-box stage (which consumes it). This is an external AXIS stage wired into `sparevideo_top`, not internal to `axis_motion_detect`.

```
In sparevideo_top, current wiring:

  axis_motion_detect ──► msk (1-bit AXIS) ──► axis_bbox_reduce

With morphological opening:

  axis_motion_detect ──► msk (1-bit AXIS) ──► [axis_morph_open] ──► msk_clean (1-bit AXIS) ──► axis_bbox_reduce
```

The new module sits on the mask stream between `u_motion_detect`'s mask output and `u_bbox_reduce`'s mask input. In `sparevideo_top`, this means:
1. The current `msk_*` signals connect to `axis_morph_open`'s slave (input) port
2. New `msk_clean_*` signals connect from `axis_morph_open`'s master (output) port to `axis_bbox_reduce`'s slave port
3. All other wiring (video passthrough, bbox sideband, overlay) stays unchanged

**Why it cannot go before the threshold:** Morphological operations are defined on binary images. Erosion is AND-of-neighborhood, dilation is OR-of-neighborhood — these operations are meaningless on continuous 8-bit values. If you need spatial smoothing on the continuous signal, that's what the Gaussian (block 2) does.

**Why it cannot go after bbox_reduce / CCL:** The bbox/CCL stage consumes the mask and produces bounding-box coordinates. Once the mask is reduced to coordinates, there's no pixel data left to erode or dilate. The morphological cleanup must happen while the data is still a per-pixel stream.

**Why it's external to `axis_motion_detect` (unlike the Gaussian):** The Gaussian is internal because it operates on the Y channel *before* the comparison, sharing data with the RAM read/write path. The morphological opening operates on the *output* mask, which is already an independent AXIS stream. There's no data dependency with `axis_motion_detect`'s internals, so placing it outside keeps the module boundaries clean and makes it easy to bypass (just reconnect `msk_*` directly to `bbox_reduce` to skip morphology).

**Latency impact on the video passthrough:** The morphological opening adds ~4 line-periods of latency on the mask path (2 lines for erosion + 2 lines for dilation). The video passthrough and mask must still arrive at `axis_overlay_bbox` / `axis_bbox_reduce` with matching timing. Since `axis_bbox_reduce` is a pure sink (always ready, no backpressure) and its output is a sideband latched at end-of-frame, the extra mask latency is absorbed naturally — the bbox just latches ~4 lines later within the same frame, which doesn't matter because the bbox is only used starting from the *next* frame. No compensating delay is needed on the video path.

**Implementation:** New module `axis_morph_open` (or two separate `axis_erode3x3` / `axis_dilate3x3` modules) in `hw/ip/motion/rtl/`. Wired in `sparevideo_top` on the mask AXIS stream between `u_motion_detect` and `u_bbox_reduce`.

**References:**
- [DavisLiao/Kryon](https://github.com/DavisLiao/Kryon) — Verilog erosion, dilation, and CCL (Apache 2.0)
- [Xilinx Vitis Vision Library](https://github.com/Xilinx/Vitis_Libraries) — `xf::cv::erode`, `xf::cv::dilate` (Apache 2.0, HLS C++)

---

### 4. Connected-Component Labeling (multi-object bounding boxes)

**What:** Replace `axis_bbox_reduce` (single bbox) with a streaming CCL stage that identifies distinct connected regions in the binary mask and outputs a bounding box per component. This enables tracking multiple moving objects simultaneously.

**Why:** The current single-bbox approach merges all motion into one rectangle. If two people walk in opposite corners, the bbox covers the entire frame. CCL lets you draw separate rectangles per object.

**Data flow — streaming CCL and its memory structures:**

CCL operates on the binary mask stream (1-bit per pixel, raster order) and must assign a label to each foreground pixel such that connected foreground pixels share the same label. The standard streaming approach is a "single-pass" algorithm that processes one row at a time, comparing each pixel to its already-labeled neighbors (left, above-left, above, above-right in 8-connected):

```
Previous row labels:  [L₀] [L₁] [L₂] [L₃] ...  ← stored in "label line buffer"
Current row:           ... [?]                   ← pixel being labeled now
```

**Memory structures (all local to the CCL module, not in shared RAM):**

1. **Label line buffer** (320 entries x ~10 bits = ~400 bytes): Stores the label assigned to each pixel in the *previous* row. As the current row is processed, each pixel checks its above-neighbor's label from this buffer. After the row completes, the current row's labels overwrite it. This is a simple 1R1W SRAM or register array — one read (above-neighbor lookup) and one write (store current label) per pixel per clock.

2. **Label equivalence table** (~256 entries x ~10 bits = ~320 bytes): When a foreground pixel has two different-labeled neighbors (e.g., two blobs merging), their labels must be recorded as equivalent. This is a small union-find table stored in registers or a small SRAM. Accessed by random label ID, so it needs single-cycle read-modify-write.

3. **Per-label feature table** (~256 entries x ~40 bits = ~1.3 KB): For each active label, stores the running {min_x, max_x, min_y, max_y} bounding box — exactly what `axis_bbox_reduce` currently does, but per-label instead of globally. Updated on every foreground pixel. At end-of-frame, the valid entries are read out as the multi-bbox result.

**Why not in shared RAM:** All three structures require random-access reads and writes indexed by label ID (not by pixel address), and the equivalence table needs single-cycle read-modify-write for union-find merges. The shared RAM is organized by pixel address and its ports are occupied by the background model. These are small structures (~2 KB total) best implemented as register files or small distributed RAMs (LUT-RAM on Xilinx).

**Output interface change:** Currently `axis_bbox_reduce` outputs a single `{min_x, max_x, min_y, max_y, empty}` sideband. With CCL, the output becomes an array of up to N bboxes (N = max simultaneous labels, e.g., 16 or 32), latched at EOF. `axis_overlay_bbox` would iterate over all non-empty entries and draw a rectangle for each. This could be done by storing the bbox array in a small register file and having the overlay module index through it using the frame's row/col counters — for each pixel, check "am I on the border of *any* of the N rectangles?"

**Resource cost:** ~2 KB of register/LUT-RAM for the three tables. The label line buffer could optionally be BRAM (one 18Kb block RAM is more than enough). Logic complexity is moderate — the union-find merge path is the trickiest part.

**Placement — where in the pipeline and why it must go there:**

CCL replaces `axis_bbox_reduce` at the same position in the pipeline — it consumes the (cleaned) 1-bit mask stream and produces bounding-box sidebands for the overlay.

```
In sparevideo_top, current wiring:

  msk (1-bit AXIS) ──► axis_bbox_reduce ──► {min_x, max_x, min_y, max_y, empty} ──► axis_overlay_bbox

With CCL (and morphology from block 3):

  msk ──► [axis_morph_open] ──► msk_clean ──► [axis_ccl] ──► N x {min_x, max_x, min_y, max_y, empty} ──► axis_overlay_bbox
```

The CCL module's slave (input) AXIS port connects where `axis_bbox_reduce`'s input was — to the morphology output (or directly to the mask output if morphology is not present). Its output is a sideband register file instead of a single set of coordinates.

**Why it must be the last stage on the mask path:** CCL assigns labels and accumulates per-label statistics. Any modification to the mask after labeling would invalidate the labels. Morphological cleanup must happen *before* CCL so that the label assignments reflect the final, clean mask.

**Why it cannot be combined with the motion detector:** CCL has no dependency on luma values, RGB data, or the background model. It is a pure consumer of the binary mask. Keeping it as a separate module means:
1. It can be swapped between `axis_bbox_reduce` (simple, single-bbox) and `axis_ccl` (multi-bbox) via the control-flow mux or a parameter
2. It can be tested independently with any binary mask source
3. The `axis_motion_detect` module's complexity doesn't grow

**Changes to downstream `axis_overlay_bbox`:** The overlay module's sideband input changes from a single `{min_x, max_x, min_y, max_y, empty}` to an array of N entries. The wiring in `sparevideo_top` changes accordingly — N sets of coordinate signals (or a small register-file interface with address + data). The overlay's hit-test logic at [axis_overlay_bbox.sv:70-86](hw/ip/motion/rtl/axis_overlay_bbox.sv#L70-L86) changes from a single comparator to an N-wide OR:

```
Current:   on_rect = !bbox_empty && ((on_left_or_right && in_y_range) || ...)

Modified:  on_rect = |{ bbox_hit[0], bbox_hit[1], ..., bbox_hit[N-1] }
           where each bbox_hit[k] is the same comparator logic applied to bbox[k]
```

This is a `generate for` loop producing N copies of the existing comparator, OR'd together. The AXIS video path is unchanged.

**Implementation:** New module `axis_ccl` replacing `axis_bbox_reduce`. Single-pass algorithm processing pixels in raster order. Outputs N bounding boxes via a sideband register file. `axis_overlay_bbox` modified to check against N rectangles instead of 1.

**References:**
- [OpenCores LinkRunCCA](https://opencores.org/projects/linkruncca) — Verilog single-pass streaming CCL (LGPL), outputs bounding boxes directly
- [DavisLiao/Kryon](https://github.com/DavisLiao/Kryon) — Verilog single-pass CCL, one line buffer only (Apache 2.0)
- Paper: "Real-Time FPGA Implementation of Parallel CCL for 4K Video" (Springer, SystemVerilog on Zynq UltraScale+)

---

### 5. Adaptive Threshold (per-pixel variance tracking)

**What:** Maintain a second frame buffer storing the running variance (`|Y_cur - bg|` averaged over time). The motion threshold then becomes `k * variance[i]` per pixel instead of a global constant.

**Why:** Eliminates the fixed `MOTION_THRESH` parameter. Areas with more natural variation (trees swaying, water) get a higher threshold automatically, while static areas (walls) get a very low threshold — making the detector more sensitive where it matters.

**Data flow — second RAM region for variance:**

This requires a second per-pixel value stored across frames, alongside the background mean from block 1:

```
Shared RAM layout (after this block):
  Region 0 [0 .. 76,799]:        bg_mean[i]  (8-bit, from block 1 EMA)
  Region 1 [76,800 .. 153,599]:  bg_var[i]   (8-bit, variance EMA)
  Total: 153,600 bytes
```

Per pixel, the motion detector must now do **two** read-modify-write cycles:
1. Read `bg_mean[i]`, compute EMA update, write back (same as block 1)
2. Read `bg_var[i]`, compute `var_new = bg_var[i] + ((|diff| - bg_var[i]) >>> VAR_SHIFT)`, write back

**Port contention:** The current shared `ram` has 2 ports (A and B). Port A handles the mean read/write. Port B is currently tied off (reserved for future host). Two options:
- **Use port B** for the variance region — zero structural changes, both regions accessed in parallel on the same clock cycle. This is the simplest approach but consumes the reserved host port.
- **Time-multiplex port A** — stall the pipeline for 1 extra cycle per pixel to do the second read/write. Doubles the per-pixel latency but keeps port B free. At 100 MHz clk_dsp with 320x240 @ 60fps = 4.6M pixels/sec, we have ~21 clocks per pixel on average, so an extra cycle is affordable.

The variance values themselves are small and purely per-pixel (no spatial neighborhood), so no line buffers are involved — just an additional RAM region.

**Resource cost:** +76,800 bytes of RAM (doubles the frame buffer). No additional line buffers. Adds a small comparator per pixel (`diff > (bg_var >>> K_SHIFT)` instead of `diff > THRESH`).

**Placement — where in the pipeline and why it must go there:**

Like block 1 (EMA), this is not a new pipeline stage — it modifies the internals of `axis_motion_detect`. Specifically, it changes the threshold comparison and adds a second RAM read-modify-write cycle.

```
Inside axis_motion_detect, with EMA (block 1) and adaptive threshold (block 5):

  y_cur_smooth ──────────────────────────────┐
                                              ├─ diff = abs(y_cur_smooth - bg_mean)
  RAM read region 0 (bg_mean) ──────────────┘
                                              │
  RAM read region 1 (bg_var) ──► threshold = bg_var >>> K_SHIFT
                                              │
                                              ├─ mask_bit = (diff > threshold)  ← CHANGED from fixed THRESH
                                              │
  RAM write region 0 ◄── EMA(y_cur_smooth, bg_mean)          (same as block 1)
  RAM write region 1 ◄── EMA(|diff|, bg_var)                  (new)
```

The adaptive threshold is co-located with the EMA background model because both operate on the same data at the same pipeline stage: the point where `y_cur` and `mem_rd_data` are both valid. The variance EMA needs `|diff|` which is already computed for the mask comparison, so there's no additional computation to route — just a second read/write to a different RAM region.

**Why it cannot be a separate AXIS stage:** The variance needs the continuous `|diff|` value, which is internal to `axis_motion_detect` and never exposed on any AXIS interface. The mask output is already binary (1-bit), so the diff magnitude is lost. The threshold decision and the diff computation are tightly coupled — they must live in the same module.

**Changes to `sparevideo_top`:** The RAM region table grows:
```
Current:
  localparam int RGN_Y_PREV_BASE = 0;
  localparam int RGN_Y_PREV_SIZE = H_ACTIVE * V_ACTIVE;   // 76,800
  localparam int RAM_DEPTH       = RGN_Y_PREV_SIZE;        // 76,800

With adaptive threshold:
  localparam int RGN_BG_MEAN_BASE = 0;
  localparam int RGN_BG_MEAN_SIZE = H_ACTIVE * V_ACTIVE;   // 76,800
  localparam int RGN_BG_VAR_BASE  = RGN_BG_MEAN_SIZE;
  localparam int RGN_BG_VAR_SIZE  = H_ACTIVE * V_ACTIVE;   // 76,800
  localparam int RAM_DEPTH        = RGN_BG_MEAN_SIZE + RGN_BG_VAR_SIZE;  // 153,600
```

If using port B for the variance region, `axis_motion_detect` gains a second set of memory ports (`mem_b_rd_addr_o`, `mem_b_rd_data_i`, `mem_b_wr_addr_o`, `mem_b_wr_data_o`, `mem_b_wr_en_o`) which connect to `ram` port B in `sparevideo_top`. The port B tie-off is removed.

**Implementation:** Extend `axis_motion_detect` to maintain a second EMA for the variance. Add `RGN_VAR_BASE` / `RGN_VAR_SIZE` region in `sparevideo_top`. Increase `RAM_DEPTH` to `2 * H_ACTIVE * V_ACTIVE`. The comparison becomes `diff > (variance_avg >>> K_SHIFT)`.

**References:**
- Same EMA references as block 1
- Papers on adaptive background subtraction (IEEE, ResearchGate)

---

## Proposed Pipeline (after all blocks)

### Current pipeline

```
RGB in ──► axis_motion_detect ──► vid (RGB passthrough) ──► axis_overlay_bbox ──► RGB out
                │                                                ▲
                ├──► msk (1-bit) ──► axis_bbox_reduce ───────────┘
                │                    (single bbox sideband)
                └──► shared RAM port A (raw Y write / Y_prev read)
```

Three modules, each with a fixed role:
- `axis_motion_detect`: RGB→Y, raw frame diff, threshold, produces vid + mask
- `axis_bbox_reduce`: mask → single {min_x, max_x, min_y, max_y}
- `axis_overlay_bbox`: stamps one green rectangle onto the video

### Proposed pipeline

```
                            Y processing path
                            ─────────────────
RGB in ──► axis_motion_detect ─────────────────────────────────────────────────────┐
               │                                                                   │
               │  (Y extracted by rgb2ycrcb, internal to motion_detect)            │
               │         │                                                         │
               │   [axis_gauss3x3]  ◄── NEW block 2                               │
               │         │              spatial pre-filter on Y                    │
               │         ▼                                                         │
               │   [EMA bg model]   ◄── block 1 (modifies existing write-back)    │
               │         │              replaces raw Y_prev storage                │
               │         ▼                                                         │
               │   [threshold]      ◄── block 5 (or existing fixed THRESH)         │
               │         │              adaptive per-pixel, replaces MOTION_THRESH │
               │         ▼                                                         │
               │      1-bit mask                                                   │
               │         │                                                         │
               │   [axis_morph_open] ◄── NEW block 3                               │
               │         │               erode + dilate, cleans mask               │
               │         ▼                                                         │
               │   [axis_ccl]        ◄── NEW block 4                               │
               │         │               replaces axis_bbox_reduce                 │
               │         ▼                                                         │
               │    N bbox sidebands                                               │
               │         │                                                     vid │
               │         ▼                                                     RGB │
               │   [axis_overlay_bbox] ◄── MODIFIED (N rects instead of 1)    ◄────┘
               │         │
               ▼         ▼
             RGB out (overlaid)
```

### What changes, what stays, what gets replaced

| Current module | Status | Explanation |
|---|---|---|
| `axis_motion_detect` | **Modified** | Blocks 1, 2, and 5 change its internals but don't replace the module. Block 1 changes the RAM write-back from raw Y to EMA. Block 2 adds a Gaussian stage on the Y path before the diff (either internal sub-module or a separate AXIS stage feeding into it). Block 5 replaces the fixed `THRESH` parameter with a per-pixel adaptive comparison. The module's external AXIS interface (RGB in, vid out, mask out, RAM ports) stays the same. |
| `axis_bbox_reduce` | **Replaced** by block 4 (`axis_ccl`) | `axis_bbox_reduce` tracks a single global bounding box — it has no concept of separate objects. `axis_ccl` subsumes its functionality entirely: it tracks per-label bounding boxes internally (the same min/max comparisons, but indexed by label). There is no reason to keep `axis_bbox_reduce` in the pipeline once CCL is in place. The module can remain in the repo for the simpler single-bbox control flow if desired. |
| `axis_overlay_bbox` | **Modified** | Currently takes a single `{min_x, max_x, min_y, max_y, empty}` sideband and draws one rectangle. After block 4, it receives an array of N bboxes. The hit-test logic changes from "am I on the border of this one rectangle?" to "am I on the border of *any* of these N rectangles?" — an N-wide OR of the existing comparator. The AXIS video path (passthrough + pixel replace) is unchanged. |
| `rgb2ycrcb` | **Unchanged** | Still converts RGB→Y inside `axis_motion_detect`. No interface change. |
| `ram` | **Unchanged** (block 5 adds a region) | Block 1 reuses the existing Y8 region identically — same addresses, same port. Block 5 adds a second region for variance, using either port B or time-multiplexed port A. The `ram` module itself doesn't change; only `RAM_DEPTH` and the region table in `sparevideo_top` grow. |

### Why the blocks are ordered this way in the pipeline

The ordering follows the signal-processing principle of **clean the signal before you make decisions on it**:

1. **Gaussian pre-filter (block 2) comes first** in the Y processing path because it operates on the raw Y values before any comparison. Its job is to suppress pixel-level noise (sensor jitter, quantization artifacts) so that downstream stages see a smoother signal. If you put it after the threshold, you'd be trying to smooth a binary image — which is what morphology does better. Spatial smoothing is most effective on the continuous-valued luma signal.

2. **EMA background model (block 1) comes after the Gaussian** because it compares the (now spatially smoothed) current Y against the background model. The Gaussian has already removed high-frequency spatial noise, so the EMA sees a cleaner input and produces a more stable background estimate. The EMA itself provides *temporal* smoothing — averaging over time. Spatial first, then temporal, because spatial noise is independent between pixels while temporal noise is independent between frames; addressing them in separate stages is cleaner than trying to do both at once.

3. **Threshold (block 5 / existing fixed) comes after the background model** because it's the decision boundary — converting the continuous difference `|Y_smoothed - bg|` into a binary yes/no. This must happen after both smoothing stages have done their work. If you threshold first and smooth after, you lose information (binary signals can't be "un-thresholded").

4. **Morphological opening (block 3) comes after the threshold** because it operates on the *binary mask*, not on luma values. Its job is to remove isolated false-positive pixels (erosion) and restore the shape of real blobs (dilation). This is the spatial cleanup stage for the binary domain — analogous to what the Gaussian does for the continuous domain. It must come after thresholding (needs binary input) and before CCL (CCL would waste labels on noise pixels that morphology would have removed).

5. **CCL (block 4) comes last** in the mask path because it needs the *final, clean* binary mask to work correctly. Every noise pixel that reaches CCL consumes a label and creates a spurious bounding box. By placing it after morphology, the mask is as clean as possible, so CCL's label table and equivalence structures are used efficiently for real objects rather than wasted on noise.

6. **The video RGB passthrough runs in parallel** to the entire Y/mask processing path, with matched latency. The overlay module sits at the end where both paths converge — it has the clean video pixels and the bbox decisions, and stamps rectangles onto the video. This is the same architecture as the current pipeline; the new blocks only add stages to the mask path between the threshold and the overlay.

## Recommended Implementation Order

| Phase | Block | Effort | Impact |
|-------|-------|--------|--------|
| 1 | EMA background model | Small (modify existing module) | High |
| 2 | Morphological opening | Medium (new module, simple logic) | High |
| 3 | Gaussian pre-filter | Medium (new module, line buffers) | Medium |
| 4 | Connected-component labeling | Large (new module, architectural change) | High |
| 5 | Adaptive threshold | Medium (extend existing, double RAM) | Medium |

Phases 1-3 are independent improvements that each make the mask cleaner. Phase 4 is a larger architectural shift. Phase 5 builds on phase 1.

## Key Reference Repos (summary)

| Repo | License | Useful for |
|------|---------|------------|
| [DavisLiao/Kryon](https://github.com/DavisLiao/Kryon) | Apache 2.0 | Erosion, dilation, CCL — most complete open core |
| [ykqiu/image-processing](https://github.com/ykqiu/image-processing) | Unlicensed | Gaussian, median, line-buffer architecture |
| [sistenix.com tutorial](https://sistenix.com/sobel.html) | Tutorial | Sliding window + line buffer in SystemVerilog |
| [OpenCores LinkRunCCA](https://opencores.org/projects/linkruncca) | LGPL | Streaming CCL with bbox output |
| [OpenResearchInstitute/lowpass_ema](https://github.com/OpenResearchInstitute/lowpass_ema) | CERN-OHL-W | EMA filter reference |
| [Gowtham1729/Image-Processing](https://github.com/Gowtham1729/Image-Processing) | Apache 2.0 | 3x3 convolution kernels |
| [damdoy/fpga_image_processing](https://github.com/damdoy/fpga_image_processing) | Unlicensed | Gaussian blur, Verilator-tested |
| [fpgarelated.com](https://www.fpgarelated.com/showarticle/917.php) | Article | EMA as shift-only operation |

## Verification

Each new block should:
1. Get its own unit testbench in `hw/ip/motion/tb/` following the existing `tb_axis_*` pattern
2. Be added to `make test-ip`
3. Be wired into `sparevideo_top` and verified with `make run-pipeline CTRL_FLOW=motion`
4. Have a corresponding Python model in `py/` for pixel-accurate verification

---

## Sub-Plans

Detailed implementation, testing, and acceptance criteria for each block:

| Block | Sub-plan | Status |
|-------|----------|--------|
| 0. Mask display ctrl flow | [old/2026-04-15_ctrl-flow-mask-display.md](old/2026-04-15_ctrl-flow-mask-display.md) | done |
| 1. EMA background model | [old/2026-04-15_block1-ema-background.md](old/2026-04-15_block1-ema-background.md) | done |
| 2. Gaussian pre-filter (causal) | [old/2026-04-16_block2-gaussian-prefilter.md](old/2026-04-16_block2-gaussian-prefilter.md) | done |
| 2a. Centered Gaussian upgrade | [2026-04-16_block2a-centered-gaussian.md](2026-04-16_block2a-centered-gaussian.md) | not started |
| —. Decouple RGB/mask pipelines | [2026-04-17_decouple-rgb-mask-pipelines.md](2026-04-17_decouple-rgb-mask-pipelines.md) | not started |
| 3. Morphological opening | block3-morphological-opening.md | not started |
| 4. Connected-component labeling | block4-ccl.md | not started |
| 5. Adaptive threshold | block5-adaptive-threshold.md | not started |
