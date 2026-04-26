# axis_hflip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a horizontal-mirror stage at the head of the proc_clk pipeline so the user sees a "selfie-cam" view; the flip is upstream of every ctrl_flow branch so motion masks and bbox coordinates agree with the displayed frame. The block is bypassable at runtime via a build-time-tied `enable_i`.

**Architecture:** A new `axis_hflip` AXIS module sits between the input CDC FIFO output (`dsp_in_*`) and the existing top-level `axis_fork` / passthrough mux. Internals: a single `H_ACTIVE × 24-bit` line buffer with a two-phase RECV/XMIT FSM — RECV asserts upstream `tready`, fills `line_buf[col]`; XMIT asserts downstream `tvalid`, reads `line_buf[H_ACTIVE-1-col]`. SOF latched at write-phase start, re-emitted on the first XMIT pixel. EOL emitted on the last XMIT pixel of every line. `enable_i=0` is a zero-latency combinational passthrough. Because RECV and XMIT do not overlap, the input CDC FIFO must absorb one line of write-clock pixels during XMIT — `IN_FIFO_DEPTH` is bumped from 32 to 128 (covers the worst-case ~80-pixel buildup with margin). The Python reference model gets a new op (`py/models/ops/hflip.py` = `np.fliplr` per frame) and is composed at the head of every control-flow model when `HFLIP=1`.

**Tech Stack:** SystemVerilog (Verilator 5 / Icarus 12 compatible synthesis subset — no SVA, no interfaces, no classes), Python (numpy), FuseSoC core files, Makefile parameter propagation.

**Prerequisites:** None. The morph plan (`2026-04-24-axis-morph-open-plan.md`) is merged and provides the pattern this plan mirrors for runtime-bypass stages and Python-model composition. Branch from `origin/main` per CLAUDE.md "one branch per plan" — suggested name `feat/axis-hflip`.

---

## File Structure

**New files:**
- `hw/ip/hflip/hflip.core` — FuseSoC CAPI=2 core for the new IP.
- `hw/ip/hflip/rtl/axis_hflip.sv` — the module.
- `hw/ip/hflip/tb/tb_axis_hflip.sv` — unit TB (`drv_*` pattern, asymmetric stall).
- `docs/specs/axis_hflip-arch.md` — architecture doc (spec lives under `docs/specs/`, not `hw/ip/<block>/docs/`).
- `py/models/ops/hflip.py` — `np.fliplr` reference model.
- `py/tests/test_hflip.py` — unit test for the reference model against hand-crafted goldens.

**Modified files:**
- `hw/top/sparevideo_top.sv` — instantiate `axis_hflip` between `dsp_in_*` and the existing `axis_fork`; add `HFLIP` parameter; bump `IN_FIFO_DEPTH` from 32 to 128.
- `dv/sv/tb_sparevideo.sv` — add `HFLIP` parameter; propagate to DUT; accept `+HFLIP=` plusarg (informational — `HFLIP` is a compile-time `-G`).
- `dv/sim/Makefile` — add `HFLIP ?= 1` default, `-GHFLIP=$(HFLIP)` flag, include in `CONFIG_STAMP`, add `IP_HFLIP_RTL`, `test-ip-hflip` target, wire into `test-ip` aggregate and `clean`.
- `Makefile` (top) — add `HFLIP ?= 1`, include in `SIM_VARS`, persist into `dv/data/config.mk`, add to `verify` / `render` argument lists, advertise in `help`.
- `py/harness.py` — add `--hflip` CLI argument to `prepare`/`verify`/`render`; thread `hflip_en` into `run_model(...)`.
- `py/models/__init__.py` — accept `hflip_en` kwarg; pre-flip frames once before dispatch so each control-flow model sees the flipped input.
- `README.md` — add the new IP to the block table; add `HFLIP` to the build-options list.
- `CLAUDE.md` — add `HFLIP` to the build-knob list under "Build Commands"; add `hw/ip/hflip/rtl/` to "Project Structure".

**No changes required:** `hw/top/sparevideo_pkg.sv` (no new shared types), `py/frames/video_source.py` (no new synthetic source — existing patterns exercise hflip), every existing per-block IP and TB.

---

## Task 1: Capture pre-integration regression golden

**Purpose:** lock in a byte-perfect reference of every control flow's output with `HFLIP=0`. After the integration in Task 8, `HFLIP=0` must remain byte-identical to this golden — that's the gate proving the new RTL hasn't perturbed the pre-existing path.

**Files:**
- Create (local, gitignored): `renders/golden/<ctrl_flow>-pre-hflip.bin` (4 files)

- [ ] **Step 1: Run the four pre-integration pipelines**

Run each command in turn, capturing the output:

```bash
mkdir -p renders/golden

for FLOW in passthrough motion mask ccl_bbox; do
    make run-pipeline CTRL_FLOW=$FLOW SOURCE="synthetic:moving_box" \
                      WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary
    cp dv/data/output.bin renders/golden/$FLOW-pre-hflip.bin
done
```

Expected: each invocation exits status 0; verify reports PASS; four `.bin` files exist in `renders/golden/`.

- [ ] **Step 2: Sanity-check the goldens**

Run:
```bash
ls -l renders/golden/*-pre-hflip.bin
xxd renders/golden/passthrough-pre-hflip.bin | head -1
```

Expected: each file is `12 + 320*240*3*8 = 1,843,212` bytes; the first 12 bytes decode as `(0x140, 0xF0, 0x8) = (320, 240, 8)`.

*(Do not commit — `renders/` is gitignored. These are deleted at the end of Task 9.)*

---

## Task 2: Architecture doc

**Files:**
- Create: `docs/specs/axis_hflip-arch.md`

- [ ] **Step 1: Write the arch doc**

Use the `hardware-arch-doc` skill. Required sections:

1. **Purpose** — horizontal mirror at the head of the proc_clk pipeline; selfie-cam semantic; placed before the ctrl_flow mux so motion masks / bbox coords agree with the user-visible frame.
2. **Ports** — standard AXIS in/out (`tdata[23:0]`, `tvalid`, `tready`, `tlast=eol`, `tuser=sof`) + `enable_i` sideband, `clk_i`, `rst_n_i`.
3. **Parameters** — `H_ACTIVE` (default `sparevideo_pkg::H_ACTIVE = 320`), `V_ACTIVE` (default 240; informational only — not used internally).
4. **Internal structure** — ASCII block diagram showing: input AXIS → RECV/XMIT FSM → 320×24-bit single line buffer → output AXIS; `enable_i=0` mux around the whole datapath.
5. **FSM** — two states `S_RECV` and `S_XMIT`. RECV: `s_axis_tready_o = 1`, on accepted beat write `line_buf[wr_col] = tdata`, increment `wr_col`; on accepted beat with `tlast=1` latch `sof_pending = sof_in` and transition to XMIT. XMIT: `m_axis_tvalid_o = 1`, output `line_buf[H_ACTIVE-1-rd_col]`, `tuser_o = sof_pending && (rd_col == 0)`, `tlast_o = (rd_col == H_ACTIVE-1)`; on accepted output beat increment `rd_col`; when `rd_col` rolls over after the last beat clear `sof_pending` and return to RECV.
6. **Edge rule** — per-frame: SOF aligns the FSM to RECV column 0 by overriding `wr_col`. No inter-frame state.
7. **Latency / throughput** — 1 line of latency (~`H_ACTIVE` proc_clk cycles before first output beat after first input beat). 1 pixel/cycle throughput at the burst, 1 pixel/cycle long-term average.
8. **Backpressure & FIFO sizing** — RECV alternates with XMIT, so `s_axis_tready_o` is low for one full line per line. The input-side CDC FIFO must absorb one line of write-clock pixels during this window. With `pix_clk = 25 MHz`, `dsp_clk = 100 MHz`, `H_ACTIVE = 320`: XMIT lasts ~320 dsp cycles = 80 pix_clk cycles → ≤80 pixels accumulate. `IN_FIFO_DEPTH = 128` chosen for ≥50% headroom. Document Risk B1 (lower) from the design doc and note "ping-pong variant available as a future optimization".
9. **`enable_i` semantics** — when `0`, all five output lines map combinationally to the corresponding input lines and `s_axis_tready_o = m_axis_tready_i`. The line buffer holds last value but is never read. Must be held frame-stable (toggling mid-frame is undefined).
10. **Verification** — list `tb_axis_hflip` directed tests + the top-level integration regression matrix from §5.4 of the design doc.
11. **Risk B1 cross-reference** — point at `2026-04-23-pipeline-extensions-design.md` §3.1.

