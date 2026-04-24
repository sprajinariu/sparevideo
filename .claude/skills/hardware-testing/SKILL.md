---
name: hardware-testing
description: Use when writing SystemVerilog unit testbenches or integration tests for hardware verification in the sparevideo project.
---

# Hardware Testing

## Overview

Two test layers exist in sparevideo: **SV unit testbenches** (one per RTL module) and **SV integration testbench** (one for the whole sparevideo_top module). Both layers must pass before a module is complete.

## Layer 1: SV Unit Testbenches

One testbench per RTL module. Lives in `hw/ip/<module>/tb/tb_<module>.sv`.

### Testbench Template

**Critical**: Always use `drv_*` intermediaries with blocking `=` in the initial block, then register them to DUT inputs via `always_ff @(posedge clk)`. This avoids Verilator INITIALDLY races where NBA assignments (`<=`) in initial blocks are treated as deferred and arrive after the DUT samples on posedge.

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps
module tb_<module>;

  localparam int CLK_PERIOD = 10; // ns

  // Clock
  logic clk = 0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // Reset
  logic rst_n;

  // Driver intermediaries — driven with blocking = in initial block
  logic [23:0] drv_tdata  = '0;
  logic        drv_tvalid = 1'b0;
  logic        drv_tlast  = 1'b0;
  logic        drv_tuser  = 1'b0;

  // DUT inputs — registered on posedge
  logic [23:0] s_tdata;
  logic        s_tvalid, s_tlast, s_tuser;

  always_ff @(posedge clk) begin
    s_tdata  <= drv_tdata;
    s_tvalid <= drv_tvalid;
    s_tlast  <= drv_tlast;
    s_tuser  <= drv_tuser;
  end

  // DUT outputs
  logic [23:0] m_tdata;
  logic        m_tvalid, m_tlast, m_tuser;
  logic        s_tready;

  // DUT instantiation — always named connections
  <module> u_dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .s_axis_tdata (s_tdata),
    .s_axis_tvalid(s_tvalid),
    .s_axis_tready(s_tready),
    .s_axis_tlast (s_tlast),
    .s_axis_tuser (s_tuser),
    .m_axis_tdata (m_tdata),
    .m_axis_tvalid(m_tvalid),
    .m_axis_tlast (m_tlast),
    .m_axis_tuser (m_tuser)
  );

  // Error counter
  integer num_errors = 0;

  // Check task
  task automatic check(
    input string      name,
    input logic [7:0] got,
    input logic [7:0] expected
  );
    if (got !== expected) begin
      $display("FAIL %s: got %02h expected %02h", name, got, expected);
      num_errors = num_errors + 1;
    end else
      $display("PASS %s", name);
  endtask

  initial begin
    // Reset
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // --- Test cases ---
    // Set drv_* with blocking =, then @(posedge clk) to advance,
    // then read DUT outputs (they are stable at/after posedge).

    drv_tdata  = 24'hRR_GG_BB;
    drv_tvalid = 1'b1;
    @(posedge clk);
    // sample output here

    // Report
    if (num_errors == 0) $display("ALL TESTS PASSED");
    else                 $fatal(1, "%0d TEST(S) FAILED", num_errors);
    $finish;
  end
endmodule
```

### Rules

- Your job is to discover implementation issues.
- Layer 1 testing should be more diligent than layer 2, since debugging effort is much larger in layer 2.
- Create basic tests that cover most use-cases. Synthetic data inputs are preffered for simplicity.
- Test backpressure mechanism does not disturb data content.
- Use `!==` (4-state inequality) not `!=` — catches `X` and `Z` propagation.
- Test boundary conditions: zero, max value, overflow, sign extension edge cases.
- Each test case is one `check()` call with a descriptive name.
- Always use `drv_*` + posedge register pattern for DUT inputs (see template above).
- Use `$display` + `num_errors` counter for accumulated failures; `$fatal(1, ...)` at end if any failed.
- **Verilator only** — Icarus Verilog is not maintained in this project and will likely fail.

### Adding to Makefile

Edit `dv/sim/Makefile`:

1. Add RTL sources to a variable (or reuse an existing one):
   ```makefile
   IP_<MODULE>_RTL = ../../hw/ip/<module>/rtl/<module>.sv
   ```

2. Add a per-block target:
   ```makefile
   test-ip-<module>:
   	verilator $(VLT_TB_FLAGS) --top-module tb_<module> --Mdir obj_tb_<module> \
   	  $(IP_<MODULE>_RTL) ../../hw/ip/<module>/tb/tb_<module>.sv
   	obj_tb_<module>/Vtb_<module>
   ```

3. Add the target to the `test-ip` aggregate:
   ```makefile
   test-ip: test-ip-rgb2ycrcb test-ip-motion-detect test-ip-bbox-reduce test-ip-overlay-bbox test-ip-<module>
   ```

4. Document usage of the new test-ip-<module> in README.md, Claude.md and help description of make commands.

Run all unit tests: `make test-ip`  
Run one block: `make -C dv/sim test-ip-<module>`  
Expected: `ALL TESTS PASSED`

## Layer 2: SV integration testbench

Lives in `dv/sv/tb_sparevideo.sv`. Focuses on correct pipeline operation, not pixel-exact data content: the pipeline does not stall, no screen tearing, VGA timing is correct.

### Rules

- Drive `s_axis_*` inputs using the same `drv_*` + posedge register pattern as unit testbenches.
- Mirror VGA timing: insert `H_BLANK` idle cycles (tvalid=0) after each active row and `V_BLANK × H_TOTAL` idle cycles after the last row. Driving continuously without blanking will overflow the output FIFO.
- Capture DUT output via `always @(negedge clk_pix)` to avoid races with DUT `always_ff` outputs.
- Check pipeline health, not pixel values: assert `s_axis_tready` never stuck low, `vga_hsync`/`vga_vsync` toggle at expected intervals, no X/Z on outputs.
- Include at least one test that deasserts `m_tready` mid-frame to exercise backpressure.

### Checking Results

- `make run-pipeline` runs the full flow: prepare → compile → sim → verify → render.
- `make verify` checks that output matches input within `TOLERANCE` pixels/frame (default `2*(W+H)` to allow the motion-detect bbox border).
- `make render` produces an input vs output comparison image in `renders/`.
- For a quick pass/fail without Python: inspect `$display` output from the testbench for `ALL TESTS PASSED` or error lines.
- To debug a failure, consult the **Debugging a failing simulation** section in `CLAUDE.md`.

## Test Coverage Requirements Per Module

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| `!=` instead of `!==` | Use `!==` to catch X/Z |
| No `#1` after combinational input change | Add `#1;` before reading output |
| Testing only happy path | Always test boundary and negative cases |
| Test not added to Makefile | Add to TESTS list in `sim/Makefile` |
