---
name: rtl-writing
description: Use when writing, editing, or reviewing SystemVerilog RTL modules for the sparevideo project. Covers file structure, coding conventions, signal declarations, always blocks, and lint compliance.
---

# RTL Writing

## Overview

Produce clean, lint-passing SystemVerilog RTL that follows the coding guidelines in `CLAUDE.md`. Every RTL file must be self-consistent, match the architecture document, and pass Verilator `--Wall` before committing.

## Checklist Before Writing Any RTL

- [ ] Architecture document exists and is up to date
- [ ] All port names and widths match the interface table in the arch doc
- [ ] `sparevideo_pkg.sv` has all required types — do not define types inline in modules

## File Template

Two naming conventions are used depending on the module type:

- **Single-clock IP modules** (`hw/ip/*/rtl/`): `clk_i`, `rst_n_i`
- **Top-level / multi-clock modules** (`hw/top/`): `clk_<domain>_i`, `rst_<domain>_n_i`

Use `_i`/`_o` port suffixes in this project. AXI4-Stream ports use the `s_axis_*` (sink) and `m_axis_*` (source) prefix convention.

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Single-clock IP module template
module <module_name> #(
    parameter int EXAMPLE_PARAM = 4
) (
    // --- Clocks and resets ---
    input  logic        clk_i,
    input  logic        rst_n_i,         // active-low synchronous reset

    // ---- AXI4-Stream input ------------------------------------------
    input  logic [23:0] s_axis_tdata_i,
    input  logic        s_axis_tvalid_i,
    output logic        s_axis_tready_o,
    input  logic        s_axis_tlast_i,
    input  logic        s_axis_tuser_i,

    // ---- AXI4-Stream output -----------------------------------------
    output logic [23:0] m_axis_tdata_o,
    output logic        m_axis_tvalid_o,
    input  logic        m_axis_tready_i,
    output logic        m_axis_tlast_o,
    output logic        m_axis_tuser_o
);
  import sparevideo_pkg::*;

  // Constants
  localparam int unsigned DEPTH = 4;

  // Datapath registers and FSMs (driven by always_ff)
  logic [31:0] state_q;

  // Combinational signals (driven by always_comb / assign)
  logic [31:0] next_state;

  // Submodule interface signals
  logic [31:0] sub_result;

  ...

endmodule
```

For multi-clock top-level modules, use `clk_pix_i`/`clk_dsp_i` and `rst_pix_n_i`/`rst_dsp_n_i` matching existing top-level conventions.

## Key Rules

**Signals**
- `logic` only — never `wire` or `reg`
- All signals declared at the top, grouped in order: constants → structs → state registers → combinational → submodule signals
- Active-low reset: `rst_n_i` (single-clock IPs) or `rst_<domain>_n_i` (top-level multi-clock)
- Use `_i`/`_o` port suffixes — use descriptive names or AXI4-Stream `s_axis_*`/`m_axis_*` prefix

**Always blocks**
- `always_ff` for registers, `always_comb` for combinational — nothing else
- `always_comb`: assign defaults at the top, then override in branches

**Case statements**
- `unique case` always — never plain `case`, `casex`, or `casez`
- Always include `default` branch

```systemverilog
// Correct
always_comb begin
  result = '0;                     // default
  unique case (op)
    ALU_ADD:  result = a + b;
    ALU_SUB:  result = a - b;
    default:  result = '0;
  endcase
end
```

**Signed arithmetic**
```systemverilog
// Signed comparison
$signed(a) < $signed(b)

// Arithmetic right shift
$signed(a) >>> b[4:0]

// Sign extension
{{24{byte_val[7]}}, byte_val}      // extend 8-bit to 32-bit
{{20{instr[31]}}, instr[31:20]}    // sign-extend 12-bit immediate
```

**Port connections**
- Named connections always: `.port(signal)` — never positional
- Unused outputs: `()` — unused inputs: `'0`

**Pipeline architecture**
- Add pipeline stages to split large combinational logic
- Prefer adding pipeline stages or FIFOs instead of back-pressure modules earlier in the pipeline.

**SVAs**
- Write SVAs at the bottom of modules to check assumptions required for correct operation.
- Verilator only — Icarus Verilog 12 does not support SVA. Never add SVA to files that must compile under Icarus.


## Lint

Run before every commit:

```bash
make lint
```

Fix all warnings. `--Wno-UNUSED` is the only suppression permitted.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| `always @(posedge clk)` | Use `always_ff @(posedge clk_i or negedge rst_ni)` |
| `always @(*)` | Use `always_comb` |
| `case` without `unique` | Use `unique case` |
| Missing `default` | Add `default: signal = '0;` |
| Signal declared mid-module | Move to declaration block at top |
| Positional port connection | Use named: `.port(signal)` |
| Latch inferred | Add default assignment at top of `always_comb` |
| Width mismatch silently truncates | Use explicit casts or intermediate signals |

## After Writing RTL

1. Run lint — fix all errors and warnings
2. Verify every port matches the architecture document
3. Update `sparevideo_top.core` if new files were added
4. Write or update the corresponding testbench (see `hardware-testing` skill)