- [ ] **Step 2: Commit the arch doc**

Run:
```bash
git add docs/specs/axis_hflip-arch.md
git commit -m "docs(hflip): add axis_hflip architecture doc"
```

---

## Task 3: Module scaffolding (skeleton + Makefile wiring)

**Files:**
- Create: `hw/ip/hflip/hflip.core`
- Create: `hw/ip/hflip/rtl/axis_hflip.sv` (skeleton — body added in Task 5)
- Modify: `dv/sim/Makefile`
- Modify: `Makefile` (top)

- [ ] **Step 1: Create the FuseSoC core**

Create `hw/ip/hflip/hflip.core`:

```yaml
CAPI=2:
name: "sparevideo:ip:hflip"
description: "Horizontal mirror (selfie-cam) AXIS stage with single line buffer + enable_i bypass"

filesets:
  files_rtl:
    files:
      - rtl/axis_hflip.sv
    file_type: systemVerilogSource

targets:
  default:
    filesets:
      - files_rtl
```

- [ ] **Step 2: Create the empty module skeleton**

Create `hw/ip/hflip/rtl/axis_hflip.sv`:

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_hflip -- horizontal mirror stage (selfie-cam) on a 24-bit RGB AXIS.
//
// FSM-driven RECV/XMIT alternation over a single H_ACTIVE x 24-bit line
// buffer. Receive phase fills line_buf[col]; transmit phase reads
// line_buf[H_ACTIVE-1-col]. SOF is latched at write-phase start and
// re-emitted on the first XMIT pixel; EOL emitted on the last XMIT pixel
// of every line. No inter-frame state.
//
// Latency: ~1 line (H_ACTIVE proc_clk cycles).
// Throughput: 1 pixel/cycle long-term; bursty (RECV/XMIT alternation).
//
// Blanking / FIFO sizing requirements:
//   The upstream CDC FIFO must absorb one line of write-clock pixels
//   during XMIT. For pix_clk = 25 MHz, dsp_clk = 100 MHz, H_ACTIVE = 320,
//   that's <= 80 entries. IN_FIFO_DEPTH = 128 in the top is safe.
//
// enable_i: when 1, the FSM-driven mirror path drives the output. When 0,
// s_axis_* is forwarded combinatorially to m_axis_* with zero latency and
// the line buffer is idle. enable_i must be held frame-stable.

module axis_hflip #(
    parameter int H_ACTIVE = 320,
    parameter int V_ACTIVE = 240    // informational only
) (
    // --- Clocks and resets ---
    input  logic clk_i,
    input  logic rst_n_i,

    // --- Sideband ---
    input  logic enable_i,

    // --- AXI4-Stream input (24-bit RGB) ---
    input  logic [23:0] s_axis_tdata_i,
    input  logic        s_axis_tvalid_i,
    output logic        s_axis_tready_o,
    input  logic        s_axis_tlast_i,
    input  logic        s_axis_tuser_i,

    // --- AXI4-Stream output (24-bit RGB) ---
    output logic [23:0] m_axis_tdata_o,
    output logic        m_axis_tvalid_o,
    input  logic        m_axis_tready_i,
    output logic        m_axis_tlast_o,
    output logic        m_axis_tuser_o
);

    // Placeholder tie-offs so the module elaborates cleanly. Body lands in
    // Task 5; the unit TB (Task 4) is expected to FAIL against this skeleton.
    assign s_axis_tready_o = 1'b0;
    assign m_axis_tdata_o  = '0;
    assign m_axis_tvalid_o = 1'b0;
    assign m_axis_tlast_o  = 1'b0;
    assign m_axis_tuser_o  = 1'b0;

    // Touch unused inputs to keep Verilator quiet on the skeleton.
    logic _unused;
    assign _unused = &{1'b0, enable_i, s_axis_tdata_i, s_axis_tvalid_i,
                       s_axis_tlast_i, s_axis_tuser_i, m_axis_tready_i,
                       (V_ACTIVE != 0)};

endmodule
```

- [ ] **Step 3: Wire into `dv/sim/Makefile`**

Edit `dv/sim/Makefile`:

a) Add `IP_HFLIP_RTL` near the other `IP_*_RTL` definitions (after the existing block around line 126):

```make
IP_HFLIP_RTL        = ../../hw/ip/hflip/rtl/axis_hflip.sv
```

b) Add the new RTL source to `RTL_SRCS` so the top-level sim can find `axis_hflip` after Task 8 instantiates it. Update the `RTL_SRCS` list (currently lines 1–16) by inserting `../../hw/ip/hflip/rtl/axis_hflip.sv` immediately after the existing `axis_fork.sv` line, so the section reads:

```make
RTL_SRCS = ../../hw/top/sparevideo_pkg.sv \
           ../../hw/top/ram.sv \
           ../../hw/ip/rgb2ycrcb/rtl/rgb2ycrcb.sv \
           ../../hw/ip/axis/rtl/axis_fork.sv \
           ../../hw/ip/hflip/rtl/axis_hflip.sv \
           ../../hw/ip/window/rtl/axis_window3x3.sv \
           ../../hw/ip/filters/rtl/axis_gauss3x3.sv \
           ../../hw/ip/filters/rtl/axis_morph3x3_erode.sv \
           ../../hw/ip/filters/rtl/axis_morph3x3_dilate.sv \
           ../../hw/ip/filters/rtl/axis_morph3x3_open.sv \
           ../../hw/ip/motion/rtl/motion_core.sv \
           ../../hw/ip/motion/rtl/axis_motion_detect.sv \
           ../../hw/ip/ccl/rtl/axis_ccl.sv \
           ../../hw/ip/overlay/rtl/axis_overlay_bbox.sv \
           ../../hw/top/sparevideo_top.sv \
           ../../hw/ip/vga/rtl/vga_controller.sv \
           ../../third_party/verilog-axis/rtl/axis_async_fifo.v
```

c) Add `HFLIP ?= 1` after the existing `MORPH ?= 1` (around line 35):

```make
HFLIP             ?= 1
```

d) Add `-GHFLIP=$(HFLIP)` to `VLT_FLAGS` (the `-G...` line currently around 85). Append it so the line ends:

```make
            -GH_ACTIVE=$(WIDTH) -GV_ACTIVE=$(HEIGHT) -GALPHA_SHIFT=$(ALPHA_SHIFT) -GALPHA_SHIFT_SLOW=$(ALPHA_SHIFT_SLOW) -GGRACE_FRAMES=$(GRACE_FRAMES) -GGRACE_ALPHA_SHIFT=$(GRACE_ALPHA_SHIFT) -GGAUSS_EN=$(GAUSS_EN) -GMORPH=$(MORPH) -GHFLIP=$(HFLIP) \
```

e) Update the `CONFIG_STAMP` rule (around line 99) to include `HFLIP`:

```make
$(CONFIG_STAMP): FORCE
	@mkdir -p $(VOBJ_DIR)
	@echo "$(WIDTH) $(HEIGHT) $(ALPHA_SHIFT) $(ALPHA_SHIFT_SLOW) $(GRACE_FRAMES) $(GRACE_ALPHA_SHIFT) $(GAUSS_EN) $(MORPH) $(HFLIP)" | cmp -s - $@ || echo "$(WIDTH) $(HEIGHT) $(ALPHA_SHIFT) $(ALPHA_SHIFT_SLOW) $(GRACE_FRAMES) $(GRACE_ALPHA_SHIFT) $(GAUSS_EN) $(MORPH) $(HFLIP)" > $@
```

f) Add `test-ip-hflip` to the `.PHONY` list (around line 44):

```make
.PHONY: compile sim sim-waves sw-dry-run clean \
       test-ip test-ip-rgb2ycrcb test-ip-window test-ip-gauss3x3 \
       test-ip-motion-detect test-ip-motion-detect-gauss \
       test-ip-overlay-bbox test-ip-ccl \
       test-ip-morph3x3-erode test-ip-morph3x3-dilate test-ip-morph3x3-open \
       test-ip-hflip
