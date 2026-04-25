# axis_morph3x3_open Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 3×3 morphological opening stage (erode → dilate) operating on the 1-bit motion mask, wired into all three mask-producing control flows (motion, mask, ccl_bbox) behind a runtime `MORPH` enable.

**Architecture:** Two thin RTL wrappers (`axis_morph3x3_erode`, `axis_morph3x3_dilate`) each wrap `axis_window3x3 #(DATA_WIDTH=1)` and reduce the 9-tap window with a single 9-way logical op (AND for erode, OR for dilate). A composite `axis_morph3x3_open` instantiates erode → internal AXIS link → dilate. The stage sits inside `sparevideo_top` on the mask stream between `u_motion_detect` and its downstream consumers (mask→RGB expand, `axis_ccl`, mask-grey canvas). A shared `MORPH` runtime enable (tied to the Makefile `MORPH` knob via a parameter) gates both sub-modules; when low, both pass through transparently. The Python reference model gets a new op (`py/models/ops/morph_open.py`) that wraps `scipy.ndimage.binary_opening` with a 3×3 square structuring element and edge replication; it is composed into `motion.py`, `mask.py`, and `ccl_bbox.py` when `MORPH=1`.

**Tech Stack:** SystemVerilog (Verilator 5 / Icarus 12 compatible synthesis subset), Python (numpy + scipy.ndimage for the reference), FuseSoC core files, Makefile parameter propagation.

**Prerequisites:** The `axis_window3x3` primitive already exists at `hw/ip/window/rtl/axis_window3x3.sv` with 1-bit `DATA_WIDTH` support. The predecessor plan `2026-04-24-window3x3-refactor-plan.md` is already merged — this plan starts from its tip (or a branch forked from the same base if that plan is still open; note the dependency in the PR description per CLAUDE.md).

---

## File Structure

**New files:**
- `hw/ip/filters/rtl/axis_morph3x3_erode.sv` — 9-way AND over `axis_window3x3<1>` + output register + `enable_i` bypass.
- `hw/ip/filters/rtl/axis_morph3x3_dilate.sv` — 9-way OR over `axis_window3x3<1>` + output register + `enable_i` bypass.
- `hw/ip/filters/rtl/axis_morph3x3_open.sv` — composite: erode → internal AXIS → dilate. Forwards `enable_i` to both.
- `hw/ip/filters/tb/tb_axis_morph3x3_erode.sv` — unit TB (per-block, `drv_*` pattern).
- `hw/ip/filters/tb/tb_axis_morph3x3_dilate.sv` — unit TB.
- `hw/ip/filters/tb/tb_axis_morph3x3_open.sv` — unit TB covering salt removal, thin-stripe removal (documents Risk D1), and asymmetric-stall behaviour.
- `hw/ip/filters/docs/axis_morph3x3_open-arch.md` — architecture doc (covers all three morph modules as one stage).
- `py/models/ops/__init__.py` — new ops package (empty module marker; future ops land here too).
- `py/models/ops/morph_open.py` — reference model for 3×3 opening with edge replication, frame-by-frame.
- `py/tests/test_morph_open.py` — unit test for the reference model against hand-crafted 8×8 goldens.

**Modified files:**
- `hw/ip/filters/filters.core` — add the three new RTL sources.
- `hw/top/sparevideo_top.sv` — instantiate `axis_morph3x3_open` on `msk_*` stream, rewire three downstream consumers.
- `dv/sv/tb_sparevideo.sv` — add `MORPH` parameter, propagate to DUT.
- `dv/sim/Makefile` — add `MORPH ?= 1` default, `-GMORPH=$(MORPH)` flag, include in `CONFIG_STAMP`, add `test-ip-morph3x3-erode`, `test-ip-morph3x3-dilate`, `test-ip-morph3x3-open` targets, wire into `test-ip` and `clean`.
- `Makefile` (top) — add `MORPH ?= 1`, include in `SIM_VARS`, `config.mk`, `verify`/`render` argument lists, `help` output.
- `py/harness.py` — add `--morph` argument plumbing (prepare / verify / render).
- `py/models/__init__.py` — accept `morph_en` kwarg, pass to motion/mask/ccl_bbox run functions.
- `py/models/motion.py` — apply `morph_open` op to mask after `_compute_mask` when `morph_en=True`.
- `py/models/mask.py` — same composition.
- `py/models/ccl_bbox.py` — same composition.
- `py/frames/video_source.py` — add `thin_moving_line` synthetic pattern (Risk D1 exercise).
- `requirements.txt` — add `scipy` (new dep for the reference model).
- `README.md` — document the new IP + `MORPH` knob.
- `CLAUDE.md` — document the `MORPH` knob + build-command example.

**No changes required:** `hw/top/sparevideo_pkg.sv` (no new shared types), `hw/ip/window/` (primitive already has 1-bit support), `hw/ip/motion/` (morph_open sits outside motion_detect at the top).

---

## Task 1: Architecture doc

**Files:**
- Create: `hw/ip/filters/docs/axis_morph3x3_open-arch.md`

- [ ] **Step 1: Write the arch doc**

Use the `hardware-arch-doc` skill. The doc must cover all three modules (`axis_morph3x3_erode`, `axis_morph3x3_dilate`, `axis_morph3x3_open`) as one logical stage. Required sections:

1. **Purpose** — 3×3 square opening on a 1-bit mask; removes salt noise (isolated foreground pixels) and erodes thin stripes (< 3 px wide), then restores surviving blobs to approximate original size.
2. **Ports** — standard AXIS (`tdata[0:0]`, `tvalid`, `tready`, `tlast=eol`, `tuser=sof`) + `enable_i` sideband.
3. **Parameters** — `H_ACTIVE`, `V_ACTIVE` (passed through to both `axis_window3x3` instances).
4. **Internal structure** — ASCII block diagram: `axis_morph3x3_erode` → internal AXIS link → `axis_morph3x3_dilate`. Each wrapper = `axis_window3x3<1>` + one `always_comb` 9-way reduction + one output register.
5. **Edge policy** — `EDGE_REPLICATE` from `axis_window3x3` (only policy today).
6. **Latency** — `2 × (H_ACTIVE + 3)` cycles end-to-end (two full window fills). Throughput = 1 pixel/cycle after fill.
7. **Blanking requirements** — forwarded from `axis_window3x3`: per-row H-blank ≥ 1, V-blank ≥ H_ACTIVE + 1. The two instances are pipelined, so the blanking budget does not double.
8. **`enable_i` semantics** — when low, the combinational reduction is bypassed: each sub-module forwards `s_axis_*` to `m_axis_*` directly (no line-buffer latency). Must be held stable across a frame; toggling mid-frame is undefined.
9. **Risk D1 (from design)** — 3×3 square opening deletes features < 3 px wide. Document that the synthetic test suite gains a `thin_moving_line` source to exercise this.
10. **Verification** — list the three unit TBs + the top-level integration regression matrix.

- [ ] **Step 2: Commit**

```bash
git add hw/ip/filters/docs/axis_morph3x3_open-arch.md
git commit -m "docs(morph): add axis_morph3x3_open architecture doc"
```

---

## Task 2: `axis_morph3x3_erode` RTL + unit TB (TDD)

**Files:**
- Create: `hw/ip/filters/rtl/axis_morph3x3_erode.sv`
- Create: `hw/ip/filters/tb/tb_axis_morph3x3_erode.sv`
- Modify: `dv/sim/Makefile` (add target)

