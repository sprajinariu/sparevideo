# Plan: Decouple RGB and mask pipelines — RTL restructure + documentation cleanup

## Context

The sparevideo motion pipeline uses a 1-frame-delayed bbox design: `axis_bbox_reduce` latches the bbox at EOF, and `axis_overlay_bbox` applies it to the next frame. The RGB video and mask paths are architecturally decoupled. However, inside `axis_motion_detect`, the two outputs share a backpressure fork (`axis_fork_pipe`), creating an internal coupling that propagates confusing "lockstep" / "latency-matched" language into specs and plans.

**Goal:** Make the decoupling structural by removing the fork from `axis_motion_detect`, moving it to the top level, and cleaning up all documentation that claims pipeline synchronization.

### Architecture change

**Before:**
```
dsp_in → axis_motion_detect ─┬─► vid (RGB, via internal sideband pipeline) → overlay → out
                              └─► msk (1-bit, shared backpressure)          → bbox_reduce
```

**After:**
```
dsp_in → axis_fork ─┬─► axis_motion_detect (mask-only) → bbox_reduce → bbox sideband
                     └─► axis_overlay_bbox ◄─────────────────────────── (bbox sideband)
                              │
                              ▼ out
```

---

## Implementation Checklist

### Documentation (do first)

- [ ] Update `docs/specs/axis_motion_detect-arch.md` — major rewrite: remove fork, sideband pipeline, vid output; redraw datapath as single-input/single-output mask producer; remove all "arrives same cycle" / "latency-matched" language; replace fork-based backpressure with single-output pipeline stall
- [ ] Update `docs/specs/sparevideo-top-arch.md` — update pipeline diagram to show top-level fork; rewrite submodule descriptions (`u_fork` new, `u_motion_detect` mask-only); remove "matched latency" from line 114
- [ ] Update `docs/plans/motion-pipeline-improvements.md` — update lines 40-63 diagram/explanation (fork is now at top level); remove line 320 sideband pipeline reference
- [ ] Update `docs/plans/2026-04-16_block2a-centered-gaussian.md` — remove all sideband BRAM FIFO references and `axis_fork_pipe` changes section; remove "All three are in lockstep"; simplify to only idx_pipe + Gaussian alignment

### RTL implementation

- [ ] Create `hw/ip/axis/rtl/axis_fork.sv` — zero-latency 1-to-2 AXI4-Stream broadcast fork
- [ ] Restructure `hw/ip/motion/rtl/axis_motion_detect.sv` — remove vid output ports, remove `axis_fork_pipe`, replace with single-output pipeline control
- [ ] Rewire `hw/top/sparevideo_top.sv` — add top-level `axis_fork`, connect fork outputs to motion detect and overlay, update control flow mux
- [ ] Delete `hw/ip/axis/rtl/axis_fork_pipe.sv` — no longer instantiated

### Testbench

- [ ] Update `hw/ip/motion/tb/tb_axis_motion_detect.sv` — remove vid output checks, remove asymmetric stall tests, add msk-output stall test

### Build system

- [ ] Update `hw/ip/axis/axis.core` — replace `axis_fork_pipe.sv` with `axis_fork.sv`
- [ ] Update `hw/ip/motion/motion.core` — remove `axis` dependency
- [ ] Update `dv/sim/Makefile` — update `RTL_SRCS` and `IP_MOTION_DETECT_SRCS`

### Project-level docs

- [ ] Update `CLAUDE.md` — project structure, stall pitfalls section
- [ ] Update `README.md` — if pipeline description changes

### Verification

- [ ] `make lint` — no new warnings
- [ ] `make test-ip` — all unit tests pass
- [ ] `make run-pipeline CTRL_FLOW=passthrough TOLERANCE=0`
- [ ] `make run-pipeline CTRL_FLOW=motion TOLERANCE=0`
- [ ] `make run-pipeline CTRL_FLOW=mask TOLERANCE=0`
- [ ] `make run-pipeline CTRL_FLOW=motion ALPHA_SHIFT=0 TOLERANCE=0`
- [ ] `make run-pipeline CTRL_FLOW=mask ALPHA_SHIFT=2 TOLERANCE=0`

---

## Phase 1: New module — `hw/ip/axis/rtl/axis_fork.sv`

Zero-latency AXI4-Stream 1-to-2 broadcast fork. Combinational data path (no sideband pipeline). Per-output acceptance tracking to prevent duplicate transfers.

- Input: `s_axis_*` (DATA_WIDTH parameterized)
- Output A: `m_a_axis_*` — to `axis_motion_detect`
- Output B: `m_b_axis_*` — to `axis_overlay_bbox`
- `s_axis_tready_o = both_done` (both consumers accepted)
- `m_a_axis_tvalid_o = s_axis_tvalid_i && !a_accepted`
- Data, tlast, tuser are combinational pass-through to both outputs
- Acceptance tracking: 2 registered flags (`a_accepted`, `b_accepted`), reset on `both_done`
- ~50 lines, follows the pattern from vendored `axis_broadcast`