```

g) Add `test-ip-hflip` to the `test-ip` aggregate target (currently line 139):

```make
test-ip: test-ip-rgb2ycrcb test-ip-window test-ip-gauss3x3 test-ip-motion-detect test-ip-motion-detect-gauss test-ip-overlay-bbox test-ip-ccl test-ip-morph3x3-erode test-ip-morph3x3-dilate test-ip-morph3x3-open test-ip-hflip
	@echo "All block testbenches passed."
```

h) Add the per-block target after `test-ip-morph3x3-open`:

```make
# --- axis_hflip ---
test-ip-hflip:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_hflip --Mdir obj_tb_axis_hflip \
	  $(IP_HFLIP_RTL) ../../hw/ip/hflip/tb/tb_axis_hflip.sv
	obj_tb_axis_hflip/Vtb_axis_hflip
```

i) Add `obj_tb_axis_hflip` to the `clean` target's `rm -rf` list (around line 217):

```make
	rm -rf $(VOBJ_DIR) obj_tb_rgb2ycrcb obj_tb_axis_window3x3 obj_tb_axis_gauss3x3 \
	       obj_tb_axis_motion_detect obj_tb_axis_motion_detect_gauss \
	       obj_tb_axis_overlay_bbox obj_tb_axis_ccl \
	       obj_tb_axis_morph3x3_erode obj_tb_axis_morph3x3_dilate obj_tb_axis_morph3x3_open \
	       obj_tb_axis_hflip
```

- [ ] **Step 4: Wire into top `Makefile`**

Edit the top-level `Makefile`:

a) Add the default after `MORPH ?= 1` (around line 33):

```make
# Horizontal flip (selfie-cam) on the proc_clk pipeline. 0 = bypass, 1 = mirror (default).
HFLIP ?= 1
```

b) Append `HFLIP=$(HFLIP)` to the `SIM_VARS` line (currently around 51):

```make
SIM_VARS = SIMULATOR=$(SIMULATOR) \
           WIDTH=$(WIDTH) HEIGHT=$(HEIGHT) FRAMES=$(FRAMES) \
           MODE=$(MODE) CTRL_FLOW=$(CTRL_FLOW) \
           ALPHA_SHIFT=$(ALPHA_SHIFT) ALPHA_SHIFT_SLOW=$(ALPHA_SHIFT_SLOW) GRACE_FRAMES=$(GRACE_FRAMES) GRACE_ALPHA_SHIFT=$(GRACE_ALPHA_SHIFT) GAUSS_EN=$(GAUSS_EN) MORPH=$(MORPH) HFLIP=$(HFLIP) \
           INFILE=$(CURDIR)/$(PIPE_INFILE) \
           OUTFILE=$(CURDIR)/$(PIPE_OUTFILE)
```

c) Add `HFLIP` to the `prepare` target's `printf` config-stamp (around line 126), so the line becomes:

```make
	@printf 'SOURCE = %s\nWIDTH = %s\nHEIGHT = %s\nFRAMES = %s\nMODE = %s\nCTRL_FLOW = %s\nALPHA_SHIFT = %s\nALPHA_SHIFT_SLOW = %s\nGRACE_FRAMES = %s\nGRACE_ALPHA_SHIFT = %s\nGAUSS_EN = %s\nMORPH = %s\nHFLIP = %s\n' \
		'$(SOURCE)' '$(WIDTH)' '$(HEIGHT)' '$(FRAMES)' '$(MODE)' '$(CTRL_FLOW)' '$(ALPHA_SHIFT)' '$(ALPHA_SHIFT_SLOW)' '$(GRACE_FRAMES)' '$(GRACE_ALPHA_SHIFT)' '$(GAUSS_EN)' '$(MORPH)' '$(HFLIP)' > $(DATA_DIR)/config.mk
```

d) Append `--hflip $(HFLIP)` to the `verify` target's harness invocation (around line 154):

```make
	cd py && $(HARNESS) verify \
		--input $(CURDIR)/$(PIPE_INFILE) --output $(CURDIR)/$(PIPE_OUTFILE) \
		--mode $(MODE) --ctrl-flow $(CTRL_FLOW) --tolerance $(TOLERANCE) \
		--alpha-shift $(ALPHA_SHIFT) --alpha-shift-slow $(ALPHA_SHIFT_SLOW) --grace-frames $(GRACE_FRAMES) --grace-alpha-shift $(GRACE_ALPHA_SHIFT) --gauss-en $(GAUSS_EN) --morph $(MORPH) --hflip $(HFLIP)
```

e) Append `--hflip $(HFLIP)` to the `render` target's harness invocation (around line 165):

```make
	cd py && $(HARNESS) render \
		--input $(CURDIR)/$(PIPE_INFILE) --output $(CURDIR)/$(PIPE_OUTFILE) \
		--mode $(MODE) --ctrl-flow $(CTRL_FLOW) --alpha-shift $(ALPHA_SHIFT) \
		--alpha-shift-slow $(ALPHA_SHIFT_SLOW) --grace-frames $(GRACE_FRAMES) --grace-alpha-shift $(GRACE_ALPHA_SHIFT) --gauss-en $(GAUSS_EN) --morph $(MORPH) --hflip $(HFLIP) --render-output $(RENDER_OUT)
```

f) Add `HFLIP` to the `RENDER_OUT` filename (around line 157) so artifacts don't collide:

```make
RENDER_OUT = $(CURDIR)/renders/$(RENDER_SOURCE_SAFE)__width=$(WIDTH)__height=$(HEIGHT)__frames=$(FRAMES)__ctrl-flow=$(CTRL_FLOW)__alpha-shift=$(ALPHA_SHIFT)__alpha-shift-slow=$(ALPHA_SHIFT_SLOW)__grace-frames=$(GRACE_FRAMES)__grace-alpha-shift=$(GRACE_ALPHA_SHIFT)__gauss-en=$(GAUSS_EN)__morph=$(MORPH)__hflip=$(HFLIP).png
```

g) Add `HFLIP=1` to the `help` text (after the `MORPH=1` line, around line 99):

```make
	@echo "    HFLIP=1                          Horizontal mirror on/off (default 1)"
```

h) Add the per-block TB to `help` (after `test-ip-morph3x3-open` if present, else after `test-ip-overlay-bbox`):

```make
	@echo "    test-ip-hflip              axis_hflip: 5 tests, mirror correctness, asymmetric stall, enable_i passthrough"
```

- [ ] **Step 5: Verify Makefile parses (dry-run)**

Run:
```bash
make -n test-ip-hflip | head -3
```

Expected: prints the `verilator ... --top-module tb_axis_hflip ...` line; no `make: *** No rule to make target` errors. The TB file does not exist yet so do **not** invoke the rule.

- [ ] **Step 6: Commit**

Run:
```bash
git add hw/ip/hflip/hflip.core hw/ip/hflip/rtl/axis_hflip.sv dv/sim/Makefile Makefile
git commit -m "feat(hflip): scaffold axis_hflip IP + Makefile wiring

Empty module + FuseSoC core file; HFLIP knob propagates through top
Makefile -> dv/sim/Makefile -GHFLIP=N -> CONFIG_STAMP. Body and TB land
in follow-up commits."
```

---

## Task 4: Write `tb_axis_hflip` (failing tests)

**Files:**
- Create: `hw/ip/hflip/tb/tb_axis_hflip.sv`

- [ ] **Step 1: Write the testbench**

Create `hw/ip/hflip/tb/tb_axis_hflip.sv`. Model after `hw/ip/filters/tb/tb_axis_morph3x3_erode.sv` for the `drv_*` pattern, capture loop, asymmetric-stall structure. Use `H=8`, `V=4` for short sims.

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Unit testbench for axis_hflip.
//
// Tests:
//   T1 -- enable_i=1, gradient ramp: output is exactly the input mirrored
//         left-to-right, line by line, frame by frame.
//   T2 -- enable_i=1, multi-frame: two distinct frames; second frame's
//         first-line tuser asserts on the first XMIT pixel of frame 2.
//   T3 -- enable_i=1, downstream stall in the middle of XMIT: output is
//         identical to the no-stall reference (golden mirror).
//   T4 -- enable_i=1, mid-RECV upstream pause (tvalid=0): output unchanged.
//   T5 -- enable_i=0 passthrough: input emerges combinationally on the
//         output with zero latency and no mirror.

`timescale 1ns / 1ps