- [ ] **Step 1: Write the failing unit TB**

Create `hw/ip/filters/tb/tb_axis_morph3x3_erode.sv`. Model after `hw/ip/filters/tb/tb_axis_gauss3x3.sv` — same `drv_*` pattern, same `@(posedge clk)` driver register, same blanking-aware `drive_frame` / `drive_frame_stall` / `drive_frame_noblank` tasks. Parameters: `H=16`, `V=8`. Tests (each writes `frame_img`, computes `golden_out` via the golden task, drives + captures, calls `check_frame`):

```systemverilog
// Test 1: All-ones → all-ones (AND of nine 1s = 1)
// Test 2: All-zeros → all-zeros
// Test 3: Isolated single pixel at (4,4)=1, rest 0 → all-zeros output (erosion removes it)
// Test 4: 3×3 solid block at rows 3..5, cols 4..6 → output has a single 1 at (4,5), rest 0
// Test 5: Horizontal stripe at row 4, all cols = 1, rest 0 → output all-zeros
//         (a 1-px-tall stripe has a 0 neighbour above and below, AND → 0)
// Test 6: 3-row-tall stripe at rows 3..5, all cols = 1 → output row 4 all 1s, rows 3 and 5 all 0s
//         (rows 3 and 5 have a 0 neighbour on the outside edge, so edge replication still → 0
//         at the bottom/top after extending the 0-row)
// Test 7: enable_i=0 passthrough: checker pattern → output == input bit-for-bit, no latency
// Test 8: Stall behaviour: drive_frame_stall + compare to no-stall reference (golden_out)
// Test 9: Multi-frame SOF reset: drive frame A = all-ones, then frame B = all-zeros; B must NOT
//         show leakage from A after the window fill.
```

Golden task — straight 3×3 AND with EDGE_REPLICATE:

```systemverilog
function automatic logic erode_golden(
    input logic img [V][H],
    input int r, input int c
);
    int rr, cc;
    logic out;
    out = 1'b1;
    for (int dr = 0; dr < 3; dr++) begin
        for (int dc = 0; dc < 3; dc++) begin
            rr = r + dr - 1; cc = c + dc - 1;
            if (rr < 0) rr = 0; if (rr >= V) rr = V - 1;
            if (cc < 0) cc = 0; if (cc >= H) cc = H - 1;
            out = out & img[rr][cc];
        end
    end
    return out;
endfunction
```

The DUT instantiation references `axis_morph3x3_erode` with `.H_ACTIVE(H), .V_ACTIVE(V)`, ports: `clk_i, rst_n_i, enable_i, s_axis_tdata_i, s_axis_tvalid_i, s_axis_tready_o, s_axis_tlast_i, s_axis_tuser_i, m_axis_tdata_o, m_axis_tvalid_o, m_axis_tready_i, m_axis_tlast_o, m_axis_tuser_o, busy_o`.

- [ ] **Step 2: Add Makefile target**

Edit `dv/sim/Makefile`. Add under the IP-sources block (next to `IP_GAUSS3X3_RTL`):

```make
IP_MORPH3X3_ERODE_RTL  = ../../hw/ip/filters/rtl/axis_morph3x3_erode.sv
IP_MORPH3X3_DILATE_RTL = ../../hw/ip/filters/rtl/axis_morph3x3_dilate.sv
IP_MORPH3X3_OPEN_RTL   = ../../hw/ip/filters/rtl/axis_morph3x3_open.sv
```

Update `test-ip` aggregate (currently line ~131) to include the three new subtargets — do NOT remove existing ones:

```make
test-ip: test-ip-rgb2ycrcb test-ip-window test-ip-gauss3x3 test-ip-motion-detect test-ip-motion-detect-gauss test-ip-overlay-bbox test-ip-ccl test-ip-morph3x3-erode test-ip-morph3x3-dilate test-ip-morph3x3-open
	@echo "All block testbenches passed."
```

Update `.PHONY` list at the top of the file to include `test-ip-morph3x3-erode test-ip-morph3x3-dilate test-ip-morph3x3-open`.

Append after `test-ip-gauss3x3`:

```make
# --- axis_morph3x3_erode ---
test-ip-morph3x3-erode:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_morph3x3_erode --Mdir obj_tb_axis_morph3x3_erode \
	  $(IP_WINDOW3X3_RTL) $(IP_MORPH3X3_ERODE_RTL) ../../hw/ip/filters/tb/tb_axis_morph3x3_erode.sv
	obj_tb_axis_morph3x3_erode/Vtb_axis_morph3x3_erode
```

Update the `clean` target's `rm -rf` list to include `obj_tb_axis_morph3x3_erode obj_tb_axis_morph3x3_dilate obj_tb_axis_morph3x3_open`.

- [ ] **Step 3: Run the TB — expected FAIL**

```bash
cd dv/sim && make test-ip-morph3x3-erode
```

Expected: Verilator errors out because `axis_morph3x3_erode.sv` does not exist.

- [ ] **Step 4: Write the minimal RTL**

Create `hw/ip/filters/rtl/axis_morph3x3_erode.sv`:

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// 3x3 morphological erosion on a 1-bit mask stream. Thin wrapper over
// axis_window3x3 #(DATA_WIDTH=1): output = AND of all 9 window taps.
// enable_i=0 bypasses the window (zero-latency passthrough).
//
// Latency (enable_i=1): H_ACTIVE + 3 cycles.
// Throughput: 1 pixel/cycle after fill.

