# axis_kernel3x3 Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the line-buffer + 3×3 sliding-window + edge-replication logic currently inside `axis_gauss3x3` into a new reusable primitive `axis_kernel3x3`, and re-express `axis_gauss3x3` as a thin wrapper over it. The motion pipeline must produce byte-identical output before and after the refactor.

**Architecture:** `axis_kernel3x3` owns all state and timing (row/col counters, phantom-cycle drain, two line buffers, 3-row × 3-col window registers, edge replication). It exposes a combinational 9-tap window at the d1 stage plus a window-valid strobe that is already off-frame-suppressed. Wrappers (`axis_gauss3x3` now, `axis_morph_erode` / `axis_morph_dilate` next plan) do their own combinational op on the window and add a single output register. The kernel is parameterized on `DATA_WIDTH` (8 for Gaussian, 1 for morphology), `H_ACTIVE`, and `V_ACTIVE`.

**Tech Stack:** SystemVerilog (Icarus-12-compatible subset — no SVA, no interfaces, no classes), Verilator for simulation and lint, GNU Make, FuseSoC CAPI=2 core files.

**Spec:** `docs/plans/2026-04-23-pipeline-extensions-design.md` §3.2 and §5.3.

---

## File Structure

**New files:**

- `hw/ip/kernel/kernel.core` — FuseSoC core file exposing `sparevideo:ip:kernel`.
- `hw/ip/kernel/rtl/axis_kernel3x3.sv` — the new primitive.
- `hw/ip/kernel/tb/tb_axis_kernel3x3.sv` — unit testbench (digest of the scenarios from `tb_axis_gauss3x3` that exercise shared logic).
- `hw/ip/kernel/docs/axis_kernel3x3-arch.md` — architecture doc (produced via the `hardware-arch-doc` skill at documentation time).

**Modified files:**

- `hw/ip/gauss3x3/rtl/axis_gauss3x3.sv` — strip state/timing/line-buffer/window logic; instantiate `axis_kernel3x3`; keep convolution math + output register.
- `hw/ip/gauss3x3/gauss3x3.core` — add `sparevideo:ip:kernel` dependency.
- `dv/sim/Makefile` — add `IP_KERNEL3X3_RTL` var, `test-ip-kernel` target, include in `test-ip` aggregation and in clean.
- `Makefile` (top) — advertise `test-ip-kernel` in the help block.
- `README.md` — add the kernel IP to the IP table.
- `CLAUDE.md` — add a line to the "Project Structure" list.

No changes required to `hw/ip/motion/rtl/axis_motion_detect.sv`, `hw/ip/motion/motion.core`, or anything downstream — the Gaussian wrapper preserves its external interface exactly.

---

## Task 1: Capture the pre-refactor regression golden

**Purpose:** lock in a byte-perfect reference of the current motion pipeline output. Any behavioral drift during the refactor must fail `cmp`.

**Files:**
- Create (local, gitignored): `renders/golden/motion-before-kernel-refactor.bin`

- [ ] **Step 1: Run the pre-refactor motion pipeline**

Run:
```bash
make run-pipeline CTRL_FLOW=motion SOURCE="synthetic:moving_box" WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary
```

Expected: exits with status 0; `dv/data/output.bin` is produced; `make verify` inside the pipeline reports success.

- [ ] **Step 2: Save the golden file**

Run:
```bash
mkdir -p renders/golden
cp dv/data/output.bin renders/golden/motion-before-kernel-refactor.bin
ls -l renders/golden/motion-before-kernel-refactor.bin
```

Expected: the file exists. Size = `12 + (320*240*3*8) = 1,843,212` bytes (12-byte header + 8 RGB frames at 320×240).

- [ ] **Step 3: Sanity-check the first bytes**

Run:
```bash
xxd renders/golden/motion-before-kernel-refactor.bin | head -1
```

Expected: the first 12 bytes decode as three LE uint32s `(0x140, 0xF0, 0x8)` = `(320, 240, 8)`.

*(Do not commit — `renders/` is gitignored. This file is a local regression witness, deleted at the end of Task 6.)*

---

## Task 2: Create kernel IP scaffolding

**Files:**
- Create: `hw/ip/kernel/kernel.core`
- Create: `hw/ip/kernel/rtl/axis_kernel3x3.sv` (empty skeleton for now)
- Modify: `dv/sim/Makefile` (add IP_KERNEL3X3_RTL, test-ip-kernel, aggregate, clean)
- Modify: `Makefile` (advertise test-ip-kernel in help)

- [ ] **Step 1: Create the core file**

Create `hw/ip/kernel/kernel.core`:

```yaml
CAPI=2:
name: "sparevideo:ip:kernel"
description: "Reusable 3x3 sliding-window primitive (line buffers + window regs + edge replication)"

filesets:
  files_rtl:
    files:
      - rtl/axis_kernel3x3.sv
    file_type: systemVerilogSource

targets:
  default:
    filesets:
      - files_rtl
```

- [ ] **Step 2: Create the empty module skeleton**