module tb_axis_hflip;

    localparam int H          = 8;
    localparam int V          = 4;
    localparam int CLK_PERIOD = 10;
    localparam int H_BLANK    = 4;
    localparam int V_BLANK    = H + 8;

    logic clk = 0;
    logic rst_n = 0;
    logic enable;

    // drv_* intermediaries (blocking writes from initial)
    logic [23:0] drv_tdata  = '0;
    logic        drv_tvalid = 1'b0;
    logic        drv_tlast  = 1'b0;
    logic        drv_tuser  = 1'b0;

    // DUT inputs (driven on negedge)
    logic [23:0] s_tdata;
    logic        s_tvalid;
    logic        s_tready;
    logic        s_tlast;
    logic        s_tuser;

    always_ff @(negedge clk) begin
        s_tdata  <= drv_tdata;
        s_tvalid <= drv_tvalid;
        s_tlast  <= drv_tlast;
        s_tuser  <= drv_tuser;
    end

    logic [23:0] m_tdata;
    logic        m_tvalid;
    logic        m_tready = 1'b1;
    logic        m_tlast;
    logic        m_tuser;

    axis_hflip #(
        .H_ACTIVE (H),
        .V_ACTIVE (V)
    ) dut (
        .clk_i           (clk),
        .rst_n_i         (rst_n),
        .enable_i        (enable),
        .s_axis_tdata_i  (s_tdata),
        .s_axis_tvalid_i (s_tvalid),
        .s_axis_tready_o (s_tready),
        .s_axis_tlast_i  (s_tlast),
        .s_axis_tuser_i  (s_tuser),
        .m_axis_tdata_o  (m_tdata),
        .m_axis_tvalid_o (m_tvalid),
        .m_axis_tready_i (m_tready),
        .m_axis_tlast_o  (m_tlast),
        .m_axis_tuser_o  (m_tuser)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- Capture: store every accepted output beat in a (V, H) array ----
    logic [23:0] cap_tdata [V][H];
    logic        cap_tlast [V][H];
    logic        cap_tuser [V][H];
    int          cap_row, cap_col;

    task automatic clear_capture;
        begin
            for (int r = 0; r < V; r++)
                for (int c = 0; c < H; c++) begin
                    cap_tdata[r][c] = '0;
                    cap_tlast[r][c] = 1'b0;
                    cap_tuser[r][c] = 1'b0;
                end
            cap_row = 0;
            cap_col = 0;
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            cap_tdata[cap_row][cap_col] <= m_tdata;
            cap_tlast[cap_row][cap_col] <= m_tlast;
            cap_tuser[cap_row][cap_col] <= m_tuser;
            if (cap_col == H - 1) begin
                cap_col <= 0;
                if (cap_row == V - 1)
                    cap_row <= 0;
                else
                    cap_row <= cap_row + 1;
            end else begin
                cap_col <= cap_col + 1;
            end
        end
    end

    // ---- Helpers ----
    task automatic drive_frame(input logic [23:0] pixels [V][H]);
        begin
            for (int r = 0; r < V; r++) begin
                for (int c = 0; c < H; c++) begin
                    drv_tdata  = pixels[r][c];
                    drv_tvalid = 1'b1;
                    drv_tlast  = (c == H - 1);
                    drv_tuser  = (r == 0) && (c == 0);
                    @(posedge clk);
                    while (!s_tready) @(posedge clk);
                end
                drv_tvalid = 1'b0;
                drv_tlast  = 1'b0;
                drv_tuser  = 1'b0;
                for (int b = 0; b < H_BLANK; b++) @(posedge clk);
            end
            for (int b = 0; b < V_BLANK; b++) @(posedge clk);
        end
    endtask

    task automatic check_mirror(input logic [23:0] pixels [V][H], input string label);
        begin
            for (int r = 0; r < V; r++) begin
                for (int c = 0; c < H; c++) begin
                    if (cap_tdata[r][c] !== pixels[r][H-1-c]) begin
                        $display("FAIL %s @(r=%0d, c=%0d): got %06h, want %06h",
                                 label, r, c, cap_tdata[r][c], pixels[r][H-1-c]);
                        $fatal(1);
                    end
                end
                if (!cap_tlast[r][H-1]) begin
                    $display("FAIL %s: missing tlast at r=%0d c=%0d", label, r, H-1);
                    $fatal(1);
                end
            end
            if (!cap_tuser[0][0]) begin
                $display("FAIL %s: missing tuser at output (0,0)", label);
                $fatal(1);
            end
        end
    endtask

    // ---- Stimulus ----
    initial begin
        logic [23:0] frame_a [V][H];
        logic [23:0] frame_b [V][H];

        m_tready = 1'b1;
        enable   = 1'b1;
        #(CLK_PERIOD*3);
        rst_n = 1'b1;
        #(CLK_PERIOD*2);

        // T1: gradient ramp
        $display("T1: gradient mirror");
        clear_capture();
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_a[r][c] = 24'(r * 32 + c * 4);
        drive_frame(frame_a);
        check_mirror(frame_a, "T1");

        // T2: multi-frame -- second frame must produce its own SOF
        $display("T2: two distinct frames, SOF at frame boundary");
        clear_capture();
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame_b[r][c] = 24'hAA0000 | 24'(r * 16 + c);
        drive_frame(frame_a);
        // After frame A drains, capture buffers reset implicitly by overwrite
        clear_capture();
        drive_frame(frame_b);
        check_mirror(frame_b, "T2");

        // T3: downstream stall mid-XMIT
        $display("T3: downstream stall mid-XMIT");
        clear_capture();
        fork
            drive_frame(frame_a);
            begin
                // Hold m_tready low for a brief window in the middle of the
                // first XMIT phase, then release. Output count must remain V*H.
                for (int b = 0; b < H * 3; b++) @(posedge clk);
                m_tready = 1'b0;
                for (int b = 0; b < 5; b++)         @(posedge clk);
                m_tready = 1'b1;
            end
        join
        check_mirror(frame_a, "T3");

        // T4: mid-RECV upstream pause -- TB drops drv_tvalid for a few cycles
        // mid-line (drive_frame already does this implicitly between rows; here
        // we additionally insert a single in-row pause).
        $display("T4: in-row upstream tvalid bubble");
        clear_capture();
        begin
            for (int r = 0; r < V; r++) begin
                for (int c = 0; c < H; c++) begin
                    drv_tdata  = frame_a[r][c];
                    drv_tvalid = 1'b1;
                    drv_tlast  = (c == H - 1);
                    drv_tuser  = (r == 0) && (c == 0);
                    @(posedge clk);
                    while (!s_tready) @(posedge clk);
                    // Insert a 1-cycle bubble after each accepted mid-row pixel
                    if (c == H/2) begin
                        drv_tvalid = 1'b0;
                        @(posedge clk);
                    end
                end
                drv_tvalid = 1'b0;
                drv_tlast  = 1'b0;
                drv_tuser  = 1'b0;
                for (int b = 0; b < H_BLANK; b++) @(posedge clk);
            end
            for (int b = 0; b < V_BLANK; b++) @(posedge clk);
        end
        check_mirror(frame_a, "T4");

        // T5: enable_i = 0 passthrough -- output equals input, no mirror.
        $display("T5: enable_i=0 passthrough");
        enable = 1'b0;
        clear_capture();
        drive_frame(frame_a);
        for (int r = 0; r < V; r++) begin
            for (int c = 0; c < H; c++) begin
                if (cap_tdata[r][c] !== frame_a[r][c]) begin
                    $display("FAIL T5 @(r=%0d, c=%0d): got %06h, want %06h",
                             r, c, cap_tdata[r][c], frame_a[r][c]);
                    $fatal(1);
                end
            end
        end
        enable = 1'b1;

        $display("ALL HFLIP TESTS PASSED");
        $finish;
    end

endmodule
```

- [ ] **Step 2: Run the TB — expect FAIL (skeleton stub'd)**

Run:
```bash
make test-ip-hflip 2>&1 | tail -20
```

Expected: Verilator elaborates (skeleton's tie-offs drive 0); the simulation starts but T1's `check_mirror` fires `$fatal(1)` because `m_tvalid` never asserts. The log ends with a `FAIL T1 @...` or "missing tuser" line and Verilator exits non-zero.

- [ ] **Step 3: Commit the TB**

Run:
```bash
git add hw/ip/hflip/tb/tb_axis_hflip.sv
git commit -m "test(hflip): add tb_axis_hflip directed tests

Six tests cover gradient mirror, multi-frame SOF, downstream stall,
in-row tvalid bubble, enable_i=0 passthrough. Fails until axis_hflip
body lands in Task 5."
```

---

## Task 5: Implement `axis_hflip` body

**Files:**
- Modify: `hw/ip/hflip/rtl/axis_hflip.sv`

- [ ] **Step 1: Replace the skeleton body**

In `hw/ip/hflip/rtl/axis_hflip.sv`, **delete the entire placeholder block** (the five `assign` lines and the `_unused` tie) and replace with the implementation below. Keep the file header comments.

```systemverilog
    // ---- Counter widths ----
    localparam int COL_W = $clog2(H_ACTIVE + 1);

    // ---- FSM ----
    typedef enum logic [0:0] { S_RECV, S_XMIT } state_e;
    state_e state_q;

    logic [COL_W-1:0] wr_col;          // 0..H_ACTIVE-1 during RECV
    logic [COL_W-1:0] rd_col;          // 0..H_ACTIVE-1 during XMIT
    logic             sof_pending_q;   // latched SOF, applied on first XMIT pixel

    // ---- Line buffer ----
    logic [23:0] line_buf [H_ACTIVE];

    // ---- RECV-phase combinational ----
    logic recv_ready;
    logic recv_accept;
    assign recv_ready  = (state_q == S_RECV);
    assign recv_accept = recv_ready && s_axis_tvalid_i;

    // ---- XMIT-phase combinational ----
    logic        xmit_active;
    logic [23:0] xmit_data;
    logic        xmit_sof;
    logic        xmit_eol;
    logic        xmit_accept;
    assign xmit_active = (state_q == S_XMIT);
    assign xmit_data   = line_buf[(COL_W)'(H_ACTIVE - 1) - rd_col];
    assign xmit_sof    = sof_pending_q && (rd_col == '0);
    assign xmit_eol    = (rd_col == (COL_W)'(H_ACTIVE - 1));
    assign xmit_accept = xmit_active && m_axis_tready_i;

    // ---- Sequential: state, counters, line buffer write ----
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            state_q       <= S_RECV;
            wr_col        <= '0;
            rd_col        <= '0;
            sof_pending_q <= 1'b0;
        end else begin
            unique case (state_q)
                S_RECV: begin
                    if (recv_accept) begin
                        // SOF realigns wr_col to 0 (and clears any stale state)
                        if (s_axis_tuser_i)
                            wr_col <= (COL_W)'(1);
                        else
                            wr_col <= wr_col + (COL_W)'(1);
                        line_buf[s_axis_tuser_i ? '0 : wr_col] <= s_axis_tdata_i;
                        // Latch sof for the upcoming XMIT
                        if (s_axis_tuser_i)
                            sof_pending_q <= 1'b1;
                        // EOL terminates the receive phase
                        if (s_axis_tlast_i) begin
                            state_q <= S_XMIT;
                            rd_col  <= '0;
                            wr_col  <= '0;
                        end
                    end
                end
                S_XMIT: begin
                    if (xmit_accept) begin
                        if (xmit_eol) begin
                            state_q       <= S_RECV;
                            rd_col        <= '0;
                            sof_pending_q <= 1'b0;
                        end else begin
                            rd_col <= rd_col + (COL_W)'(1);
                        end
                    end
                end
                default: state_q <= S_RECV;
            endcase
        end
    end

    // ---- enable_i bypass mux ----
    always_comb begin
        if (enable_i) begin
            s_axis_tready_o = recv_ready;
            m_axis_tdata_o  = xmit_data;
            m_axis_tvalid_o = xmit_active;
            m_axis_tlast_o  = xmit_active && xmit_eol;
            m_axis_tuser_o  = xmit_active && xmit_sof;
        end else begin
            s_axis_tready_o = m_axis_tready_i;
            m_axis_tdata_o  = s_axis_tdata_i;
            m_axis_tvalid_o = s_axis_tvalid_i;
            m_axis_tlast_o  = s_axis_tlast_i;
            m_axis_tuser_o  = s_axis_tuser_i;
        end
    end

    // V_ACTIVE is informational only; touch to keep Verilator quiet.
    logic _unused;
    assign _unused = (V_ACTIVE != 0);
```

- [ ] **Step 2: Run the unit TB — expect PASS**

Run:
```bash
make test-ip-hflip 2>&1 | tail -20
```

Expected: `ALL HFLIP TESTS PASSED` followed by a clean Verilator exit. If any `FAIL` line appears, debug from the test name + (r,c) coordinates printed on failure.

- [ ] **Step 3: Run lint**

Run:
```bash
make lint 2>&1 | tail -20
```

Expected: no new warnings attributable to `axis_hflip`. If a benign `UNUSED` or `WIDTH` warning appears for an internal signal, add a Verilator waiver in `hw/lint/verilator_waiver.vlt` rather than restructuring the RTL.

- [ ] **Step 4: Commit**

Run:
```bash
git add hw/ip/hflip/rtl/axis_hflip.sv
git commit -m "feat(hflip): implement axis_hflip body

Two-state FSM (RECV/XMIT) over a single H_ACTIVE x 24-bit line buffer;
mirrored read address H_ACTIVE-1-rd_col; SOF latched at write-phase and
re-emitted on first XMIT pixel; EOL on last XMIT beat. enable_i=0 is a
combinational passthrough."
```

---

## Task 6: Python reference model

**Files:**
- Create: `py/models/ops/hflip.py`
- Create: `py/tests/test_hflip.py`

- [ ] **Step 1: Write the failing test**

Create `py/tests/test_hflip.py`:

```python
"""Unit tests for the axis_hflip Python reference model."""

import sys
from pathlib import Path

import numpy as np

# Allow running standalone (mirrors test_morph_open.py setup).
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from models.ops.hflip import hflip


def test_hflip_2d_uint8():
    img = np.array([[1, 2, 3, 4],
                    [5, 6, 7, 8]], dtype=np.uint8)
    expected = np.array([[4, 3, 2, 1],
                         [8, 7, 6, 5]], dtype=np.uint8)
    out = hflip(img)
    assert out.shape == img.shape
    assert out.dtype == img.dtype
    assert np.array_equal(out, expected)


def test_hflip_3d_rgb():
    img = np.zeros((2, 3, 3), dtype=np.uint8)
    img[0, 0] = (255,   0,   0)
    img[0, 1] = (  0, 255,   0)
    img[0, 2] = (  0,   0, 255)
    out = hflip(img)
    assert tuple(out[0, 0]) == (0,   0, 255)
    assert tuple(out[0, 1]) == (0, 255,   0)
    assert tuple(out[0, 2]) == (255, 0,   0)


def test_hflip_idempotent_twice():
    rng = np.random.default_rng(0)
    img = rng.integers(0, 256, size=(8, 16, 3), dtype=np.uint8)
    assert np.array_equal(hflip(hflip(img)), img)


def test_hflip_does_not_mutate_input():
    img = np.arange(24, dtype=np.uint8).reshape(2, 4, 3)
    snapshot = img.copy()
    _ = hflip(img)
    assert np.array_equal(img, snapshot)


if __name__ == "__main__":
    test_hflip_2d_uint8()
    test_hflip_3d_rgb()
    test_hflip_idempotent_twice()
    test_hflip_does_not_mutate_input()
    print("ALL HFLIP MODEL TESTS PASSED")
```

- [ ] **Step 2: Run the test — expect FAIL**

Run:
```bash
.venv/bin/python py/tests/test_hflip.py
```

Expected: `ModuleNotFoundError: No module named 'models.ops.hflip'`.

- [ ] **Step 3: Implement the model**

Create `py/models/ops/hflip.py`:

```python
"""Horizontal flip (hflip) reference model.

Matches axis_hflip RTL: per-row reversal of pixel order, no inter-frame state,
no edge handling needed (single-axis index reversal).
"""

import numpy as np


def hflip(image: np.ndarray) -> np.ndarray:
    """Return a left-to-right mirror of `image`.

    Args:
        image: (H, W) or (H, W, C) numpy array of any dtype.

    Returns:
        New array with axis-1 reversed; input is not mutated.
    """
    return np.ascontiguousarray(np.flip(image, axis=1))
```

- [ ] **Step 4: Run the test — expect PASS**

Run:
```bash
.venv/bin/python py/tests/test_hflip.py
```

Expected: `ALL HFLIP MODEL TESTS PASSED`.

- [ ] **Step 5: Commit**

Run:
```bash
git add py/models/ops/hflip.py py/tests/test_hflip.py
git commit -m "test(hflip): add Python reference model + unit tests

py/models/ops/hflip.py wraps np.flip(axis=1). Unit tests cover 2D, 3D
RGB, double-flip idempotence, and non-mutation."
```

---

## Task 7: Compose `hflip` into the model dispatcher + harness

**Files:**
- Modify: `py/models/__init__.py`
- Modify: `py/harness.py`

- [ ] **Step 1: Add `hflip_en` plumbing to the dispatcher**

Edit `py/models/__init__.py`. Replace the entire file with:

```python
"""Control-flow reference models for pixel-accurate pipeline verification.

Each control flow has its own module with a run() entry point.
Dispatch via run_model() which maps the control flow name to the correct model.

Pipeline-stage flags (e.g. `hflip_en`) are applied in this dispatcher so each
control-flow model only needs to know about its own algorithm.
"""

from models.ops.hflip   import hflip as _hflip
from models.passthrough import run as _run_passthrough
from models.motion      import run as _run_motion
from models.mask        import run as _run_mask
from models.ccl_bbox    import run as _run_ccl_bbox

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
    # Pre-flip frames once at the head of the pipeline. Mirrors the RTL
    # placement: axis_hflip sits before the ctrl_flow mux, so motion masks
    # and bbox coordinates are computed on the flipped view.
    hflip_en = kwargs.pop("hflip_en", False)
    if hflip_en:
        frames = [_hflip(f) for f in frames]
    return _MODELS[ctrl_flow](frames, **kwargs)
```

- [ ] **Step 2: Add `--hflip` CLI argument to `harness.py`**

Edit `py/harness.py`. Three changes:

a) In `cmd_verify` (around line 105), add `hflip_en` after the existing kwarg extractions and pass it to `run_model`:

```python
def cmd_verify(args):
    """Compare RTL output against reference model output."""
    input_frames, output_frames = _load_input_output(args)
    ctrl_flow = args.ctrl_flow
    tolerance = args.tolerance

    alpha_shift = getattr(args, "alpha_shift", 3)
    alpha_shift_slow = getattr(args, "alpha_shift_slow", 6)
    grace_frames = getattr(args, "grace_frames", 0)
    grace_alpha_shift = getattr(args, "grace_alpha_shift", 1)
    gauss_en = bool(getattr(args, "gauss_en", 1))
    morph_en = bool(getattr(args, "morph", 1))
    hflip_en = bool(getattr(args, "hflip", 1))
    expected_frames = run_model(ctrl_flow, input_frames, alpha_shift=alpha_shift,
                                alpha_shift_slow=alpha_shift_slow,
                                grace_frames=grace_frames,
                                grace_alpha_shift=grace_alpha_shift,
                                gauss_en=gauss_en,
                                morph_en=morph_en,
                                hflip_en=hflip_en)
```

b) In `cmd_render` (around line 149), add the same kwarg threading:

```python
def cmd_render(args):
    """Render input vs output comparison grid."""
    input_frames, output_frames = _load_input_output(args)
    ctrl_flow = getattr(args, "ctrl_flow", None)
    alpha_shift = getattr(args, "alpha_shift", 3)
    alpha_shift_slow = getattr(args, "alpha_shift_slow", 6)
    grace_frames = getattr(args, "grace_frames", 0)
    grace_alpha_shift = getattr(args, "grace_alpha_shift", 1)
    gauss_en = bool(getattr(args, "gauss_en", 1))
    morph_en = bool(getattr(args, "morph", 1))
    hflip_en = bool(getattr(args, "hflip", 1))
    reference_frames = None
    if ctrl_flow:
        reference_frames = run_model(ctrl_flow, input_frames, alpha_shift=alpha_shift,
                                     alpha_shift_slow=alpha_shift_slow,
                                     grace_frames=grace_frames,
                                     grace_alpha_shift=grace_alpha_shift,
                                     gauss_en=gauss_en,
                                     morph_en=morph_en,
                                     hflip_en=hflip_en)
```

c) Add the `--hflip` argument to all three subparsers (`prepare`, `verify`, `render`). Inside `main()`, after each existing `--morph` argument addition (one per subparser):

```python
    p_prep.add_argument("--hflip", type=int, default=1, dest="hflip",
                        help="Horizontal flip on/off (0/1, default 1)")
```

```python
    p_ver.add_argument("--hflip", type=int, default=1, dest="hflip",
                       help="Horizontal flip on/off (0/1, default 1)")
```

```python
    p_ren.add_argument("--hflip", type=int, default=1, dest="hflip",
                       help="Horizontal flip on/off (0/1, default 1)")
```

(The `prepare` argument is silently accepted; it does not affect the prepared input file but keeps the CLI surface uniform.)

- [ ] **Step 3: Run existing model tests — expect PASS**

Run:
```bash
make test-py
```

Expected: all existing tests pass — `hflip_en=False` is the default in the dispatcher, so no behaviour changes for callers that omit it.

- [ ] **Step 4: Run the hflip model test directly**

Run:
```bash
.venv/bin/python py/tests/test_hflip.py
```

Expected: `ALL HFLIP MODEL TESTS PASSED`.

- [ ] **Step 5: Commit**

Run:
```bash
git add py/models/__init__.py py/harness.py
git commit -m "feat(hflip): dispatch hflip pre-flip through run_model

Dispatcher applies np.fliplr at the head of the pipeline when
hflip_en=True, so each ctrl_flow model sees the flipped input. Harness
gains --hflip CLI plumbing for prepare/verify/render."
```

---

## Task 8: Top-level RTL integration

**Files:**
- Modify: `hw/top/sparevideo_top.sv`
- Modify: `dv/sv/tb_sparevideo.sv`

- [ ] **Step 1: Add `HFLIP` parameter and integrate `axis_hflip` in `sparevideo_top`**

Edit `hw/top/sparevideo_top.sv`:

a) Add the parameter declaration after the existing `MORPH` parameter (around line 53):

```systemverilog
    // Horizontal mirror (selfie-cam) on the proc_clk pipeline. 1 = mirror
    // (default), 0 = bypass (zero-latency combinational passthrough).
    parameter int HFLIP             = 1
```

b) Bump `IN_FIFO_DEPTH` from 32 to 128 (around line 93). Update both the `localparam` line and the corresponding `IN_FIFO_DEPTH` reference in the SVA `assert_fifo_in_not_full` if any explicit numeric appears (the existing SVAs use `IN_FIFO_DEPTH` symbolically, so only the `localparam` itself changes):

```systemverilog
    localparam int IN_FIFO_DEPTH = 128;
```

c) Insert the `axis_hflip` instantiation between the input async FIFO and the existing `axis_fork`. Locate the comment block just before the `motion_pipe_active`/`fork_s_tvalid` block (around line 269). Add the new module **above** that block, right after the input FIFO instance ends. Specifically, after the closing `);` of `u_fifo_in` (around line 151) and before the existing `localparam int RGN_Y_PREV_BASE = 0;` (line 159), the new block goes lower — right before the `// Top-level fork` comment. Insert:

```systemverilog
    // -----------------------------------------------------------------
    // axis_hflip: horizontal mirror at the head of the proc_clk pipeline.
    //   - Sits before the ctrl_flow mux so motion masks and bbox coords
    //     agree with the user-visible frame.
    //   - enable_i tied to HFLIP at compile time (CSR-ready).
    // -----------------------------------------------------------------
    logic [23:0] flip_tdata;
    logic        flip_tvalid;
    logic        flip_tready;
    logic        flip_tlast;
    logic        flip_tuser;

    axis_hflip #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE)
    ) u_hflip (
        .clk_i           (clk_dsp_i),
        .rst_n_i         (rst_dsp_n_i),
        .enable_i        (1'(HFLIP)),
        .s_axis_tdata_i  (dsp_in_tdata),
        .s_axis_tvalid_i (dsp_in_tvalid),
        .s_axis_tready_o (dsp_in_tready),
        .s_axis_tlast_i  (dsp_in_tlast),
        .s_axis_tuser_i  (dsp_in_tuser),
        .m_axis_tdata_o  (flip_tdata),
        .m_axis_tvalid_o (flip_tvalid),
        .m_axis_tready_i (flip_tready),
        .m_axis_tlast_o  (flip_tlast),
        .m_axis_tuser_o  (flip_tuser)
    );
```

d) **Critical** — `dsp_in_tready` is currently driven combinationally by the ctrl_flow mux (see `always_comb begin case (ctrl_flow_i)` around line 476). With the hflip insert, that signal is now an **input** to `axis_hflip`. Rename the existing mux output and rewire:

   - In each branch of the ctrl_flow mux (lines 478–510), replace every `dsp_in_tready = ...` assignment with `flip_tready = ...`. There are four branches (passthrough, mask_display, ccl_bbox, default/motion). The text changes are:

     ```systemverilog
     // CTRL_PASSTHROUGH:    dsp_in_tready = proc_tready;     →   flip_tready = proc_tready;
     // CTRL_MASK_DISPLAY:   dsp_in_tready = fork_s_tready;   →   flip_tready = fork_s_tready;
     // CTRL_CCL_BBOX:       dsp_in_tready = fork_s_tready;   →   flip_tready = fork_s_tready;
     // default (MOTION):    dsp_in_tready = fork_s_tready;   →   flip_tready = fork_s_tready;
     ```

   - In `CTRL_PASSTHROUGH`, the four `proc_*` assignments must now read from the flipped stream, not raw `dsp_in_*`. Update:

     ```systemverilog
     sparevideo_pkg::CTRL_PASSTHROUGH: begin
         proc_tdata    = flip_tdata;
         proc_tvalid   = flip_tvalid;
         proc_tlast    = flip_tlast;
         proc_tuser    = flip_tuser;
         flip_tready   = proc_tready;
         ovl_tready    = 1'b1;       // fork inactive, no overlay data
     end
     ```

e) Also update the `fork_s_tvalid` assignment and the `axis_fork` instantiation inputs to use the flipped stream. Search for `assign fork_s_tvalid = motion_pipe_active ? dsp_in_tvalid : 1'b0;` (around line 275) and change to:

```systemverilog
    assign fork_s_tvalid = motion_pipe_active ? flip_tvalid : 1'b0;
```

In the `axis_fork` instantiation (around line 277), update the input data/last/user (the `tready` is already `fork_s_tready` and remains so):

```systemverilog
        // Input: gated flipped dsp_in
        .s_axis_tdata_i    (flip_tdata),
        .s_axis_tvalid_i   (fork_s_tvalid),
        .s_axis_tready_o   (fork_s_tready),
        .s_axis_tlast_i    (flip_tlast),
        .s_axis_tuser_i    (flip_tuser),
```

f) **Sanity-check the `dsp_in_tready` driver** — after the change, `dsp_in_tready` should be driven exclusively by `axis_hflip.s_axis_tready_o`. Search the file:

```bash
grep -n "dsp_in_tready" hw/top/sparevideo_top.sv
```

Expected: exactly two hits — one as the `logic` declaration target inside the input FIFO's port list (`m_axis_tready (dsp_in_tready)`), and one as the output of `axis_hflip`. **No other assignments.** If a `dsp_in_tready =` survives in the ctrl_flow mux, lint will catch a multi-driver error — fix immediately.

- [ ] **Step 2: Add `HFLIP` parameter to `tb_sparevideo`**

Edit `dv/sv/tb_sparevideo.sv`:

a) Add the parameter (after the existing `MORPH` line, around 28):

