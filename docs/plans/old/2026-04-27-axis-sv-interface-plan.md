# AXI-Stream SV Interface Conversion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace flat AXI4-Stream ports across the project with a SystemVerilog `interface` (`axis_if`); promote the `axis_ccl` → `axis_overlay_bbox` bbox sideband to its own `bbox_if`; convert all unit and integration testbenches to match; formally remove Icarus Verilog support.

**Architecture:** Two `interface` declarations live in `hw/top/sparevideo_if.sv` alongside the existing `sparevideo_pkg`. A single thin wrapper (`axis_async_fifo_ifc`) adapts the vendored `verilog-axis` `axis_async_fifo` from flat ports + active-high reset to interface ports + active-low reset. Conversion is **mechanical** — a uniform port-shape change with no logic edits — so it proceeds module-by-module while the integration test stays runnable throughout, using temporary adapter glue inside `sparevideo_top.sv` that collapses as adjacent modules convert.

**Tech Stack:** SystemVerilog (synthesis-style; no SVA/classes), Verilator 5+, Icarus removed, FuseSoC `.core` filesets, project Make targets (`make lint`, `make test-ip-*`, `make sim`, `make run-pipeline`).

**Source spec:** [docs/plans/2026-04-27-axis-sv-interface-design.md](2026-04-27-axis-sv-interface-design.md) (commit `35eb636`).

**Branch:** `refactor/axis-sv-interface` (already created, off `origin/main`).

---

## Module conversion order (Phase 2)

Ordered to minimize internal adapter glue inside any module that instantiates other AXIS modules:

| Task | Module(s) | Why this position |
|---|---|---|
| 3 | `axis_fork` | broadcast utility, no internal AXIS deps |
| 4 | `axis_hflip` | leaf, no internal AXIS deps |
| 5 | `axis_motion_detect` | leaf (motion_core is combinational, not AXIS) |
| 6 | `axis_morph3x3_erode` + `_dilate` + `_open` | converted **together** in one task. erode and dilate are leaves, but `axis_morph3x3_open` instantiates both internally — converting them separately would leave `_open` with port-mismatched internal instantiations and break `make lint`. Bundling them keeps lint clean at every commit. |
| 7 | `axis_ccl` | introduces the new `bbox_if.tx` |
| 8 | `axis_overlay_bbox` | consumes the new `bbox_if.rx` |

After Phase 2, all leaf IPs use interfaces but `sparevideo_top.sv` still has accumulated adapter glue around every IP instantiation. Phase 3 collapses that glue.

---

## The conversion mechanics (referenced from every Phase-2 task)

### Module signature transformation

```sv
// before:
module FOO #(...) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    input  logic [W-1:0] s_axis_tdata_i,
    input  logic         s_axis_tvalid_i,
    output logic         s_axis_tready_o,
    input  logic         s_axis_tlast_i,
    input  logic         s_axis_tuser_i,

    output logic [W-1:0] m_axis_tdata_o,
    output logic         m_axis_tvalid_o,
    input  logic         m_axis_tready_i,
    output logic         m_axis_tlast_o,
    output logic         m_axis_tuser_o,

    /* any non-AXIS sideband stays as-is */
);

// after:
module FOO #(...) (
    input  logic clk_i,
    input  logic rst_n_i,

    axis_if.rx   s_axis,
    axis_if.tx   m_axis,

    /* any non-AXIS sideband stays as-is */
);
```

### Body rename pattern (uniform across every Phase-2 task)

| Flat-port symbol | Interface reference |
|---|---|
| `s_axis_tdata_i`  | `s_axis.tdata`  |
| `s_axis_tvalid_i` | `s_axis.tvalid` |
| `s_axis_tready_o` | `s_axis.tready` |
| `s_axis_tlast_i`  | `s_axis.tlast`  |
| `s_axis_tuser_i`  | `s_axis.tuser`  |
| `m_axis_tdata_o`  | `m_axis.tdata`  |
| `m_axis_tvalid_o` | `m_axis.tvalid` |
| `m_axis_tready_i` | `m_axis.tready` |
| `m_axis_tlast_o`  | `m_axis.tlast`  |
| `m_axis_tuser_o`  | `m_axis.tuser`  |

`axis_fork` has two TX ports; the convention extends naturally: the flat `m_a_axis_*_o` group becomes `axis_if.tx m_a_axis` and `m_b_axis_*_o` becomes `axis_if.tx m_b_axis` (preserving the existing `m_a_` / `m_b_` prefix). Body renames: `m_a_axis_tvalid_o` → `m_a_axis.tvalid`, `m_b_axis_tready_i` → `m_b_axis.tready`, etc.

### Top-level adapter-glue pattern (used in Phase 2, removed in Phase 3)

When converting an IP whose neighbours are still flat, declare an `axis_if` instance per side and bridge it to the existing flat wires with `assign`s:

```sv
// in sparevideo_top.sv, around the converted IP "u_foo":
axis_if #(.DATA_W(24), .USER_W(1)) u_foo_in_axis ();
assign u_foo_in_axis.tdata  = upstream_tdata;     // flat → interface
assign u_foo_in_axis.tvalid = upstream_tvalid;
assign u_foo_in_axis.tlast  = upstream_tlast;
assign u_foo_in_axis.tuser  = upstream_tuser;
assign upstream_tready      = u_foo_in_axis.tready;  // interface → flat back-pressure

axis_if #(.DATA_W(24), .USER_W(1)) u_foo_out_axis ();
assign downstream_tdata     = u_foo_out_axis.tdata;  // interface → flat
assign downstream_tvalid    = u_foo_out_axis.tvalid;
assign downstream_tlast     = u_foo_out_axis.tlast;
assign downstream_tuser     = u_foo_out_axis.tuser;
assign u_foo_out_axis.tready = downstream_tready;    // flat → interface back-pressure

axis_foo u_foo (
    .clk_i   (clk_proc),
    .rst_n_i (rst_n_proc),
    .s_axis  (u_foo_in_axis),
    .m_axis  (u_foo_out_axis),
    /* sideband ports unchanged */
);
```

This glue is throwaway. As the upstream and downstream IPs convert in subsequent tasks, the flat wires they used vanish and the glue is replaced by direct interface pass-through (Phase 3, Task 9).

### Per-IP unit TB transformation

```sv
// before:
logic [W-1:0] drv_tdata;
logic         drv_tvalid;
// ...

logic [W-1:0] s_axis_tdata;
logic         s_axis_tvalid;
// ... (one register per signal)

always_ff @(negedge clk) begin
    s_axis_tdata  <= drv_tdata;
    s_axis_tvalid <= drv_tvalid;
end

dut u_dut (
    .s_axis_tdata_i  (s_axis_tdata),
    .s_axis_tvalid_i (s_axis_tvalid),
    .s_axis_tready_o (s_axis_tready),
    /* ... */
);

// after:
logic [W-1:0] drv_tdata;
logic         drv_tvalid;
// ... (drv_* unchanged)

axis_if #(.DATA_W(W), .USER_W(1)) s_axis ();

always_ff @(negedge clk) begin
    s_axis.tdata  <= drv_tdata;
    s_axis.tvalid <= drv_tvalid;
    /* ... */
end

dut u_dut (
    .s_axis (s_axis),
    /* ... */
);
```

The `drv_*` + negedge-driver pattern (CLAUDE.md "Verilator INITIALDLY race") is preserved. Output capture (`cap_*` regs sampled on negedge from `m_axis.tdata`) follows the symmetric pattern.

---

## Task 0: Verify clean starting state

**Files:** none modified.

- [ ] **Step 1: Confirm branch and tip**

```bash
git branch --show-current
# Expected: refactor/axis-sv-interface

git log -1 --oneline
# Expected: 35eb636 docs(plans): SV interface conversion for AXI-Stream — design
```

- [ ] **Step 2: Establish baseline — lint clean, all unit TBs pass, integration sim passes**

```bash
make lint
# Expected: no warnings/errors

make test-ip
# Expected: all 11 per-IP TBs pass

make sim
# Expected: passthrough sim runs end-to-end, output matches input
```

If any baseline command fails, STOP — do not start the conversion against a broken baseline. Fix or report the unrelated failure first.

---

## Task 1: Create `sparevideo_if.sv` (interface declarations)

**Files:**
- Create: `hw/top/sparevideo_if.sv`
- Modify: `hw/top/pkg.core`

- [ ] **Step 1: Write the interface file**

Create `hw/top/sparevideo_if.sv` with **exactly** this content:

```sv
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Project-wide SystemVerilog interfaces.
//
// Two top-level interface declarations live in this single file, mirroring the
// one-file pattern of sparevideo_pkg.sv. Both interfaces follow a uniform
// modport convention:
//
//   tx  — produces the bundle (drives data, reads back-pressure where present)
//   rx  — consumes the bundle (reads data, drives back-pressure where present)
//   mon — passive observer (all signals input); for testbench monitors
//
// Convention: clk/rst_n are NOT carried inside the interface. They remain
// explicit clk_i/rst_n_i ports on every module so that
//   (a) the project's existing port-naming convention is preserved, and
//   (b) a single interface bundle can cross a clock domain (e.g. the producer
//       is in clk_pix and the consumer in clk_proc, with axis_async_fifo_ifc
//       between them) without ambiguity about which clock owns the interface.

// AXI4-Stream — minimal subset used by this project (tdata, tvalid, tready,
// tlast, tuser). Add tkeep / tdest / tid here when an actual consumer needs
// them; do not pre-add. USER_W defaults to 1 to match the SOF semantics used
// by every current AXI-Stream stage in the pipeline.
interface axis_if #(
    parameter int DATA_W = 24,
    parameter int USER_W = 1
);
    logic [DATA_W-1:0] tdata;
    logic              tvalid;
    logic              tready;
    logic              tlast;
    logic [USER_W-1:0] tuser;

    modport tx  (output tdata, tvalid, tlast, tuser, input  tready);
    modport rx  (input  tdata, tvalid, tlast, tuser, output tready);
    modport mon (input  tdata, tvalid, tready, tlast, tuser);
endinterface

// Sideband bbox bundle from axis_ccl to axis_overlay_bbox. N_OUT slots, each
// with a valid bit and four coordinates. Latched per-frame, not per-beat —
// hence no handshake signals on this interface.
interface bbox_if #(
    parameter int N_OUT = sparevideo_pkg::CCL_N_OUT,
    parameter int H_W   = $clog2(sparevideo_pkg::H_ACTIVE),
    parameter int V_W   = $clog2(sparevideo_pkg::V_ACTIVE)
);
    logic [N_OUT-1:0]           valid;
    logic [N_OUT-1:0][H_W-1:0]  min_x;
    logic [N_OUT-1:0][H_W-1:0]  max_x;
    logic [N_OUT-1:0][V_W-1:0]  min_y;
    logic [N_OUT-1:0][V_W-1:0]  max_y;

    modport tx  (output valid, min_x, max_x, min_y, max_y);
    modport rx  (input  valid, min_x, max_x, min_y, max_y);
    modport mon (input  valid, min_x, max_x, min_y, max_y);
endinterface
```

- [ ] **Step 2: Add the file to `pkg.core`**

Edit `hw/top/pkg.core`. Replace the file list block to add `sparevideo_if.sv`:

```
filesets:
  files_rtl:
    files:
      - sparevideo_pkg.sv
      - sparevideo_if.sv
    file_type: systemVerilogSource
```

- [ ] **Step 3: Lint the new file**

```bash
make lint
# Expected: no warnings/errors. Adding interfaces with no consumers is benign.
```

- [ ] **Step 4: Commit**

```bash
git add hw/top/sparevideo_if.sv hw/top/pkg.core
git commit -m "feat(sparevideo_if): add axis_if and bbox_if interfaces (no consumers)"
```

---

## Task 2: Create `axis_async_fifo_ifc.sv` (vendored FIFO wrapper)

**Files:**
- Create: `hw/ip/axis/rtl/axis_async_fifo_ifc.sv`
- Modify: `hw/ip/axis/axis.core`

- [ ] **Step 1: Write the wrapper file**

Create `hw/ip/axis/rtl/axis_async_fifo_ifc.sv` with **exactly** this content:

```sv
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Interface-port wrapper around the vendored verilog-axis axis_async_fifo.
// The vendored core uses flat ports and active-high reset; this wrapper
// adapts both to the project conventions (interface bundles + active-low
// rst_n_i) without modifying the vendored source.

module axis_async_fifo_ifc #(
    parameter int DEPTH          = 1024,
    parameter int DATA_W         = 24,
    parameter int USER_W         = 1,
    parameter int RAM_PIPELINE   = 2,
    parameter bit FRAME_FIFO     = 1'b0,
    parameter bit DROP_BAD_FRAME = 1'b0,
    parameter bit DROP_WHEN_FULL = 1'b0
) (
    input  logic                       s_clk,
    input  logic                       s_rst_n,
    input  logic                       m_clk,
    input  logic                       m_rst_n,

    axis_if.rx                         s_axis,
    axis_if.tx                         m_axis,

    // Status / occupancy. Width follows the vendored core ($clog2(DEPTH)+1).
    // Note (per CLAUDE.md): these depths do NOT include the internal output
    // pipeline FIFO (~16 entries with default RAM_PIPELINE=2). Do not use
    // them as the sole signal for tight back-pressure thresholds.
    output logic [$clog2(DEPTH):0]     s_status_depth,
    output logic [$clog2(DEPTH):0]     m_status_depth
);

    // Adapt project-convention active-low reset to the vendored active-high.
    logic s_rst, m_rst;
    assign s_rst = ~s_rst_n;
    assign m_rst = ~m_rst_n;

    axis_async_fifo #(
        .DEPTH         (DEPTH),
        .DATA_WIDTH    (DATA_W),
        .USER_ENABLE   (1),
        .USER_WIDTH    (USER_W),
        .RAM_PIPELINE  (RAM_PIPELINE),
        .FRAME_FIFO    (FRAME_FIFO),
        .DROP_BAD_FRAME(DROP_BAD_FRAME),
        .DROP_WHEN_FULL(DROP_WHEN_FULL)
    ) u_fifo (
        .s_clk          (s_clk),
        .s_rst          (s_rst),
        .s_axis_tdata   (s_axis.tdata),
        .s_axis_tvalid  (s_axis.tvalid),
        .s_axis_tready  (s_axis.tready),
        .s_axis_tlast   (s_axis.tlast),
        .s_axis_tuser   (s_axis.tuser),
        .s_status_depth (s_status_depth),

        .m_clk          (m_clk),
        .m_rst          (m_rst),
        .m_axis_tdata   (m_axis.tdata),
        .m_axis_tvalid  (m_axis.tvalid),
        .m_axis_tready  (m_axis.tready),
        .m_axis_tlast   (m_axis.tlast),
        .m_axis_tuser   (m_axis.tuser),
        .m_status_depth (m_status_depth)
    );

endmodule
```

- [ ] **Step 2: Update `hw/ip/axis/axis.core`**

Add the new file and add a dependency on `sparevideo:pkg:common` (so the interface declarations are in scope) and `sparevideo:third_party:verilog-axis` (the vendored core).

Replace the entire file with:

```
CAPI=2:
name: "sparevideo:ip:axis"
description: "Reusable AXI4-Stream utilities — axis_fork, axis_async_fifo_ifc"

filesets:
  files_rtl:
    files:
      - rtl/axis_fork.sv
      - rtl/axis_async_fifo_ifc.sv
    file_type: systemVerilogSource
    depend:
      - sparevideo:pkg:common
      - sparevideo:third_party:verilog-axis

targets:
  default:
    filesets:
      - files_rtl
```

- [ ] **Step 3: Lint**

```bash
make lint
# Expected: no warnings/errors. Wrapper exists but is not yet instantiated anywhere.
```

- [ ] **Step 4: Commit**

```bash
git add hw/ip/axis/rtl/axis_async_fifo_ifc.sv hw/ip/axis/axis.core
git commit -m "feat(axis): add axis_async_fifo_ifc — interface wrapper for vendored async FIFO"
```

---

## Task 3: Convert `axis_fork`

**Files:**
- Modify: `hw/ip/axis/rtl/axis_fork.sv`
- Modify: `hw/top/sparevideo_top.sv` (add adapter glue around `u_fork`)
- (No unit TB exists for `axis_fork`.)

- [ ] **Step 1: Convert `axis_fork.sv` to interface ports**

Read the current file at `hw/ip/axis/rtl/axis_fork.sv`. Apply the conversion mechanics from the top of this plan:

- Replace the flat sink port group with `axis_if.rx s_axis`.
- Replace the flat `m_a_axis_*_o` group with `axis_if.tx m_a_axis`.
- Replace the flat `m_b_axis_*_o` group with `axis_if.tx m_b_axis`.
- Inside the body: `s_axis_tdata_i` → `s_axis.tdata`, `m_a_axis_tvalid_o` → `m_a_axis.tvalid`, `m_b_axis_tready_i` → `m_b_axis.tready`, etc. — uniform rename per the body rename pattern.
- `clk_i` and `rst_n_i` ports unchanged.
- The internal `a_accepted` / `b_accepted` registers and the per-output acceptance logic are unchanged (CLAUDE.md "1-to-N output forks at the top level must use per-output acceptance tracking" — this is already correct in `axis_fork`).