module axis_morph3x3_erode #(
    parameter int H_ACTIVE = 320,
    parameter int V_ACTIVE = 240
) (
    input  logic clk_i,
    input  logic rst_n_i,
    input  logic enable_i,

    // AXI4-Stream input (1-bit mask)
    input  logic s_axis_tdata_i,
    input  logic s_axis_tvalid_i,
    output logic s_axis_tready_o,
    input  logic s_axis_tlast_i,
    input  logic s_axis_tuser_i,

    // AXI4-Stream output (1-bit mask)
    output logic m_axis_tdata_o,
    output logic m_axis_tvalid_o,
    input  logic m_axis_tready_i,
    output logic m_axis_tlast_o,
    output logic m_axis_tuser_o,

    output logic busy_o
);

    // Bypass path: direct forward, no window
    logic [0:0] bypass_data;
    assign bypass_data = s_axis_tdata_i;

    // Window-based active path
    logic        stall;
    assign stall = !m_axis_tready_i;

    logic [0:0] window [9];
    logic       window_valid;
    logic       win_busy;

    axis_window3x3 #(
        .DATA_WIDTH  (1),
        .H_ACTIVE    (H_ACTIVE),
        .V_ACTIVE    (V_ACTIVE),
        .EDGE_POLICY (0)
    ) u_window (
        .clk_i          (clk_i),
        .rst_n_i        (rst_n_i),
        .valid_i        (s_axis_tvalid_i),
        .sof_i          (s_axis_tuser_i),
        .stall_i        (stall),
        .din_i          (bypass_data),
        .window_o       (window),
        .window_valid_o (window_valid),
        .busy_o         (win_busy)
    );

    // Combinational 9-way AND
    logic erode_bit;
    always_comb begin
        erode_bit = window[0][0] & window[1][0] & window[2][0]
                  & window[3][0] & window[4][0] & window[5][0]
                  & window[6][0] & window[7][0] & window[8][0];
    end

    // Output register (window path only)
    logic       active_valid_q;
    logic       active_data_q;
    logic       active_last_q;
    logic       active_user_q;

    // Forward tlast/tuser with the valid_d1 → window_valid delay. Simplest
    // correct behaviour: gate them with window_valid, tracking per-pixel
    // via a 2-stage shift of the incoming markers aligned to the window.
    // We mirror the gauss3x3 wrapper's approach: the tlast/tuser alignment
    // is handled upstream by the window primitive's valid_i/sof_i inputs.
    // Our local register captures the output bit only; tlast/tuser are
    // derived from counters exposed by the window (not present today) or,
    // in this minimal implementation, regenerated from sof/eol counts in
    // a separate 1-bit FIFO keyed on accepted beats. To keep this task
    // scoped, we use the simplest working model: shift tlast/tuser through
    // a small register pipeline of depth = window latency, enabled by the
    // same !stall signal.
    //
    // NOTE: this mirrors how gauss3x3 works today — see axis_gauss3x3.sv
    // for the pattern. If the existing Gaussian passes tests without a
    // tlast/tuser FIFO, this wrapper can too; fall back to asserting both
    // on the m_axis output according to a small counter.
    //
    // Implementation: pass tlast high on the last pixel of each frame
    // (col == H-1, row == V-1); pass tuser high on the first pixel
    // (col == 0, row == 0). Both can be derived from the output pixel
    // coordinate maintained inside axis_window3x3 if exposed; if not,
    // re-derive from a local (col, row) counter clocked on window_valid.

    logic [$clog2(H_ACTIVE+1)-1:0] out_col;
    logic [$clog2(V_ACTIVE+1)-1:0] out_row;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            out_col <= '0;
            out_row <= '0;
        end else if (!stall && window_valid) begin
            if (out_col == H_ACTIVE - 1) begin
                out_col <= '0;
                out_row <= (out_row == V_ACTIVE - 1) ? '0 : out_row + 1;
            end else begin
                out_col <= out_col + 1;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            active_valid_q <= 1'b0;
            active_data_q  <= 1'b0;
            active_last_q  <= 1'b0;
            active_user_q  <= 1'b0;
        end else if (!stall) begin
            active_valid_q <= window_valid;
            active_data_q  <= erode_bit;
            active_user_q  <= window_valid && (out_col == 0) && (out_row == 0);
            active_last_q  <= window_valid && (out_col == H_ACTIVE - 1) && (out_row == V_ACTIVE - 1);
        end
    end

    // MUX the two paths on enable_i
    assign m_axis_tdata_o  = enable_i ? active_data_q  : s_axis_tdata_i;
    assign m_axis_tvalid_o = enable_i ? active_valid_q : s_axis_tvalid_i;
    assign m_axis_tlast_o  = enable_i ? active_last_q  : s_axis_tlast_i;
    assign m_axis_tuser_o  = enable_i ? active_user_q  : s_axis_tuser_i;

    // When enabled, the window swallows input and the window primitive
    // handshakes via stall_i + busy_o. When disabled, tready is pass-through.
    assign s_axis_tready_o = enable_i ? !stall : m_axis_tready_i;
    assign busy_o          = enable_i ? win_busy : 1'b0;

endmodule
```

> **Note to implementer:** The `(col, row)` regeneration above is a documented trade-off. If the existing `axis_gauss3x3` solves tlast/tuser forwarding differently (e.g., by pipelining the incoming markers in sync with the window), copy that exact pattern instead — the point is bit-parity with gauss3x3's approach, not inventing a new one. Read `hw/ip/filters/rtl/axis_gauss3x3.sv` once before writing this file and match its tlast/tuser handling line-for-line if it differs.

- [ ] **Step 5: Run the TB — expected PASS**

```bash
cd dv/sim && make test-ip-morph3x3-erode
```

Expected: `tb_axis_morph3x3_erode PASSED -- 9 tests OK`.

If any test fails, debug using the VCD approach from CLAUDE.md §Debugging (scoped dump → grep for the failing pixel's (col, row) → inspect `window[*]` and `erode_bit` around the mismatch cycle).

- [ ] **Step 6: Lint**

```bash
make lint
```

Expected: no new Verilator warnings attributable to the new file. Fix any that appear.

- [ ] **Step 7: Commit**

```bash
git add hw/ip/filters/rtl/axis_morph3x3_erode.sv \
        hw/ip/filters/tb/tb_axis_morph3x3_erode.sv \
        dv/sim/Makefile
git commit -m "feat(filters): add axis_morph3x3_erode + unit TB"
```

---

## Task 3: `axis_morph3x3_dilate` RTL + unit TB (TDD)

Structurally identical to Task 2 but with OR instead of AND.

**Files:**
- Create: `hw/ip/filters/rtl/axis_morph3x3_dilate.sv`
- Create: `hw/ip/filters/tb/tb_axis_morph3x3_dilate.sv`
- Modify: `dv/sim/Makefile`

- [ ] **Step 1: Write the failing unit TB**

Copy `tb_axis_morph3x3_erode.sv` → `tb_axis_morph3x3_dilate.sv`. Change:
- Module name and banner comment.
- DUT instantiation to `axis_morph3x3_dilate`.
- Golden function: `out = out | img[rr][cc];` (initial `out = 1'b0`).
- Tests:

```systemverilog
// Test 1: All-zeros → all-zeros
// Test 2: All-ones → all-ones
// Test 3: Isolated single pixel at (4,4)=1 → 3×3 output block at rows 3..5, cols 3..5
// Test 4: Horizontal stripe at row 4 = 1, rest 0 → rows 3,4,5 all 1s (stripe thickens vertically)
// Test 5: Corner pixel (0,0)=1 → output 2×2 at (0,0)..(1,1) = 1 (edge replication extends the 1)
//         Actually with EDGE_REPLICATE, the top/left neighbours of (0,0) replicate (0,0) = 1,
//         so the dilation output at (0,0) and its neighbours is 1.
// Test 6: enable_i=0 passthrough
// Test 7: Stall behaviour
// Test 8: Multi-frame SOF reset
```

- [ ] **Step 2: Add Makefile target**

Append to `dv/sim/Makefile` after `test-ip-morph3x3-erode`:

```make
# --- axis_morph3x3_dilate ---
test-ip-morph3x3-dilate:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_morph3x3_dilate --Mdir obj_tb_axis_morph3x3_dilate \
	  $(IP_WINDOW3X3_RTL) $(IP_MORPH3X3_DILATE_RTL) ../../hw/ip/filters/tb/tb_axis_morph3x3_dilate.sv
	obj_tb_axis_morph3x3_dilate/Vtb_axis_morph3x3_dilate
```

- [ ] **Step 3: Run the TB — expected FAIL**

```bash
cd dv/sim && make test-ip-morph3x3-dilate
```

Expected: Verilator errors out because `axis_morph3x3_dilate.sv` does not exist.

- [ ] **Step 4: Write the minimal RTL**

Copy `axis_morph3x3_erode.sv` → `axis_morph3x3_dilate.sv`. Change:
- Module name `axis_morph3x3_erode` → `axis_morph3x3_dilate` everywhere.
- Banner comment: "erosion" → "dilation", "AND" → "OR".
- The combinational reduction: change `&` to `|`:

```systemverilog
always_comb begin
    dilate_bit = window[0][0] | window[1][0] | window[2][0]
               | window[3][0] | window[4][0] | window[5][0]
               | window[6][0] | window[7][0] | window[8][0];
end
```