```systemverilog
    parameter int HFLIP             = 1
```

b) Pass it through to the DUT instantiation (after the existing `.MORPH(MORPH)` line around 118):

```systemverilog
        .MORPH             (MORPH),
        .HFLIP             (HFLIP)
```

(Mind the trailing comma on the existing `.MORPH(...)` — it must move to the end of the line.)

c) Add `+HFLIP` to the plusarg comment block at the top of the file (around line 13):

```systemverilog
//   +HFLIP=<n>         Horizontal mirror enable (informational; HFLIP is
//                      a compile-time -G parameter — recompile to change)
```

(No actual `$value$plusargs` parsing needed — `HFLIP` flows in via `-GHFLIP=N` and is fixed for the whole simulation.)

- [ ] **Step 3: Verify all four pre-existing flows still pass with `HFLIP=0`**

This is the integration regression gate.

Run:
```bash
for FLOW in passthrough motion mask ccl_bbox; do
    make run-pipeline CTRL_FLOW=$FLOW SOURCE="synthetic:moving_box" \
                      WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary HFLIP=0
done
```

Expected: each invocation exits 0 and verify reports PASS for all 8 frames. The verify pass is the **first** check — `hflip_en=0` keeps the model identical to its previous behaviour.

- [ ] **Step 4: Byte-diff against the pre-integration golden**