---

## Phase 2: Restructure `axis_motion_detect.sv`

Remove `m_axis_vid_*` output ports and `axis_fork_pipe` instantiation. The module becomes a single-input, single-output mask producer.

### Ports removed
- `m_axis_vid_tdata_o`, `m_axis_vid_tvalid_o`, `m_axis_vid_tready_i`, `m_axis_vid_tlast_o`, `m_axis_vid_tuser_o`

### Internal changes
1. **Remove** `axis_fork_pipe` instantiation (`u_fork`) and all `fork_*` signals
2. **Add** pipeline tracking arrays: `valid_pipe[PIPE_STAGES]`, `tlast_pipe[PIPE_STAGES]`, `tuser_pipe[PIPE_STAGES]` — same shift-register pattern as the removed sideband, but only 3 bits wide (no tdata)
3. **Replace** `fork_stall` → `pipe_stall = pipe_valid && !m_axis_msk_tready_i`
4. **Replace** `fork_beat_done` → `beat_done = pipe_valid && !pipe_stall`
5. **Replace** `s_axis_tready_o` (was from fork) → `!pipe_valid || !pipe_stall` (= `!pipe_valid || m_axis_msk_tready_i`)
6. **Update** rgb2ycrcb stall mux: held data comes from a registered `held_tdata` (captures `s_axis_tdata_i` on `!pipe_stall`) instead of `fork_tdata`
7. **Update** `mem_wr_en_o` gate: `beat_done` instead of `fork_beat_done`
8. **Update** Gaussian `stall_i`: `pipe_stall` instead of `fork_stall`
9. **Drive** mask output:
   ```
   m_axis_msk_tdata_o  = mask_bit
   m_axis_msk_tvalid_o = pipe_valid  (= valid_pipe[PIPE_STAGES-1])
   m_axis_msk_tlast_o  = tlast_pipe[PIPE_STAGES-1]
   m_axis_msk_tuser_o  = tuser_pipe[PIPE_STAGES-1]
   ```

### Kept unchanged
- `rgb2ycrcb` instantiation and stall mux pattern (just different held-data source)
- Gaussian instantiation and control signals
- `motion_core` instantiation
- `idx_pipe` and `pix_addr` counter
- Memory read/write address logic
- All parameters

---

## Phase 3: Rewire `sparevideo_top.sv`

### Add top-level fork
```
axis_fork #(.DATA_WIDTH(24)) u_fork (
    .clk_i / .rst_n_i,
    .s_axis_*  ← fork input (gated dsp_in),
    .m_a_axis_* → axis_motion_detect input,
    .m_b_axis_* → axis_overlay_bbox input
);
```

### Fork input gating
```
fork_s_tvalid = motion_pipe_active ? dsp_in_tvalid : 1'b0;
fork_s_tdata  = dsp_in_tdata;
fork_s_tlast  = dsp_in_tlast;
fork_s_tuser  = dsp_in_tuser;
```

### Motion detect connection
Remove vid ports — only mask output + memory port remain.

### Overlay connection
Overlay `s_axis_*` now comes from fork output B (was from motion detect vid output).

### Control flow mux update
```
CTRL_PASSTHROUGH: dsp_in_tready = proc_tready  (fork inactive, tvalid=0)
CTRL_MOTION_DETECT: dsp_in_tready = fork_s_tready; ovl → proc
CTRL_MASK_DISPLAY:  dsp_in_tready = fork_s_tready; msk_rgb → proc; ovl_tready = 1
```

### Signal cleanup
- Remove `vid_tdata`, `vid_tvalid`, `vid_tready`, `vid_tlast`, `vid_tuser` declarations
- Remove `md_s_tvalid`, `md_s_tready` (replaced by fork wiring)
- Add fork intermediate signals

### Comments update
- Remove "latency-matched" from line 184 comment
- Update pipeline comment block (lines 178-182) to reflect new architecture

---

## Phase 4: Delete `axis_fork_pipe.sv`

No longer instantiated anywhere. Recoverable from git history.

- Delete `hw/ip/axis/rtl/axis_fork_pipe.sv`
- Update `hw/ip/axis/axis.core`: replace `axis_fork_pipe.sv` with `axis_fork.sv`
- Update `dv/sim/Makefile`:
  - `RTL_SRCS`: replace `axis_fork_pipe.sv` with `axis_fork.sv`
  - `IP_MOTION_DETECT_SRCS`: remove `axis_fork_pipe.sv` (motion detect no longer uses fork)

---

## Phase 5: Update testbench `tb_axis_motion_detect.sv`

### Remove
- `vid_tdata`, `vid_tvalid`, `vid_tlast`, `vid_tuser` DUT outputs
- `drv_vid_rdy`, `vid_tready` consumer ready signals
- `cap_vid[]` capture array, `vid_cap_cnt` counter
- `check_vid_passthrough()` task
- Asymmetric stall tests (Frames 4-5 — vid-only and msk-only stall modes)
  - The fork desync bug these tested for no longer exists (single output)