Rename `erode_bit` → `dilate_bit`, `active_data_q` stays. Everything else (tlast/tuser regeneration, enable_i mux, handshake) is identical.

- [ ] **Step 5: Run the TB — expected PASS**

```bash
cd dv/sim && make test-ip-morph3x3-dilate
```

Expected: `tb_axis_morph3x3_dilate PASSED -- 8 tests OK`.

- [ ] **Step 6: Lint**

```bash
make lint
```

- [ ] **Step 7: Commit**

```bash
git add hw/ip/filters/rtl/axis_morph3x3_dilate.sv \
        hw/ip/filters/tb/tb_axis_morph3x3_dilate.sv \
        dv/sim/Makefile
git commit -m "feat(filters): add axis_morph3x3_dilate + unit TB"
```

---

## Task 4: `axis_morph3x3_open` composite + unit TB

**Files:**
- Create: `hw/ip/filters/rtl/axis_morph3x3_open.sv`
- Create: `hw/ip/filters/tb/tb_axis_morph3x3_open.sv`
- Modify: `dv/sim/Makefile`, `hw/ip/filters/filters.core`

- [ ] **Step 1: Write the failing unit TB**

Create `hw/ip/filters/tb/tb_axis_morph3x3_open.sv`, modelled on the erode/dilate TBs. Golden function — two-pass, erode then dilate over the intermediate buffer:

```systemverilog
task automatic compute_open_golden(input logic img [V][H]);
    logic eroded [V][H];
    for (int r = 0; r < V; r++)
        for (int c = 0; c < H; c++)
            eroded[r][c] = erode_golden(img, r, c);
    for (int r = 0; r < V; r++)
        for (int c = 0; c < H; c++)
            golden_out[r][c] = dilate_golden(eroded, r, c);
endtask
```

(Copy `erode_golden` and `dilate_golden` in verbatim from the two prior TBs.)

Tests:

```systemverilog
// Test 1: All-zeros → all-zeros
// Test 2: All-ones → all-ones
// Test 3: Isolated single pixel at (4,4)=1 → all-zeros (salt removal, key feature)
// Test 4: 3×3 solid block → same 3×3 block (opening preserves blobs >= 3×3)
// Test 5: 1-px-tall horizontal stripe (row 4 all 1s) → all-zeros (thin feature removed — Risk D1 evidence)
// Test 6: 5×5 solid block → output == input (opening is idempotent on sufficiently large blobs)
// Test 7: enable_i=0 passthrough — both sub-modules bypass
// Test 8: Asymmetric downstream stall (drive_frame_stall) — golden-match under stall
// Test 9: Multi-frame SOF reset
// Test 10: Latency measurement — expect 2 × (H + DEF_HBLANK + 3) cycles from first valid to first valid_out
```

DUT instantiation:

```systemverilog
axis_morph3x3_open #(
    .H_ACTIVE (H),
    .V_ACTIVE (V)
) u_dut (
    .clk_i           (clk),
    .rst_n_i         (rst_n),
    .enable_i        (1'b1),           // switched to 0 for Test 7
    .s_axis_tdata_i  (dut_tdata),
    .s_axis_tvalid_i (dut_valid),
    .s_axis_tready_o (),
    .s_axis_tlast_i  (dut_last),
    .s_axis_tuser_i  (dut_sof),
    .m_axis_tdata_o  (m_tdata),
    .m_axis_tvalid_o (m_tvalid),
    .m_axis_tready_i (1'b1),
    .m_axis_tlast_o  (),
    .m_axis_tuser_o  (),
    .busy_o          (busy_out)
);
```

- [ ] **Step 2: Add Makefile target**

Append to `dv/sim/Makefile`:

```make
# --- axis_morph3x3_open (erode + dilate composite) ---
test-ip-morph3x3-open:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_morph3x3_open --Mdir obj_tb_axis_morph3x3_open \
	  $(IP_WINDOW3X3_RTL) $(IP_MORPH3X3_ERODE_RTL) $(IP_MORPH3X3_DILATE_RTL) $(IP_MORPH3X3_OPEN_RTL) \
	  ../../hw/ip/filters/tb/tb_axis_morph3x3_open.sv
	obj_tb_axis_morph3x3_open/Vtb_axis_morph3x3_open
```

- [ ] **Step 3: Run the TB — expected FAIL**

```bash
cd dv/sim && make test-ip-morph3x3-open
```

Expected: Verilator errors out because `axis_morph3x3_open.sv` does not exist.

- [ ] **Step 4: Write the composite RTL**

Create `hw/ip/filters/rtl/axis_morph3x3_open.sv`:

```systemverilog
// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// 3x3 morphological OPENING on a 1-bit mask: axis_morph3x3_erode -> axis_morph3x3_dilate.
// Removes isolated foreground pixels (salt noise) and thin features (< 3 px),
// while preserving the size of blobs that survive the erosion.
//
// enable_i=0 bypasses both sub-modules (zero-latency passthrough, no line
// buffer cost in terms of logical behaviour — the buffers still exist but
// their output is muxed out).
//
// Latency (enable_i=1): 2 * (H_ACTIVE + 3) cycles.
// Throughput: 1 pixel/cycle after fill. Blanking requirements: same as a
// single axis_window3x3 (H-blank >= 1/row, V-blank >= H_ACTIVE + 1 total);
// the two stages are pipelined, so blanking does not double.

module axis_morph3x3_open #(
    parameter int H_ACTIVE = 320,
    parameter int V_ACTIVE = 240
) (
    input  logic clk_i,
    input  logic rst_n_i,
    input  logic enable_i,

    input  logic s_axis_tdata_i,
    input  logic s_axis_tvalid_i,
    output logic s_axis_tready_o,
    input  logic s_axis_tlast_i,
    input  logic s_axis_tuser_i,

    output logic m_axis_tdata_o,
    output logic m_axis_tvalid_o,
    input  logic m_axis_tready_i,
    output logic m_axis_tlast_o,
    output logic m_axis_tuser_o
);

    // Internal AXIS link between erode and dilate.
    logic mid_tdata;
    logic mid_tvalid;
    logic mid_tready;
    logic mid_tlast;
    logic mid_tuser;

    axis_morph3x3_erode #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE)
    ) u_erode (
        .clk_i           (clk_i),
        .rst_n_i         (rst_n_i),
        .enable_i        (enable_i),
        .s_axis_tdata_i  (s_axis_tdata_i),
        .s_axis_tvalid_i (s_axis_tvalid_i),
        .s_axis_tready_o (s_axis_tready_o),
        .s_axis_tlast_i  (s_axis_tlast_i),
        .s_axis_tuser_i  (s_axis_tuser_i),
        .m_axis_tdata_o  (mid_tdata),
        .m_axis_tvalid_o (mid_tvalid),
        .m_axis_tready_i (mid_tready),
        .m_axis_tlast_o  (mid_tlast),
        .m_axis_tuser_o  (mid_tuser),
        .busy_o          ()
    );

    axis_morph3x3_dilate #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE)
    ) u_dilate (
        .clk_i           (clk_i),
        .rst_n_i         (rst_n_i),
        .enable_i        (enable_i),
        .s_axis_tdata_i  (mid_tdata),
        .s_axis_tvalid_i (mid_tvalid),
        .s_axis_tready_o (mid_tready),
        .s_axis_tlast_i  (mid_tlast),
        .s_axis_tuser_i  (mid_tuser),
        .m_axis_tdata_o  (m_axis_tdata_o),
        .m_axis_tvalid_o (m_axis_tvalid_o),
        .m_axis_tready_i (m_axis_tready_i),
        .m_axis_tlast_o  (m_axis_tlast_o),
        .m_axis_tuser_o  (m_axis_tuser_o),
        .busy_o          ()
    );

endmodule
```