Run:
```bash
for FLOW in passthrough motion mask ccl_bbox; do
    make run-pipeline CTRL_FLOW=$FLOW SOURCE="synthetic:moving_box" \
                      WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary HFLIP=0
    cmp dv/data/output.bin renders/golden/$FLOW-pre-hflip.bin && \
        echo "INTEGRATION GATE: PASS ($FLOW)"
done
```

Expected: four `INTEGRATION GATE: PASS (...)` lines, no `cmp` complaints.

**If `cmp` reports a difference**, the integration has perturbed the pre-existing path. Likely cause: a multi-driver on `dsp_in_tready`, a missing rewire from `dsp_in_*` to `flip_*` in one of the ctrl_flow mux branches, or `enable_i` not honoured. Debug by:

1. `xxd dv/data/output.bin | head -20` vs `xxd renders/golden/<FLOW>-pre-hflip.bin | head -20` — find the first differing byte.
2. Compute its `(frame, row, col, channel)` from the offset: `offset = 12 + ((frame*H*W + row*W + col)*3 + channel)`.
3. If column 0 of every row differs, suspect the SOF/EOL handling in `axis_hflip` (the bypass path may be muxing wrong on first beat). If random pixels differ, suspect a backpressure rewire miss.

- [ ] **Step 5: Run with `HFLIP=1` — verify exact mirror**