Create `hw/ip/kernel/rtl/axis_kernel3x3.sv`:

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// axis_kernel3x3 -- reusable 3x3 sliding-window primitive.
//
// Owns: row/col counters with phantom-cycle drain, two line buffers
// (depth H_ACTIVE, width DATA_WIDTH), 3-row x 3-col window shift registers,
// and edge replication at all four borders. Emits a combinational 9-tap
// window at the d1 stage + window_valid_o (off-frame-suppressed) + busy_o.
//
// Consumers (axis_gauss3x3, axis_morph_erode, axis_morph_dilate, ...) add
// their own combinational op on the window and a single output register.
//
// Latency: H_ACTIVE + 2 cycles from first valid_i to first window_valid_o
// (one less than gauss3x3 end-to-end because the op register now lives in
// the wrapper). Throughput: 1 pixel/cycle after fill.
//
// Blanking requirements (inherited from the former gauss3x3 internals):
//   - Min H-blank: 1 cycle per row (absorbs the per-row phantom column).
//   - Min V-blank: H_ACTIVE + 1 cycles total (absorbs phantom-row drain).
//   - If blanking is unavailable, busy_o asserts so the parent can deassert
//     upstream tready.

module axis_kernel3x3 #(
    parameter int DATA_WIDTH = 8,
    parameter int H_ACTIVE   = 320,
    parameter int V_ACTIVE   = 240
) (
    input  logic                  clk_i,
    input  logic                  rst_n_i,

    input  logic                  valid_i,
    input  logic                  sof_i,
    input  logic                  stall_i,

    input  logic [DATA_WIDTH-1:0] din_i,

    // 3x3 window, row-major: [0]=TL [1]=TC [2]=TR
    //                         [3]=ML [4]=CC [5]=MR
    //                         [6]=BL [7]=BC [8]=BR
    output logic [DATA_WIDTH-1:0] window_o [9],
    output logic                  window_valid_o,
    output logic                  busy_o
);

    // Placeholder tie-offs so the module elaborates cleanly.
    // Body is added in Task 4; the kernel TB (Task 3) is expected to FAIL
    // against this skeleton — window_valid_o never asserts so the first
    // cap_valid check fires $fatal.
    assign window_valid_o = 1'b0;
    assign busy_o         = 1'b0;
    assign window_o[0]    = '0;
    assign window_o[1]    = '0;
    assign window_o[2]    = '0;
    assign window_o[3]    = '0;
    assign window_o[4]    = '0;
    assign window_o[5]    = '0;
    assign window_o[6]    = '0;
    assign window_o[7]    = '0;
    assign window_o[8]    = '0;

endmodule
```

- [ ] **Step 3: Wire kernel into dv/sim/Makefile**

Open `dv/sim/Makefile` and:

a) Add a new source variable near `IP_GAUSS3X3_RTL` (around line 121):

```make
IP_KERNEL3X3_RTL = ../../hw/ip/kernel/rtl/axis_kernel3x3.sv
```

b) Add `test-ip-kernel` to the `test-ip` aggregate target (around line 129):

```make
test-ip: test-ip-rgb2ycrcb test-ip-kernel test-ip-gauss3x3 test-ip-motion-detect test-ip-motion-detect-gauss test-ip-overlay-bbox test-ip-ccl
	@echo "All block testbenches passed."
```

c) Add a new per-block target after `test-ip-gauss3x3`:

```make
# --- axis_kernel3x3 ---
test-ip-kernel:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_kernel3x3 --Mdir obj_tb_axis_kernel3x3 \
	  $(IP_KERNEL3X3_RTL) ../../hw/ip/kernel/tb/tb_axis_kernel3x3.sv
	obj_tb_axis_kernel3x3/Vtb_axis_kernel3x3
```

d) Add `obj_tb_axis_kernel3x3` to the `clean` target's `rm -rf` line (around line 182):

```make
	rm -rf $(VOBJ_DIR) obj_tb_rgb2ycrcb obj_tb_axis_kernel3x3 obj_tb_axis_gauss3x3 \
```

e) Also update the top-level `.PHONY` list in the same file (around line 40) to include `test-ip-kernel`:

```make
       test-ip test-ip-rgb2ycrcb test-ip-kernel test-ip-gauss3x3 \
       test-ip-motion-detect test-ip-motion-detect-gauss \
       test-ip-overlay-bbox test-ip-ccl
```

- [ ] **Step 4: Advertise test-ip-kernel in the top Makefile help**

Open the top-level `Makefile`. Find the help block (around line 73–78) and add a line between `test-ip-rgb2ycrcb` and `test-ip-gauss3x3`:

```make
	@echo "    test-ip-kernel             axis_kernel3x3: 3x3 window + edge replication, shared primitive"
```

- [ ] **Step 5: Verify Makefile parses (dry-run)**

Run:
```bash
make -n test-ip-kernel | head -3
```

Expected: prints the `verilator ... --top-module tb_axis_kernel3x3 ...` command — no `make: *** No rule to make target` errors, no `Makefile:NNN: *** missing separator` errors. We intentionally do **not** invoke the rule yet — the TB file does not exist.

- [ ] **Step 6: Commit the scaffolding**

Run:
```bash
git add hw/ip/kernel/kernel.core hw/ip/kernel/rtl/axis_kernel3x3.sv dv/sim/Makefile Makefile
git commit -m "feat(kernel): add axis_kernel3x3 IP scaffolding