- [ ] **Step 5: Update `filters.core`**

Edit `hw/ip/filters/filters.core`. In the `files_rtl` fileset, add the three new sources (alphabetized after the existing entry):

```yaml
filesets:
  files_rtl:
    files:
      - rtl/axis_gauss3x3.sv
      - rtl/axis_morph3x3_dilate.sv
      - rtl/axis_morph3x3_erode.sv
      - rtl/axis_morph3x3_open.sv
    file_type: systemVerilogSource
    depend:
      - sparevideo:ip:window
```

Update the top-level `description:` field to: `"Spatial filters over the shared axis_window3x3 primitive (Gaussian, morphological erode/dilate/open)"`.

- [ ] **Step 6: Run the composite TB — expected PASS**

```bash
cd dv/sim && make test-ip-morph3x3-open
```

Expected: `tb_axis_morph3x3_open PASSED -- 10 tests OK`.

- [ ] **Step 7: Run the full test-ip suite**

```bash
cd dv/sim && make test-ip
```

Expected: All existing + three new TBs pass.

- [ ] **Step 8: Lint**

```bash
make lint
```

- [ ] **Step 9: Commit**

```bash
git add hw/ip/filters/rtl/axis_morph3x3_open.sv \
        hw/ip/filters/tb/tb_axis_morph3x3_open.sv \
        hw/ip/filters/filters.core \
        dv/sim/Makefile
git commit -m "feat(filters): add axis_morph3x3_open composite + TB"
```

---

## Task 5: Python reference model (`morph_open` op)

**Files:**
- Create: `py/models/ops/__init__.py`
- Create: `py/models/ops/morph_open.py`
- Create: `py/tests/test_morph_open.py`
- Modify: `requirements.txt`

- [ ] **Step 1: Add scipy dep**

Edit `requirements.txt` — add a new line:

```
scipy>=1.10
```

- [ ] **Step 2: Install**

```bash
source .venv/bin/activate && pip install -r requirements.txt
```

Expected: scipy installs; existing packages stay at current versions.

- [ ] **Step 3: Write the failing model test**

Create `py/tests/test_morph_open.py`:

```python
"""Unit tests for py/models/ops/morph_open.py."""

import numpy as np
import pytest

from models.ops.morph_open import morph_open


def test_all_zeros_stays_zero():
    mask = np.zeros((8, 8), dtype=bool)
    out = morph_open(mask)
    assert out.dtype == bool
    assert out.shape == (8, 8)
    assert not out.any()


def test_all_ones_stays_ones():
    mask = np.ones((8, 8), dtype=bool)
    out = morph_open(mask)
    assert out.all()


def test_isolated_pixel_removed():
    # Single isolated foreground pixel → opening removes it (salt noise).
    mask = np.zeros((8, 8), dtype=bool)
    mask[4, 4] = True
    out = morph_open(mask)
    assert not out.any(), f"Isolated pixel not removed:\n{out.astype(int)}"


def test_thin_stripe_removed():
    # 1-px-tall horizontal stripe → opening removes it (Risk D1 evidence).
    mask = np.zeros((8, 8), dtype=bool)
    mask[3, :] = True
    out = morph_open(mask)
    assert not out.any(), f"Thin stripe survived opening:\n{out.astype(int)}"


def test_3x3_block_survives():
    # 3×3 solid block → opening preserves it exactly.
    mask = np.zeros((8, 8), dtype=bool)
    mask[2:5, 3:6] = True
    out = morph_open(mask)
    np.testing.assert_array_equal(out, mask)


def test_5x5_block_idempotent():
    mask = np.zeros((8, 8), dtype=bool)
    mask[1:6, 1:6] = True
    out = morph_open(mask)
    np.testing.assert_array_equal(out, mask)


def test_edge_replication_corner():
    # Lit 3×3 in the top-left corner — edge replication means the off-image
    # neighbours of the corner pixel are all 1, so erosion preserves the
    # corner of the 3×3. Dilation then restores the same block.
    mask = np.zeros((8, 8), dtype=bool)
    mask[0:3, 0:3] = True
    out = morph_open(mask)
    np.testing.assert_array_equal(out, mask)
```

Run:

```bash
source .venv/bin/activate && pytest py/tests/test_morph_open.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'models.ops'`.

- [ ] **Step 4: Write the reference model**

Create `py/models/ops/__init__.py` (empty file — just marks the package):

```python
"""Per-op reference models composed by the control-flow dispatcher."""
```

Create `py/models/ops/morph_open.py`:

```python
"""3x3 morphological opening (erode then dilate) with edge replication.

Matches axis_morph3x3_open RTL: 3x3 square structuring element, EDGE_REPLICATE
border policy at all four borders, single pass.
"""

import numpy as np
from scipy.ndimage import grey_erosion, grey_dilation


def morph_open(mask: np.ndarray) -> np.ndarray:
    """Apply 3x3 opening to a 2D boolean mask.

    Args:
        mask: (H, W) boolean array. True = foreground.

    Returns:
        (H, W) boolean array — mask after erosion then dilation.
    """
    if mask.dtype != bool:
        raise TypeError(f"morph_open expects bool mask, got {mask.dtype}")
    # scipy's mode='nearest' implements edge replication, matching the
    # axis_window3x3 EDGE_REPLICATE policy.
    u8 = mask.astype(np.uint8)
    eroded  = grey_erosion (u8, size=(3, 3), mode='nearest')
    dilated = grey_dilation(eroded, size=(3, 3), mode='nearest')
    return dilated.astype(bool)
```

- [ ] **Step 5: Run the test — expected PASS**

```bash
source .venv/bin/activate && pytest py/tests/test_morph_open.py -v
```

Expected: All 7 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add requirements.txt py/models/ops/__init__.py \
        py/models/ops/morph_open.py py/tests/test_morph_open.py
git commit -m "feat(models): add morph_open reference op + unit tests"
```

---

## Task 6: Compose `morph_open` into control-flow models

**Files:**
- Modify: `py/models/motion.py`, `py/models/mask.py`, `py/models/ccl_bbox.py`, `py/models/__init__.py`

- [ ] **Step 1: Update the dispatcher signature**

Edit `py/models/__init__.py`. Change `run_model` to pass `morph_en` through `**kwargs` (already supported — `kwargs` already flows to each model's `run`). No code change needed here yet; the dispatcher is pass-through. Verify by reading the file.

- [ ] **Step 2: Update `mask.py`**

Edit `py/models/mask.py`. Add `morph_en` kwarg to `run` and apply the op after `_compute_mask`. The applicable change is in the `else` branch where `raw_mask` is computed:

```python
def run(frames, thresh=16, alpha_shift=3, alpha_shift_slow=6, grace_frames=0,
        grace_alpha_shift=1, gauss_en=True, morph_en=True, **kwargs):
```

And after `raw_mask = _compute_mask(y_cur_filt, y_bg, thresh)` inside the main loop, insert:

```python
            if morph_en:
                from models.ops.morph_open import morph_open
                raw_mask = morph_open(raw_mask)
