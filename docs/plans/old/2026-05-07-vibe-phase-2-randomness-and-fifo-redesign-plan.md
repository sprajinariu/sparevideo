# ViBe Phase 2 — Randomness & FIFO Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two design corrections to the just-merged-but-still-PR-open ViBe Phase 2 work: (Phase A) replace the 512-deep V-blank-batched defer-FIFO with a 64-deep delay FIFO that holds each diffusion write for `W+1` accepted-pixel ticks before letting it commit, so writes don't compete with the CCL FSM for V-blank cycles and stay in LUTRAM; (Phase B) replace the chained-Xorshift32 init-noise scheme with parallel Xorshift32 streams to eliminate serial correlation and improve fmax.

**Architecture:**
- **Phase A** is a pure RTL refactor of `motion_core_vibe.sv`'s defer-FIFO. The bank state at end-of-frame is identical to the current V-blank-batch scheme, so all existing unit-TB goldens and Python-ref outputs MUST continue to pass byte-exact. This is a verification-by-non-regression change.
- **Phase B** changes the randomness source for frame-0 self-init and the external-init ROM. RTL output and Python-ref output WILL differ from today's goldens — they must be regenerated. RTL vs Python remains byte-exact (both sides use the same parallel-streams algorithm with shared magic-constant seeds). Mask coverage on real clips must remain statistically within the Phase-0 cross-check tolerance vs upstream PyTorch reference.

**Tech Stack:**
- **RTL:** SystemVerilog. Files modified: `hw/ip/motion/rtl/motion_core_vibe.sv` (both phases).
- **Python:** Files modified: `py/models/ops/vibe.py::_init_scheme_c`, `py/models/motion_vibe.py::compute_lookahead_median_bank`, `py/gen_vibe_init_rom.py`.
- **Verification:** Verilator unit TBs at `hw/ip/motion/tb/tb_axis_motion_detect_vibe*.sv` — Phase A passes existing goldens; Phase B regenerates all goldens. Top-level integration via `make run-pipeline` at TOLERANCE=0.

**Reference docs:**
- [Phase 2 design spec](old/2026-05-06-vibe-phase-2-design.md) — supersedes some of this; treat as historical context after this plan lands
- [Master ViBe design](2026-05-01-vibe-motion-design.md) §6.2 (defer-FIFO discussion), §6.5 (init scheme c)
- [Phase 0 redo design](old/2026-05-05-vibe-phase-0-redo-design.md) — original source of the 8-bit-byte / `% 41 - 20` noise scheme this plan retains
- [`docs/specs/axis_motion_detect_vibe-arch.md`](../specs/axis_motion_detect_vibe-arch.md) — per-module arch doc; updated by tasks A1 and B1

