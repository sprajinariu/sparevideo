# Pipeline Extensions — Design

**Date:** 2026-04-23
**Status:** Design approved, pending implementation plan

## 1. Scope & goals

Add five self-contained AXIS pipeline stages to `sparevideo`, plus one reusable primitive extracted from existing code, chosen to improve user-visible output quality and broaden the ISP-front-end story without forcing a large architectural change. Each stage is an independent module; each can be enabled or disabled via a build knob; the four that are runtime-bypassable are instantiated unconditionally and bypassed via an `enable_i` sideband, to pre-wire a future CSR interface.

**New / refactored modules** (the five stages are `axis_hflip`, `axis_morph3x3_open`, `axis_gamma_cor`, `axis_hud`, `axis_scale2x`; `axis_window3x3` is the shared primitive):

1. `axis_hflip` — horizontal mirror at the input ("selfie-cam" semantic).
2. `axis_window3x3` — **new reusable primitive** extracting the shared line-buffer + sliding-window logic currently inside `axis_gauss3x3`. `axis_gauss3x3` is refactored to wrap it. Morph modules also wrap it.
3. `axis_morph3x3_open` — mask cleanup: `axis_morph3x3_erode` → `axis_morph3x3_dilate`, both wrapping `axis_window3x3<1>`. Inserted inside mask-producing ctrl_flows.
4. `axis_gamma_cor` — per-channel display gamma correction with 33-entry LUT and linear interpolation. LUT contents driven in as sidebands, generated at build time by `py/gen_gamma_lut.py`.
5. `axis_hud` — text overlay (frame#, ctrl_flow tag, bbox count, end-to-end latency in µs), drawn post-scaler.
6. `axis_scale2x` — 320×240 → 640×480 upscaler (default bilinear; NN as a compile-time filter option).

**Compile-time knobs** (Makefile-driven, same thread-through pattern as `ALPHA_SHIFT` / `GRACE_FRAMES`):

| Knob | Default | Values | Nature |
|------|---------|--------|--------|
| `HFLIP` | `1` | `0/1` | Runtime (ties `enable_i`) |
| `MORPH` | `1` | `0/1` | Runtime (ties `enable_i`) |
| `GAMMA_COR` | `1` | `0/1` | Runtime (ties `enable_i`) |
| `GAMMA_CURVE` | `srgb` | `srgb\|linear` | Compile-time — selects curve generator |
| `SCALER` | `1` | `0/1` | Compile-time (`generate if`) — changes VGA timing + `pix_clk` frequency |
| `SCALE_FILTER` | `bilinear` | `nn\|bilinear` | Compile-time — internal to `axis_scale2x` |
| `HUD` | `1` | `0/1` | Runtime (ties `enable_i`) |

**Non-goals:** Bayer demosaic, FPN/PRNU, dithering, cross-frame tracking, runtime resolution switching, runtime filter switching, a real CSR bus (future work — `enable_i` is CSR-ready).

## 2. Top-level architecture

```
AXIS in  (clk_pix_in: input-rate, ≈6.3 MHz native for 320×240; matches the upstream sensor/source clock)
  │
  ▼
CDC FIFO  (clk_pix_in → clk_dsp 100 MHz)
  │
  ▼
axis_hflip               (enable_i ← HFLIP)
  │
  ▼
ctrl_flow mux ──► passthrough
              ──► motion:   axis_motion_detect ─┬─► axis_morph3x3_open (enable_i←MORPH) ─► axis_ccl ─► axis_overlay_bbox
              │   (RGB fork) ────────────────── ┘
              ──► mask:     axis_motion_detect ─► axis_morph3x3_open ─► mask→RGB expand
              ──► ccl_bbox: axis_motion_detect ─► axis_morph3x3_open ─► axis_ccl ─► (mask-grey + bboxes)
  │
  ▼
axis_gamma_cor           (enable_i ← GAMMA_COR; LUT sidebands from TB / board wrapper)
  │
  ▼
[axis_scale2x]           (generate if SCALER; SCALE_FILTER = nn | bilinear)
  │
  ▼
axis_hud                 (enable_i ← HUD; draws at 640×480 when SCALER=1, else 320×240)
  │
  ▼
CDC FIFO  (clk_dsp → clk_pix_out)
  │
  ▼
vga_controller           (H_ACTIVE_OUT/V_ACTIVE_OUT from sparevideo_pkg)
  │
  ▼
VGA out  (clk_pix_out: output-rate, 25.175 MHz for standard 640×480@60)
```

**Key properties:**

- All new stages live in `clk_dsp`. Clock domains: `clk_pix_in` (input AXIS only), `clk_dsp` (the entire pipeline), `clk_pix_out` (VGA controller only).
- `axis_hflip` before the ctrl_flow mux so motion masks and bbox coords agree with what the user sees.
- `axis_morph3x3_open` inside each mask-producing branch; elided for `passthrough`.
- Gamma → (scaler) → HUD is the post-mux tail. HUD is **after** the scaler so HUD text is rendered at native output resolution and never softened by bilinear.
- Four blocks use runtime `enable_i`; only `SCALER` / `SCALE_FILTER` are compile-time (they change resolution and the in:out clock ratio, which can't be runtime-reconfigured without a display resync).

**Two pix_clk ports** — the input and output sides of the pipeline run on independent pixel clocks, so the rate ratio is established by clock frequencies rather than by software pacing:

```systemverilog
// sparevideo_pkg.sv
localparam int H_ACTIVE_OUT_2X = 2 * H_ACTIVE;     // 640 when H_ACTIVE=320
localparam int V_ACTIVE_OUT_2X = 2 * V_ACTIVE;     // 480 when V_ACTIVE=240
// + matching H_FP / H_SY / H_BP per mode (vertical porches stay — they count
//   lines, not pixels, so they are the same in both modes)

// sparevideo_top expected port wiring:
//   clk_pix_in_i  : input-rate pixel clock (sensor/source clock)
//   clk_pix_out_i : output-rate pixel clock (display clock)
//   clk_dsp_i     : 100 MHz processing clock (existing)
//
// SCALER=1 typical wiring:
//   clk_pix_out_i = 25.175 MHz (standard VGA 640×480@60)
//   clk_pix_in_i  ≈ 6.3 MHz  (output / 4, since axis_scale2x emits 4 px/in_px)
//
// SCALER=0 typical wiring:
//   clk_pix_in_i = clk_pix_out_i (caller ties them together — any rate)
//   The two-port signature is preserved so the same RTL covers both modes,
//   and SCALER=0 stays byte-identical to the pre-scaler design.
```

Both async FIFOs (`axis_async_fifo_ifc`) cross between `clk_pix_*` and `clk_dsp` domains; they are agnostic to the actual frequency, so the same RTL handles `SCALER=0` (single rate) and `SCALER=1` (4:1 ratio) without changes.

**Clock-stability assumptions** — see also §3.5:
- Long-term rate balance: `clk_pix_in_i × N² = clk_pix_out_i` for an N× scaler (N=2 here ⇒ 4:1).
- Phase between input SOF and output VGA frame boundary is **not constrained** by the design. The `vga_started` one-shot in `sparevideo_top` aligns frame 0 to the first SOF; subsequent frames rely on the rate balance plus output `V_BLANK` real-time slack to absorb the per-frame `S_FILL_FIRST_ROW` startup of the scaler.
- Sustained drift between the two clocks (real silicon with independent crystals) eventually drifts the output FIFO and trips `assert_fifo_out_no_overflow` or `assert_no_output_underrun`. Real-silicon deployments need one of: (a) genlock — derive `clk_pix_out_i` from `clk_pix_in_i` via a PLL; (b) a frame buffer between the pipeline and VGA, with explicit drop/duplicate-frame logic; (c) accept that the system is timing-tight and audit headroom for the worst-case crystal tolerance.
- Sim is exempt because clock periods are exact.

**Risks:**
- **A1 (medium).** Bilinear output produces 4× pixel rate in bursts. Output-side CDC FIFO must absorb ≥ one output line (640 entries) without underflow. Verify in the FIFO-depth audit (§5).
- **A2 (medium).** `axis_hflip` uses a single-line buffer → write-phase stalls downstream, read-phase stalls upstream. Long-term rates match; verify the input-side CDC FIFO is deep enough (≥ one line). A ping-pong variant is available as a future optimization.
- **A3 (real-silicon only).** Two-clk model assumes correct long-term rate balance. Sustained mismatch between independent crystals drifts the output FIFO; mitigations listed in "Clock-stability assumptions" above. Sim is unaffected.
- **A4 (lower).** Gamma is applied before the scaler → bilinear averages happen in non-linear space, producing slightly darker midpoints than ground truth. Visually invisible at 2× on typical content; noted for completeness.
- **A5 (lower).** `axis_ccl` EOF FSM cycle budget remains comfortable at both VGA timings (V_BLANK ≥ 16 in either config); no action required now.

## 3. Per-block detail

### 3.1 `axis_hflip`

- **Domain:** proc_clk. **Data:** 24-bit RGB. **Latency:** 1 line.
- **Ports:** `clk, rst_n, enable_i`, standard AXIS in/out with `tuser=sof`, `tlast=eol`.
- **Internals:** 320×24-bit single line buffer. Receive phase fills `line_buf[col]`; transmit phase reads `line_buf[319 − col]`. When `enable_i=0`, inputs pass straight to outputs and the line buffer stays idle.
- **Edge rule:** per-frame — SOF aligns write-phase to column 0; no inter-frame state.

**Risk B1 (lower).** Stall alternation → input-side CDC FIFO must cushion one line. Audited alongside Risk A2.

### 3.2 `axis_window3x3` *(new reusable primitive)*

- **Domain:** proc_clk. **Data width:** `DATA_WIDTH` parameter (1 for morph, 8 for Gaussian).
- **Params:** `DATA_WIDTH`, `H_ACTIVE`, `V_ACTIVE`, `EDGE_POLICY` (currently only `REPLICATE`).
- **Internals:** 2 line buffers, 3-row × 3-col window register, AXIS handshake with `held_tdata` and `pix_addr_hold` per the motion-pipeline lessons-learned. Edge-replication at all four borders.
- **Output:** flat window `window_o[0:8][DATA_WIDTH-1:0]` (row-major TL..BR) + `window_valid_o` + `m_axis_*`. Users consume the window combinationally.

**Risk C1 (high).** Refactoring `axis_gauss3x3` to wrap this primitive must produce byte-identical motion-pipeline output. Gated by the **Refactor regression gate** (§5) before any morph wrapper is built.

### 3.3 `axis_morph3x3_open`

- **Domain:** proc_clk. **Data:** 1-bit mask. **Latency:** 2 kernel windows (one per erode/dilate).
- **Params:** none (kernel is 3×3 square, single pass).
- **Structure:** `axis_morph3x3_erode` (9-way `AND` over `axis_window3x3<1>` window) → internal AXIS link → `axis_morph3x3_dilate` (9-way `OR`). Each wrapper module is ~20 lines.
- **Ports:** `enable_i` forwards to both sub-modules; both pass through when disabled.

**Risk D1 (medium).** 3×3 square opening deletes features < 3 px wide (thin objects, far-field targets). Current synthetic test patterns are all ≥ 10 px, so regression won't catch this. Document in `axis_morph3x3_open-arch.md`; add a `thin_moving_line` synthetic source so the behaviour is visible.

### 3.4 `axis_gamma_cor`

- **Domain:** proc_clk. **Data:** 24-bit RGB. **Latency:** 1 cycle.
- **Params:** `LUT_ENTRIES = 33` (not expected to vary).
- **Ports:** `enable_i`, three flat LUT sideband buses `lut_r_i [33][8]`, `lut_g_i [33][8]`, `lut_b_i [33][8]`, standard AXIS.
- **Per-pixel math:**
  ```
  addr = pixel[7:3]         // 0..31 → entry index
  frac = pixel[2:0]         // 0..7  → fractional weight
  out  = (LUT[addr]   * (8 - frac) +
          LUT[addr+1] *      frac ) >> 3
  ```
- **LUT source:** `py/gen_gamma_lut.py --curve $(GAMMA_CURVE) --out dv/data/gamma_tables.svh`, run by `make prepare`. The TB `include`s this file and wires the three `localparam byte` arrays to the DUT ports. Synthesis constant-folds them.

**Risk E1 (lower — covered by A4).** Averaging downstream of gamma is technically incorrect; visually invisible.

### 3.5 `axis_scale2x`

- **Domain:** clk_dsp. **Data:** 24-bit RGB. **Instantiated only when `SCALER=1`.**
- **Params:** `SCALE_FILTER = "nn" | "bilinear"` (compile-time).
- **NN mode:** each source pixel emitted twice; each source line emitted twice. Needs one line buffer (so the second emitted line can be replayed under backpressure).
- **Bilinear mode:** one line buffer. Output row cadence is `(source_row, interp_row, source_row, interp_row, …)`. Within each source row: `(A, (A+B)>>1, B, (B+C)>>1, …)`. Within each interp row: `((A+C)>>1, (A+B+C+D)>>2, (B+D)>>1, …)`. Top edge replicates the first source row. No multipliers — all weights are powers of two.
- **Output rate:** 4× input rate in bursts. Output-side CDC FIFO depth ≥ 1 output line (see Risk A1).
- **Per-frame startup:** on every input SOF the scaler enters `S_FILL_FIRST_ROW` and emits no output until row 0 is buffered (≈1 input row of `clk_dsp` time). The output VGA controller is in `V_BLANK` for the matching real-time interval, so under nominal rate balance no underflow occurs at the seam between frames. Bench numbers (TB porches): `S_FILL_FIRST_ROW` ≈50 µs vs output `V_BLANK` ≈430 µs ⇒ ~8× headroom. Real-silicon deployments must verify this margin against worst-case PLL/crystal tolerances or use one of the mitigations listed in §2 ("Clock-stability assumptions").
- **Rate-balance precondition:** correctness assumes `clk_pix_in_i × 4 = clk_pix_out_i` on average over a frame. The TB sets period ratios exactly; real silicon needs genlock or a frame buffer (see §2).

### 3.6 `axis_hud`

- **Domain:** proc_clk. **Data:** 24-bit RGB. **Latency:** 1 cycle.
- **Ports:** `enable_i`, sidebands `frame_num_i[15:0]`, `bbox_count_i[7:0]` (up to 2-digit decimal, 99 max), `ctrl_flow_tag_i[1:0]`, `latency_us_i[15:0]`, AXIS.
- **Sideband latching:** all four values sampled at the HUD's own input-SOF and held for the whole frame (prevents mid-frame flicker).
- **Font:** 8×8 bitmap ROM, digits 0–9 + A–Z = 36 glyphs × 8 bytes = 288 B. Public-domain IBM VGA 8×8.
- **Layout:** `F:####  T:XXX  N:##  L:#####us` at `(x=8, y=8)` in output coordinates (640×480 when SCALER=1, else 320×240).
- **ctrl_flow tag ROM:** index → `"PAS" | "MOT" | "MSK" | "CCL"`.
- **Latency measurement:** top captures SOF-of-current-input-frame (at proc_clk CDC exit) as a cycle count; HUD subtracts that from its own input-SOF cycle count, multiplies by `10 ns / cycle`, converts to µs. Iterative divide once per frame during vblank — ample budget.

**Risk F1 (medium — A5 from earlier).** `LAT` measures proc_clk-SOF-in to proc_clk-SOF-at-HUD. The output-side CDC adds a few extra cycles before the pixel actually reaches VGA. Document the measurement boundary in `axis_hud-arch.md`.

## 4. Build system

### 4.1 Parameter propagation

Same chain as `ALPHA_SHIFT` / `GRACE_FRAMES`:

```
top Makefile  ?= defaults
  → SIM_VARS exported
  → dv/sim/Makefile  ?= defaults (fallback when invoked directly)
  → VLT_FLAGS: -G HFLIP=$(HFLIP) -G MORPH=$(MORPH) -G GAMMA_COR=$(GAMMA_COR)
               -G SCALER=$(SCALER) -G SCALE_FILTER=$(SCALE_FILTER) -G HUD=$(HUD)
  → tb_sparevideo.sv parameters (with local defaults matching top Makefile)
  → sparevideo_top parameters
  → SCALER: generate if; others: tie enable_i at top
```

`GAMMA_CURVE` is not passed to the RTL — it only affects the generated `gamma_tables.svh`.

### 4.2 Config stamp

`dv/sim/Makefile` writes a stamp whose filename encodes every knob that should trigger recompilation:

```
.config-stamp-hflip=$(HFLIP)-morph=$(MORPH)-gamma=$(GAMMA_COR)-curve=$(GAMMA_CURVE)-
                    scaler=$(SCALER)-filter=$(SCALE_FILTER)-hud=$(HUD)-
                    alpha=$(ALPHA_SHIFT)-slow=$(ALPHA_SHIFT_SLOW)-grace=$(GRACE_FRAMES)
```

Changing any knob creates a new stamp; the rule deletes the old build dir and forces a full recompile.

**Risk G1 (high).** Missing any knob from this stamp produces silent stale-compile bugs. The implementation plan must include an explicit checklist entry for every knob added.

### 4.3 `make prepare` additions

- Accepts `HFLIP`, `MORPH`, `GAMMA_COR`, `GAMMA_CURVE`, `SCALER`, `SCALE_FILTER`, `HUD`.
- Persists them into `dv/data/config.mk` alongside existing options.
- Runs `py/gen_gamma_lut.py --curve $(GAMMA_CURVE) --out dv/data/gamma_tables.svh` unconditionally (cheap; keeps TB `include` unconditional even when `GAMMA_COR=0`).
- `dv/data/gamma_tables.svh` is gitignored.
- Verilator / Icarus flag `-I dv/data` (Verilator) or `+incdir+dv/data` (Icarus) added.

### 4.4 TB `pix_clk` period

```systemverilog
localparam real T_PIX_NS = (SCALER == 1) ? 39.72 : 158.7;
```

## 5. Verification

### 5.1 Per-block unit TBs

Each new / refactored module gets a TB under `hw/ip/<block>/tb/`, wired into `make test-ip`, following the existing `drv_*` pattern and the asymmetric-stall discipline from CLAUDE.md.

| TB | Stimuli |
|----|---------|
| `tb_axis_hflip` | Gradient ramp (exact-mirror check), asymmetric downstream stall, `enable_i=0` passthrough, 1-pixel-wide corner case |
| `tb_axis_window3x3` | 3-row gradient (window ordering + edge replication at all four borders), both 1-bit and 8-bit `DATA_WIDTH`, stall mid-window |
| `tb_axis_morph3x3_open` | Salt-noise removal, thin-stripe removal (documents Risk D1), `enable_i=0` passthrough |
| `tb_axis_gamma_cor` | Identity LUT passthrough, sRGB LUT with black/mid/white ramp, `enable_i=0` |
| `tb_axis_scale2x` | NN build: 2×2 replication check; bilinear build: hand-checked 4×4 golden patch (captures top-edge + corner); downstream stall |
| `tb_axis_hud` | Render one known field set → byte-diff against golden frame; `enable_i=0` passthrough |

### 5.2 Python reference models

One per op under `py/models/ops/`:

```
py/models/ops/hflip.py
py/models/ops/window3x3.py      # shared helper
py/models/ops/morph_open.py
py/models/ops/gamma_cor.py
py/models/ops/scale2x.py        # mode: 'nn' | 'bilinear'
py/models/ops/hud.py
```

Each model gets a unit test in `py/tests/test_models.py` against a tiny hand-crafted golden (~4–8 pixels), typed inline — mitigates **Risk H1 (high): model/RTL co-bug**. The *model* must be correct independently before the RTL is compared against it.

Top-level dispatcher in `py/models/__init__.py` reads `dv/data/config.mk` and composes:

```
frames → (hflip if HFLIP) → ctrl_flow_model (with morph inside if MORPH) →
         (gamma_cor if GAMMA_COR) → (scale2x if SCALER) → (hud if HUD) → expected
```

### 5.3 Refactor regression gate (Risk C1)

Before any new wrapper is added over `axis_window3x3`:

1. On the current tip: `make run-pipeline CTRL_FLOW=motion MODE=binary`, save `dv/data/output.bin` as `renders/golden/motion-before-kernel-refactor.bin`.
2. Refactor `axis_gauss3x3` to wrap `axis_window3x3`.
3. Re-run the same command, `cmp` against the golden. Any delta must be resolved before continuing.

### 5.4 Integration regression matrix (reduced)

~13 configs at `TOLERANCE=0`:

- All-off: `HFLIP=0 MORPH=0 GAMMA_COR=0 SCALER=0 HUD=0` × `passthrough`.
- All-on: `HFLIP=1 MORPH=1 GAMMA_COR=1 SCALER=1 HUD=1` × {`passthrough`, `motion`, `mask`, `ccl_bbox`}.
- Each knob toggled singly from all-on × `motion` (5 runs).
- `SCALE_FILTER=nn` vs `bilinear` × `motion` at all-on (2 runs).
- `GAMMA_CURVE=linear` × `motion` at all-on (1 run; should closely match `GAMMA_COR=0`).

Exposed as `make regress-extended`.

### 5.5 FIFO-depth audit (Risk A1 + A2 + B1)

A dedicated `make fifo-audit` target runs one bilinear-scaler config with `+DUMP_VCD`, then invokes a small Python script that parses `m_status_depth` / `s_status_depth` traces from the VCD and prints the observed maxima. Acceptance: both CDC FIFOs show headroom ≥ 25% after the run.

### 5.6 Documentation updates

Required alongside every new / refactored module (from the CLAUDE.md TODO list):

- `hw/ip/<block>/docs/<block>-arch.md` — architecture doc per block, using the `hardware-arch-doc` skill.
- `README.md` — new IPs added to the block table.
- `CLAUDE.md` — knob names + defaults + one-line build-commands entry.
- `requirements.txt` — no new Python deps expected (Pillow/numpy already present).

## 6. Implementation order (proposed)

A detailed plan is the next artifact. Proposed staging:

1. `axis_window3x3` refactor of `axis_gauss3x3` (gated by §5.3 regression check).
2. `axis_morph3x3_open` (unblocked by #1).
3. `axis_hflip`.
4. `axis_gamma_cor` + `py/gen_gamma_lut.py`.
5. `axis_scale2x` (NN first, bilinear second) + VGA timing parameterization.
6. `axis_hud`.

Only step 1 is a hard prerequisite. After it lands, step 2 (`axis_morph3x3_open`) depends on `axis_window3x3`, but steps 3–6 are independent of step 2 and of each other — they can proceed in any order. The reference-model dispatcher (§5.2) grows incrementally alongside each block.