```

(The import lives at module scope in a real edit — move it next to `from models.motion import ...` at the top of the file. The above inline-import form is only for clarity in this step block.)

Docstring: add a one-line entry for the new kwarg under `Args:`:

```
        morph_en: Apply 3x3 morphological opening to the mask (default True).
```

- [ ] **Step 3: Update `motion.py`**

Edit `py/models/motion.py`. Same pattern: add `morph_en` kwarg, apply `morph_open` to the mask immediately after `_compute_mask` and before the EMA update and before CCL. Order matters: the morph-cleaned mask is what feeds `axis_ccl` in the RTL, so the model must do the same.

Also: the EMA `_selective_ema_update` uses the mask to pick the rate. The RTL uses the motion-detect-internal raw mask for the EMA decision (morph is downstream of motion_detect), so pass the *raw* (pre-morph) mask to the EMA and the *morphed* mask to CCL / overlay:

```python
            raw_mask   = _compute_mask(y_cur_filt, y_bg, thresh)
            clean_mask = morph_open(raw_mask) if morph_en else raw_mask
            in_grace   = grace_cnt < grace_frames
            if in_grace:
                y_bg = _ema_update(y_cur_filt, y_bg, grace_alpha_shift)
                grace_cnt += 1
                mask_for_downstream = np.zeros_like(clean_mask)
            else:
                # EMA uses raw_mask (pre-morph) to match the RTL, where the
                # motion_detect block is the sole EMA driver and sits before
                # axis_morph3x3_open.
                y_bg = _selective_ema_update(y_cur_filt, y_bg, raw_mask,
                                             alpha_shift, alpha_shift_slow)
                mask_for_downstream = clean_mask
            # downstream (CCL, overlay) consumes mask_for_downstream
```

Adjust the rest of the function to use `mask_for_downstream` where it previously used `mask`. Add `from models.ops.morph_open import morph_open` at the top.

- [ ] **Step 4: Update `ccl_bbox.py`**

Edit `py/models/ccl_bbox.py` with the same pattern as `motion.py`: add `morph_en` kwarg, apply `morph_open` after `_compute_mask`, route the morphed mask into both the grey-canvas renderer and the CCL input.

- [ ] **Step 5: Regenerate existing mask/motion/ccl_bbox tests baseline**

If `py/tests/test_models.py` has baseline arrays for motion/mask/ccl_bbox with `morph_en` implicitly True, the default behaviour change (True) may invalidate some assertions. Run:

```bash
source .venv/bin/activate && pytest py/tests/test_models.py -v
```

For any test that fails because the golden changes under opening: if the test's intent is "verify RTL behaviour" (not "verify a specific hand-computed output"), update the test to pass `morph_en=False` to isolate pre-existing behaviour. Do **not** update hand-computed goldens to match the new model — that hides bugs. If the test intent is ambiguous, split into two: one with `morph_en=False` (legacy golden) and one with `morph_en=True` (new golden derived from running `morph_open` on the legacy golden's intermediate mask by hand).

- [ ] **Step 6: Commit**

```bash
git add py/models/__init__.py py/models/motion.py py/models/mask.py py/models/ccl_bbox.py \
        py/tests/test_models.py
git commit -m "feat(models): compose morph_open into motion/mask/ccl_bbox flows"
```

---

## Task 7: Makefile `MORPH` knob end-to-end plumbing

**Files:**
- Modify: `Makefile` (top), `dv/sim/Makefile`, `dv/sv/tb_sparevideo.sv`, `py/harness.py`

- [ ] **Step 1: Top Makefile**

Edit the top-level `Makefile`. After the `GAUSS_EN ?= 1` line (around line 31), add:

```make
# Morphological opening on the motion mask. 0 = bypass, 1 = erode+dilate (default).
MORPH ?= 1
```

In the `SIM_VARS` definition (around line 46–49), append `MORPH=$(MORPH)` to the variable list passed to `dv/sim/Makefile`.

In the `prepare` target's `printf` (around line 123), add `MORPH = %s\n` to the format string and `$(MORPH)` to the args, so `dv/data/config.mk` captures it.

In the `verify` target invocation of `py/harness.py` (around line 151), add `--morph $(MORPH)` to the args. Same for `render` (around line 162–163). Add `__morph=$(MORPH)` to `RENDER_OUT` (line 154) so rendered images are disambiguated.

In the `help` target, under the knob-description block, add:

```make
	@echo "    MORPH=1                          Mask 3x3 opening on/off (default 1)"
```

- [ ] **Step 2: `dv/sim/Makefile`**

Edit `dv/sim/Makefile`:

- Add `MORPH ?= 1` after `GAUSS_EN ?= 1` (around line 31).
- Append `-GMORPH=$(MORPH)` to `VLT_FLAGS` (line 80).
- Append `$(MORPH)` to the `CONFIG_STAMP` contents (line 94) — the `echo` line on both sides of the `cmp`.

- [ ] **Step 3: `tb_sparevideo.sv`**

Edit `dv/sv/tb_sparevideo.sv`. Add a new parameter to the TB module header:

```systemverilog
    parameter int MORPH             = 1
```

Pass it through to the DUT instantiation:

```systemverilog
        .MORPH             (MORPH),
```

(The DUT port will be added in Task 8.)

- [ ] **Step 4: `py/harness.py`**

Edit `py/harness.py`. For each of `prepare`, `verify`, `render` argparse blocks:

```python
    p_<stage>.add_argument("--morph", type=int, default=1, dest="morph",
                           help="3x3 morphological opening on mask (0/1)")
```

In the `verify` and `render` handlers, extract and forward:

```python
    morph_en = bool(getattr(args, "morph", 1))
    # ... add morph_en=morph_en to run_model(...) kwargs
```

- [ ] **Step 5: Smoke test — build with MORPH=0 and MORPH=1**

```bash
make sim MORPH=0 CTRL_FLOW=mask
make sim MORPH=1 CTRL_FLOW=mask
```

Expected: both complete without Verilator errors. The `MORPH=1` run will currently behave identically to `MORPH=0` because the RTL isn't wired yet (Task 8) — that's fine for this step; we're only verifying the plumbing compiles.

- [ ] **Step 6: Commit**

```bash
git add Makefile dv/sim/Makefile dv/sv/tb_sparevideo.sv py/harness.py
git commit -m "build(morph): thread MORPH knob through Makefile/TB/harness"
```

---

## Task 8: Top-level RTL integration

**Files:**
- Modify: `hw/top/sparevideo_top.sv`

- [ ] **Step 1: Add the parameter**

Edit `hw/top/sparevideo_top.sv`. Add a new parameter next to `GAUSS_EN` (around line 50):

```systemverilog
    // 3x3 morphological opening on the motion mask. 1 = enabled (default),
    // 0 = bypass. Wired to axis_morph3x3_open.enable_i.
    parameter int MORPH             = 1,
```

- [ ] **Step 2: Declare the cleaned-mask stream**

Inside the module body, next to the existing `msk_*` declarations (around line 213):

```systemverilog
    // Cleaned mask stream (output of axis_morph3x3_open). Consumers previously
    // read from msk_*; they now read from msk_clean_*.
    logic msk_clean_tdata;
    logic msk_clean_tvalid;
    logic msk_clean_tready;
    logic msk_clean_tlast;
    logic msk_clean_tuser;