Run:
```bash
for FLOW in passthrough motion mask ccl_bbox; do
    make run-pipeline CTRL_FLOW=$FLOW SOURCE="synthetic:moving_box" \
                      WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary HFLIP=1
done
```

Expected: each invocation exits 0; verify reports PASS for all 8 frames at `TOLERANCE=0`. The Python model pre-flips frames, so RTL output (mirrored) matches model output (model also mirrored).

- [ ] **Step 6: Lint**

Run:
```bash
make lint 2>&1 | tail -25
```

Expected: no new warnings attributable to `axis_hflip` or the rewired ctrl_flow mux. A `MULTIDRIVEN` error on `dsp_in_tready` indicates Step 1d/e was incomplete — fix and re-run.

- [ ] **Step 7: Commit**

Run:
```bash
git add hw/top/sparevideo_top.sv dv/sv/tb_sparevideo.sv
git commit -m "feat(top): integrate axis_hflip ahead of ctrl_flow mux

axis_hflip sits between the input CDC FIFO and axis_fork; ctrl_flow mux
now sources passthrough from the flipped stream. IN_FIFO_DEPTH bumped
32 -> 128 so the FIFO can absorb one line of upstream pixels during
hflip's XMIT phase. Tied enable_i to HFLIP build-knob (CSR-ready)."
```

---

## Task 9: Integration regression matrix

**Purpose:** confirm that every (ctrl_flow × HFLIP × MORPH) combination still produces model-matching output at `TOLERANCE=0`. This catches interactions between the new geometric stage and the existing mask / motion paths.

- [ ] **Step 1: Run the matrix**

Run:
```bash
for FLOW in passthrough motion mask ccl_bbox; do
    for HF in 0 1; do
        for MO in 0 1; do
            echo "=== CTRL_FLOW=$FLOW HFLIP=$HF MORPH=$MO ==="
            make run-pipeline CTRL_FLOW=$FLOW HFLIP=$HF MORPH=$MO \
                              SOURCE="synthetic:moving_box" \
                              WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary \
                || { echo "FAILED ($FLOW, HFLIP=$HF, MORPH=$MO)"; exit 1; }
        done
    done
done
echo "ALL CONFIGS PASS"
```

Expected: 16 invocations × 8 frames = 128 verify-PASS lines, then `ALL CONFIGS PASS`.

- [ ] **Step 2: Spot-check a non-default source**

Run with `noisy_moving_box` to exercise the EMA bg path under hflip:

```bash
make run-pipeline CTRL_FLOW=motion HFLIP=1 MORPH=1 \
                  SOURCE="synthetic:noisy_moving_box" \
                  WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary
```

Expected: PASS at `TOLERANCE=0`.