### Keep
- All mask golden model checks (Frames 0-3, 6-7)
- Symmetric stall test (Frame 3 — msk output stall)
- RAM EMA checks
- Block pixel pattern (Frames 6-7 — Gaussian edge smoothing)

### Add
- Simple msk-output stall test (replace one of the removed asymmetric tests): stall `msk_tready` periodically, verify mask correctness

### Renumber frames
Frames become 0-5 (was 0-7), with Frame 3 as stall test and Frames 4-5 for Gaussian patterns.

---

## Phase 6: Documentation updates

### `docs/specs/axis_motion_detect-arch.md` — major rewrite
- §1: Remove "passes the RGB video stream through unchanged with matched latency"
- §2 Module Hierarchy: Remove `axis_fork_pipe`
- §2 Datapath: Redraw diagram — single input, single mask output, no sideband pipeline
- Remove all "arrives same cycle" annotations
- Remove "arriving at the video output on the same cycle as the mask" paragraph
- §3 Interface: Remove `m_axis_vid_*` ports
- §5 Backpressure: Replace fork-based logic with single-output pipeline stall
- Update pipeline stage descriptions
- Add note: "The mask output is the module's only AXI4-Stream output. The RGB video path is handled at the top level via `axis_fork`, fully decoupled from mask processing."

### `docs/specs/sparevideo-top-arch.md` — update
- Line 114: "emits a 1-bit motion mask" (remove "plus the original RGB video with matched latency")
- Update pipeline diagram to show top-level fork
- Update submodule descriptions: `u_fork` (new), `u_motion_detect` (mask-only)

### `docs/plans/motion-pipeline-improvements.md`
- Lines 40-63: Update diagram and explanation — fork is now at top level, not inside motion detect. The "Does mask latency need to be matched?" answer is still "No" but the explanation changes (there's no shared-backpressure fork internally anymore).
- Line 320: Remove "sideband pipeline must be extended" — no sideband pipeline exists.

### `docs/plans/2026-04-16_block2a-centered-gaussian.md`
- Remove all references to sideband pipeline BRAM FIFO (Section: `axis_fork_pipe` changes)
- The `idx_pipe` BRAM FIFO is still needed (memory addressing)
- Remove "All three are in lockstep" — only two things need alignment now (idx_pipe and Gaussian output)
- The plan simplifies significantly: no `axis_fork_pipe` changes needed at all

### `hw/top/sparevideo_top.sv` — comments
- Update header comment (lines 1-17) to reflect new pipeline structure
- Remove "latency-matched" reference

### `CLAUDE.md`
- Update Project Structure: `hw/ip/axis/rtl/` description — "axis_fork: 1-to-2 broadcast" instead of "axis_fork_pipe"
- Update "AXI4-Stream pipeline stall" section: Remove references to fork-based stall pattern that no longer exists in motion detect. Keep the general fork stall guidance (still relevant for the top-level fork).

---

## Verification

```bash
make lint                                            # No new warnings
make test-ip                                         # All unit tests pass
make run-pipeline CTRL_FLOW=passthrough TOLERANCE=0  # Passthrough unaffected
make run-pipeline CTRL_FLOW=motion TOLERANCE=0       # Motion detect + overlay
make run-pipeline CTRL_FLOW=mask TOLERANCE=0         # Mask display
```

Also verify with different ALPHA_SHIFT values:
```bash
make run-pipeline CTRL_FLOW=motion ALPHA_SHIFT=0 TOLERANCE=0
make run-pipeline CTRL_FLOW=mask ALPHA_SHIFT=2 TOLERANCE=0
```

---

## Files changed (summary)

| File | Action |
|------|--------|
| `hw/ip/axis/rtl/axis_fork.sv` | **New** — zero-latency 1-to-2 broadcast fork |
| `hw/ip/axis/rtl/axis_fork_pipe.sv` | **Delete** — no longer used |
| `hw/ip/axis/axis.core` | Update file list |
| `hw/ip/motion/rtl/axis_motion_detect.sv` | **Major rewrite** — remove vid output, remove fork, simplify to single-output pipeline |
| `hw/top/sparevideo_top.sv` | Add top-level fork, rewire motion detect and overlay, update control flow mux |
| `hw/ip/motion/tb/tb_axis_motion_detect.sv` | Remove vid checks, remove asymmetric stall tests, keep mask/EMA checks |
| `dv/sim/Makefile` | Update RTL_SRCS and IP_MOTION_DETECT_SRCS |
| `hw/ip/motion/motion.core` | Remove `axis` dependency (motion detect no longer uses axis_fork_pipe) |
| `docs/specs/axis_motion_detect-arch.md` | Major rewrite — mask-only module |
| `docs/specs/sparevideo-top-arch.md` | Update pipeline diagram and descriptions |
| `docs/plans/motion-pipeline-improvements.md` | Update architecture discussion |
| `docs/plans/2026-04-16_block2a-centered-gaussian.md` | Remove sideband FIFO sections |
| `CLAUDE.md` | Update project structure references |
| `README.md` | Update if pipeline description changes |