```

- [ ] **Step 3: Instantiate `axis_morph3x3_open`**

Insert after `u_motion_detect` and before the existing `msk_rgb_tdata` assignment:

```systemverilog
    axis_morph3x3_open #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE)
    ) u_morph_open (
        .clk_i           (clk_dsp_i),
        .rst_n_i         (rst_dsp_n_i),
        .enable_i        (1'(MORPH)),
        .s_axis_tdata_i  (msk_tdata),
        .s_axis_tvalid_i (msk_tvalid),
        .s_axis_tready_o (msk_tready),           // was: the big ternary below
        .s_axis_tlast_i  (msk_tlast),
        .s_axis_tuser_i  (msk_tuser),
        .m_axis_tdata_o  (msk_clean_tdata),
        .m_axis_tvalid_o (msk_clean_tvalid),
        .m_axis_tready_i (msk_clean_tready),
        .m_axis_tlast_o  (msk_clean_tlast),
        .m_axis_tuser_o  (msk_clean_tuser)
    );
```

- [ ] **Step 4: Rewire `msk_tready` and downstream consumers**

Remove the old `assign msk_tready = ...` ternary (around line 323). Replace with the new downstream-side ternary applied to `msk_clean_tready`:

```systemverilog
    // Mask tready backpressure, re-expressed on the morph-open output.
    // In mask/ccl_bbox modes the cleaned mask is also consumed by the
    // passthrough-to-output path; in motion mode axis_ccl is the sole consumer.
    logic bbox_msk_tready;
    assign msk_clean_tready =
        ((ctrl_flow_i == sparevideo_pkg::CTRL_MASK_DISPLAY)
      || (ctrl_flow_i == sparevideo_pkg::CTRL_CCL_BBOX))
        ? (proc_tready && bbox_msk_tready)
        : bbox_msk_tready;
```

Replace every downstream reference to `msk_tdata` / `msk_tvalid` / `msk_tlast` / `msk_tuser` (but NOT `msk_tready`, which is now the morph input-side tready driven back by the `axis_morph3x3_open` handshake) with `msk_clean_*`. Specifically:

- `msk_rgb_tdata`, `msk_rgb_tvalid`, `msk_rgb_tlast`, `msk_rgb_tuser` (B/W expansion): use `msk_clean_*`.
- `ccl_beat_strobe`: becomes `msk_clean_tvalid && msk_clean_tready`.
- `axis_ccl` ports: `s_axis_tdata_i (msk_clean_tdata)`, `s_axis_tlast_i (msk_clean_tlast)`, `s_axis_tuser_i (msk_clean_tuser)`.
- `mask_grey_rgb` assignment: use `msk_clean_tdata`.

Do NOT change `u_motion_detect`'s `m_axis_msk_*` connections — that still writes `msk_*` (the raw mask, feeding `axis_morph3x3_open`'s input).

- [ ] **Step 5: Lint**

```bash
make lint
```

Expected: zero new warnings. Fix anything attributable to the new module or rewiring.

- [ ] **Step 6: Compile + smoke**

```bash
make sim CTRL_FLOW=mask MORPH=1
make sim CTRL_FLOW=mask MORPH=0
```

Expected: both runs produce an output file (no crashes).

- [ ] **Step 7: Quick verify — MORPH=0 matches pre-morph behaviour**

With `MORPH=0`, the cleaned-mask stream should behave identically to the raw mask. Compare against the pre-Task-8 golden:

```bash
# On main (pre-plan), capture a golden
git stash
make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=mask MODE=binary
cp dv/data/output.bin /tmp/morph0-golden.bin
git stash pop

# On this branch with MORPH=0
make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=mask MODE=binary MORPH=0
cmp dv/data/output.bin /tmp/morph0-golden.bin
```

Expected: `cmp` reports no difference. If it differs, the integration has an unintended side effect — debug before proceeding.

- [ ] **Step 8: Commit**

```bash
git add hw/top/sparevideo_top.sv
git commit -m "feat(top): wire axis_morph3x3_open into mask stream"
```

---

## Task 9: `thin_moving_line` synthetic source (Risk D1 exercise)

**Files:**
- Modify: `py/frames/video_source.py`

- [ ] **Step 1: Add the generator**

Edit `py/frames/video_source.py`. Add a new generator function near the other synthetic generators:

```python
def _gen_thin_moving_line(width, height, num_frames):
    """1-pixel-wide horizontal line moving down over a dark background.

    Exercises Risk D1 from the pipeline-extensions design: a 3x3 opening
    deletes features < 3 px. With MORPH=1 this line should never appear
    in the mask output. With MORPH=0 it should appear as a 1-px stripe.
    Frame 0 is background-only (no foreground) to avoid contaminating
    the EMA bg hard-init.
    """
    import numpy as np
    frames = []
    bg = np.full((height, width, 3), 32, dtype=np.uint8)  # dark grey
    for f in range(num_frames):
        frame = bg.copy()
        if f >= 1:
            # Line descends one row per frame, centered horizontally.
            row = min(1 + (f - 1), height - 2)
            frame[row, :, :] = 200  # bright line, 1 px tall
        frames.append(frame)
    return frames
```

Register it in the generator dispatch dict (around line 110):

```python
        "thin_moving_line": _gen_thin_moving_line,
```

Update the docstring at the top of the file (line 7) to include `thin_moving_line` in the pattern list.

- [ ] **Step 2: Smoke test — sw-dry-run**

```bash
make sw-dry-run SOURCE="synthetic:thin_moving_line" FRAMES=4
```

Expected: no errors; input frames produced.

- [ ] **Step 3: End-to-end — MORPH=0 (line visible) vs MORPH=1 (line erased)**

```bash
make run-pipeline SOURCE="synthetic:thin_moving_line" CTRL_FLOW=mask MODE=binary MORPH=0 FRAMES=6
# Expected: verify passes — mask output contains the 1-px stripe from frame 2 onward.

make run-pipeline SOURCE="synthetic:thin_moving_line" CTRL_FLOW=mask MODE=binary MORPH=1 FRAMES=6
# Expected: verify passes — mask output is all-black because opening erases the stripe.
```

Both runs should pass `verify` at `TOLERANCE=0` (the Python reference model composes `morph_open` when `--morph 1`, so RTL and model agree in both configurations).

- [ ] **Step 4: Commit**

```bash
git add py/frames/video_source.py
git commit -m "feat(source): add thin_moving_line synthetic pattern"
```

---

## Task 10: Integration regression sweep

- [ ] **Step 1: Run the 4×2 matrix**

For `CTRL_FLOW ∈ {passthrough, motion, mask, ccl_bbox}` × `MORPH ∈ {0, 1}`:

```bash
for cf in passthrough motion mask ccl_bbox; do
  for m in 0 1; do
    echo "=== CTRL_FLOW=$cf MORPH=$m ==="
    make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=$cf MODE=binary MORPH=$m FRAMES=6 || exit 1
  done
done
```

Expected: all 8 runs pass `verify` at `TOLERANCE=0`.

Notes:
- `CTRL_FLOW=passthrough` should produce identical output for MORPH=0 and MORPH=1 (morph is bypassed when the motion pipe is inactive; `fork_s_tvalid` is gated by `motion_pipe_active`).
- `CTRL_FLOW=motion` with `MORPH=1` may yield slightly different bboxes than `MORPH=0` because salt is removed before CCL. That's expected; the reference model composes the same way.

- [ ] **Step 2: Noisy pattern exercise**

```bash
make run-pipeline SOURCE="synthetic:noisy_moving_box" CTRL_FLOW=motion MODE=binary MORPH=1 ALPHA_SHIFT=2 ALPHA_SHIFT_SLOW=6 FRAMES=8
make run-pipeline SOURCE="synthetic:noisy_moving_box" CTRL_FLOW=motion MODE=binary MORPH=0 ALPHA_SHIFT=2 ALPHA_SHIFT_SLOW=6 FRAMES=8
```

Expected: both pass verify. The `MORPH=1` render should visibly have fewer spurious bboxes than `MORPH=0` — inspect `renders/*.png` to confirm.

- [ ] **Step 3: Full `make test-ip`**

```bash
make test-ip
```

Expected: all block TBs pass, including the three new morph TBs.

- [ ] **Step 4: Commit (if any fixes were needed)**

If Steps 1–3 passed clean: no commit. If fixes were needed, commit them with a descriptive message.

---

## Task 11: Documentation updates

**Files:**
- Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: `README.md`**

Locate the IP-block table (search for `axis_gauss3x3` in README.md). Add rows for the three new modules:

| IP | Role | Doc |
|----|------|-----|
| `axis_morph3x3_erode` | 3×3 erosion on 1-bit mask (AND over window) | `hw/ip/filters/docs/axis_morph3x3_open-arch.md` |
| `axis_morph3x3_dilate` | 3×3 dilation on 1-bit mask (OR over window) | `hw/ip/filters/docs/axis_morph3x3_open-arch.md` |
| `axis_morph3x3_open` | Composite: erode → dilate (salt removal) | `hw/ip/filters/docs/axis_morph3x3_open-arch.md` |

Update any `make run-pipeline` examples to mention the `MORPH` knob where appropriate (at least one example in the knob summary).

- [ ] **Step 2: `CLAUDE.md`**

In the Build Commands section, add a line next to the existing knob examples:

```
make run-pipeline CTRL_FLOW=mask MORPH=0                    # raw mask, morph opening bypassed
```

In the "Motion pipeline — lessons learned" section, append a new subsection:

```
**Mask cleanup via `axis_morph3x3_open`.** A 3×3 square opening (erode → dilate) is applied to the motion mask before CCL, overlay, and mask display. This removes single-pixel salt noise and thin stripes < 3 px wide. Consequence: thin features (far-field objects, 1-px-wide lines) are erased. The `thin_moving_line` synthetic pattern exists specifically to exercise this. Runtime gate: `MORPH=0` disables both sub-modules; default is 1. The Python reference model composes `morph_open` when `morph_en=True`, so RTL and model agree in both configurations.
```

Update the project structure block (the `hw/ip/filters/rtl/` bullet) to list the new modules:

```
- `hw/ip/filters/rtl/` — Spatial filters over axis_window3x3 (axis_gauss3x3; axis_morph3x3_erode, axis_morph3x3_dilate, axis_morph3x3_open; future: axis_sobel — all land here as peer `.sv` files under one `filters.core`)
```

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs(morph): document axis_morph3x3_open stage and MORPH knob"
```

---

## Task 12: Final sweep and plan close-out

- [ ] **Step 1: Run the complete test matrix again**

```bash
make lint
make test-ip
for cf in passthrough motion mask ccl_bbox; do
  for m in 0 1; do
    make run-pipeline SOURCE="synthetic:moving_box" CTRL_FLOW=$cf MODE=binary MORPH=$m FRAMES=6 || { echo "FAIL $cf/$m"; exit 1; }
  done
done
make run-pipeline SOURCE="synthetic:thin_moving_line" CTRL_FLOW=mask MORPH=0 FRAMES=6
make run-pipeline SOURCE="synthetic:thin_moving_line" CTRL_FLOW=mask MORPH=1 FRAMES=6
```

Expected: all green.

- [ ] **Step 2: Move the design doc and this plan to the history directory**

Per CLAUDE.md ("After implementing a plan, move it to docs/plans/old/ and put a date timestamp on it"):

```bash
mkdir -p docs/plans/old
git mv docs/plans/2026-04-24-axis-morph-open-plan.md docs/plans/old/2026-04-24-axis-morph-open-plan.md
```

Do NOT move `docs/plans/2026-04-23-pipeline-extensions-design.md` — it still governs the remaining sibling plans (hflip, gamma_cor, scale2x, hud).

- [ ] **Step 3: Squash the branch**

Per CLAUDE.md ("Squash at plan completion"):

```bash
git log --oneline main..HEAD    # review: every commit should be morph_open-scoped
# If any tangential commits slipped in, move them to their own branch before squashing.
git reset --soft $(git merge-base HEAD main)
git commit -m "feat(morph): add 3x3 morphological opening stage

Adds axis_morph3x3_erode, axis_morph3x3_dilate, and axis_morph3x3_open composite
on the 1-bit motion mask stream. Integrated into sparevideo_top between
axis_motion_detect and its downstream consumers (mask->RGB, axis_ccl,
mask-grey canvas). Gated by a runtime MORPH knob (default 1) tied to
enable_i on both sub-modules.

Removes single-pixel salt noise and thin features < 3 px wide before CCL
and display. Adds thin_moving_line synthetic source to make Risk D1
(thin-feature deletion) visible in regression.

Python reference model composes scipy.ndimage-based morph_open into
motion/mask/ccl_bbox flows when morph_en=True, keeping RTL and model in
agreement at TOLERANCE=0 for MORPH in {0, 1}."
```

- [ ] **Step 4: Open the PR**

```bash
git push -u origin $(git branch --show-current)
gh pr create --title "feat(morph): add axis_morph3x3_open stage" --body "$(cat <<'EOF'
## Summary
- New `axis_morph3x3_erode`, `axis_morph3x3_dilate`, and `axis_morph3x3_open` composite, each wrapping `axis_window3x3 #(DATA_WIDTH=1)` with a 9-way AND/OR reduction.
- Wired into `sparevideo_top` between `axis_motion_detect` and the downstream mask consumers; runtime `MORPH` knob (default 1) gates both sub-modules.
- `thin_moving_line` synthetic source added to exercise Risk D1 (3×3 opening deletes features < 3 px wide).
- Python reference model (`py/models/ops/morph_open.py`) composed into motion/mask/ccl_bbox flows.

Implements plan [`docs/plans/old/2026-04-24-axis-morph-open-plan.md`](docs/plans/old/2026-04-24-axis-morph-open-plan.md), step 2 of [`docs/plans/2026-04-23-pipeline-extensions-design.md`](docs/plans/2026-04-23-pipeline-extensions-design.md).

## Test plan
- [x] `make lint` clean
- [x] `make test-ip` passes (includes three new TBs: `test-ip-morph3x3-erode`, `-dilate`, `-open`)
- [x] `pytest py/tests/test_morph_open.py` passes (7 tests)
- [x] `pytest py/tests/test_models.py` passes with updated baselines
- [x] 4×2 matrix `{passthrough, motion, mask, ccl_bbox} × MORPH={0, 1}` passes `verify` at TOLERANCE=0
- [x] `thin_moving_line` shows expected behaviour: line visible with MORPH=0, erased with MORPH=1
EOF
)"
```

- [ ] **Step 5: Memorialize**

Note in the PR comments: the plan is now at `docs/plans/old/` and step 2 of the pipeline-extensions design is complete; the remaining sibling plans (`axis-hflip`, `axis-gamma-cor`, `axis-scale2x`, `axis-hud`) are independent of step 2 per design §6.