**Branch strategy:** All work on the existing `feat/vibe-phase-2` branch (PR #38 open). Each task lands as a separate commit for review; the whole set squashes into one commit before PR merge (replacing the existing single squashed commit). PR description updates after Phase B to reflect the final scope.

---

## File Structure

| File | Phase | Change |
|---|---|---|
| `hw/ip/motion/rtl/motion_core_vibe.sv` | A + B | Replace V-blank-batched FIFO with W+1-delay FIFO (A); replace chained init PRNG with parallel streams (B) |
| `py/models/ops/vibe.py` | B | Update `_init_scheme_c` to use parallel-stream PRNG |
| `py/models/motion_vibe.py` | B | Update `compute_lookahead_median_bank` to use parallel-stream PRNG |
| `py/gen_vibe_init_rom.py` | B | Mirror Python ref's parallel-stream change |
| `hw/ip/motion/tb/tb_axis_motion_detect_vibe.sv` | A + B | Shrink V-blank back to 36 (A); regenerate after golden regen (B) |
| `hw/ip/motion/tb/tb_axis_motion_detect_vibe_k20.sv` | A + B | Same as above |
| `hw/ip/motion/tb/tb_axis_motion_detect_vibe_external.sv` | A + B | Same as above |
| `hw/ip/motion/tb/golden/test2_*.bin`, `test3_k20_*.bin`, `test4_*.{bin,mem}` | B | Regenerate (Phase A keeps these unchanged) |
| `hw/ip/motion/tb/gen_golden.py` | B | Update if needed for parallel-stream parity |
| `py/tests/test_vibe_init_rom.py` | B | Re-run; outputs change but test logic unchanged |
| `docs/specs/axis_motion_detect_vibe-arch.md` | A + B | §5.5 defer-FIFO description updated (A); §5.4 PRNG construction updated (B) |
| `docs/plans/2026-05-07-vibe-phase-2-randomness-and-fifo-redesign-plan.md` | this plan | Move to `docs/plans/old/` post-merge |
| `CLAUDE.md` | B | "ViBe parity discipline" lessons-learned subsection: add note about magic-constant seeds and the parallel-streams design rationale |

---

## Phase A — W+1-delay FIFO (bit-exact wrt current implementation)

Phase A replaces the 512-deep V-blank-batched FIFO with a 64-deep delay FIFO whose entries hold a `deadline` value measured in **accepted-pixel ticks** (a monotonic counter that increments only on real AXIS handshakes — ignores stalls, V-blank, H-blank). Diffusion writes push with `deadline = (firing pixel's count) + W + 1`; the FIFO head pops when `pix_count_s2 >= deadline` AND Port-B is free (no self-update for the current S2 pixel). Self-update writes never enter the FIFO — they use Port-B directly the same cycle the firing pixel is at S2.

**Bit-exactness invariant:** for every (addr, slot) pair, the *last* write before the next-frame read of that pixel determines the bank value seen at next-frame compare. Both schemes (V-blank-batch and W+1-delay) drain writes in FIFO firing order and complete all writes before next-frame's read of any target. So the bank state at the start of every frame is identical → all goldens still match. (See arch doc §5.5 for the end-of-frame deadline-crosses-frame-boundary case.)

**Why W+1 specifically:** in raster scan, the worst-case ahead-of-firing neighbor is SE at exactly +W+1 pixel ticks. A W+1 delay ensures the write commits NO EARLIER than the SE read — which under READ_FIRST port-A semantics means the SE read returns the *pre-update* sample (matching Python's `compute_mask` first / `_apply_update_coupled` second).

**No separate joint-fire FIFO:** master design §6.2's 4-deep joint-fire FIFO was for the rare case where self-update and diffusion fire same cycle and only one can take Port-B. With every diffusion write going through the W+1 delay FIFO unconditionally, that scenario disappears: self-update takes Port-B immediately, diffusion enqueues with its deadline, drained later. The single 64-deep FIFO subsumes both mechanisms.

**Pixel counter, not cycle counter:** the deadline is in **accepted-pixel ticks**, not raw clock cycles. AXIS streams have stalls, blanking, and bursts; raster offsets between firing pixel and target neighbors are constant in pixel ticks but vary wildly in cycles. Using a pixel counter makes the W+1 delay invariant under any pacing of the input stream. The counter is monotonic across frames (32-bit, never resets except on chip reset) so end-of-frame firings whose deadlines fall slightly past the frame boundary still drain correctly when the next frame's first ~W pixels reach S2.

### Task A1: Update arch doc — §5.5 defer-FIFO redesign description

**Files:**
- Modify: `docs/specs/axis_motion_detect_vibe-arch.md`

The existing arch doc §5.5 describes a 512-deep V-blank-batched FIFO. Replace with the W+1-delay scheme.

- [ ] **Step 1: Open the file and locate §5.5.**

```bash
grep -n "^### 5.5\|^## 5\.\|^### 5\." docs/specs/axis_motion_detect_vibe-arch.md
```

- [ ] **Step 2: Replace the §5.5 body with the W+1-delay description.**

Replace the existing §5.5 content with:

```markdown
### 5.5 Defer-FIFO — W+1 pixel delay

Diffusion writes target one of 8 spatial neighbors of the current pixel. In raster order, four directions (NW, N, NE, W) target already-read pixels — writes to them affect only the *next* frame's read. Four directions (E, SE, S, SW) target not-yet-read pixels — without delay, the write would land before that pixel's read, contaminating the same-frame classification.

The defer-FIFO holds every diffusion write with a `deadline` field measured in **accepted-pixel ticks** (not raw cycles). A monotonic 32-bit `pixel_count_q` register increments only on accepted pixel beats (`valid_i && ready_o && !pipe_stall_i`); it is NOT reset across frames — pixels of frame N are at counts `[N·H·W, (N+1)·H·W − 1]`. The counter ignores AXIS stalls, V-blank, and H-blank, so a pixel-tick distance always corresponds to the same raster-scan offset regardless of how the input stream is paced.

For a diffusion firing at pixel-count `C_fire`, deadline is `C_fire + W + 1` (where W = `WIDTH`). The worst-case ahead-of-firing neighbor in raster order is SE at exactly +W+1 pixel ticks. Holding for W+1 pixel ticks guarantees the write commits no earlier than the target's same-frame read — which under Port-A READ_FIRST semantics means same-frame reads see the pre-update sample bank.

**Pixel-count is monotonic across frames** (32-bit, wraps every ~55,000 VGA frames ≈ 30 minutes at 30fps). End-of-frame firings whose deadlines fall into early next-frame are still drained correctly: the deadline value `H·W·N + H·W + δ` (a small δ ≤ W) is reached when next-frame's δ-th pixel is at S2. The diffusion target for those firings is always a row-(H-1) pixel, never read again until next-frame's row H-1 reaches S0 — far past the drain point.

**The pixel count is registered along the pipeline** as `pix_count_s1` and `pix_count_s2` (matching `pix_addr_s1`, `pix_addr_s2`). The FIFO push at firing time uses `pix_count_s2` as the firing pixel's count. The FIFO drain compares `pix_count_s2` against the head's deadline.

**Self-update writes do not go through the FIFO.** They target the current pixel (the pixel currently at S2) and use Port-B directly. READ_FIRST guarantees the read at S0 (two cycles earlier) saw pre-update samples; the write commits, and next-frame reads of that pixel see the new value.

**Per-pixel-cycle Port-B priority:**

| Source | Priority | Frequency |
|---|---|---|
| Frame-0 self-init (`init_phase`) | 1 (highest) | first frame only |
| Self-update for current S2 pixel | 2 | ≈ 1 / φ_update (≈ 6.25%) |
| FIFO head with deadline ≤ `pix_count_s2` | 3 | ≈ 1 / φ_diffuse on average; bursts higher |
| Idle | — | ≈ 88% |

The single delay FIFO covers all diffusion writes — there is no separate "joint-fire" FIFO. When diffusion AND self-update fire on the same firing pixel, self-update takes Port-B immediately and the diffusion write enqueues with its W+1 deadline like any other diffusion. The original master-design 4-deep joint-fire FIFO is fully subsumed.

**FIFO depth analysis at default `φ_diffuse = 16, φ_update = 16, W = 320`:**

Diffusion fires at average rate `λ = 1/φ_diffuse = 1/16` per pixel tick (Poisson process). Each entry's residency in the FIFO ranges from W+1 (no contention; drains exactly at deadline) to W+1 + extra (when self-update steals Port-B at deadline cycles).

- **Without contention:** average occupancy = `λ × (W+1) = 320/16 = 20` entries
- **With Port-B contention:** self-update steals Port-B at rate `1/φ_update = 1/16`. Effective drain rate = `15/16` of cycles when an entry is past deadline. Effective residency stretches by factor `16/15`, giving average occupancy ≈ `21` entries.
- **Statistical peak** (Poisson with N=21 mean): standard deviation σ = √21 ≈ 4.6. The 99.99-percentile (4σ) peak ≈ `21 + 4·4.6 ≈ 39` entries.

**Phase 2 picks 64 entries** — ~60% margin over peak. Stays in distributed LUTRAM (no dedicated BRAM tile required) since the entry width is ≈ 64 bits (32-bit deadline + addr + slot + data) × 64 entries = 4 Kbit, well under the LUTRAM threshold on typical FPGAs.

**Sizing constraint:** the depth assumption is `W ≤ 640, φ_diffuse ≥ 16`. Combinations beyond that range require recomputing — for `W = 1024, φ = 16`: avg ≈ 64, peak ≈ 96 → FIFO_DEPTH should be ≥ 128. The overflow assertion in step 3 catches violations at sim time.

**FIFO entry format:** `{deadline[31:0], addr[ADDR_W-1:0], slot[$clog2(K)-1:0], data[7:0]}`. Total ≈ 56–64 bits depending on K and ADDR_W.

**Compared to V-blank-batch alternative:** the W+1 design avoids competing with the CCL FSM for V-blank cycles, drains continuously through the active region (smoother BRAM access pattern), and stays in LUTRAM. The V-blank-batch scheme — with peak occupancy ≈ pixels-per-frame / `φ_diffuse` ≈ 4,800 entries at default φ for VGA — was the implementer's first-cut fix during Phase 2 task 17 and is now superseded.
```

- [ ] **Step 3: If §5.7 (Resource cost) mentions the 512-deep FIFO, update it to "64-deep delay FIFO in distributed LUTRAM".**

```bash
grep -n "512\|defer.FIFO\|V-blank" docs/specs/axis_motion_detect_vibe-arch.md
```

For any line that references the old design, edit to match the new scheme.

- [ ] **Step 4: Commit.**

```bash
git add docs/specs/axis_motion_detect_vibe-arch.md
git commit -m "docs(specs): update axis_motion_detect_vibe arch §5.5 — W+1-delay defer-FIFO"
```

NO `Co-Authored-By` trailer (per CLAUDE.md).

---

### Task A2: RTL — Replace V-blank-batched FIFO with W+1-delay FIFO

**Files:**
- Modify: `hw/ip/motion/rtl/motion_core_vibe.sv`

The existing implementation has a 512-deep circular FIFO that holds writes during the active frame and drains during V-blank. Replace with a 64-deep FIFO with deadline counters that drain continuously.

- [ ] **Step 1: Locate the existing defer-FIFO block in `motion_core_vibe.sv`.**

```bash
grep -n "defer\|fifo\|in_vblank\|circular\|head\|tail" hw/ip/motion/rtl/motion_core_vibe.sv | head -30
```

Read the surrounding context — note the FIFO entry format, the push side (when diffusion fires), and the drain side (when in_vblank). Note also where `in_vblank` is computed.

- [ ] **Step 2: Replace the FIFO declaration and add the pixel counter.**

Replace the 512-deep buffer with:

```sv
// Defer-FIFO for diffusion writes.
// Each entry holds a deadline measured in monotonic accepted-pixel ticks
// (NOT cycles). Drain when head.deadline <= pix_count_s2 AND Port-B is free.
// Self-update writes do NOT go through this FIFO — they hit Port-B directly
// when the firing pixel is at S2.
//
// Depth: 64. See arch doc §5.5 for the depth derivation:
//   avg occupancy ≈ (1/φ_diffuse) × (W+1) = 20 at default φ=16, W=320
//   peak ≈ avg + 4·sqrt(avg) ≈ 39
//   64 entries = ~60% margin over peak; fits LUTRAM
// Sizing constraint: W ≤ 640, φ_diffuse ≥ 16. Larger W or smaller φ requires
// recomputing — the overflow assertion below catches violations at sim time.
localparam int FIFO_DEPTH = 64;
localparam int LOG2_FIFO  = $clog2(FIFO_DEPTH);
localparam int PIX_CNT_W  = 32;  // monotonic across frames; wraps every
                                 // ~55k VGA frames (~30 min at 30fps).

// Pixel counter — increments only on accepted pixel beats. Ignores AXIS
// stalls, V-blank, H-blank. Monotonic across frames (no per-frame reset).
// This makes deadline arithmetic frame-boundary-agnostic: a firing at the
// last pixel of frame N gets deadline ~H·W·N + H·W + δ; reached when next
// frame's δ-th pixel is at S2.
logic [PIX_CNT_W-1:0] pixel_count_q;
always_ff @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i)
        pixel_count_q <= '0;
    else if (valid_i && ready_o && !pipe_stall_i)
        pixel_count_q <= pixel_count_q + 1'b1;
end

// Pipeline-aligned copies of the count: pix_count_s1 (the pixel currently
// at S1), pix_count_s2 (the pixel currently at S2). Updated alongside the
// existing pix_addr_s1, pix_addr_s2 registers — same enable signal.
logic [PIX_CNT_W-1:0] pix_count_s1, pix_count_s2;
always_ff @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
        pix_count_s1 <= '0;
        pix_count_s2 <= '0;
    end else if (!pipe_stall_i) begin
        // Snapshot pixel_count_q for the pixel entering S1 this cycle.
        // valid_s1 indicates a real pixel at S1; pix_count_s1 must align.
        if (valid_i && ready_o)
            pix_count_s1 <= pixel_count_q;  // value BEFORE this cycle's increment
        pix_count_s2 <= pix_count_s1;
    end
end

// FIFO entry layout. Deadline width matches PIX_CNT_W so wraparound is
// handled by signed-difference comparison (see step 4).
typedef struct packed {
    logic [PIX_CNT_W-1:0]   deadline;
    logic [ADDR_W-1:0]      addr;
    logic [$clog2(K)-1:0]   slot;
    logic [7:0]             data;
} defer_entry_t;

defer_entry_t defer_fifo [0:FIFO_DEPTH-1];
logic [LOG2_FIFO:0]   fifo_count;
logic [LOG2_FIFO-1:0] fifo_head, fifo_tail;
```

Adapt `ADDR_W` and `$clog2(K)` to the existing module's localparam names. The implementer must match the exact name of `pix_addr_s1` / `pix_addr_s2` as already used in `motion_core_vibe.sv` — `pix_count_s1` / `pix_count_s2` should be added next to those, with the same enable conditions.

- [ ] **Step 3: Replace the push-side logic.**

When diffusion fires (decision evaluated at S2 in the existing code, gated by `diffuse_fire`), push to FIFO with `deadline = pix_count_s2 + WIDTH + 1`. The firing pixel's count is `pix_count_s2` because the diffusion decision is computed when the firing pixel is at S2:

```sv
logic       fifo_push;
defer_entry_t fifo_push_data;

assign fifo_push_data = '{
    // Firing pixel's count is pix_count_s2; SE neighbor is +W+1 ticks later.
    deadline: pix_count_s2 + PIX_CNT_W'(WIDTH + 1),
    addr:     diffuse_addr,
    slot:     diffuse_slot,
    data:     y_pipe   // or whatever the existing diffusion data signal is
};

// Push fires whenever diffusion classification fires AND we're not in init
// phase AND we're past the backpressure stall.
assign fifo_push = diffuse_fire && !init_phase && !pipe_stall_i;

always_ff @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
        fifo_tail  <= '0;
        fifo_count <= '0;
    end else begin
        if (fifo_push && !fifo_pop) begin
            defer_fifo[fifo_tail] <= fifo_push_data;
            fifo_tail  <= fifo_tail + 1'b1;
            fifo_count <= fifo_count + 1'b1;
        end else if (fifo_push && fifo_pop) begin
            defer_fifo[fifo_tail] <= fifo_push_data;
            fifo_tail  <= fifo_tail + 1'b1;
            // count unchanged: one in, one out
        end else if (fifo_pop) begin
            fifo_count <= fifo_count - 1'b1;
        end
    end
end

// Overflow assertion. CLAUDE.md prohibits SVA, so use a procedural $error.
// The check fires if a push would overflow the FIFO. Only enabled in
// simulation; synthesis tools elide $error.
always_ff @(posedge clk_i) begin
    if (rst_n_i && (fifo_count > LOG2_FIFO'(FIFO_DEPTH-2)) && fifo_push)
        $error("motion_core_vibe: defer FIFO overflow (count=%0d, FIFO_DEPTH=%0d). \
                Increase FIFO_DEPTH or reduce phi_diffuse rate (see arch doc §5.5).",
               fifo_count, FIFO_DEPTH);
end
```

- [ ] **Step 4: Replace the drain-side logic.**

The drain is gated by `(head.deadline <= pix_count_s2) AND no self-update this cycle`:

```sv
// Drain decision: head's deadline reached AND no self-update wants Port-B.
// The comparison uses signed difference so the 32-bit wraparound (every ~55k
// VGA frames) is handled correctly — within any (W+1) tick window, the
// signed difference is bounded by ±W+1, far inside 2^31.
logic fifo_pop;
logic head_ready;
defer_entry_t head;
assign head       = defer_fifo[fifo_head];
assign head_ready = (fifo_count != '0) &&
                    ($signed(head.deadline - pix_count_s2) <= $signed(PIX_CNT_W'd0));

// Drain only on real pixel cycles (not during stall/init). The drain itself
// uses Port-B for that cycle's S2-pixel slot, so it does not increment any
// pipeline state — pix_count_s2 only advances on real pixel beats, which
// is also when self_update_fire is meaningful.
assign fifo_pop = head_ready && !self_update_fire && !init_phase && !pipe_stall_i;

always_ff @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i)
        fifo_head <= '0;
    else if (fifo_pop)
        fifo_head <= fifo_head + 1'b1;
end
```

`self_update_fire` is the existing per-pixel self-update gate (decision computed at S2; uses the runtime PRNG word and the S2 pixel's mask). Adapt the name to whatever the file uses.

**Why use `pix_count_s2` and not `pixel_count_q` directly:** the drain happens on the SAME cycle as the firing pixel's `pix_count_s2 + W + 1` value would naturally appear at S2 — i.e., when the SE neighbor is at S2. Using `pixel_count_q` (which is "S0 pixel about to enter") would drain 2 cycles too early and the write would land before the neighbor's S0 read completed.

- [ ] **Step 5: Replace the Port-B mux.**

```sv
// Port-B priority: init writes > self-update > FIFO drain
always_comb begin
    if (init_phase && valid_s1) begin
        // Frame-0 self-init writes all K slots
        mem_wr_en   = 1'b1;
        mem_wr_addr = pix_addr_s1;
        mem_wr_data = init_word;       // existing signal
        mem_wr_be   = '1;
    end else if (self_update_fire && !pipe_stall_i) begin
        mem_wr_en   = 1'b1;
        mem_wr_addr = pix_addr_s1;
        mem_wr_data = update_data;     // existing signal: y_pipe replicated
        mem_wr_be   = update_be;       // existing 1-hot byte-enable for the chosen slot
    end else if (fifo_pop) begin
        mem_wr_en   = 1'b1;
        mem_wr_addr = head.addr;
        mem_wr_data = {K{head.data}};  // replicate y; byte-enable picks one slot
        mem_wr_be   = K'(1) << head.slot;
    end else begin
        mem_wr_en   = 1'b0;
        mem_wr_addr = '0;
        mem_wr_data = '0;
        mem_wr_be   = '0;
    end
end
```

- [ ] **Step 6: Remove the `in_vblank` signal and any V-blank-gating logic.**

The W+1-delay scheme drains continuously — no V-blank gate needed. Find any `in_vblank`-gated condition and remove the gate.

```bash
grep -n "in_vblank\|drain_busy" hw/ip/motion/rtl/motion_core_vibe.sv
```

If `drain_busy_o` is exposed for the wrapper to gate `s_axis_pix.tready`, the new design no longer needs it (drain happens continuously, not blocking the input). Hold the port present for now (assign to `1'b0`) to avoid breaking the wrapper; remove the wrapper-side dependency in step 7.

- [ ] **Step 7: Update the wrapper if needed.**

```bash
grep -n "drain_busy" hw/ip/motion/rtl/axis_motion_detect_vibe.sv
```

If the wrapper uses `drain_busy_o` to gate `s_axis_pix.tready` (the Phase 2 implementer added this), remove the dependency since the new FIFO doesn't need input backpressure for drain.

- [ ] **Step 8: Run lint.**

```bash
make lint
```

Expected: exits 0, no warnings.

- [ ] **Step 9: Commit.**

```bash
git add hw/ip/motion/rtl/motion_core_vibe.sv hw/ip/motion/rtl/axis_motion_detect_vibe.sv
git commit -m "hw(motion_core_vibe): replace V-blank-batch FIFO with W+1-delay FIFO"
```

NO `Co-Authored-By` trailer.

---

### Task A3: Verify all unit TBs pass with EXISTING goldens (bit-exactness check)

**Files:** none (verification only)

This is the critical Phase A non-regression check. The bank state at end-of-frame must be identical to the V-blank-batch scheme, so all existing goldens must pass without regeneration.

- [ ] **Step 1: Run all unit TBs.**

```bash
make test-ip-vibe
```

Expected: all 8 tests PASS — T1 (static bg), T2 (200-frame parity vs Python K=8), T2b (diffusion progress K=8), T3 (200-frame parity K=20), T3b (K=20), T4 (external-init), T5 (backpressure), T6 (PRNG-no-drift), T7 (misconfig external), T8 (misconfig K).

Especially T2 and T3: these are the bit-exact-vs-Python-ref tests. They MUST pass without regenerating goldens. If they fail:
- Bisect by frame index. The first divergent frame tells you whether the issue is in frame-0 (init, unlikely since FIFO change doesn't affect init) or frames 1+ (FIFO ordering bug).
- Within the divergent frame, log per-pixel mask + dump the FIFO state at the divergence cycle. Most likely cause: FIFO push/pop ordering or deadline arithmetic edge case.

If a bug is found, fix it, re-run, and amend the Task A2 commit (same task scope).

- [ ] **Step 2: If all pass, no further action.**

If goldens pass, the bit-exactness invariant holds and Phase A is correct.

- [ ] **Step 3: No commit (verification step).**

---

### Task A4: End-to-end integration — `make run-pipeline` ViBe profiles at TOLERANCE=0

**Files:** none (verification only)

- [ ] **Step 1: Run for `default_vibe`.**

```bash
make run-pipeline CFG=default_vibe SOURCE=synthetic:moving_box CTRL_FLOW=motion TOLERANCE=0
```

Expected: PASS, zero pixel diff between RTL output and Python ref.

- [ ] **Step 2: Run for `vibe_k20`.**

```bash
make run-pipeline CFG=vibe_k20 SOURCE=synthetic:moving_box CTRL_FLOW=motion TOLERANCE=0
```

- [ ] **Step 3: Run for `vibe_init_external`.**

```bash
make run-pipeline CFG=vibe_init_external SOURCE=synthetic:ghost_box_disappear CTRL_FLOW=motion TOLERANCE=0
```

- [ ] **Step 4: Run for `vibe_no_gauss`, `vibe_init_frame0`, `vibe_no_diffuse`.**

```bash
for cfg in vibe_no_gauss vibe_init_frame0 vibe_no_diffuse; do
    make run-pipeline CFG=$cfg SOURCE=synthetic:moving_box CTRL_FLOW=motion TOLERANCE=0
done
```

Expected: all PASS at TOLERANCE=0.

- [ ] **Step 5: No commit.**

If any fail, debug. Most likely: top-level integration sees a different vblank shape than the unit TB (the integration TB has different H_BLANK/V_BLANK). With the W+1-delay FIFO drain happening during active region, the integration should now work with the project's standard V_BLANK without modification.

---

### Task A5: Shrink unit TB V-blank back to 36 cycles

**Files:**
- Modify: `hw/ip/motion/tb/tb_axis_motion_detect_vibe.sv`
- Modify: `hw/ip/motion/tb/tb_axis_motion_detect_vibe_k20.sv`
- Modify: `hw/ip/motion/tb/tb_axis_motion_detect_vibe_external.sv`

The Phase 2 implementer bumped V-blank from 36 → 256 because the V-blank-batch FIFO needed time to drain. With the W+1-delay scheme, drains happen during active region — V-blank can shrink back.

- [ ] **Step 1: Find the V_BLANK constants.**

```bash
grep -n "V_BLANK\|vblank\|256" hw/ip/motion/tb/tb_axis_motion_detect_vibe*.sv
```

- [ ] **Step 2: Change 256 back to 36 in all three TB files.**

```sv
// Before:
localparam int V_BLANK = 256;
// After:
localparam int V_BLANK = 36;
```

(Confirm the project's standard V_BLANK matches by checking `dv/sv/tb_sparevideo.sv` — should be 16+2+2 = 20 lines × W or similar. 36 is a reasonable "small but safe" number for unit TBs.)

- [ ] **Step 3: Run all unit TBs.**

```bash
make test-ip-vibe
```

Expected: all PASS with the shorter V-blank (the W+1-delay FIFO never needs V-blank cycles).

- [ ] **Step 4: Commit.**

```bash
git add hw/ip/motion/tb/tb_axis_motion_detect_vibe*.sv
git commit -m "dv(vibe): shrink unit TB V_BLANK from 256 to 36 (no longer FIFO-bound)"
```

NO `Co-Authored-By` trailer.

---

### Task A6: Phase A — Update CLAUDE.md lessons-learned subsection

**Files:**
- Modify: `CLAUDE.md`

The Phase 2 squash commit added a "ViBe parity discipline (Phase 2)" subsection mentioning the V-blank-batched FIFO. Update it to reflect the W+1-delay scheme.

- [ ] **Step 1: Find the subsection.**

```bash
grep -n "ViBe parity discipline\|defer-FIFO\|V-blank" CLAUDE.md
```

- [ ] **Step 2: Edit the subsection.**

The existing text mentions the V-blank-batched approach. Replace with text describing the W+1-delay FIFO and why the design landed there:

```markdown
**ViBe parity discipline (Phase 2).** When implementing or modifying a stochastic algorithm with both SV and Python implementations, the PRNG seed and per-cycle advance schedule must match exactly between sides. Critical pitfall: PRNG advance during AXIS backpressure stalls. SV's `pipe_stall` gate must gate the PRNG advance, otherwise frame-N drift between sides accumulates silently. Unit TB Test 6 (`test-ip-vibe`) explicitly catches this by toggling `tready` and comparing against the Python reference.

A second pitfall: read-vs-write ordering for diffusion writes. Python's `process_frame` computes the entire frame's mask (against start-of-frame bank state) before applying any updates. RTL must defer diffusion writes by exactly `WIDTH+1` accepted-pixel ticks (NOT clock cycles — AXIS stalls would break a raw-cycle delay) so they commit no earlier than the worst-case neighbor read (SE direction). The 64-deep delay FIFO in `motion_core_vibe.sv` uses a monotonic-across-frames `pixel_count_q` register that increments only on `valid_i && ready_o && !pipe_stall_i`; deadlines are stored in pixel-tick space and compared against `pix_count_s2`. Bank state at end-of-frame is identical to a V-blank-batch scheme, so byte-exact RTL-vs-Python parity holds. The continuous-drain design avoids competing with the CCL FSM for V-blank cycles and stays in distributed LUTRAM.
```

- [ ] **Step 3: Commit.**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md ViBe parity discipline note for W+1-delay FIFO"
```

NO `Co-Authored-By`.

---

## Phase B — Parallel-stream PRNG init

Phase B replaces chained Xorshift32 advances with parallel Xorshift32 streams for the frame-0 init noise generation. Each lane group gets its own independent 32-bit state, eliminating the serial correlation between consecutive Xorshift32 outputs.

**Stream allocation by K:**
- K=8 needs 64 bits per pixel → **2 parallel streams** (`s0`, `s1`)
- K=20 needs 160 bits per pixel → **5 parallel streams** (`s0..s4`)

**Magic-constant seeds** (mirrored exactly between Python ref and RTL):
```
SEED_0 = PRNG_SEED                               (existing seed, e.g., 0xDEADBEEF)
SEED_1 = PRNG_SEED ^ 0x9E3779B9                  (golden ratio)
SEED_2 = PRNG_SEED ^ 0xD1B54A32                  (φ × 2^32 / 3 ≈ ½)
SEED_3 = PRNG_SEED ^ 0xCAFEBABE                  (arbitrary, distinctive)
SEED_4 = PRNG_SEED ^ 0x12345678                  (arbitrary, distinctive)
```

Each magic constant must (a) be non-zero, (b) when XORed with PRNG_SEED produce a non-zero state (Xorshift32 fixed point at 0), and (c) be distinctive enough that streams don't degenerate into each other under common seeds. The four chosen constants satisfy all three.

**Per-pixel scheme:**
1. Each of N streams advances once (combinationally — single Xorshift32 stage critical path, parallel)
2. Concatenate the N updated states: `pool = {s_{N-1}, s_{N-2}, ..., s_1, s_0}` (N×32 bits)
3. Slice `pool` into K bytes: byte `k` = `pool[k*8 +: 8]`
4. Apply existing noise formula: `noise = (byte % 41) - 20` ∈ [-20, +20]
5. `bank[k] = clamp(y_smooth + noise, 0, 255)`

**Runtime PRNG (per-frame update/diffusion rolls): UNCHANGED.** Single stream `prng_state` continues to advance once per pixel during runtime — only init switches to parallel streams.

**Cross-check vs upstream:** Phase 0's mask-coverage tolerance vs upstream PyTorch reference is ~10% per-frame. With each stream still being Xorshift32, the per-stream randomness character is unchanged. Phase 0 cross-check should pass with the same margins as the chained scheme.

### Task B1: Update arch doc and design spec

**Files:**
- Modify: `docs/specs/axis_motion_detect_vibe-arch.md`

- [ ] **Step 1: Locate the PRNG section in the arch doc.**

```bash
grep -n "PRNG\|Xorshift\|init.*lane\|parallel" docs/specs/axis_motion_detect_vibe-arch.md
```

- [ ] **Step 2: Replace the PRNG-related text with the parallel-stream description.**

In the §5.4 PRNG section, replace the chained-N-times description with:

```markdown
### 5.4 PRNG — Xorshift32 (parallel streams for init)

**Runtime PRNG (frames 1+):** Single Xorshift32 stream `prng_state`. Advances once per accepted pixel beat, gated on `!pipe_stall_i`. Provides the ~17 bits per pixel needed for self-update / diffusion rolls. State register: 32 bits.

**Init PRNG (frame 0 only, when `vibe_bg_init_external == 0`):** N parallel Xorshift32 streams. Each stream owns a 32-bit state and one xorshift core. All N streams advance once per accepted pixel beat (gated on `!pipe_stall_i`); their post-advance states concatenate into a `8*K`-bit noise pool sliced into K 8-bit lanes. The lane-byte → noise transform is `(byte % 41) - 20`, producing noise ∈ [-20, +20] matching upstream's `randint(-20, 20)`.

**N as a function of K:**
- K=8: N=2 streams (64 bits per pixel, 8 lanes × 8-bit byte)
- K=20: N=5 streams (160 bits per pixel, 20 lanes × 8-bit byte)
- General: `N = ceil(8*K / 32) = ceil(K/4)`

**Stream seeds (must match Python ref exactly):**
```
SEED_0 = PRNG_SEED                       (the module's PRNG_SEED parameter, default 32'hDEADBEEF)
SEED_1 = PRNG_SEED ^ 32'h9E3779B9        (golden ratio constant)
SEED_2 = PRNG_SEED ^ 32'hD1B54A32        (arbitrary distinctive)
SEED_3 = PRNG_SEED ^ 32'hCAFEBABE        (arbitrary distinctive)
SEED_4 = PRNG_SEED ^ 32'h12345678        (arbitrary distinctive)
```

**Why parallel instead of chained:** chaining N Xorshift32 advances combinationally produces consecutive outputs of one stream, with measurable serial correlation (Xorshift32 fails several BigCrush tests on consecutive-output independence). Parallel streams with different seeds have no analytically-derivable correlation between streams. The fmax cost is also ~N× lower since the critical path is one xorshift core, not a chain of N. The register-bit cost is N×32 (32 for K=8; 128 extra for K=20) — small relative to the 8*K bits per pixel × WIDTH × HEIGHT sample bank.

**Phase 0 cross-check** (mask coverage vs upstream PyTorch reference) was originally passed with the chained scheme. Parallel streams maintain the per-stream Xorshift32 character, so the cross-check passes with the same ±10% tolerance margin.
```

- [ ] **Step 3: If §5.7 (Resource cost) lists PRNG state bits, update it.**

```bash
grep -n "PRNG.*state\|32.*bits\|register" docs/specs/axis_motion_detect_vibe-arch.md
```

Update entries for K=8 (32+32 = 64 bits PRNG state, runtime + 1 init stream) and K=20 (32+128 = 160 bits PRNG state, runtime + 4 extra init streams).

- [ ] **Step 4: Commit.**

```bash
git add docs/specs/axis_motion_detect_vibe-arch.md
git commit -m "docs(specs): update axis_motion_detect_vibe arch §5.4 — parallel-stream init PRNG"
```

NO `Co-Authored-By`.

---

### Task B2: Python — Update `_init_scheme_c` to parallel streams (TDD)

**Files:**
- Modify: `py/models/ops/vibe.py`
- Modify: `py/tests/` (add new test for parallel-stream init)

- [ ] **Step 1: Add a test that asserts the new bit pattern.**

Create `py/tests/test_vibe_init_scheme_c_parallel.py`:

```python
"""Parallel-stream init scheme c: independent Xorshift32 streams for init noise.

Each lane gets one byte from a distinct stream; streams are seeded as
PRNG_SEED ^ MAGIC_i for fixed magic constants. Bit-exact regression test —
locks in the magic constants and stream allocation.
"""
import numpy as np
import pytest
from models.ops.vibe import ViBe
from models.ops.xorshift import xorshift32


SEED = 0xDEADBEEF
MAGIC_0 = 0x00000000           # base stream uses SEED unchanged
MAGIC_1 = 0x9E3779B9
MAGIC_2 = 0xD1B54A32
MAGIC_3 = 0xCAFEBABE
MAGIC_4 = 0x12345678
MAGICS = (MAGIC_0, MAGIC_1, MAGIC_2, MAGIC_3, MAGIC_4)


def _expected_bank_for_constant_y(k: int, y: int, h: int, w: int) -> np.ndarray:
    """Compute expected K-slot bank for a constant-Y frame using parallel streams."""
    n_streams = (k + 3) // 4
    states = [(SEED ^ MAGICS[i]) & 0xFFFFFFFF for i in range(n_streams)]
    bank = np.zeros((h, w, k), dtype=np.uint8)
    for r in range(h):
        for c in range(w):
            for i in range(n_streams):
                states[i] = xorshift32(states[i])
            for slot in range(k):
                stream_idx = slot // 4
                byte_idx   = slot % 4
                byte       = (states[stream_idx] >> (8 * byte_idx)) & 0xFF
                noise      = (byte % 41) - 20
                v = y + noise
                bank[r, c, slot] = max(0, min(255, v))
    return bank


@pytest.mark.parametrize("k", [4, 8, 20])
def test_init_scheme_c_parallel_streams(k):
    """Init bank for a constant-Y frame matches the parallel-stream construction."""
    h, w, y = 8, 12, 100
    frame_0 = np.full((h, w), y, dtype=np.uint8)

    v = ViBe(K=k, prng_seed=SEED, init_scheme="c")
    v.init_from_frame(frame_0)

    expected = _expected_bank_for_constant_y(k, y, h, w)
    np.testing.assert_array_equal(v.samples, expected)
```

- [ ] **Step 2: Run the test (must FAIL — current `_init_scheme_c` chains).**

```bash
source .venv/bin/activate
python -m pytest py/tests/test_vibe_init_scheme_c_parallel.py -v
```

Expected: FAIL with "Arrays are not equal" pointing at byte mismatches. Confirms the test is exercising the new requirement.

- [ ] **Step 3: Update `_init_scheme_c` in `py/models/ops/vibe.py`.**

```python
# Add to the top of the ViBe class (or as module-level constants):
INIT_SEED_MAGICS = (
    0x00000000,  # stream 0 uses prng_seed unchanged
    0x9E3779B9,  # golden ratio (stream 1)
    0xD1B54A32,  # arbitrary distinctive (stream 2)
    0xCAFEBABE,  # arbitrary distinctive (stream 3)
    0x12345678,  # arbitrary distinctive (stream 4)
)


def _init_scheme_c(self, frame_0: np.ndarray) -> None:
    """Scheme (c): each slot = clamp(y + noise, 0, 255), noise ∈ [-20, +20].

    Parallel-stream construction:
      - N = ceil(K / 4) parallel Xorshift32 streams
      - Stream i seeded as (prng_seed ^ INIT_SEED_MAGICS[i]) & 0xFFFFFFFF
      - Each pixel: all N streams advance once; output bytes sliced from the
        concatenated post-advance states
      - Noise = (byte % 41) - 20

    Eliminates serial correlation between lanes (chained variant had this
    because consecutive Xorshift32 outputs are not statistically independent).
    All streams use Xorshift32 so per-stream character is unchanged from
    the previous chained scheme — Phase 0 cross-check vs upstream still
    holds within the original ~10% tolerance.

    Runtime PRNG (self.prng_state) is unchanged — single stream, used by
    process_frame for update/diffusion rolls in subsequent frames. The init
    streams are local to this function.
    """
    n_streams = (self.K + 3) // 4
    states = [
        (self.prng_state ^ INIT_SEED_MAGICS[i]) & 0xFFFFFFFF
        for i in range(n_streams)
    ]
    # Sanity: any zero state would freeze its stream (Xorshift32 fixed point)
    for i, s in enumerate(states):
        if s == 0:
            raise ValueError(
                f"_init_scheme_c stream {i} would be zero — change PRNG_SEED")

    for r in range(self.H):
        for c in range(self.W):
            # Advance each stream once, in parallel.
            for i in range(n_streams):
                states[i] = xorshift32(states[i])
            y = int(frame_0[r, c])
            for k in range(self.K):
                stream_idx = k // 4
                byte_idx   = k % 4
                byte       = (states[stream_idx] >> (8 * byte_idx)) & 0xFF
                noise      = (byte % 41) - 20
                val        = y + noise
                self.samples[r, c, k] = 0 if val < 0 else (255 if val > 255 else val)

    # IMPORTANT: do NOT update self.prng_state. The runtime PRNG is independent
    # of the init streams. The runtime PRNG starts unchanged at prng_seed, so
    # frame-1's process_frame produces the same sequence as before.
```

Note: this leaves `self.prng_state` untouched. The previous chained scheme advanced `self.prng_state` `n_advances` times per pixel during init, then `process_frame` advanced it once per pixel for runtime rolls. The new scheme separates init streams from runtime PRNG entirely, so runtime PRNG starts from `prng_seed` for frame 1.

This means **the runtime PRNG state is no longer "after-init"** — frame 1's runtime decisions will use a *different* PRNG sequence than they did with the chained scheme. Both Python ref and RTL must reflect this. Frame-1+ masks WILL DIFFER from current goldens because the runtime PRNG starts from a different state. Goldens regenerate in Task B6.

- [ ] **Step 4: Run the new test (must PASS).**

```bash
python -m pytest py/tests/test_vibe_init_scheme_c_parallel.py -v
```

Expected: 3/3 PASS (K=4, K=8, K=20).

- [ ] **Step 5: Run the full Python suite — many tests will FAIL because outputs changed.**

```bash
python -m pytest py/tests/ -q
```

Expected: tests that bake in specific bank values (`test_init_scheme_c_samples_within_noise_band`, etc.) will fail. Note which ones — they get fixed in subsequent tasks (B3, B6) when goldens regenerate. **Do not commit yet** — Task B3 must land first to keep the codebase consistent.

- [ ] **Step 6: Commit AFTER Task B3 is also complete.** (Skip this step here.)

---

### Task B3: Python — Update `compute_lookahead_median_bank` to parallel streams

**Files:**
- Modify: `py/models/motion_vibe.py`
- Modify: `py/gen_vibe_init_rom.py`

These two files share an algorithm — the lookahead-median bank construction. They must use the same parallel-stream scheme as `_init_scheme_c` (with the `_ROM_SEED_DOMAIN_OFFSET` applied to keep ROM init independent of self-init).

- [ ] **Step 1: Update `compute_lookahead_median_bank` in `py/models/motion_vibe.py`.**

The function currently does `n_advances` chained advances of one stream. Replace with N parallel streams:

```python
from models.ops.vibe import INIT_SEED_MAGICS  # NEW import — share constants


def compute_lookahead_median_bank(
    rgb_frames: list[np.ndarray],
    *,
    k: int,
    lookahead_n: int,
    seed: int,
) -> np.ndarray:
    """Compute the ViBe sample bank from a lookahead-median of RGB frames
    using parallel-stream init.

    Mirrors `ViBe._init_scheme_c` exactly (parallel streams, magic-constant
    seeds, byte-slicing, (byte % 41) - 20 noise) but with the seed domain
    offset by _ROM_SEED_DOMAIN_OFFSET to keep ROM init's PRNG state
    independent of the runtime self-init PRNG state.

    Args:
        rgb_frames: List of (H, W, 3) uint8 RGB frames.
        k:          Number of ViBe slots.
        lookahead_n: 0 = all frames; otherwise first N.
        seed:       vibe_prng_seed.

    Returns:
        (H, W, K) uint8.
    """
    if not rgb_frames:
        raise ValueError("rgb_frames must be non-empty")

    y_stack = np.stack([_rgb_to_y(f) for f in rgb_frames], axis=0)
    n_total = y_stack.shape[0]
    n = n_total if lookahead_n == 0 else int(lookahead_n)
    if not (1 <= n <= n_total):
        raise ValueError(f"lookahead_n={lookahead_n} out of range [1, {n_total}]")

    median = np.median(y_stack[:n], axis=0).astype(np.uint8)
    h, w = median.shape

    # Domain-separated base seed (avoids collision with self-init PRNG state).
    base = (seed ^ _ROM_SEED_DOMAIN_OFFSET) & 0xFFFFFFFF

    # Parallel streams — same construction as ViBe._init_scheme_c.
    n_streams = (k + 3) // 4
    states = [(base ^ INIT_SEED_MAGICS[i]) & 0xFFFFFFFF for i in range(n_streams)]
    for i, s in enumerate(states):
        if s == 0:
            raise ValueError(
                f"compute_lookahead_median_bank stream {i} would be zero")

    bank = np.zeros((h, w, k), dtype=np.uint8)
    for r in range(h):
        for c in range(w):
            for i in range(n_streams):
                states[i] = xorshift32(states[i])
            y_val = int(median[r, c])
            for slot in range(k):
                stream_idx = slot // 4
                byte_idx   = slot % 4
                byte       = (states[stream_idx] >> (8 * byte_idx)) & 0xFF
                noise      = (byte % 41) - 20
                val        = y_val + noise
                bank[r, c, slot] = 0 if val < 0 else (255 if val > 255 else val)
    return bank
```

- [ ] **Step 2: `py/gen_vibe_init_rom.py` already imports `compute_lookahead_median_bank` — no change needed.**

Verify with a grep:

```bash
grep -n "compute_lookahead_median_bank\|n_advances\|xorshift32" py/gen_vibe_init_rom.py
```

If `gen_vibe_init_rom.py` re-implements the loop instead of calling the helper, refactor to call the helper (DRY). The Phase 2 implementer's design factored these together; verify that's still the case.

- [ ] **Step 3: Run the parallel-streams test from Task B2 — should still pass.**

```bash
python -m pytest py/tests/test_vibe_init_scheme_c_parallel.py -v
```

- [ ] **Step 4: Run the gen_vibe_init_rom parity test.**

```bash
python -m pytest py/tests/test_vibe_init_rom.py -v
```

Expected: PASS for both K=8 and K=20. The test compares `gen_vibe_init_rom.py` output against `compute_lookahead_median_bank` directly — both must use the same algorithm to match.

- [ ] **Step 5: Commit Tasks B2 and B3 together.**

```bash
git add py/models/ops/vibe.py py/models/motion_vibe.py py/gen_vibe_init_rom.py \
        py/tests/test_vibe_init_scheme_c_parallel.py
git commit -m "py(vibe): switch init PRNG from chained to parallel Xorshift32 streams"
```

NO `Co-Authored-By`.

---

### Task B4: Re-run Phase 0 cross-check vs upstream

**Files:** none (verification only)

The Phase 0 redo design specified ~10% mask-coverage tolerance vs upstream PyTorch reference. With parallel streams, each stream is still Xorshift32; per-stream randomness character is unchanged. Phase 0 should pass with the same margins.

- [ ] **Step 1: Run the Phase 0 experiment script.**

```bash
source .venv/bin/activate
python py/experiments/run_phase0.py 2>&1 | tee /tmp/phase0_parallel_streams.log
```

Expected: average per-frame `|ours − upstream|` ≤ 10% mask coverage (the original Phase 0 threshold). The exact numbers will differ from the chained scheme (different PRNG sequence) but should be in the same ballpark.

- [ ] **Step 2: Compare key metrics against the prior run.**

The prior Phase 0 results live at `docs/plans/old/2026-05-04-vibe-phase-0-results.md`. Compare:
- Per-source mask coverage curves (real clips, synthetic sources)
- The `lighting_ramp` outlier (was 0.0630 with chained; should remain low with parallel)
- The `noisy_moving_box` mid-range source

If any source REGRESSES significantly (>20% worse than chained), STOP and escalate. The parallel-stream scheme should not produce qualitatively different results.

- [ ] **Step 3: No commit (verification step).**

---

### Task B5: RTL — Update `motion_core_vibe.sv` init lanes to parallel streams

**Files:**
- Modify: `hw/ip/motion/rtl/motion_core_vibe.sv`

- [ ] **Step 1: Add the magic-constant `localparam`s near the existing PRNG_SEED definition.**

```sv
// Init-PRNG magic constants — XOR with PRNG_SEED to derive per-stream seeds.
// Must match Python's models/ops/vibe.py INIT_SEED_MAGICS.
localparam logic [31:0] INIT_MAGIC_0 = 32'h00000000;
localparam logic [31:0] INIT_MAGIC_1 = 32'h9E3779B9;
localparam logic [31:0] INIT_MAGIC_2 = 32'hD1B54A32;
localparam logic [31:0] INIT_MAGIC_3 = 32'hCAFEBABE;
localparam logic [31:0] INIT_MAGIC_4 = 32'h12345678;

localparam int N_INIT_STREAMS = (K + 3) / 4;  // 1 for K=4, 2 for K=8, 5 for K=20
```

- [ ] **Step 2: Replace the existing init-PRNG state register block.**

The current implementation has `prng_state` (runtime) and either chained advances or `prng_init1`/`prng_init2` (Phase 2 K=20 multi-stream remnants). Replace with N parallel state registers:

```sv
// N parallel init-PRNG state registers. Each advances once per accepted
// pixel during init_phase. Stream 0 starts at PRNG_SEED unchanged so that
// the K=4 (single-stream) case is identical to a single Xorshift32 pass.
logic [31:0] init_prng [0:N_INIT_STREAMS-1];

// Function for combinational xorshift32
function automatic logic [31:0] xorshift32(input logic [31:0] s);
    logic [31:0] s1, s2;
    s1 = s ^ (s << 13);
    s2 = s1 ^ (s1 >> 17);
    xorshift32 = s2 ^ (s2 << 5);
endfunction

// Per-stream seed
function automatic logic [31:0] init_stream_seed(input int idx);
    case (idx)
        0:       init_stream_seed = PRNG_SEED ^ INIT_MAGIC_0;
        1:       init_stream_seed = PRNG_SEED ^ INIT_MAGIC_1;
        2:       init_stream_seed = PRNG_SEED ^ INIT_MAGIC_2;
        3:       init_stream_seed = PRNG_SEED ^ INIT_MAGIC_3;
        4:       init_stream_seed = PRNG_SEED ^ INIT_MAGIC_4;
        default: init_stream_seed = PRNG_SEED;  // unreachable for K∈{4,8,20}
    endcase
endfunction

// Reset / advance
genvar gi;
generate
    for (gi = 0; gi < N_INIT_STREAMS; gi++) begin : g_init_streams
        always_ff @(posedge clk_i or negedge rst_n_i) begin
            if (!rst_n_i)
                init_prng[gi] <= init_stream_seed(gi);
            else if (init_phase && valid_i && ready_o && !pipe_stall_i)
                init_prng[gi] <= xorshift32(init_prng[gi]);
        end
    end
endgenerate
```

- [ ] **Step 3: Update the noise-pool concatenation.**

Replace the existing chained-state-words concatenation with the parallel-streams pool. The pool is `8*K` bits wide (= 64 for K=8, 160 for K=20).

```sv
// Concatenate all N stream states into the noise pool. MSB = stream N-1, LSB = stream 0.
logic [8*K-1:0] init_pool;
generate
    for (gi = 0; gi < N_INIT_STREAMS; gi++) begin : g_pool
        // Stream gi contributes 32 bits at position [gi*32 +: 32]
        // Note: clip the top stream to (K - 4*gi)*8 bits to handle K not a multiple of 4.
        if ((gi+1) * 4 <= K) begin : g_full
            assign init_pool[gi*32 +: 32] = init_prng[gi];
        end else begin : g_partial
            // Last stream: only (K - 4*gi) bytes used
            localparam int N_BYTES_PARTIAL = K - 4*gi;
            assign init_pool[gi*32 +: 8*N_BYTES_PARTIAL] = init_prng[gi][8*N_BYTES_PARTIAL-1:0];
        end
    end
endgenerate
```

For K∈{4,8,20}: K=4 → 1 stream × 4 bytes (full); K=8 → 2 streams × 4 bytes (both full); K=20 → 5 streams × 4 bytes (all full, 5*4=20 ✓). The `g_partial` branch only triggers if K is not a multiple of 4; for the supported K values, it doesn't fire. Keep the branch for correctness if K=12 or similar is ever added.

- [ ] **Step 4: Update the per-lane noise computation.**

The existing code has K parallel noise lanes. Replace the byte source from the chained-state word to the new pool:

```sv
// Per-lane noise generation
logic signed [5:0] noise [0:K-1];     // 6-bit signed: range ±32 (covers ±20)
logic signed [9:0] sum   [0:K-1];     // 10-bit signed: -20 .. 275
logic        [7:0] sample [0:K-1];

generate
    for (gi = 0; gi < K; gi++) begin : g_init_lanes
        // Lane gi gets byte gi from init_pool
        wire [7:0] byte_gi = init_pool[gi*8 +: 8];
        // noise = (byte % 41) - 20
        assign noise[gi]  = $signed({1'b0, 5'($unsigned(byte_gi) % 6'd41)}) - 6'sd20;
        assign sum[gi]    = $signed({2'b0, y_pipe}) + 10'(noise[gi]);
        assign sample[gi] = (sum[gi] < 0)   ? 8'd0
                          : (sum[gi] > 255) ? 8'd255
                          :                   sum[gi][7:0];
    end
endgenerate

// Pack into init_word, slot k at position [k*8 +: 8]
logic [8*K-1:0] init_word;
generate
    for (gi = 0; gi < K; gi++) begin : g_pack
        assign init_word[gi*8 +: 8] = sample[gi];
    end
endgenerate
```

The `% 41` operation in Verilog: ensure the modulus operand width is wide enough. `byte_gi` is 8 bits, so `byte_gi % 41` fits in 6 bits (max value 40). Use `$unsigned` to prevent sign-extension.

- [ ] **Step 5: Verify runtime PRNG (`prng_state`) is unchanged.**

The runtime PRNG advances once per accepted pixel for ALL frames (gated on `!pipe_stall_i`). It is NOT advanced during init (only `init_prng[]` advances during init). The Python ref must match: `process_frame` advances `self.prng_state` once per pixel during runtime, and `_init_scheme_c` does NOT advance `self.prng_state` (per Task B2 step 3 design).

```bash
grep -n "prng_state.*<=" hw/ip/motion/rtl/motion_core_vibe.sv
```

Verify the runtime `prng_state` register's `always_ff` advances on `valid_i && ready_o && !pipe_stall_i` regardless of `init_phase`. This is the critical bit — if the implementation conditioned runtime advance on `!init_phase`, it would create a Python-RTL parity drift starting at frame 1.

- [ ] **Step 6: Run lint.**

```bash
make lint
```

Expected: clean, exit 0.

- [ ] **Step 7: Commit.**

```bash
git add hw/ip/motion/rtl/motion_core_vibe.sv
git commit -m "hw(motion_core_vibe): parallel-stream init PRNG (K=8: 2 streams, K=20: 5 streams)"
```

NO `Co-Authored-By`.

---

### Task B6: Regenerate all unit-TB goldens

**Files:**
- Modify: `hw/ip/motion/tb/golden/test2_input.bin`
- Modify: `hw/ip/motion/tb/golden/test2_ghost_box_disappear.bin`
- Modify: `hw/ip/motion/tb/golden/test3_k20_input.bin`
- Modify: `hw/ip/motion/tb/golden/test3_k20_ghost_box_disappear.bin`
- Modify: `hw/ip/motion/tb/golden/test4_input.bin`
- Modify: `hw/ip/motion/tb/golden/test4_init_bank.mem`

The Python ref now produces different masks (different PRNG sequence) and different bank ROMs. Regenerate all golden files using `gen_golden.py`.

- [ ] **Step 1: Run `gen_golden.py`.**

```bash
source .venv/bin/activate
python hw/ip/motion/tb/gen_golden.py
```

This script (created in Phase 2 task 17) regenerates all input/golden/ROM files. Verify each file is present after running:

```bash
ls -la hw/ip/motion/tb/golden/
```

Expected: 6 files updated with new timestamps.

- [ ] **Step 2: If `gen_golden.py` doesn't already cover the K=20 + external paths, extend it.**

```bash
grep -n "k=20\|k_20\|VIBE_INIT_EXTERNAL\|init_bank" hw/ip/motion/tb/gen_golden.py
```

The Phase 2 implementer's `gen_golden.py` should cover all goldens. If any are missing, add them to the script's main loop.

- [ ] **Step 3: Re-tune Test 2b's diffusion-progress threshold.**

Test 2b asserts `avg_late_coverage <= threshold * avg_early_coverage`. The threshold is pinned to `1.25 ×` the measured Python-ref ratio. With the new PRNG, the ratio changes — re-measure.

```bash
# In gen_golden.py, after generating goldens, print the per-frame coverage
# in the ghost ROI for K=8 and K=20:
python -c "
from hw.ip.motion.tb.gen_golden import compute_diffusion_ratio
print('K=8 ratio  =', compute_diffusion_ratio(k=8))
print('K=20 ratio =', compute_diffusion_ratio(k=20))
"
```

If `compute_diffusion_ratio` doesn't exist in `gen_golden.py`, add a small helper and have it print the K=8 and K=20 measured ratios. Update the TB threshold constants accordingly:

In `hw/ip/motion/tb/tb_axis_motion_detect_vibe.sv`:
```sv
// Old: localparam real T2B_THRESHOLD = 0.117747;
// New: localparam real T2B_THRESHOLD = <measured K=8 ratio> * 1.25;
```

In `hw/ip/motion/tb/tb_axis_motion_detect_vibe_k20.sv`:
```sv
// Old: localparam real T3B_THRESHOLD = 0.052588;
// New: localparam real T3B_THRESHOLD = <measured K=20 ratio> * 1.25;
```

- [ ] **Step 4: Commit.**

```bash
git add hw/ip/motion/tb/golden/ hw/ip/motion/tb/gen_golden.py \
        hw/ip/motion/tb/tb_axis_motion_detect_vibe.sv \
        hw/ip/motion/tb/tb_axis_motion_detect_vibe_k20.sv
git commit -m "dv(vibe): regenerate goldens + retune T2b/T3b thresholds for parallel-stream PRNG"
```

NO `Co-Authored-By`.

---

### Task B7: Verify all unit TBs pass with regenerated goldens

**Files:** none (verification only)

- [ ] **Step 1: Run all unit TBs.**

```bash
make test-ip-vibe
```

Expected: all 8 tests PASS — T1, T2, T2b, T3, T3b, T4, T5, T6, T7, T8.

If any FAIL:
- T2 / T3 byte-mismatch: bisect by frame index. The first divergence pinpoints whether the issue is init (frame 0) or runtime (frames 1+). Most likely: SV magic-constant `localparam`s don't match Python `INIT_SEED_MAGICS`, or the byte-slicing endianness differs.
- T2b / T3b threshold fail: re-measure with the regenerated goldens and update the threshold (Task B6 step 3 may have under-margin'd it).
- T6 PRNG-no-drift: backpressure during init must NOT advance the init streams either. If T6 fails, the init stream's `always_ff` is missing the `!pipe_stall_i` gate.

- [ ] **Step 2: No commit.**

If a fix is needed, fix and amend Task B5 or B6 commit.

---

### Task B8: End-to-end ViBe profiles at TOLERANCE=0

**Files:** none (verification only)

- [ ] **Step 1: Run all six ViBe profiles end-to-end.**

```bash
for cfg in default_vibe vibe_k20 vibe_init_external vibe_no_gauss vibe_init_frame0 vibe_no_diffuse; do
    src=synthetic:moving_box
    if [ "$cfg" = "vibe_init_external" ]; then src=synthetic:ghost_box_disappear; fi
    make run-pipeline CFG=$cfg SOURCE=$src CTRL_FLOW=motion TOLERANCE=0
done
```

Expected: all PASS.

- [ ] **Step 2: No commit.**

---

### Task B9: EMA non-regression matrix

**Files:** none (verification only)

- [ ] **Step 1: Run all 9 EMA profiles × 3 sources.**

```bash
for cfg in default default_hflip no_ema no_morph no_gauss no_gamma_cor no_scaler no_hud demo; do
    for src in synthetic:moving_box synthetic:two_boxes synthetic:noisy_moving_box; do
        make run-pipeline CFG=$cfg SOURCE=$src CTRL_FLOW=motion TOLERANCE=0 || exit 1
    done
done
```

Expected: 27/27 PASS. Phase B is ViBe-only, so EMA paths must not regress. (The defer-FIFO and PRNG changes are entirely inside `motion_core_vibe.sv`, which is not instantiated when `bg_model=BG_MODEL_EMA`.)

- [ ] **Step 2: All 4 control flows on default profile.**

```bash
for ctrl in passthrough motion mask ccl_bbox; do
    make run-pipeline CFG=default SOURCE=synthetic:moving_box CTRL_FLOW=$ctrl TOLERANCE=0 || exit 1
done
```

- [ ] **Step 3: No commit.**

---

### Task B10: Update PRNG_SEED parity test for parallel-stream magic constants

**Files:**
- Modify: `py/tests/test_motion_vibe.py`

The Phase 2 implementer added `test_sv_prng_seed_matches_python_default` which greps the SV file for the `PRNG_SEED` literal. Extend this to also verify the magic constants match between SV and Python.

- [ ] **Step 1: Add the magic-constant parity test.**

In `py/tests/test_motion_vibe.py`, append:

```python
import re
from pathlib import Path
from models.ops.vibe import INIT_SEED_MAGICS


def test_sv_init_seed_magics_match_python():
    """The five INIT_MAGIC_N localparams in motion_core_vibe.sv must equal
    the INIT_SEED_MAGICS tuple in py/models/ops/vibe.py. Drift here causes
    init-bank divergence between SV and Python and breaks T2/T3 parity."""
    sv_path = (Path(__file__).parent.parent.parent
               / "hw/ip/motion/rtl/motion_core_vibe.sv")
    src = sv_path.read_text()

    for i, expected in enumerate(INIT_SEED_MAGICS):
        m = re.search(
            rf"localparam\s+logic\s*\[31:0\]\s+INIT_MAGIC_{i}\s*=\s*32'h([0-9A-Fa-f]+)",
            src,
        )
        assert m, f"INIT_MAGIC_{i} not found in motion_core_vibe.sv"
        sv_val = int(m.group(1), 16)
        assert sv_val == expected, (
            f"INIT_MAGIC_{i} drift: SV=0x{sv_val:08X}, Python=0x{expected:08X}. "
            f"Update one to match the other."
        )
```

- [ ] **Step 2: Run.**

```bash
python -m pytest py/tests/test_motion_vibe.py -v
```

Expected: PASS for both `test_sv_prng_seed_matches_python_default` and `test_sv_init_seed_magics_match_python`.

- [ ] **Step 3: Commit.**

```bash
git add py/tests/test_motion_vibe.py
git commit -m "py(tests): assert SV INIT_MAGIC_N localparams match Python INIT_SEED_MAGICS"
```

NO `Co-Authored-By`.

---

### Task B11: Update CLAUDE.md and remaining docs

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the ViBe parity discipline subsection.**

In CLAUDE.md, append to the existing ViBe parity discipline subsection (already updated for the W+1-delay FIFO in Task A6):

```markdown
A third pitfall: PRNG construction for K-byte init lanes. Chained Xorshift32 advances produce consecutive outputs of one stream with measurable serial correlation. Phase 2's redesign uses N parallel Xorshift32 streams instead, seeded as PRNG_SEED ^ INIT_MAGIC_i for fixed magic constants. The runtime PRNG (single stream, used by process_frame) is independent of the init streams; its state is unchanged across `_init_scheme_c`. SV `INIT_MAGIC_N` localparams in motion_core_vibe.sv must match Python's `INIT_SEED_MAGICS` tuple in models/ops/vibe.py — the parity test `test_sv_init_seed_magics_match_python` enforces this.
```

- [ ] **Step 2: Commit.**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md ViBe parity discipline note for parallel-stream init"
```

NO `Co-Authored-By`.

---

## Phase C — Finalize

### Task C1: Squash all Phase A + Phase B commits into one

**Files:** workflow only

- [ ] **Step 1: Verify no unrelated commits crept in.**

```bash
git log --oneline origin/main..HEAD
```

Expected: only Phase A (A1–A6) and Phase B (B1–B11) commits, plus any pre-existing commits already on the `feat/vibe-phase-2` branch (the original Phase 2 squashed commit `2286814` and the Phase 0 commit chain on `docs/vibe-rtl-cfg-contract` branch base).

If any commit is outside the plan scope, move it to its own branch + PR before squashing.

- [ ] **Step 2: Squash all branch commits since `origin/main` into one.**

```bash
git rebase -i origin/main
# In the editor: keep the first 'pick', change all others to 'squash' (or 's')
# Edit the resulting commit message to describe the entire Phase 2 work
# (now including the redesign):
```

Suggested commit message:

```
feat(motion): ViBe Phase 2 — RTL background-subtraction block + cfg_t trim

- New axis_motion_detect_vibe + motion_core_vibe modules, parametric K∈{8,20}
- bg_model generate gate at sparevideo_top selects EMA or ViBe at elaboration
- 64-deep W+1-delay defer-FIFO: continuous-drain in active region, byte-exact
  with Python's "compute_mask first, then apply update" semantics, no V-blank
  competition with the CCL FSM, fits in distributed LUTRAM
- Parallel-stream init PRNG: N=ceil(K/4) parallel Xorshift32 streams seeded
  with magic-constant XORs of PRNG_SEED. Eliminates serial correlation between
  init lanes that chained advances had. Runtime PRNG unchanged (single stream).
- External-init via $readmemh-loaded ROM file (lookahead-median); demo path
  skips the canonical-init ghost period
- cfg_t trim: 25 → 21 fields per the contract spec; Python-only fields
  guarded by PYTHON_ONLY_FIELDS allowlist + drift-detection test
- Unit TB at hw/ip/motion/tb/tb_axis_motion_detect_vibe*.sv covers parametric
  K, both init paths, backpressure, PRNG-no-drift-during-stall, elaboration
  misconfig errors
- Python helper py/gen_vibe_init_rom.py + Make integration; only generates
  the .mem file when CFG.vibe_bg_init_external=1
- All existing EMA profiles non-regression at TOLERANCE=0
```

- [ ] **Step 3: Force-push to update PR #38.**

```bash
git push --force-with-lease origin feat/vibe-phase-2
```

`--force-with-lease` is safer than `--force` — it refuses to push if someone else has pushed to the branch since you fetched. PR #38 updates automatically.

NEVER use `--force` to main/master. This is a feature branch — `--force-with-lease` is allowed.

---

### Task C2: Move plan to `docs/plans/old/` and update PR description

**Files:**
- Move: `docs/plans/2026-05-07-vibe-phase-2-randomness-and-fifo-redesign-plan.md` → `docs/plans/old/`
- Possibly modify: `docs/plans/old/2026-05-06-vibe-phase-2-design.md` (the original design, now partially superseded — note in the file)

- [ ] **Step 1: Move this plan to `docs/plans/old/`.**

Per CLAUDE.md: "After implementing a plan, move it to docs/plans/old/ and put a date timestamp on it."

```bash
git mv docs/plans/2026-05-07-vibe-phase-2-randomness-and-fifo-redesign-plan.md docs/plans/old/
```

- [ ] **Step 2: Add a footer to the original Phase 2 design spec noting partial supersession.**

Open `docs/plans/old/2026-05-06-vibe-phase-2-design.md` and append:

```markdown
---

## Update — 2026-05-07: Partially superseded

§3.3 (B1 multi-stream PRNG for K=20) was superseded during implementation. The
implemented scheme uses parallel Xorshift32 streams for ALL K (not just K=20),
seeded with magic-constant XORs of PRNG_SEED. See `docs/plans/old/2026-05-07-
vibe-phase-2-randomness-and-fifo-redesign-plan.md` for the redesign.

§4 / §5 / §6 references to "4-deep defer-FIFO with opportunistic per-pixel
drain" and "V-blank-batched FIFO" were both proposed but neither was retained.
The implemented scheme is a 64-deep delay FIFO with deadline counters; see the
redesign plan and `docs/specs/axis_motion_detect_vibe-arch.md` §5.5.
```

- [ ] **Step 3: Amend C1's squashed commit to include this move.**

```bash
git add docs/plans/old/
git commit --amend --no-edit
git push --force-with-lease origin feat/vibe-phase-2
```

- [ ] **Step 4: Update the PR description on GitHub.**

```bash
gh pr view 38
```

Read the existing description. Update it to include the redesign:

```bash
gh pr edit 38 --body "$(cat <<'EOF'
## Summary
- Implements [Phase 2 design spec](docs/plans/old/2026-05-06-vibe-phase-2-design.md) and the [`cfg_t` contract spec](docs/plans/old/2026-05-06-vibe-rtl-cfg-contract-design.md).
- During implementation, two design corrections landed (see [redesign plan](docs/plans/old/2026-05-07-vibe-phase-2-randomness-and-fifo-redesign-plan.md)):
  - Defer-FIFO: 64-deep W+1-delay (replaces both the master design's 4-deep opportunistic and the implementer's first-cut 512-deep V-blank-batch).
  - Init PRNG: N parallel Xorshift32 streams (replaces chained advances).
- New RTL ViBe block selectable via `CFG.bg_model`. EMA path unchanged.
- Parametric K ∈ {8, 20}. External-init via `$readmemh` ROM file for ghost-skip demos.
- All existing EMA profiles non-regression at TOLERANCE=0.

## Test plan
- [ ] `make lint` passes
- [ ] `make test-py` passes (incl. `test_vibe_init_rom`, PRNG_SEED parity, INIT_SEED_MAGICS parity, PYTHON_ONLY_FIELDS guard)
- [ ] `make test-ip` passes (incl. `test-ip-vibe-{k8,k20,external,misconfig-{external,k}}`)
- [ ] Phase 0 cross-check vs upstream PyTorch ref still within ~10% mask coverage tolerance
- [ ] `make run-pipeline CFG=default_vibe SOURCE=synthetic:moving_box TOLERANCE=0` passes
- [ ] `make run-pipeline CFG=vibe_k20 ... TOLERANCE=0` passes
- [ ] `make run-pipeline CFG=vibe_init_external SOURCE=synthetic:ghost_box_disappear TOLERANCE=0` passes
- [ ] EMA full matrix non-regression
- [ ] `make demo` produces no visual change in committed WebPs

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

(NO `Co-Authored-By` per CLAUDE.md applies to commits, not PR descriptions.)

---

## Self-Review Checklist

| Item | Status |
|---|---|
| Phase A spec coverage — every claim about W+1 delay maps to a task | ✓ — A1 (arch doc), A2 (RTL), A3 (golden non-regression), A4 (E2E non-regression), A5 (TB V-blank shrink), A6 (CLAUDE.md update) |
| Phase B spec coverage — parallel streams across Python/RTL/tests/docs | ✓ — B1 (arch doc), B2 (Python `_init_scheme_c`), B3 (Python `compute_lookahead_median_bank`), B4 (Phase 0 cross-check), B5 (RTL), B6 (golden regen), B7 (TB pass), B8 (E2E ViBe), B9 (EMA non-regression), B10 (parity test for magic constants), B11 (CLAUDE.md) |
| Bit-exactness invariant — Phase A passes existing goldens | ✓ — A3 explicitly checks; if it fails, Phase A is wrong by definition |
| Bit-exactness invariant — Phase B keeps RTL=Python bit-exact (with new goldens) | ✓ — B5 mirrors B2 exactly; B7 verifies; B10 catches drift via constant-parity test |
| Statistical equivalence — Phase B passes Phase 0 cross-check vs upstream | ✓ — B4 explicit |
| Placeholder scan: TBD/TODO/"add appropriate ..." | ✓ — none found; threshold values in Task B6 step 3 reference measured-and-pinned values, not blank placeholders |
| Type consistency — `INIT_SEED_MAGICS` (Python) ↔ `INIT_MAGIC_N` (SV) ↔ `init_stream_seed()` function naming consistent across tasks | ✓ |
| Frequent commits — every task ends with a commit step (or is a verification-only task) | ✓ |
| TDD — tests precede implementation where applicable | ✓ — B2 has failing test first |
| Branch strategy — explicit | ✓ — same `feat/vibe-phase-2` branch, force-push at squash |

---

## Notes for the implementer

1. **Phase A bit-exactness is the safety net.** If A3 fails (existing goldens don't pass with the new FIFO), the bug is in A2's FIFO logic. Don't proceed to Phase B until Phase A is verified bit-exact — Phase B's "regenerate goldens" step would mask any Phase-A-induced drift.

2. **Phase B will produce different mask outputs from today's goldens.** That is expected. The tests that go GREEN after regeneration are: T2 (200-frame parity), T3, T4, end-to-end. The Phase 0 cross-check vs upstream is the statistical-equivalence check.

3. **Magic constants are load-bearing.** Once chosen, they cannot change without invalidating all goldens. Pick once in B2 and lock them in via the parity test in B10.

4. **`init_prng[]` array size is parametric.** SV `generate-for` over `N_INIT_STREAMS = (K+3)/4` correctly generates 1, 2, or 5 state registers for K=4, 8, 20 respectively. Only K=8 and K=20 are exercised in unit TBs; K=4 is supported by the algorithm but not by the elaboration check (`K != 8 && K != 20` triggers `$error`).

5. **Runtime PRNG independence.** A common bug shape: developer thinks "init advances PRNG, then runtime continues from after-init state". With parallel streams, the runtime PRNG is *separate* and starts from PRNG_SEED on every reset, never advanced by init. Both Python and SV must reflect this. Test 6 (PRNG-no-drift) catches some but not all variants of this bug.

6. **Phase 0 cross-check failure recovery.** If Task B4 shows the parallel-stream scheme regresses the upstream cross-check by more than ~20% on any source, the magic constants chosen in B2 may be poorly mixed. Try alternate magic constants (e.g., known-good Stafford Mix variants) before reverting to chained.

7. **No new profile or `cfg_t` field is added.** This redesign touches algorithm internals; the user-facing knobs are unchanged. The arch-doc changes are the only documentation-visible delta.