- [ ] **Step 2: Update `sparevideo_top.sv` to wrap `u_fork` with adapter glue**

Locate the `axis_fork u_fork (...)` instantiation (around line 315–340). Wrap the three sides with `axis_if` instances bridged to the existing flat wires:

```sv
axis_if #(.DATA_W(24), .USER_W(1)) u_fork_in_axis ();
assign u_fork_in_axis.tdata  = <upstream_tdata>;
assign u_fork_in_axis.tvalid = <upstream_tvalid>;
assign u_fork_in_axis.tlast  = <upstream_tlast>;
assign u_fork_in_axis.tuser  = <upstream_tuser>;
assign <upstream_tready>     = u_fork_in_axis.tready;

axis_if #(.DATA_W(24), .USER_W(1)) u_fork_a_axis ();
assign <a_downstream_tdata>  = u_fork_a_axis.tdata;
assign <a_downstream_tvalid> = u_fork_a_axis.tvalid;
assign <a_downstream_tlast>  = u_fork_a_axis.tlast;
assign <a_downstream_tuser>  = u_fork_a_axis.tuser;
assign u_fork_a_axis.tready  = <a_downstream_tready>;

axis_if #(.DATA_W(24), .USER_W(1)) u_fork_b_axis ();
assign <b_downstream_tdata>  = u_fork_b_axis.tdata;
assign <b_downstream_tvalid> = u_fork_b_axis.tvalid;
assign <b_downstream_tlast>  = u_fork_b_axis.tlast;
assign <b_downstream_tuser>  = u_fork_b_axis.tuser;
assign u_fork_b_axis.tready  = <b_downstream_tready>;

axis_fork #(
    .DATA_WIDTH(24), .USER_WIDTH(1)
) u_fork (
    .clk_i    (clk_proc),
    .rst_n_i  (rst_n_proc),
    .s_axis   (u_fork_in_axis),
    .m_a_axis (u_fork_a_axis),
    .m_b_axis (u_fork_b_axis)
);
```

Replace each `<...>` placeholder with the actual flat-wire name from the existing `u_fork` connection in `sparevideo_top.sv` (e.g. the existing `.s_axis_tdata_i (dsp_in_tdata)` becomes `assign u_fork_in_axis.tdata = dsp_in_tdata;`). Keep all parameter overrides identical to the existing instantiation.

- [ ] **Step 3: Lint**

```bash
make lint
# Expected: clean.
```

- [ ] **Step 4: Run integration sim (passthrough)**

```bash
make sim
# Expected: passes — pixel-accurate match. Behaviour is unchanged; this is a pure structural rewrap.
```