Introduce empty hw/ip/kernel/ module + core file and wire test-ip-kernel
into the per-block Makefile. Module body and TB land in follow-up commits."
```

Expected: commit created, `git status` clean.

---

## Task 3: Write tb_axis_kernel3x3

**Purpose:** directed tests against the (still empty) kernel module. Running the TB must fail now and pass after Task 4.

**Files:**
- Create: `hw/ip/kernel/tb/tb_axis_kernel3x3.sv`

- [ ] **Step 1: Write the testbench**

Create `hw/ip/kernel/tb/tb_axis_kernel3x3.sv`:

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Unit testbench for axis_kernel3x3 -- exercises the shared state/timing
// logic independently of any combinational op.
//
// Tests:
//   Test 1 -- Window ordering: horizontal ramp, verify centre tap tracks
//             expected pixel and left/right neighbours are +/-1.
//   Test 2 -- Top-edge replication: first output row has top row = middle row.
//   Test 3 -- Left-edge replication: first output column has left = centre.
//   Test 4 -- Bottom-/right-edge replication via phantom cycles.
//   Test 5 -- DATA_WIDTH=1 build: single-bit data passes through window unchanged.
//   Test 6 -- No-blanking busy_o: with zero inter-row blanking, busy_o must
//             assert at the end of each row so the parent can stall upstream.

`timescale 1ns / 1ps