- [ ] **Step 3: Run the full per-block aggregate**

Run:
```bash
make test-ip 2>&1 | tail -10
```

Expected: `All block testbenches passed.` (now includes `test-ip-hflip`).

- [ ] **Step 4: Run all Python tests**

Run:
```bash
make test-py
.venv/bin/python py/tests/test_hflip.py
```

Expected: both report success.

- [ ] **Step 5: Delete the local goldens**

Run:
```bash
rm -f renders/golden/*-pre-hflip.bin
rmdir renders/golden 2>/dev/null || true
```

*(The integration gate has passed; the goldens are no longer needed. Nothing to commit — `renders/` is gitignored.)*

---

## Task 10: Documentation

**Files:**
- Modify: `docs/specs/sparevideo-top-arch.md`
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update `docs/specs/sparevideo-top-arch.md`**

The top-level wiring changed: `axis_hflip` is now in the proc_clk pipeline before the ctrl_flow mux, and `IN_FIFO_DEPTH` grew from 32 to 128. Both must be reflected in the top arch spec. Five edits:

a) **§2 Module Hierarchy** (around line 49) — add `axis_hflip` to the ASCII tree, immediately above `axis_fork`:

```
├── axis_hflip         (u_hflip)         — horizontal mirror at the head of the proc_clk pipeline; runtime bypassable
├── axis_fork          (u_fork)          — 1-to-2 broadcast: fork_a → motion detect, fork_b → overlay
```

b) **§3.1 Parameters** — add a row for `HFLIP` to the parameter table (place it adjacent to the existing `MORPH` row). Use the same column format as the surrounding entries:

```
| `HFLIP`              | `int`        | `1`      | Horizontal mirror runtime enable. `1` = mirror (default), `0` = combinational passthrough. Tied to `axis_hflip.enable_i`. |
```

c) **§4 Concept Description** — add a short paragraph in §4.1 (around line 134, after the existing dual-path description) noting that `axis_hflip` is upstream of the fork, so the motion mask and bbox coordinates are computed on the mirrored view. The user-visible RGB and the mask therefore agree by construction — no coordinate-flip needed in the overlay.

d) **§5 Design Rationale** — add a new subsection between §5.1 and §5.2 (the existing numbering must shift accordingly: old §5.2..§5.7 become §5.3..§5.8). The new §5.2 reads:

```markdown
### 5.2 `u_hflip` — present a "selfie-cam" view to the user

Reads each input line into a 320-entry RGB line buffer, then emits the line in reverse column order. Latency: 1 line. Throughput: 1 pixel/cycle long-term. The stage sits before `u_fork`, so the motion mask and bbox coordinates downstream are computed on the mirrored frame — overlay rectangles land on top of the same pixels the user sees, with no axis-flip math elsewhere.

Why this matters: the natural front-camera mental model is that the user's right hand should appear on the right of the image. Without this stage, that requires either a host-side flip on every consumer or a bbox-coordinate flip in the overlay. Doing the flip once at the head of the pipeline keeps every downstream stage coordinate-consistent. `HFLIP=0` is a zero-latency combinational bypass for testing and for callers that prefer the raw input. Details: [axis_hflip-arch.md](axis_hflip-arch.md).

**Backpressure note:** `axis_hflip` alternates between RECV (asserts `s_axis_tready_o`) and XMIT (asserts `m_axis_tvalid_o`) phases over a single line buffer. During XMIT, upstream is stalled; the input CDC FIFO must absorb up to one line of write-clock pixels. `IN_FIFO_DEPTH = 128` is sized for `pix_clk = 25 MHz`, `dsp_clk = 100 MHz`, `H_ACTIVE = 320` (worst case ~80 entries with margin).
```

e) **§9 Assertions** — the row for `assert_fifo_in_not_full` already references `IN_FIFO_DEPTH` symbolically, so no row text changes. **However**, if §3.1 (Parameters) or §6 (Internal Architecture) lists a literal `IN_FIFO_DEPTH = 32`, change it to `IN_FIFO_DEPTH = 128`. Search for the literal:

```bash
grep -n "IN_FIFO_DEPTH" docs/specs/sparevideo-top-arch.md
```

Update every numeric literal `32` adjacent to `IN_FIFO_DEPTH` to `128`.

- [ ] **Step 2: Update `README.md`**

Open `README.md`. Four changes:

a) In the arch-docs table (find the row for `axis_window3x3-arch.md`), add a new row **above** it:

```
| [`axis_hflip-arch.md`](docs/specs/axis_hflip-arch.md) | Horizontal mirror (selfie-cam) AXIS stage with single line buffer + `enable_i` bypass |
```

b) In the `hw/ip/` tree listing, add a block **above** `hw/ip/window/rtl/`:

```
hw/ip/hflip/rtl/
└── axis_hflip.sv             Horizontal mirror (selfie-cam) — single line buffer, RECV/XMIT FSM, enable_i bypass
```

And in the `hw/ip/*/tb/` listing, add:

```
hw/ip/hflip/tb/
└── tb_axis_hflip.sv          5 tests: gradient mirror, multi-frame SOF, downstream stall, in-row tvalid bubble, enable_i passthrough
```

c) In the `make test-ip-*` examples block, add **above** `make test-ip-window`:

```
make test-ip-hflip           # axis_hflip: 5 tests, mirror correctness, asymmetric stall, enable_i passthrough
```

d) In the build-options table / list (search for the `MORPH=` row), add:

```
HFLIP=1                          Horizontal mirror on/off (default 1, 0 = bypass)
```

- [ ] **Step 3: Update `CLAUDE.md`**

Open `CLAUDE.md`:

a) In the "Project Structure" bullet list, add a new bullet **above** `hw/ip/window/rtl/`:

```
- `hw/ip/hflip/rtl/` — Horizontal mirror (axis_hflip: single line buffer + RECV/XMIT FSM + enable_i bypass; runtime knob via top-level HFLIP parameter)
```

b) In the "Build Commands" section under the existing `MORPH=` examples, add **above** the `# Other targets` section:

```bash
# Horizontal mirror (selfie-cam). Default HFLIP=1; 0 = bypass.
make run-pipeline HFLIP=0                                # bypass (no flip)
make run-pipeline HFLIP=1                                # mirror (default)
```

- [ ] **Step 4: Commit**

Run:
```bash
git add docs/specs/sparevideo-top-arch.md README.md CLAUDE.md
git commit -m "docs(hflip): top-arch + README + CLAUDE updates for axis_hflip"
```

- [ ] **Step 5: Final `git status` check**

Run:
```bash
git status
```

Expected: working tree clean (the gitignored `renders/golden/` from Task 1 is gone or still ignored).

---

## Self-Review Checklist (post-execution)

Run these after the plan is fully executed, before squashing and opening the PR:

- [ ] `make test-ip` passes (all per-block TBs, including `test-ip-hflip`).
- [ ] `make lint` passes with no new HFLIP-attributable warnings (or only via documented waivers).
- [ ] `make test-py` passes.
- [ ] `.venv/bin/python py/tests/test_hflip.py` reports `ALL HFLIP MODEL TESTS PASSED`.
- [ ] The 16-config matrix in Task 9 Step 1 ran end-to-end with `ALL CONFIGS PASS`.
- [ ] `git log --oneline -10` shows a clean sequence of focused commits (arch doc → scaffold → TB → body → model → dispatcher → top integration → docs).
- [ ] No file under `hw/ip/hflip/`, `py/models/ops/hflip.py`, or the new top-level wiring contains `TODO` / `FIXME` / dead code.
- [ ] `grep -n "dsp_in_tready" hw/top/sparevideo_top.sv` shows exactly two hits (FIFO output + axis_hflip input).
- [ ] `IN_FIFO_DEPTH = 128` in `hw/top/sparevideo_top.sv`.
- [ ] CLAUDE.md and README.md mention `HFLIP` and the new IP folder.

When all boxes are ticked, squash the plan's commits per CLAUDE.md ("squash at plan completion") into one:

```bash
git rebase -i origin/main   # squash to a single commit
git commit --amend          # write a stand-alone description
```

Then open the PR. The commit message should reference `docs/plans/2026-04-25-axis-hflip-plan.md` and note that it implements §3.1 of `2026-04-23-pipeline-extensions-design.md`.

After merge, move this plan to `docs/plans/old/` per CLAUDE.md ("After implementing a plan, move it to docs/plans/old/").