- [ ] **Step 5: Run motion-mode integration sim (exercises u_fork's two-output path under realistic backpressure)**

```bash
make run-pipeline CTRL_FLOW=motion CFG=default SOURCE=synthetic:moving_box FRAMES=4
# Expected: TOLERANCE=0 match against the Python reference model.
```

- [ ] **Step 6: Commit**

```bash
git add hw/ip/axis/rtl/axis_fork.sv hw/top/sparevideo_top.sv
git commit -m "refactor(axis_fork): convert AXIS ports to axis_if; glue at top"
```

---

## Task 4: Convert `axis_hflip`

**Files:**
- Modify: `hw/ip/hflip/rtl/axis_hflip.sv`
- Modify: `hw/ip/hflip/tb/tb_axis_hflip.sv`
- Modify: `hw/top/sparevideo_top.sv` (add adapter glue around `u_hflip` if not already present from Task 3 collapsing)
- Modify: `hw/ip/hflip/hflip.core` (add `sparevideo:pkg:common` dependency)

- [ ] **Step 1: Convert `axis_hflip.sv` RTL to interface ports**

Read the current file at `hw/ip/hflip/rtl/axis_hflip.sv`. Apply the conversion mechanics from the top of this plan: replace the flat `s_axis_*_i` group with `axis_if.rx s_axis`, the flat `m_axis_*_o` group with `axis_if.tx m_axis`. The `enable_i` sideband port stays as-is. Inside the body, rename every `s_axis_tdata_i` → `s_axis.tdata`, etc., per the body rename pattern table.

- [ ] **Step 2: Update `hflip.core` to depend on `sparevideo:pkg:common`**

Replace the entire file with:

```
CAPI=2:
name: "sparevideo:ip:hflip"
description: "Horizontal mirror (selfie-cam) AXIS stage with single line buffer + enable_i bypass"

filesets:
  files_rtl:
    files:
      - rtl/axis_hflip.sv
    file_type: systemVerilogSource
    depend:
      - sparevideo:pkg:common

targets:
  default:
    filesets:
      - files_rtl
```

- [ ] **Step 3: Convert `tb_axis_hflip.sv`**

Read the current TB. Replace the flat DUT-input registers (`s_axis_tdata`, `s_axis_tvalid`, `s_axis_tready`, `s_axis_tlast`, `s_axis_tuser`, `m_axis_tdata`, etc.) with two `axis_if` declarations:

```sv
axis_if #(.DATA_W(24), .USER_W(1)) s_axis ();
axis_if #(.DATA_W(24), .USER_W(1)) m_axis ();
```

- All `drv_*` regs are kept exactly as-is (drv pattern from CLAUDE.md is preserved).
- The negedge `always_ff` block that drove flat regs now drives the interface signals: `s_axis.tdata <= drv_tdata;` etc.
- Capture path: replace the flat `m_axis_tready` driver with `assign m_axis.tready = drv_m_tready;` (or whichever stall pattern the TB uses) and sample `m_axis.tdata` / `m_axis.tvalid` etc. on negedge into `cap_*` regs.
- DUT instantiation collapses to `.s_axis (s_axis), .m_axis (m_axis), .enable_i (enable), .clk_i (clk), .rst_n_i (rst_n)`.

- [ ] **Step 4: Update `sparevideo_top.sv` glue around `u_hflip`**

The `u_hflip` instantiation lives near line 212. Apply the top-level adapter-glue pattern from the top of this plan: declare `u_hflip_in_axis` and `u_hflip_out_axis` as `axis_if` instances, bridge them to the surrounding flat wires, and pass them into the `u_hflip` instantiation.

- [ ] **Step 5: Lint**

```bash
make lint
# Expected: clean.
```

- [ ] **Step 6: Run the unit TB**

```bash
make test-ip-hflip
# Expected: all 5 tests pass (mirror correctness, asymmetric stall, enable_i passthrough).
```

- [ ] **Step 7: Run integration sim**

```bash
make sim
# Expected: passes.

make run-pipeline CTRL_FLOW=motion CFG=default_hflip SOURCE=synthetic:moving_box FRAMES=4
# Expected: TOLERANCE=0 match (this profile enables hflip).
```

- [ ] **Step 8: Commit**

```bash
git add hw/ip/hflip/rtl/axis_hflip.sv hw/ip/hflip/tb/tb_axis_hflip.sv hw/ip/hflip/hflip.core hw/top/sparevideo_top.sv
git commit -m "refactor(axis_hflip): convert AXIS ports + TB to axis_if"
```

---

## Task 5: Convert `axis_motion_detect`

**Files:**
- Modify: `hw/ip/motion/rtl/axis_motion_detect.sv`
- Modify: `hw/ip/motion/tb/tb_axis_motion_detect.sv`
- Modify: `hw/top/sparevideo_top.sv` (glue around `u_motion`)
- (`motion.core` already depends on `sparevideo:pkg:common` — no `.core` change.)

- [ ] **Step 1: Convert `axis_motion_detect.sv` RTL**

The module has one rx (24-bit RGB) and one tx (1-bit mask). Apply the conversion mechanics. The non-AXIS sideband (RAM read/write ports `mem_rd_*` / `mem_wr_*`) and parameter list (`THRESH`, `ALPHA_SHIFT`, etc.) stay as-is.

The body has multiple references to each AXI signal name. The CLAUDE.md "Pipeline stall pitfalls" §1–6 invariants are about behavior — they are preserved automatically by the rename. In particular:
- `held_tdata` register and the MUX (pitfall §2) keep referring to the same input signal under its new name `s_axis.tdata`.
- `pix_addr_hold` register driven by `!pipe_stall` (pitfall §3) is unchanged.
- `mem_wr_en = pipe_valid && m_axis_msk_tready_i` (pitfall §4) becomes `mem_wr_en = pipe_valid && m_axis.tready` — same behavior.
- `pipe_stall = tvalid_pipe[PIPE_STAGES-1] && !both_done` (pitfall §1) — unchanged.

- [ ] **Step 2: Convert `tb_axis_motion_detect.sv`**

The TB drives an RGB rx stream and captures a 1-bit mask tx stream. Apply the per-IP unit TB transformation. Both streams get their own `axis_if` declaration:

```sv
axis_if #(.DATA_W(24), .USER_W(1)) s_axis_rgb  ();
axis_if #(.DATA_W(1),  .USER_W(1)) m_axis_msk  ();
```

The frame-stall and fork-desync test patterns from CLAUDE.md ("Unit-test fork consumer stalls explicitly — including asymmetric stalls") are preserved — they're behavioral.

- [ ] **Step 3: Update `sparevideo_top.sv` glue around `u_motion`**

The `u_motion` instantiation is near line 340. Apply the top-level adapter-glue pattern. Note: the rx side connects to fork-A (which is now interface-typed from Task 3), so the rx-side glue may already collapse to a direct interface pass-through (no wire bridging needed — just pass `u_fork_a_axis` directly as `.s_axis`). The tx side (1-bit mask) still bridges to flat wires consumed downstream by morph_open.

- [ ] **Step 4: Lint**

```bash
make lint
# Expected: clean.
```

- [ ] **Step 5: Run the unit TBs (both gauss-on and gauss-off variants)**

```bash
make test-ip-motion-detect
make test-ip-motion-detect-gauss
# Expected: both pass — 8-frame golden model match, stall and fork desync coverage.
```

- [ ] **Step 6: Run integration sim across motion profiles**

```bash
make run-pipeline CTRL_FLOW=motion  CFG=default  SOURCE=synthetic:moving_box       FRAMES=4
make run-pipeline CTRL_FLOW=motion  CFG=no_ema   SOURCE=synthetic:noisy_moving_box FRAMES=4
# Expected: TOLERANCE=0 match against the Python reference model in both cases.
```

- [ ] **Step 7: Commit**

```bash
git add hw/ip/motion/rtl/axis_motion_detect.sv hw/ip/motion/tb/tb_axis_motion_detect.sv hw/top/sparevideo_top.sv
git commit -m "refactor(axis_motion_detect): convert AXIS ports + TB to axis_if"
```

---

## Task 6: Convert `axis_morph3x3_erode`, `_dilate`, and `_open` together

**Files:**
- Modify: `hw/ip/filters/rtl/axis_morph3x3_erode.sv`
- Modify: `hw/ip/filters/rtl/axis_morph3x3_dilate.sv`
- Modify: `hw/ip/filters/rtl/axis_morph3x3_open.sv`
- Modify: `hw/ip/filters/tb/tb_axis_morph3x3_erode.sv`
- Modify: `hw/ip/filters/tb/tb_axis_morph3x3_dilate.sv`
- Modify: `hw/ip/filters/tb/tb_axis_morph3x3_open.sv`
- Modify: `hw/ip/filters/filters.core` (add `sparevideo:pkg:common`)
- Modify: `hw/top/sparevideo_top.sv` (glue around `u_morph_open`)

The three morphology RTL files convert in one task because `axis_morph3x3_open` instantiates erode and dilate internally; converting any one in isolation leaves the others' instantiation port-mismatched and breaks `make lint`.

- [ ] **Step 1: Convert `axis_morph3x3_erode.sv`**

DATA_W=1. Apply the conversion mechanics from the top of this plan: replace the flat `s_axis_*_i` group with `axis_if.rx s_axis`, the flat `m_axis_*_o` group with `axis_if.tx m_axis`. Body: rename every `s_axis_tdata_i` → `s_axis.tdata` etc. per the body rename pattern table. The `enable_i` bypass and the internal connection to `axis_window3x3` (window-style — leave its flat ports alone, pass `s_axis.tdata` etc. into them) are unchanged.

- [ ] **Step 2: Convert `axis_morph3x3_dilate.sv`**

DATA_W=1. Apply the same conversion pattern as Step 1: replace the flat `s_axis_*_i` group with `axis_if.rx s_axis`, the flat `m_axis_*_o` group with `axis_if.tx m_axis`, rename body references identically, leave `axis_window3x3` instantiation untouched.

- [ ] **Step 3: Convert `axis_morph3x3_open.sv`**

The module has one rx (1-bit mask) and one tx (1-bit mask), plus an internal stage chain `axis_morph3x3_erode` → `axis_morph3x3_dilate`. Apply the conversion mechanics to the external rx/tx ports as in Step 1. For the internal chain:

- Declare an internal `axis_if #(.DATA_W(1), .USER_W(1)) erode_to_dilate ();` to carry the intermediate stream.
- Wire `s_axis` → erode's `.s_axis`, erode's `.m_axis` → `erode_to_dilate`, `erode_to_dilate` → dilate's `.s_axis`, dilate's `.m_axis` → `m_axis`.
- The `enable_i` bypass logic stays as-is.

- [ ] **Step 4: Update `hw/ip/filters/filters.core`**

Add `sparevideo:pkg:common` to the dependency list. Replace the file with:

```
CAPI=2:
name: "sparevideo:ip:filters"
description: "Spatial filters over the shared axis_window3x3 primitive (Gaussian, morphological erode/dilate/open)"

filesets:
  files_rtl:
    files:
      - rtl/axis_gauss3x3.sv
      - rtl/axis_morph3x3_dilate.sv
      - rtl/axis_morph3x3_erode.sv
      - rtl/axis_morph3x3_open.sv
    file_type: systemVerilogSource
    depend:
      - sparevideo:pkg:common
      - sparevideo:ip:window

targets:
  default:
    filesets:
      - files_rtl
```

- [ ] **Step 5: Convert all three unit TBs**

For each of `tb_axis_morph3x3_erode.sv`, `tb_axis_morph3x3_dilate.sv`, `tb_axis_morph3x3_open.sv`, apply the per-IP unit TB transformation from the top of this plan:

- Replace the flat `s_axis_tdata` / `s_axis_tvalid` / etc. registers with `axis_if #(.DATA_W(1), .USER_W(1)) s_axis ();`.
- Replace the flat `m_axis_*` registers with `axis_if #(.DATA_W(1), .USER_W(1)) m_axis ();`.
- Keep the `drv_*` registers and the `initial` block (CLAUDE.md INITIALDLY pattern).
- Update the `always_ff @(negedge clk)` driver block: `s_axis.tdata <= drv_tdata; s_axis.tvalid <= drv_tvalid; ...`.
- Capture path: drive `m_axis.tready` from the TB's stall pattern; sample `m_axis.tdata` / `m_axis.tvalid` on negedge into `cap_*` regs.
- DUT instantiation collapses to `.s_axis (s_axis), .m_axis (m_axis), .enable_i (enable), .clk_i (clk), .rst_n_i (rst_n)`.

- [ ] **Step 6: Update `sparevideo_top.sv` glue around `u_morph_open`**

The `u_morph_open` instantiation is near line 378 in the original file. Apply the top-level adapter-glue pattern from the top of this plan: declare `u_morph_open_in_axis` and `u_morph_open_out_axis` as `axis_if` instances (DATA_W=1, USER_W=1), bridge them to the surrounding flat wires, and pass them into `u_morph_open` as `.s_axis (u_morph_open_in_axis)` and `.m_axis (u_morph_open_out_axis)`. The `enable_i` connection stays as-is.

- [ ] **Step 7: Lint**

```bash
make lint
# Expected: clean. All three morphology modules now have matching interface signatures.
```

- [ ] **Step 8: Run all morphology unit TBs**

```bash
make test-ip-morph3x3-erode
make test-ip-morph3x3-dilate
make test-ip-morph3x3-open
# Expected: all pass.
```

- [ ] **Step 9: Run integration sim and the no_morph bypass profile**

```bash
make sim
make run-pipeline CTRL_FLOW=motion CFG=default  SOURCE=synthetic:moving_box FRAMES=4
make run-pipeline CTRL_FLOW=motion CFG=no_morph SOURCE=synthetic:moving_box FRAMES=4
# Expected: all pass. The no_morph profile exercises the enable_i=0 bypass path.
```

- [ ] **Step 10: Commit**

```bash
git add hw/ip/filters/rtl/axis_morph3x3_erode.sv hw/ip/filters/rtl/axis_morph3x3_dilate.sv hw/ip/filters/rtl/axis_morph3x3_open.sv \
        hw/ip/filters/tb/tb_axis_morph3x3_erode.sv hw/ip/filters/tb/tb_axis_morph3x3_dilate.sv hw/ip/filters/tb/tb_axis_morph3x3_open.sv \
        hw/ip/filters/filters.core hw/top/sparevideo_top.sv
git commit -m "refactor(axis_morph3x3): convert erode/dilate/open + TBs to axis_if; internal erode→dilate via axis_if"
```

---

## Task 7: Convert `axis_ccl` (introduces first `bbox_if.tx` use)

**Files:**
- Modify: `hw/ip/ccl/rtl/axis_ccl.sv`
- Modify: `hw/ip/ccl/tb/tb_axis_ccl.sv`
- Modify: `hw/top/sparevideo_top.sv` (glue around `u_ccl` for both AXIS and bbox sides)

- [ ] **Step 1: Convert `axis_ccl.sv` RTL — AXIS rx + new bbox tx**

The module has one rx (1-bit mask) and one bbox sideband tx (`bbox_valid_o`, `bbox_min_x_o`, `bbox_max_x_o`, `bbox_min_y_o`, `bbox_max_y_o`).

- Replace the flat `s_axis_*_i` group with `axis_if.rx s_axis`.
- Replace the entire flat bbox output port group with `bbox_if.tx bboxes`.
- Inside the body, rename: `bbox_valid_o` → `bboxes.valid`, `bbox_min_x_o[k]` → `bboxes.min_x[k]`, etc. — uniform across the (large) body.
- The CLAUDE.md "Vblank FSM modules must deassert tready for the full FSM duration" invariant is preserved by the rename; the assignment to `s_axis_tready_o = ...` becomes `s_axis.tready = ...`.

- [ ] **Step 2: Convert `tb_axis_ccl.sv`**

Per the per-IP unit TB pattern, with the addition of a bbox monitor:

```sv
axis_if #(.DATA_W(1), .USER_W(1)) s_axis ();
bbox_if  bboxes ();
```

The TB samples bbox outputs after each frame's vblank — replace each `bbox_valid_o[k]` reference in `$display` / golden compare with `bboxes.valid[k]`, etc.

- [ ] **Step 3: Update `sparevideo_top.sv` glue around `u_ccl`**

Apply the top-level adapter-glue pattern for the AXIS rx side. For the bbox tx side, declare a `bbox_if` instance and bridge it to the existing flat `bbox_*` arrays:

```sv
bbox_if u_ccl_bboxes ();
assign bbox_valid    = u_ccl_bboxes.valid;
assign bbox_min_x    = u_ccl_bboxes.min_x;
assign bbox_max_x    = u_ccl_bboxes.max_x;
assign bbox_min_y    = u_ccl_bboxes.min_y;
assign bbox_max_y    = u_ccl_bboxes.max_y;

axis_ccl #(...) u_ccl (
    .clk_i   (clk_proc),
    .rst_n_i (rst_n_proc),
    .s_axis  (u_ccl_s_axis),
    .bboxes  (u_ccl_bboxes)
);
```

This keeps the existing flat `bbox_*` wires alive for `axis_overlay_bbox` (still flat-port until Task 8).

- [ ] **Step 4: Lint**

```bash
make lint
# Expected: clean.
```

- [ ] **Step 5: Run unit TB**

```bash
make test-ip-ccl
# Expected: all 6 tests pass (single/hollow/disjoint/U-shape/overflow/back-to-back).
```

- [ ] **Step 6: Run integration sim across ccl-exercising profiles**

```bash
make run-pipeline CTRL_FLOW=motion   CFG=default SOURCE=synthetic:two_boxes FRAMES=4
make run-pipeline CTRL_FLOW=ccl_bbox CFG=default SOURCE=synthetic:two_boxes FRAMES=4
# Expected: TOLERANCE=0 match.
```

- [ ] **Step 7: Commit**

```bash
git add hw/ip/ccl/rtl/axis_ccl.sv hw/ip/ccl/tb/tb_axis_ccl.sv hw/top/sparevideo_top.sv
git commit -m "refactor(axis_ccl): convert AXIS port to axis_if; bbox sideband to bbox_if"
```

---

## Task 8: Convert `axis_overlay_bbox` (consumes `bbox_if.rx`)

**Files:**
- Modify: `hw/ip/overlay/rtl/axis_overlay_bbox.sv`
- Modify: `hw/ip/overlay/tb/tb_axis_overlay_bbox.sv`
- Modify: `hw/top/sparevideo_top.sv` (glue collapses on the bbox side — `u_ccl_bboxes` connects directly into `u_overlay`)

- [ ] **Step 1: Convert `axis_overlay_bbox.sv` RTL**

The module has one rx (RGB), one tx (RGB), and the bbox sideband (currently flat). Apply the conversion mechanics for AXIS rx/tx, plus replace the entire bbox sideband port group with `bbox_if.rx bboxes`. Inside the body, rename `bbox_valid_i[k]` → `bboxes.valid[k]`, `bbox_min_x_i[k]` → `bboxes.min_x[k]`, etc.

- [ ] **Step 2: Convert `tb_axis_overlay_bbox.sv`**

The TB drives RGB rx, captures RGB tx, and stimulates the bbox sideband. Use:

```sv
axis_if #(.DATA_W(24), .USER_W(1)) s_axis ();
axis_if #(.DATA_W(24), .USER_W(1)) m_axis ();
bbox_if bboxes ();
```

The bbox side is driven directly by `assign` from TB-generated arrays (no handshake — per-frame latch). The 8 tests (empty/full/single-pixel/backpressure/...) carry through unchanged behaviorally.

- [ ] **Step 3: Update `sparevideo_top.sv` glue around `u_overlay`**

Apply the top-level adapter-glue pattern for AXIS rx and tx. For the bbox side, the previously-bridged flat `bbox_*` wires can now be **deleted** — connect `u_ccl_bboxes` (declared in Task 7) directly into `.bboxes (u_ccl_bboxes)` on `u_overlay`. Also delete the `bbox_*` flat wire `assign`s that were created in Task 7 Step 3. This collapses the first piece of glue.

- [ ] **Step 4: Lint**

```bash
make lint
# Expected: clean.
```

- [ ] **Step 5: Run unit TB**

```bash
make test-ip-overlay-bbox
# Expected: all 8 tests pass.
```

- [ ] **Step 6: Run integration sim — overlay-exercising matrix**

```bash
make run-pipeline CTRL_FLOW=motion   CFG=default SOURCE=synthetic:moving_box FRAMES=4
make run-pipeline CTRL_FLOW=ccl_bbox CFG=default SOURCE=synthetic:two_boxes  FRAMES=4
# Expected: TOLERANCE=0 match.
```

- [ ] **Step 7: Commit**

```bash
git add hw/ip/overlay/rtl/axis_overlay_bbox.sv hw/ip/overlay/tb/tb_axis_overlay_bbox.sv hw/top/sparevideo_top.sv
git commit -m "refactor(axis_overlay_bbox): convert AXIS ports + bbox sideband + TB to interfaces"
```

---

## Task 9: Collapse adapter glue in `sparevideo_top.sv`

**Files:**
- Modify: `hw/top/sparevideo_top.sv`

After Tasks 3–8, every IP boundary in `sparevideo_top.sv` has glue that bridges flat wires ↔ interface bundles. Now that BOTH sides of every internal hop speak interfaces, the glue can collapse into direct interface pass-throughs.

This task also fixes the canonical interface bundle names that Task 10 will reference. Use these exact names:

| Bundle name | Connects |
|---|---|
| `pix_in_to_hflip` | input async FIFO `m_axis` → `u_hflip.s_axis` |
| `hflip_to_fork`   | `u_hflip.m_axis` → `u_fork.s_axis` |
| `fork_a_to_motion` | `u_fork.m_a_axis` → `u_motion.s_axis` |
| `fork_b_to_overlay` | `u_fork.m_b_axis` → `u_overlay.s_axis` |
| `motion_to_morph` | `u_motion.m_axis` → `u_morph_open.s_axis` |
| `morph_to_ccl` | `u_morph_open.m_axis` → `u_ccl.s_axis` (motion / mask / ccl_bbox flows) |
| `overlay_to_pix_out` | `u_overlay.m_axis` → output async FIFO `s_axis` |
| `u_ccl_bboxes` | `u_ccl.bboxes` → `u_overlay.bboxes` (already named in Task 7) |

(Adjust the morph/ccl name to whatever fits the existing `msk_clean_*` flat-wire group; the names above are suggested defaults.)

- [ ] **Step 1: Identify all glue blocks**

Search `sparevideo_top.sv` for `axis_if #(...)` declarations introduced in Tasks 3–8 (and the `bbox_if` from Task 7). Each such declaration was paired with `assign` blocks bridging flat wires.

- [ ] **Step 2: For each adjacent IP-IP hop, collapse the two glue blocks into one interface declaration**

Example pattern — before:

```sv
// fork-A → motion: TWO glue blocks, one on each side
axis_if u_fork_a_axis ();   // declared in Task 3
assign mot_in_tdata  = u_fork_a_axis.tdata;
assign mot_in_tvalid = u_fork_a_axis.tvalid;
/* ... */
assign u_fork_a_axis.tready = mot_in_tready;

axis_if u_motion_in_axis ();   // declared in Task 5
assign u_motion_in_axis.tdata  = mot_in_tdata;
assign u_motion_in_axis.tvalid = mot_in_tvalid;
/* ... */
assign mot_in_tready = u_motion_in_axis.tready;
```

After:

```sv
// fork-A → motion: a single shared interface, no flat wires
axis_if #(.DATA_W(24), .USER_W(1)) fork_a_to_motion ();

// (then both u_fork.m_axis_a and u_motion.s_axis bind to fork_a_to_motion)
```

- [ ] **Step 3: Delete the obsolete flat wires**

Every `mot_in_tdata`, `mot_in_tvalid`, `msk_tdata`, etc. that was used only as glue can be deleted. The `axis_if` instance now carries the data.

Some flat wires may still be referenced by lint waivers or `$display` debug — search the file for each name being deleted and confirm no orphan reference remains.

- [ ] **Step 4: Lint**

```bash
make lint
# Expected: clean. No port mismatches, no orphan wires.
```

- [ ] **Step 5: Run integration sim**

```bash
make sim
# Expected: passthrough sim still passes.
```

- [ ] **Step 6: Run a small profile-sweep to spot-check**

```bash
make run-pipeline CTRL_FLOW=passthrough CFG=default SOURCE=synthetic:moving_box FRAMES=2
make run-pipeline CTRL_FLOW=motion      CFG=default SOURCE=synthetic:moving_box FRAMES=2
make run-pipeline CTRL_FLOW=mask        CFG=default SOURCE=synthetic:moving_box FRAMES=2
make run-pipeline CTRL_FLOW=ccl_bbox    CFG=default SOURCE=synthetic:two_boxes  FRAMES=2
# Expected: all four control flows match TOLERANCE=0.
```

- [ ] **Step 7: Commit**

```bash
git add hw/top/sparevideo_top.sv
git commit -m "refactor(sparevideo_top): collapse adapter glue — direct interface pass-through between IPs"
```

---

## Task 10: Replace `axis_async_fifo` with `axis_async_fifo_ifc` in top

**Files:**
- Modify: `hw/top/sparevideo_top.sv`

The two `axis_async_fifo` instances (lines ~110 and ~574 in the original file) currently use flat ports. Replace each with an `axis_async_fifo_ifc` instance whose interface ports connect directly to the surrounding `axis_if` bundles (now in place from Task 9).

- [ ] **Step 1: Replace the input-CDC FIFO instantiation**

For the input CDC FIFO (around line 110 originally):

```sv
// before:
axis_async_fifo #(
    .DEPTH        (PIX_FIFO_DEPTH),
    .DATA_WIDTH   (24),
    .USER_ENABLE  (1),
    .USER_WIDTH   (1),
    /* ... */
) u_pix_fifo (
    .s_clk         (clk_pix),
    .s_rst         (~rst_n_pix),
    .s_axis_tdata  (s_axis_tdata),
    /* ... flat ports ... */
);

// after:
axis_async_fifo_ifc #(
    .DEPTH        (PIX_FIFO_DEPTH),
    .DATA_W       (24),
    .USER_W       (1),
    /* ... */
) u_pix_fifo (
    .s_clk          (clk_pix),
    .s_rst_n        (rst_n_pix),
    .m_clk          (clk_proc),
    .m_rst_n        (rst_n_proc),
    .s_axis         (<input-side axis_if; the bundle that the integration TB drives — see Task 11 below>),
    .m_axis         (pix_in_to_hflip),  // named in Task 9
    .s_status_depth (),  // unused for now
    .m_status_depth ()
);
```

(For the input FIFO's `s_axis`, the source is the integration TB's drive port. Task 11 converts that port to an `axis_if`. For now, until Task 11 lands, the FIFO `s_axis` still has to bridge from the TB's flat-port drive — declare a small `axis_if` instance `tb_s_axis_to_fifo` and `assign` from the existing flat top-level ports `s_axis_tdata` etc.; Task 11 then deletes that adapter and connects the TB's `axis_if` directly.)

- [ ] **Step 2: Replace the output-CDC FIFO instantiation**

For the output CDC FIFO (around original line 574). Now the input side is `clk_proc` and the output side is `clk_pix`. Apply the same swap as Step 1:

```sv
// before:
axis_async_fifo #(
    .DEPTH        (PIX_FIFO_OUT_DEPTH),
    .DATA_WIDTH   (24),
    .USER_ENABLE  (1),
    .USER_WIDTH   (1),
    /* ... */
) u_pix_out_fifo (
    .s_clk         (clk_proc),
    .s_rst         (~rst_n_proc),
    .s_axis_tdata  (overlay_out_tdata),
    /* ... flat ports ... */
);

// after:
axis_async_fifo_ifc #(
    .DEPTH        (PIX_FIFO_OUT_DEPTH),
    .DATA_W       (24),
    .USER_W       (1),
    /* ... */
) u_pix_out_fifo (
    .s_clk          (clk_proc),
    .s_rst_n        (rst_n_proc),
    .m_clk          (clk_pix),
    .m_rst_n        (rst_n_pix),
    .s_axis         (overlay_to_pix_out),  // named in Task 9
    .m_axis         (<output-side axis_if; feeds the VGA controller's tdata input>),
    .s_status_depth (),
    .m_status_depth ()
);
```

(The output FIFO's `m_axis` flat side feeds the VGA controller, which is NOT AXI-Stream-typed and stays flat. Bridge with `assign vga_pixel_data = <m_axis_bundle>.tdata;` etc., declared adjacent to the FIFO instance. This bridge is permanent — VGA is out of conversion scope.)

- [ ] **Step 3: Lint**

```bash
make lint
# Expected: clean.
```

- [ ] **Step 4: Run integration sim**

```bash
make sim
# Expected: passes.
```

- [ ] **Step 5: Sanity-check the full matrix**

```bash
make run-pipeline CTRL_FLOW=passthrough CFG=default SOURCE=synthetic:moving_box FRAMES=4
make run-pipeline CTRL_FLOW=motion      CFG=default SOURCE=synthetic:moving_box FRAMES=4
# Expected: TOLERANCE=0.
```

- [ ] **Step 6: Commit**

```bash
git add hw/top/sparevideo_top.sv
git commit -m "refactor(sparevideo_top): swap axis_async_fifo for axis_async_fifo_ifc wrapper"
```

---

## Task 11: Convert `sparevideo_top` external port + integration TB

**Files:**
- Modify: `hw/top/sparevideo_top.sv` (external port signature)
- Modify: `dv/sv/tb_sparevideo.sv`

`sparevideo_top` still exposes the input AXI-Stream as flat top-level ports (`s_axis_tdata_i`, `s_axis_tvalid_i`, `s_axis_tready_o`, `s_axis_tlast_i`, `s_axis_tuser_i`). The integration TB drives those flat ports today. This task converts both sides together: the DUT's external port becomes a single `axis_if.rx s_axis` port, and the TB updates its drive path to match. Both must change in one commit because they meet at the DUT boundary; otherwise lint and sim break.

- [ ] **Step 1: Convert `sparevideo_top`'s external port signature**

In `hw/top/sparevideo_top.sv`, replace the five flat top-level AXI-Stream input ports with one interface port. The new module signature looks like:

```sv
module sparevideo_top (
    input  logic        clk_pix,
    input  logic        rst_n_pix,
    input  logic        clk_proc,
    input  logic        rst_n_proc,

    axis_if.rx          s_axis,    // was: s_axis_tdata_i / s_axis_tvalid_i / ...

    input  logic [1:0]  ctrl_flow_i,

    /* VGA output ports unchanged */
);
```

In the body, the previously-existing internal adapter `tb_s_axis_to_fifo` (declared in Task 10 to bridge flat top-level ports to the input FIFO's `s_axis`) is now redundant — replace it with a direct assignment of the top-level `s_axis` interface to the input FIFO. Specifically, change the input FIFO instantiation (from Task 10) to:

```sv
axis_async_fifo_ifc #(
    .DEPTH (PIX_FIFO_DEPTH), .DATA_W (24), .USER_W (1) /* ... */
) u_pix_fifo (
    .s_clk          (clk_pix),
    .s_rst_n        (rst_n_pix),
    .m_clk          (clk_proc),
    .m_rst_n        (rst_n_proc),
    .s_axis         (s_axis),               // direct top-level port pass-through
    .m_axis         (pix_in_to_hflip),
    .s_status_depth (),
    .m_status_depth ()
);
```

Delete the temporary `tb_s_axis_to_fifo` declaration and its `assign`s — they served only as bridges from the flat top-level ports.

- [ ] **Step 2: Convert `dv/sv/tb_sparevideo.sv` — declare the input `axis_if` instance**

In `dv/sv/tb_sparevideo.sv`, replace the flat `s_axis_tdata` / `s_axis_tvalid` / `s_axis_tready` / `s_axis_tlast` / `s_axis_tuser` register declarations at the top of the TB with:

```sv
axis_if #(.DATA_W(24), .USER_W(1)) s_axis ();
```

- [ ] **Step 3: Reroute the `drv_*` → DUT-input drive path**

The TB's existing `drv_*` registers (per CLAUDE.md INITIALDLY note) and the `always_ff @(negedge clk_pix)` driver remain. Update the driver block to assign onto `s_axis.tdata` etc. instead of the deleted flat regs:

```sv
always_ff @(negedge clk_pix) begin
    s_axis.tdata  <= drv_s_tdata;
    s_axis.tvalid <= drv_s_tvalid;
    s_axis.tlast  <= drv_s_tlast;
    s_axis.tuser  <= drv_s_tuser;
end
```

The TB reads back-pressure via `s_axis.tready` for flow control (where it does today via `s_axis_tready`).

- [ ] **Step 4: Update the DUT instantiation in the TB**

```sv
sparevideo_top u_dut (
    .clk_pix    (clk_pix),
    .rst_n_pix  (rst_n_pix),
    .clk_proc   (clk_proc),
    .rst_n_proc (rst_n_proc),
    .s_axis     (s_axis),
    .ctrl_flow_i(ctrl_flow),
    /* VGA output ports unchanged */
);
```

- [ ] **Step 5: Lint**

```bash
make lint
# Expected: clean.
```

- [ ] **Step 6: Run integration sim**

```bash
make sim
# Expected: passes — passthrough mode runs and pixel-matches.
```

- [ ] **Step 7: Run a small profile-sweep**

```bash
make run-pipeline CTRL_FLOW=motion CFG=default SOURCE=synthetic:moving_box FRAMES=4
make run-pipeline CTRL_FLOW=mask   CFG=default SOURCE=synthetic:moving_box FRAMES=4
# Expected: TOLERANCE=0 in both.
```

- [ ] **Step 8: Commit**

```bash
git add hw/top/sparevideo_top.sv dv/sv/tb_sparevideo.sv
git commit -m "refactor(top+tb): convert sparevideo_top external s_axis to axis_if; integration TB matches"
```

---

## Task 12: Remove Icarus support

**Files:**
- Modify: `Makefile`
- Modify: `dv/sim/Makefile`
- Modify: `dv/sv/tb_sparevideo.sv`

- [ ] **Step 1: Edit `Makefile`**

Drop "or icarus" from the help text (line 74 originally): change `Simulator: verilator (default) or icarus` → `Simulator: verilator`.

Drop `iverilog` from the `apt install` in the `setup:` target (line ~191 originally): `sudo apt install -y iverilog verilator` → `sudo apt install -y verilator`.

- [ ] **Step 2: Edit `dv/sim/Makefile`**

Delete the entire `ifeq ($(SIMULATOR),icarus)` branch (lines ~48–116 originally), including the helper variables it sets, the `iverilog -g2012 -o $@ $^` rule, and the `$(error Unknown SIMULATOR=...)` clause that mentions icarus. Keep only the verilator branch and a short error message for unknown simulators:

```makefile
ifeq ($(SIMULATOR),verilator)
# (existing verilator rules — preserved verbatim)
else
$(error Unknown SIMULATOR='$(SIMULATOR)'. Use SIMULATOR=verilator (the only supported simulator))
endif
```

- [ ] **Step 3: Edit `dv/sv/tb_sparevideo.sv`**

Lines 379 and 382 (originally) contain `$display` strings with `(wall-clock N/A on Icarus)` parentheticals. Drop the parentheticals — wall-clock is always available now via the DPI-C helper:

- `"Frame %0d: %0d pixels OK (wall-clock N/A on Icarus)"` → `"Frame %0d: %0d pixels OK"` (or keep with the wall-clock value if the surrounding context already passes it).
- `"Frame %0d: input complete (wall-clock N/A on Icarus)"` → `"Frame %0d: input complete"`.

If the surrounding `ifdef VERILATOR` blocks become trivial (single-branch), simplify them — but do not remove the DPI-C `get_wall_ms()` infrastructure; it's still used.

Leave the comment at `hw/ip/vga/rtl/pattern_gen.sv:76` (`// Pre-compute pattern bits (avoids Icarus part-select warning in always_comb)`) alone — the construct is valid SV and the comment is harmless historical context.

- [ ] **Step 4: Lint and sim**

```bash
make lint
make sim
# Expected: both pass.
```

- [ ] **Step 5: Try the unknown-simulator path to confirm the error fires**

```bash
make sim SIMULATOR=icarus 2>&1 | head -2
# Expected: the new "Unknown SIMULATOR='icarus'..." error.
```

- [ ] **Step 6: Commit**

```bash
git add Makefile dv/sim/Makefile dv/sv/tb_sparevideo.sv
git commit -m "build: remove unmaintained Icarus Verilog support"
```

---

## Task 13: Update `CLAUDE.md` and `README.md`

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Edit `CLAUDE.md` line ~29 — the prohibition list**

Find the line:

```
All RTL is SystemVerilog (.sv files). Use synthesis-style SV only (no SVA assertions, no interfaces/modports, no classes) for Icarus Verilog 12 compatibility.
```

Replace with:

```
All RTL is SystemVerilog (.sv files). Use synthesis-style SV only (no SVA assertions, no classes) — the project targets Verilator and uses SV interfaces (`axis_if`, `bbox_if`) for AXI-Stream and bbox sideband bundles.
```

- [ ] **Step 2: Edit `CLAUDE.md` line ~182 — the simulator note**

Find:

```
- Simulator: **Verilator only** for all required checks. Icarus commands exist in the Makefile but are not maintained and will likely fail.
```

Replace with:

```
- Simulator: **Verilator only**.
```

- [ ] **Step 3: Edit `CLAUDE.md` Project Structure section**

In the project-structure list, add a line under the `hw/top/` group:

```
- `hw/top/sparevideo_if.sv` — Project-wide SV interfaces: `axis_if` (AXI4-Stream) and `bbox_if` (bbox sideband). Modports: `tx`/`rx`/`mon`.
```

In the `hw/ip/axis/rtl/` description, append `axis_async_fifo_ifc`:

```
- `hw/ip/axis/rtl/` — Reusable AXI4-Stream utilities (axis_fork: zero-latency 1-to-2 broadcast fork...; axis_async_fifo_ifc: interface-port wrapper around the vendored axis_async_fifo, adapts active-high reset to project rst_n_i convention).
```

- [ ] **Step 4: Edit `CLAUDE.md` RTL Conventions section**

Add two bullets to the existing list:

```
- AXI-Stream ports use the `axis_if` interface with modports `tx`/`rx`/`mon`. The bbox sideband from `axis_ccl` to `axis_overlay_bbox` uses `bbox_if`. `clk_i`/`rst_n_i` stay as separate scalar ports on every module — the interface bundle does NOT carry them.
- `axis_window3x3` and `axis_gauss3x3` keep an internal window-style protocol (`valid_i`/`stall_i`/`sof_i`/`busy_o`) — the `axis_` prefix is historical and does NOT mean AXI-Stream. Wrappers (e.g. `axis_morph3x3_*`) use real AXI-Stream and translate at the boundary.
```

- [ ] **Step 5: Edit `README.md` line ~249**

Change the SIMULATOR table row:

```
| `SIMULATOR` | `verilator` | Simulator to use (`verilator` only; Icarus not maintained) |
```

to:

```
| `SIMULATOR` | `verilator` | Simulator to use (`verilator`) |
```

- [ ] **Step 6: Verify nothing else mentions Icarus or banned-interface rules**

```bash
grep -niE "iverilog|icarus|no interfaces|interfaces/modports" CLAUDE.md README.md
# Expected: no hits, or only contextually-correct historical mentions in plans/old/.
```

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: drop Icarus + interfaces/modports prohibition from CLAUDE.md/README"
```

---

## Task 14: Refresh per-IP architecture docs in `docs/specs/`

**Files (port-table sections only):**
- Modify: `docs/specs/axis_ccl-arch.md`
- Modify: `docs/specs/axis_hflip-arch.md`
- Modify: `docs/specs/axis_morph3x3_open-arch.md`
- Modify: `docs/specs/axis_motion_detect-arch.md`
- Modify: `docs/specs/axis_overlay_bbox-arch.md`
- Modify: `docs/specs/sparevideo-top-arch.md`

For each file in the list, locate the **port-table section** (or equivalent module-signature block) and update it to reflect the new interface ports. The semantic content of each doc is unchanged — only the port table.

- [ ] **Step 1: `docs/specs/axis_hflip-arch.md`**

Replace the rx/tx port rows (`s_axis_tdata_i`, `s_axis_tvalid_i`, ...) with two single rows:

| Port | Direction | Type | Description |
|---|---|---|---|
| `s_axis` | input | `axis_if.rx` | RGB input stream (DATA_W=24, USER_W=1; tuser=SOF) |
| `m_axis` | output | `axis_if.tx` | RGB mirrored output stream |

(Adjust the existing table style to match.) `enable_i`, `clk_i`, `rst_n_i` rows unchanged.

- [ ] **Step 2: `docs/specs/axis_motion_detect-arch.md`**

Replace flat AXIS rx group with `s_axis : input : axis_if.rx (DATA_W=24, USER_W=1)`. Replace flat AXIS tx group with `m_axis : output : axis_if.tx (DATA_W=1, USER_W=1)`. Non-AXIS sideband (RAM ports) unchanged.

- [ ] **Step 3: `docs/specs/axis_morph3x3_open-arch.md`**

Replace flat AXIS rx and tx groups with `s_axis : input : axis_if.rx (DATA_W=1, USER_W=1)` and `m_axis : output : axis_if.tx (DATA_W=1, USER_W=1)`. `enable_i` row unchanged.

- [ ] **Step 4: `docs/specs/axis_ccl-arch.md`**

Replace flat AXIS rx group with `s_axis : input : axis_if.rx (DATA_W=1, USER_W=1)`. Replace the entire flat `bbox_*` output group with a single row: `bboxes : output : bbox_if.tx (N_OUT=CCL_N_OUT)`.

- [ ] **Step 5: `docs/specs/axis_overlay_bbox-arch.md`**

Replace flat AXIS rx group with `s_axis : input : axis_if.rx (DATA_W=24, USER_W=1)`. Replace flat AXIS tx group with `m_axis : output : axis_if.tx (DATA_W=24, USER_W=1)`. Replace flat `bbox_*` input group with `bboxes : input : bbox_if.rx (N_OUT=CCL_N_OUT)`.

- [ ] **Step 6: `docs/specs/sparevideo-top-arch.md`**

Update the top-level dataflow diagram and module-port tables to reflect interface bundles flowing between every internal hop (input FIFO → hflip → fork → motion → morph_open → ccl/overlay → output FIFO). The DUT's external `s_axis` rx port (used by the integration TB) is now `axis_if.rx`.

- [ ] **Step 7: Commit**

```bash
git add docs/specs/axis_ccl-arch.md docs/specs/axis_hflip-arch.md docs/specs/axis_morph3x3_open-arch.md docs/specs/axis_motion_detect-arch.md docs/specs/axis_overlay_bbox-arch.md docs/specs/sparevideo-top-arch.md
git commit -m "docs(specs): refresh per-IP arch docs port tables for axis_if/bbox_if"
```

---

## Task 15: Cleanup + final verification matrix

**Files:**
- Delete: `experiments/sv_interface/` (the prototype that motivated the plan; superseded).

- [ ] **Step 1: Delete the experiments directory**

```bash
rm -rf experiments/sv_interface/
# Verify empty:
ls experiments/ 2>/dev/null && echo "(directory contains other things — leave them)" || echo "(experiments dir empty or removed)"
```

If the `experiments/` directory now contains nothing else, also remove the parent:

```bash
rmdir experiments 2>/dev/null || true
```

- [ ] **Step 2: Run the full lint sweep**

```bash
make lint
# Expected: no warnings, no errors.
```

- [ ] **Step 3: Run all per-IP unit testbenches**

```bash
make test-ip
# Expected: all 11 sub-targets pass — rgb2ycrcb, window, gauss3x3, motion-detect, motion-detect-gauss, overlay-bbox, ccl, morph3x3-erode, morph3x3-dilate, morph3x3-open, hflip.
```

- [ ] **Step 4: Run the full verification matrix (4 ctrl flows × 5 profiles × 2 sources, TOLERANCE=0)**

```bash
for cf in passthrough motion mask ccl_bbox ; do
  for cfg in default default_hflip no_ema no_morph no_gauss ; do
    for src in synthetic:moving_box synthetic:noisy_moving_box ; do
      echo "=== ctrl=$cf cfg=$cfg src=$src ==="
      make run-pipeline CTRL_FLOW=$cf CFG=$cfg SOURCE=$src FRAMES=4 || exit 1
    done
  done
done
echo "ALL OK"
```

Expected: every combination matches the Python reference model at TOLERANCE=0; the script ends with `ALL OK`.

If any combination fails, do NOT proceed. Investigate the failure (probably a missed signal rename or glue collapse in `sparevideo_top.sv`); fix in a new commit on this branch.

- [ ] **Step 5: Commit the cleanup**

```bash
git add -A   # picks up the experiments/ deletion
git commit -m "chore: remove experiments/sv_interface — superseded by real implementation"
```

- [ ] **Step 6: Squash all plan commits into a single commit**

Per CLAUDE.md: "Squash at plan completion." Identify the first commit on this branch (`35eb636` is the design-doc commit; the implementation commits start at the next commit). Use interactive rebase OR a soft reset:

```bash
# Find the merge-base with origin/main:
BASE=$(git merge-base HEAD origin/main)
echo "Squashing all commits since $BASE into a single commit."

# Soft-reset to the base, then re-commit everything as one:
git reset --soft "$BASE"
git status   # verify all changes are staged
git commit -m "$(cat <<'EOF'
refactor: convert AXI-Stream ports to SystemVerilog interfaces

- New hw/top/sparevideo_if.sv: axis_if (DATA_W/USER_W parameterized) and
  bbox_if (N_OUT/H_W/V_W parameterized). Modports tx/rx/mon, clk/rst_n
  stay as scalar ports.
- New hw/ip/axis/rtl/axis_async_fifo_ifc.sv: thin wrapper around the
  vendored axis_async_fifo, adapts flat ports + active-high reset to
  interface bundles + active-low rst_n_i. Exposes status_depth ports.
- All AXI-Stream-bearing modules converted: axis_fork, axis_hflip,
  axis_motion_detect, axis_morph3x3_{erode,dilate,open}, axis_ccl,
  axis_overlay_bbox, sparevideo_top.
- All affected unit testbenches converted (preserving the drv_* +
  negedge-driver pattern). dv/sv/tb_sparevideo.sv input drive converted.
- Window-style primitives axis_window3x3 and axis_gauss3x3 retained
  as-is — internal window-style protocol, not AXI-Stream.
- Icarus Verilog support formally removed — Verilator-only.
- CLAUDE.md, README.md, docs/specs/* port tables updated.
- Verified pixel-accurate (TOLERANCE=0) across all 4 ctrl_flows × 5
  profiles × 2 sources.

Implements docs/plans/2026-04-27-axis-sv-interface-design.md.
EOF
)"
```

If the squash workflow surfaces unrelated commits that slipped onto the branch (per CLAUDE.md "Before squashing, verify every commit on the branch belongs to the plan"), STOP — split those commits onto a separate branch first, then re-squash only the plan commits. With this plan's task list there should be no surprises, but the check is mandatory.

- [ ] **Step 7: Move the design doc to `docs/plans/old/`**

Per CLAUDE.md "After implementing a plan, move it to docs/plans/old/ and put a date timestamp on it":

```bash
git mv docs/plans/2026-04-27-axis-sv-interface-design.md docs/plans/old/2026-04-27-axis-sv-interface-design.md
git mv docs/plans/2026-04-27-axis-sv-interface-plan.md   docs/plans/old/2026-04-27-axis-sv-interface-plan.md
git commit -m "docs(plans): archive completed SV-interface design + plan"
```

(This commit is intentionally separate from the squash — it's archival metadata, not part of the implementation diff.)

---

## Out of scope (deferred to follow-up plans, per the design doc)

- **Renaming `axis_window3x3` and `axis_gauss3x3`** to drop the misleading `axis_` prefix.
- **Promoting the window-style protocol to AXI-Stream** in `axis_window3x3` / `axis_gauss3x3` — different contract, real regression risk.
- **Adding `tkeep` / `tdest` / `tid` to `axis_if`** — no consumer needs them today.

---

## Verification gates (cumulative)

| Gate | When checked |
|---|---|
| `make lint` clean | every task |
| Affected unit TB(s) pass | every Phase-2 task |
| `make sim` (passthrough) passes | every task |
| Full matrix at TOLERANCE=0 | Task 15 |
| `experiments/sv_interface/` removed | Task 15 |
| One squashed commit + design+plan archived | Task 15 |