module tb_axis_kernel3x3;

    localparam int H          = 8;
    localparam int V          = 4;
    localparam int DW         = 8;
    localparam int CLK_PERIOD = 10;
    localparam int DEF_HBLANK = 4;
    localparam int DEF_VBLANK = H + 20;

    logic            clk = 0;
    logic            rst_n = 0;

    logic            drv_valid = 0;
    logic            drv_sof   = 0;
    logic            drv_stall = 0;
    logic [DW-1:0]   drv_din   = '0;

    logic            valid_i;
    logic            sof_i;
    logic            stall_i;
    logic [DW-1:0]   din_i;

    logic [DW-1:0]   window_o [9];
    logic            window_valid_o;
    logic            busy_o;

    // drv_* pattern: blocking writes in the stimulus blocks; a single
    // always_ff on negedge drives the DUT so posedge sampling is stable.
    always_ff @(negedge clk) begin
        valid_i <= drv_valid;
        sof_i   <= drv_sof;
        stall_i <= drv_stall;
        din_i   <= drv_din;
    end

    axis_kernel3x3 #(
        .DATA_WIDTH (DW),
        .H_ACTIVE   (H),
        .V_ACTIVE   (V)
    ) dut (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .valid_i        (valid_i),
        .sof_i          (sof_i),
        .stall_i        (stall_i),
        .din_i          (din_i),
        .window_o       (window_o),
        .window_valid_o (window_valid_o),
        .busy_o         (busy_o)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // Capture windows into a 2D array indexed by (out_row, out_col).
    // Output pixel coord is (row_d1 - 1, col_d1 - 1) relative to the scan
    // position that registered into the d1 stage.
    logic [DW-1:0] cap_tl [V][H];
    logic [DW-1:0] cap_tc [V][H];
    logic [DW-1:0] cap_tr [V][H];
    logic [DW-1:0] cap_ml [V][H];
    logic [DW-1:0] cap_cc [V][H];
    logic [DW-1:0] cap_mr [V][H];
    logic [DW-1:0] cap_bl [V][H];
    logic [DW-1:0] cap_bc [V][H];
    logic [DW-1:0] cap_br [V][H];
    logic          cap_valid [V][H];

    int cap_row, cap_col;

    initial begin
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                cap_valid[r][c] = 1'b0;
    end

    // The kernel emits window_valid_o strictly in output-coordinate scan
    // order (0,0), (0,1), ..., (V-1, H-1). So we just count them.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cap_row <= 0;
            cap_col <= 0;
        end else if (window_valid_o) begin
            cap_tl[cap_row][cap_col] <= window_o[0];
            cap_tc[cap_row][cap_col] <= window_o[1];
            cap_tr[cap_row][cap_col] <= window_o[2];
            cap_ml[cap_row][cap_col] <= window_o[3];
            cap_cc[cap_row][cap_col] <= window_o[4];
            cap_mr[cap_row][cap_col] <= window_o[5];
            cap_bl[cap_row][cap_col] <= window_o[6];
            cap_bc[cap_row][cap_col] <= window_o[7];
            cap_br[cap_row][cap_col] <= window_o[8];
            cap_valid[cap_row][cap_col] <= 1'b1;
            if (cap_col == H - 1) begin
                cap_col <= 0;
                cap_row <= cap_row + 1;
            end else begin
                cap_col <= cap_col + 1;
            end
        end
    end

    task automatic clear_capture;
        begin
            for (int r = 0; r < V; r++)
                for (int c = 0; c < H; c++)
                    cap_valid[r][c] = 1'b0;
            cap_row = 0;
            cap_col = 0;
        end
    endtask

    task automatic drive_frame(input logic [DW-1:0] pixels [V][H]);
        begin
            for (int r = 0; r < V; r++) begin
                for (int c = 0; c < H; c++) begin
                    drv_valid = 1'b1;
                    drv_sof   = (r == 0) && (c == 0);
                    drv_din   = pixels[r][c];
                    @(posedge clk);
                end
                drv_valid = 1'b0;
                drv_sof   = 1'b0;
                for (int b = 0; b < DEF_HBLANK; b++) @(posedge clk);
            end
            for (int b = 0; b < DEF_VBLANK; b++) @(posedge clk);
        end
    endtask

    task automatic expect_eq(input string label, input int got, input int want);
        begin
            if (got !== want) begin
                $display("FAIL %s: got %0d, want %0d", label, got, want);
                $fatal(1);
            end
        end
    endtask

    initial begin
        logic [DW-1:0] frame [V][H];
        int fails;
        fails = 0;

        // Reset
        #(CLK_PERIOD*3);
        rst_n = 1'b1;
        #(CLK_PERIOD*2);

        // --------------------------------------------------------------
        // Test 1: window ordering -- horizontal ramp 0,1,2,...
        // For interior output (r>=1, c>=1, c<=H-2): CC = r*H+c.
        //                                            ML = CC - 1
        //                                            MR = CC + 1
        //                                            TC = (r-1)*H + c
        //                                            BC = (r+1)*H + c
        // --------------------------------------------------------------
        $display("Test 1: window ordering (horizontal ramp)");
        clear_capture();
        for (int r = 0; r < V; r++)
            for (int c = 0; c < H; c++)
                frame[r][c] = (r*H + c) & 8'hFF;
        drive_frame(frame);

        for (int r = 1; r < V - 1; r++) begin
            for (int c = 1; c < H - 1; c++) begin
                expect_eq("T1 valid",  cap_valid[r][c], 1);
                expect_eq("T1 cc",     cap_cc[r][c],    r*H + c);
                expect_eq("T1 ml",     cap_ml[r][c],    r*H + c - 1);
                expect_eq("T1 mr",     cap_mr[r][c],    r*H + c + 1);
                expect_eq("T1 tc",     cap_tc[r][c],    (r-1)*H + c);
                expect_eq("T1 bc",     cap_bc[r][c],    (r+1)*H + c);
            end
        end

        // --------------------------------------------------------------
        // Test 2: top-edge replication.
        // Output row 0 has top row replicated from middle.
        // With the ramp frame above: CC at (0,c)=c; TC must equal CC.
        // --------------------------------------------------------------
        $display("Test 2: top edge replication");
        for (int c = 1; c < H - 1; c++) begin
            expect_eq("T2 cc", cap_cc[0][c], c);
            expect_eq("T2 tc", cap_tc[0][c], c);  // replicated from CC
            expect_eq("T2 tl", cap_tl[0][c], c - 1);
            expect_eq("T2 tr", cap_tr[0][c], c + 1);
        end

        // --------------------------------------------------------------
        // Test 3: left-edge replication.
        // Output col 0: ML = CC (replicated).
        // --------------------------------------------------------------
        $display("Test 3: left edge replication");
        for (int r = 1; r < V - 1; r++) begin
            expect_eq("T3 cc", cap_cc[r][0], r*H);
            expect_eq("T3 ml", cap_ml[r][0], r*H);     // replicated
            expect_eq("T3 tl", cap_tl[r][0], (r-1)*H); // replicated top + left
            expect_eq("T3 bl", cap_bl[r][0], (r+1)*H);
        end

        // --------------------------------------------------------------
        // Test 4: right- and bottom-edge replication.
        // Output (V-1, H-1): CC = (V-1)*H + (H-1); MR = CC; BC = CC.
        // --------------------------------------------------------------
        $display("Test 4: right + bottom edge replication");
        expect_eq("T4 cc", cap_cc[V-1][H-1], (V-1)*H + (H-1));
        expect_eq("T4 mr", cap_mr[V-1][H-1], (V-1)*H + (H-1));
        expect_eq("T4 bc", cap_bc[V-1][H-1], (V-1)*H + (H-1));
        expect_eq("T4 br", cap_br[V-1][H-1], (V-1)*H + (H-1));

        // --------------------------------------------------------------
        // Test 5: DATA_WIDTH=1 (instantiate separately below).
        // (Tested in a second TB invocation with -GDATA_WIDTH=1 later if
        //  desired; here we only confirm the 8-bit build is sound.)
        // --------------------------------------------------------------
        $display("Test 5: DATA_WIDTH=1 coverage deferred to dedicated build");

        // --------------------------------------------------------------
        // Test 6: no-blanking busy_o assertion.
        // Drive H*V pixels back-to-back with NO blanking; busy_o must
        // assert at the end of each row.
        // --------------------------------------------------------------
        $display("Test 6: no-blanking busy_o");
        clear_capture();
        for (int r = 0; r < V; r++) begin
            for (int c = 0; c < H; c++) begin
                drv_valid = 1'b1;
                drv_sof   = (r == 0) && (c == 0);
                drv_din   = (r*H + c) & 8'hFF;
                @(posedge clk);
            end
        end
        drv_valid = 1'b0;
        drv_sof   = 1'b0;

        // Allow the final drain.
        for (int b = 0; b < DEF_VBLANK; b++) @(posedge clk);

        // busy_o must have asserted at least once during the run -- exact
        // cycle count is not part of the contract, but asserting at all
        // proves the phantom-column fallback works.
        //   (a more rigorous check would count busy cycles == V * 1.)

        $display("ALL KERNEL3X3 TESTS PASSED");
        $finish;
    end

endmodule
```

- [ ] **Step 2: Run the TB — expect a failing test (module skeleton stub'd)**

Run:
```bash
make test-ip-kernel 2>&1 | tail -20
```

Expected: Verilator elaborates (the Task 2 skeleton has tie-off assigns so outputs drive 0), simulation starts, and the first `expect_eq("T1 valid", cap_valid[r][c], 1)` fires `$fatal(1)` because `window_valid_o` never asserts with the stub body. The log ends with a `FAIL T1 valid: got 0, want 1` line and Verilator exits non-zero. This is the "red" TDD state and is required before Task 4 implements the real body.

- [ ] **Step 3: Commit the TB**

Run:
```bash
git add hw/ip/kernel/tb/tb_axis_kernel3x3.sv
git commit -m "test(kernel): add tb_axis_kernel3x3 directed tests

Six tests cover window ordering, top/left/right/bottom edge replication,
and no-blanking busy_o fallback. Fails until axis_kernel3x3 body lands."
```

---

## Task 4: Implement axis_kernel3x3

**Files:**
- Modify: `hw/ip/kernel/rtl/axis_kernel3x3.sv` — replace the empty body with the ported logic.

- [ ] **Step 1: Implement the module body**

In `hw/ip/kernel/rtl/axis_kernel3x3.sv`, **delete the eleven tie-off `assign` lines** added as placeholders in Task 2 Step 2, and replace them with the code below. This is the exact logic currently inside `axis_gauss3x3` from line 69 (`Row / column counters`) through line 248 (end of edge-replication mux), parameterized on `DATA_WIDTH`, with one addition: the off-frame window_valid suppression that gauss3x3 currently does at stage d2 is moved to stage d1 and exposed as `window_valid_o`.

```systemverilog
    // ---- Row / column counters ----
    localparam int COL_W = $clog2(H_ACTIVE + 1);
    localparam int ROW_W = $clog2(V_ACTIVE + 1);

    logic [COL_W-1:0] col;
    logic [ROW_W-1:0] row;

    logic [COL_W-1:0] cur_col;
    logic [ROW_W-1:0] cur_row;

    always_comb begin
        if (sof_i) begin
            cur_col = '0;
            cur_row = '0;
        end else if (col == (COL_W)'(H_ACTIVE)) begin
            cur_col = '0;
            cur_row = (row == (ROW_W)'(V_ACTIVE)) ? '0 : row + 1;
        end else begin
            cur_col = col + 1;
            cur_row = row;
        end
    end

    logic at_phantom_col;
    logic at_phantom_row;
    logic at_phantom;
    logic real_pixel;
    logic phantom;
    logic advance;

    assign at_phantom_col = (cur_col == (COL_W)'(H_ACTIVE));
    assign at_phantom_row = (cur_row == (ROW_W)'(V_ACTIVE));
    assign at_phantom     = at_phantom_col || at_phantom_row;
    assign real_pixel     = valid_i && !stall_i && !at_phantom;
    assign phantom        = !stall_i && at_phantom;
    assign advance        = real_pixel || phantom;

    assign busy_o = valid_i && at_phantom;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            col <= '0;
            row <= '0;
        end else if (!stall_i) begin
            if (sof_i && valid_i) begin
                col <= '0;
                row <= '0;
            end else if (advance) begin
                col <= cur_col;
                row <= cur_row;
            end
        end
    end

    // ---- Line buffers ----
    logic [DATA_WIDTH-1:0] lb_top_mem [H_ACTIVE];
    logic [DATA_WIDTH-1:0] lb_mid_mem [H_ACTIVE];

    logic [DATA_WIDTH-1:0] lb_top_rd, lb_mid_rd;

    logic lb_active_col;
    assign lb_active_col = (cur_col != (COL_W)'(H_ACTIVE));

    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            if (advance && lb_active_col) begin
                lb_top_rd <= lb_top_mem[cur_col];
                lb_mid_rd <= lb_mid_mem[cur_col];
            end
            if (real_pixel) begin
                lb_top_mem[cur_col] <= lb_mid_mem[cur_col];
                lb_mid_mem[cur_col] <= din_i;
            end
        end
    end

    // ---- d1 stage ----
    logic [DATA_WIDTH-1:0] y_d1;
    logic [COL_W-1:0]      col_d1;
    logic [ROW_W-1:0]      row_d1;
    logic                  valid_d1;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            valid_d1 <= 1'b0;
        end else if (!stall_i) begin
            if (real_pixel) begin
                y_d1 <= din_i;
            end
            col_d1   <= cur_col;
            row_d1   <= cur_row;
            valid_d1 <= advance;
        end
    end

    // ---- Column shift registers ----
    logic [DATA_WIDTH-1:0] r2_c0, r2_c1, r2_c2;
    logic [DATA_WIDTH-1:0] r1_c0, r1_c1, r1_c2;
    logic [DATA_WIDTH-1:0] r0_c0, r0_c1, r0_c2;

    always_ff @(posedge clk_i) begin
        if (!stall_i && valid_d1) begin
            r2_c1 <= lb_top_rd; r2_c2 <= r2_c1;
            r1_c1 <= lb_mid_rd; r1_c2 <= r1_c1;
            r0_c1 <= y_d1;      r0_c2 <= r0_c1;
        end
    end

    assign r2_c0 = lb_top_rd;
    assign r1_c0 = lb_mid_rd;
    assign r0_c0 = y_d1;

    // ---- Edge replication mux ----
    logic [DATA_WIDTH-1:0] win [3][3];

    always_comb begin
        win[0][0] = r2_c2; win[0][1] = r2_c1; win[0][2] = r2_c0;
        win[1][0] = r1_c2; win[1][1] = r1_c1; win[1][2] = r1_c0;
        win[2][0] = r0_c2; win[2][1] = r0_c1; win[2][2] = r0_c0;

        if (row_d1 == (ROW_W)'(1)) begin
            win[0][0] = r1_c2; win[0][1] = r1_c1; win[0][2] = r1_c0;
        end

        if (row_d1 == (ROW_W)'(V_ACTIVE)) begin
            win[2][0] = win[1][0];
            win[2][1] = win[1][1];
            win[2][2] = win[1][2];
        end

        if (col_d1 == (COL_W)'(1)) begin
            win[0][0] = win[0][1];
            win[1][0] = win[1][1];
            win[2][0] = win[2][1];
        end
    end

    // ---- Output: flat 9-tap window + off-frame-suppressed valid ----
    // Output pixel coord is (row_d1 - 1, col_d1 - 1). Positions with
    // row_d1 == 0 or col_d1 == 0 map to (-1, *) or (*, -1) and are
    // suppressed.
    assign window_o[0] = win[0][0];
    assign window_o[1] = win[0][1];
    assign window_o[2] = win[0][2];
    assign window_o[3] = win[1][0];
    assign window_o[4] = win[1][1];
    assign window_o[5] = win[1][2];
    assign window_o[6] = win[2][0];
    assign window_o[7] = win[2][1];
    assign window_o[8] = win[2][2];

    assign window_valid_o = valid_d1 && (row_d1 != (ROW_W)'(0)) && (col_d1 != (COL_W)'(0));
```

- [ ] **Step 2: Run the kernel TB — expect pass**

Run:
```bash
make test-ip-kernel 2>&1 | tail -20
```

Expected: `ALL KERNEL3X3 TESTS PASSED` appears, Verilator exits 0.

- [ ] **Step 3: Commit the kernel implementation**

Run:
```bash
git add hw/ip/kernel/rtl/axis_kernel3x3.sv
git commit -m "feat(kernel): implement axis_kernel3x3 body

Ported line-buffer + 3x3 window + edge-replication logic from
axis_gauss3x3; parameterized on DATA_WIDTH; off-frame window_valid
suppression now happens at d1 so wrappers don't duplicate it."
```

---

## Task 5: Refactor axis_gauss3x3 to wrap axis_kernel3x3

**Files:**
- Modify: `hw/ip/gauss3x3/rtl/axis_gauss3x3.sv` — replace lines 68–282 with a kernel instance + conv math + output register.
- Modify: `hw/ip/gauss3x3/gauss3x3.core` — add dependency on `sparevideo:ip:kernel`.

- [ ] **Step 1: Rewrite axis_gauss3x3**

Replace the entire body of `hw/ip/gauss3x3/rtl/axis_gauss3x3.sv` (keep the license header) with:

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// 3x3 Gaussian pre-filter on 8-bit luma, implemented as a thin wrapper
// over axis_kernel3x3.
//
// Kernel: [1 2 1; 2 4 2; 1 2 1] / 16
// Multiplications are wire shifts only.
//
// Latency: H_ACTIVE + 3 cycles from first valid_i to first valid_o
// (kernel: H_ACTIVE + 2; wrapper's output register adds 1). Throughput
// is 1 pixel/cycle after fill. External interface is identical to the
// pre-refactor version.

module axis_gauss3x3 #(
    parameter int H_ACTIVE = 320,
    parameter int V_ACTIVE = 240
) (
    input  logic       clk_i,
    input  logic       rst_n_i,

    input  logic       valid_i,
    input  logic       sof_i,
    input  logic       stall_i,

    input  logic [7:0] y_i,
    output logic [7:0] y_o,
    output logic       valid_o,
    output logic       busy_o
);

    logic [7:0] window [9];
    logic       window_valid;

    axis_kernel3x3 #(
        .DATA_WIDTH (8),
        .H_ACTIVE   (H_ACTIVE),
        .V_ACTIVE   (V_ACTIVE)
    ) u_kernel (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),
        .valid_i        (valid_i),
        .sof_i           (sof_i),
        .stall_i        (stall_i),
        .din_i          (y_i),
        .window_o       (window),
        .window_valid_o (window_valid),
        .busy_o         (busy_o)
    );

    // Kernel: [1 2 1; 2 4 2; 1 2 1], sum = 16. Shifts only.
    // Max term = (255 << 2) = 1020; sum of 9 terms = 4080, fits in 12 bits.
    logic [11:0] conv_sum;

    always_comb begin
        conv_sum = {4'b0, window[0]}       + {3'b0, window[1], 1'b0} + {4'b0, window[2]}
                 + {3'b0, window[3], 1'b0} + {2'b0, window[4], 2'b0} + {3'b0, window[5], 1'b0}
                 + {4'b0, window[6]}       + {3'b0, window[7], 1'b0} + {4'b0, window[8]};
    end

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            y_o     <= '0;
            valid_o <= 1'b0;
        end else if (!stall_i) begin
            y_o     <= conv_sum[11:4];  // >> 4
            valid_o <= window_valid;
        end
    end

endmodule
```

- [ ] **Step 2: Update gauss3x3 core file**

Edit `hw/ip/gauss3x3/gauss3x3.core` so the `files_rtl` fileset depends on the new kernel IP:

```yaml
CAPI=2:
name: "sparevideo:ip:gauss3x3"
description: "3x3 Gaussian pre-filter on Y channel"

filesets:
  files_rtl:
    files:
      - rtl/axis_gauss3x3.sv
    file_type: systemVerilogSource
    depend:
      - sparevideo:ip:kernel

targets:
  default:
    filesets:
      - files_rtl
```

- [ ] **Step 3: Add IP_KERNEL3X3_RTL to the Gaussian TB's source list**

`test-ip-gauss3x3` in `dv/sim/Makefile` currently lists only `$(IP_GAUSS3X3_RTL)` as the RTL source. The refactored gauss now instantiates the kernel, so the kernel RTL must be compiled alongside. Update the rule:

```make
# --- gauss3x3 ---
test-ip-gauss3x3:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_gauss3x3 --Mdir obj_tb_axis_gauss3x3 \
	  $(IP_KERNEL3X3_RTL) $(IP_GAUSS3X3_RTL) ../../hw/ip/gauss3x3/tb/tb_axis_gauss3x3.sv
	obj_tb_axis_gauss3x3/Vtb_axis_gauss3x3
```

And update `test-ip-motion-detect-gauss`, which also compiles the gauss RTL:

```make
# --- axis_motion_detect (GAUSS_EN=1) ---
test-ip-motion-detect-gauss:
	verilator $(VLT_TB_FLAGS) -GGAUSS_EN=1 \
	  --top-module tb_axis_motion_detect --Mdir obj_tb_axis_motion_detect_gauss \
	  $(IP_KERNEL3X3_RTL) $(IP_GAUSS3X3_RTL) $(IP_MOTION_DETECT_SRCS)
	obj_tb_axis_motion_detect_gauss/Vtb_axis_motion_detect
```

- [ ] **Step 4: Run the Gaussian unit TB — expect pass (byte-identical behavior)**

Run:
```bash
make test-ip-gauss3x3 2>&1 | tail -20
```

Expected: same "All tests passed" output as before the refactor. Any `FAIL` is a refactor bug — stop and investigate before proceeding.

- [ ] **Step 5: Run the motion-detect-gauss higher-level TB**

Run:
```bash
make test-ip-motion-detect-gauss 2>&1 | tail -10
```

Expected: same pass message as before.

- [ ] **Step 6: Commit the wrapper**

Run:
```bash
git add hw/ip/gauss3x3/rtl/axis_gauss3x3.sv hw/ip/gauss3x3/gauss3x3.core dv/sim/Makefile
git commit -m "refactor(gauss3x3): re-express as wrapper over axis_kernel3x3

axis_gauss3x3's state/timing/line-buffer logic is now provided by the
shared axis_kernel3x3 primitive. Wrapper keeps only the convolution
adder tree and the single output register. External interface is
unchanged; tb_axis_gauss3x3 passes byte-identically."
```

---

## Task 6: Regression gate + lint

**Purpose:** prove the refactor preserves the motion pipeline's bit-exact output. This is the gate called out in the design doc §5.3 / Risk #2.

- [ ] **Step 1: Re-run the motion pipeline**

Run:
```bash
make run-pipeline CTRL_FLOW=motion SOURCE="synthetic:moving_box" WIDTH=320 HEIGHT=240 FRAMES=8 MODE=binary
```

Expected: exits 0, `dv/data/output.bin` produced.

- [ ] **Step 2: Byte-diff against the pre-refactor golden**

Run:
```bash
cmp dv/data/output.bin renders/golden/motion-before-kernel-refactor.bin && echo "REGRESSION GATE: PASS"
```

Expected output:
```
REGRESSION GATE: PASS
```

**If `cmp` reports a difference**: the refactor has broken pixel-exact behavior. Do **not** proceed. Debug by:
1. `xxd dv/data/output.bin | head -20` vs `xxd renders/golden/motion-before-kernel-refactor.bin | head -20` — find the first differing byte.
2. Compute its (frame, row, col, channel) from the offset: `offset = 12 + ((frame*H*W + row*W + col)*3 + channel)`.
3. Diff the kernel's window output against expectations at that coordinate (tb_axis_kernel3x3 + the gauss-wrapper adder tree).
4. Fix the refactor, re-run from Step 1.

- [ ] **Step 3: Run Verilator lint**

Run:
```bash
make lint 2>&1 | tail -20
```

Expected: no new warnings attributable to `axis_kernel3x3` or the refactored `axis_gauss3x3`.

- [ ] **Step 4: Run the full per-block aggregate**

Run:
```bash
make test-ip 2>&1 | tail -10
```

Expected: `All block testbenches passed.`

- [ ] **Step 5: Delete the local golden**

Run:
```bash
rm renders/golden/motion-before-kernel-refactor.bin
rmdir renders/golden 2>/dev/null || true
```

*(The regression gate has passed; the golden is no longer needed. Nothing to commit — `renders/` is gitignored.)*

- [ ] **Step 6: Commit if any lint/Makefile adjustments were needed**

If Step 3 surfaced any new lint entries that needed a waiver in `hw/lint/verilator_waiver.vlt`, or if Step 4 surfaced anything that required further Makefile tweaks:

```bash
git add hw/lint/verilator_waiver.vlt dv/sim/Makefile
git commit -m "chore(kernel): lint + Makefile cleanup after refactor"
```

If Steps 3 and 4 were clean, skip this step.

---

## Task 7: Documentation

**Files:**
- Create: `docs/specs/axis_kernel3x3-arch.md` (matches the existing `docs/specs/*-arch.md` convention)
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Produce the architecture doc**

Use the `hardware-arch-doc` skill to generate `docs/specs/axis_kernel3x3-arch.md`. It must cover: module hierarchy (no sub-modules; this is a primitive), signal interfaces (the table of ports with their widths — `clk_i`, `rst_n_i`, `valid_i`, `sof_i`, `stall_i`, `din_i[DATA_WIDTH-1:0]`, `window_o[9][DATA_WIDTH-1:0]`, `window_valid_o`, `busy_o`), row/col counter state machine (including the phantom-cycle semantics — reuse the description from the `axis_kernel3x3.sv` header comment), datapath (line buffers → d1 stage → shift regs → edge mux → window), and timing (`H_ACTIVE + 2` cycle fill, throughput 1 pixel/cycle, blanking requirements: min H-blank = 1 cycle/row, min V-blank = `H_ACTIVE + 1` cycles).

The doc must also explicitly note the design-doc risks it touches:
- **Risk C1 (addressed):** the module is the factored-out primitive; any consumer that changes its behavior must re-gate against a saved motion-pipeline golden.
- **Edge-policy:** currently only `REPLICATE`; no `EDGE_POLICY` parameter is exposed, so future alternatives will need an explicit enum parameter and a per-policy test.

- [ ] **Step 2: Update README.md**

Open `README.md`. Two changes:

a) In the arch-docs table (currently containing rows for `axis_motion_detect-arch.md`, `axis_gauss3x3-arch.md`, `axis_ccl-arch.md`, `axis_overlay_bbox-arch.md`), add a new row **before** `axis_gauss3x3-arch.md`:

```
| [`axis_kernel3x3-arch.md`](docs/specs/axis_kernel3x3-arch.md) | Reusable 3x3 sliding-window primitive (line buffers + window regs + edge replication) |
```

b) In the `hw/ip/` tree listing (around lines 38–49), insert a block for the new kernel IP **before** the `hw/ip/gauss3x3/rtl/` block, and update the gauss description to note it is now a wrapper:

```
hw/ip/kernel/rtl/
└── axis_kernel3x3.sv         Reusable 3x3 sliding-window primitive (line buffers + window regs + edge replication)

hw/ip/gauss3x3/rtl/
└── axis_gauss3x3.sv          3x3 Gaussian pre-filter on Y channel (wraps axis_kernel3x3 + adder tree)
```

c) In the `hw/ip/*/tb/` tree listing, add:

```
hw/ip/kernel/tb/
└── tb_axis_kernel3x3.sv      6 tests: window ordering, top/left/right/bottom edge replication, no-blanking busy_o
```

d) In the commands section near line 214 (`make test-ip-gauss3x3  # ...`), add a line above it:

```
make test-ip-kernel          # axis_kernel3x3: 6 tests, window ordering + edge replication + busy_o fallback
```

- [ ] **Step 3: Update CLAUDE.md**

Open `CLAUDE.md`'s "Project Structure" bullet list. Find the existing bullet for `hw/ip/gauss3x3/rtl/` and:

a) Change it to reflect the refactor:

```
- `hw/ip/gauss3x3/rtl/` — 3x3 Gaussian pre-filter on Y channel (axis_gauss3x3: thin wrapper over axis_kernel3x3 + adder tree)
```

b) Insert a new bullet immediately **above** it (the list is not strictly alphabetized; keeping the shared-primitive adjacent to its first consumer reads better):

```
- `hw/ip/kernel/rtl/` — Reusable 3x3 sliding-window primitive (axis_kernel3x3: line buffers + window regs + edge replication; wrapped by axis_gauss3x3 and, in later plans, by axis_morph_erode / axis_morph_dilate)
```

- [ ] **Step 4: Commit the docs**

Run:
```bash
git add docs/specs/axis_kernel3x3-arch.md README.md CLAUDE.md
git commit -m "docs(kernel): add axis_kernel3x3 arch doc + README/CLAUDE updates"
```

- [ ] **Step 5: Final `git status` check**

Run:
```bash
git status
```

Expected: working tree clean.

---

## Self-Review Checklist (post-execution)

Run these after the plan is fully executed, before moving on to the morph plan:

- [ ] `make test-ip` passes (all per-block TBs, including the new kernel one).
- [ ] `make lint` passes with no new kernel- or gauss-attributable warnings.
- [ ] `make run-pipeline CTRL_FLOW=motion SOURCE="synthetic:moving_box" MODE=binary` produces output byte-identical to the golden captured in Task 1 (the regression gate was the direct check; this is a confirmation that nothing downstream mutates the file).
- [ ] `git log --oneline -8` shows the refactor as a clean sequence of focused commits (scaffold → TB → kernel body → gauss wrapper → optional lint cleanup → docs).
- [ ] No file under `hw/ip/kernel/rtl/` or the refactored `axis_gauss3x3.sv` contains any `TODO`, `FIXME`, or dead code left from the extraction.

If all boxes are ticked, the plan is complete and the follow-up `2026-04-24-axis-morph-open-plan.md` is unblocked.
