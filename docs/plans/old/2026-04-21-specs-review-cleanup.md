# Specs Review and Cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the scope/dependency/structural cleanup described in `docs/superpowers/specs/2026-04-21-specs-review-design.md` to all 8 files under `docs/specs/` and codify the rules in `.claude/skills/hardware-arch-doc/SKILL.md`.

**Architecture:** Policy-first — update the skill file first so later spec edits cite a single source of truth. Then edit specs in increasing order of complexity (small → medium → large). Each task uses `Edit` for precise text replacement and `Grep` for before/after verification. Each task ends in its own commit.

**Tech Stack:** Markdown edits via the `Edit` tool; `Grep` for verification; `git commit` per task. No code changes.

---

## File Map

- Modify: `.claude/skills/hardware-arch-doc/SKILL.md`
- Modify: `docs/specs/rgb2ycrcb-arch.md`
- Modify: `docs/specs/vga_controller-arch.md`
- Modify: `docs/specs/sparevideo-top-arch.md`
- Modify: `docs/specs/axis_ccl-arch.md`
- Verify only (no edits expected): `docs/specs/ram-arch.md`, `docs/specs/axis_overlay_bbox-arch.md`, `docs/specs/axis_gauss3x3-arch.md`, `docs/specs/axis_motion_detect-arch.md`

---

## Task 1: Update `hardware-arch-doc` skill

**Files:**
- Modify: `.claude/skills/hardware-arch-doc/SKILL.md`

**Reference:** design doc §4 "`hardware-arch-doc` Skill Update".

- [ ] **Step 1: Read the current skill file**

Run: `Read .claude/skills/hardware-arch-doc/SKILL.md` (entire file).

Confirm the current layout: frontmatter → Overview → When to Use → Document Structure (with Required Sections 1–10) → Style Rules → After Writing (5 items).

- [ ] **Step 2: Refresh the stale hierarchy example in §2 Module Hierarchy**

The current example under "Module Hierarchy" shows `axis_bbox_reduce` as a submodule of `sparevideo_top`. Replace it with the current tree (mirroring `docs/specs/sparevideo-top-arch.md` §2).

Old block (lines ~31–41):
```
sparevideo_top
├── axis_async_fifo         (u_fifo_in)     — clk_pix → clk_dsp CDC
├── axis_motion_detect      (u_motion)      — clk_dsp; Y8 diff, mask output
│   └── rgb2ycrcb           (u_rgb2y)       — pixel→luma conversion
├── ram                     (u_ram)         — shared Y8 frame buffer (port A: motion, port B: unused)
├── axis_bbox_reduce        (u_bbox)        — clk_dsp; reduces mask to bounding box
├── axis_overlay_bbox       (u_overlay)     — clk_dsp; draws bbox rect on video
├── axis_async_fifo         (u_fifo_out)    — clk_dsp → clk_pix CDC
└── vga_controller          (u_vga)         — clk_pix; produces hsync/vsync/RGB
```

New block:
```
sparevideo_top
├── axis_async_fifo    (u_fifo_in)       — CDC clk_pix → clk_dsp
├── ram                (u_ram)           — dual-port byte RAM, Y8 prev-frame buffer
├── axis_fork          (u_fork)          — 1-to-2 broadcast: fork_a → motion detect, fork_b → overlay
├── axis_motion_detect (u_motion_detect) — mask-only producer
│   └── rgb2ycrcb      (u_rgb2ycrcb)     — RGB888 → Y8 (1-cycle pipeline)
├── axis_ccl           (u_ccl)           — mask → N_OUT × {min_x,max_x,min_y,max_y,valid}
├── axis_overlay_bbox  (u_overlay_bbox)  — draw N_OUT-wide bbox rectangles on RGB video
├── axis_async_fifo    (u_fifo_out)      — CDC clk_dsp → clk_pix
└── vga_controller     (u_vga)           — streaming pixel → VGA timing + RGB output
```

- [ ] **Step 3: Append closing line to §4 Concept Description**

After the current §4 body (which ends with "why is it useful in the overall function of the design."), add a new line:

```
Scope rules in "Scope and Content Rules" below apply — no Python/TB narrative; no child-internal duplication in parent spec.
```

- [ ] **Step 4: Append closing line to §5 Internal architecture**

After the current §5 body (which ends with "write about each submodule in the context of the larger top-level."), add a new line:

```
Scope rules in "Scope and Content Rules" below apply — no Python/TB narrative; no child-internal duplication in parent spec.
```

- [ ] **Step 5: Insert "Scope and Content Rules" section**

Insert this new section between the existing "## Document Structure" block (after the Required Sections list ends at §10 References) and the existing "## Style Rules" heading:

````
## Scope and Content Rules

A spec is the **design contract** for one RTL module. It describes what the module does, its interface, its internal structure, its timing, and its invariants. It does not describe how the module is verified.

**Do not include:**
- Python reference models (`py/models/*`), scipy/OpenCV/numpy cross-checks, tolerance statements, "RTL matches model bit-for-bit" claims.
- Testbench narrative: plusargs (`+CTRL_FLOW=`, `+DUMP_VCD`, `sva_drain_mode`), TB V_BLANK sizing, `tb_sparevideo`, TB-specific cycle numbers.
- Implementation-plan links (`docs/plans/*`).
- Unit-TB tolerance (belongs in the TB, not the spec).
- Simulator-specific framing ("Verilator only", "at sim time").

**Do include:**
- SVA assertions — they formalize design invariants and are part of the RTL deliverable. A dedicated chapter in the top spec is appropriate.
- Behavioral vs. synthesizable RTL notes (e.g., `ram.sv` is behavioral; synthesis needs `xpm_memory_tdpram`).
- Real-hardware timing and cycle-budget statements (at spec'd clock and resolution, not TB values).
- One-sentence design rationale when a parameter was chosen for a design reason that also happens to match a model — phrase as design rationale, not model reference.

## Cross-Document Dependency Rules

- **Parent spec describes interfaces and interconnect only** for its children. §5 lists submodule roles in ≤3 sentences each and links to the child spec. Do not re-describe child internals.
- **Child spec may include a one-paragraph parent-context note** in §1 or §2 for orientation, linking up. No ASCII re-draw of the parent's tree.
- **Lateral sibling refs** allowed only when one module's design actively constrains another.
- **Forward refs** to deferred work allowed only when they explain a current design choice.
- **No implementation-plan links.** Plans are process artifacts; specs are design contracts.
````

- [ ] **Step 6: Extend the "After Writing" checklist**

Append a new item 6 to the existing 5-item "After Writing" ordered list:

```
6. Scope audit: grep the spec for `python`, `pytest`, `plusarg`, `tb_`, `testbench`, `TOLERANCE`, `py/models`. Each hit must either be removed or justified by the Scope and Content Rules above.
```

- [ ] **Step 7: Verify the skill update**

Run: `Grep --pattern 'Scope and Content Rules|Cross-Document Dependency Rules|Scope audit' --path .claude/skills/hardware-arch-doc/SKILL.md --output_mode content -n`

Expected: 3 distinct heading / list-item matches — one for each added block.

Run: `Grep --pattern 'axis_bbox_reduce' --path .claude/skills/hardware-arch-doc/SKILL.md`

Expected: 0 matches (stale name fully removed).

- [ ] **Step 8: Commit**

```bash
git add .claude/skills/hardware-arch-doc/SKILL.md
git commit -m "skill(hardware-arch-doc): add scope+dep rules, refresh hierarchy example

Codify the design-spec scope rules (no Python/TB narrative, keep SVA and
behavioral-vs-synth notes) and the parent/child/sibling dependency rules
so future specs are written to one standard. Also refresh the stale
example hierarchy that still showed axis_bbox_reduce."
```

---

## Task 2: Verify `ram-arch.md` is clean

**Files:**
- Verify: `docs/specs/ram-arch.md`

**Reference:** design doc §3.1.

- [ ] **Step 1: Scope-audit grep**

Run: `Grep --pattern 'Python|python|py/models|testbench|tb_|plusarg|TOLERANCE|Verilator only|sim time|sva_drain_mode' --path docs/specs/ram-arch.md --output_mode content -n`

Expected: 0 matches.

- [ ] **Step 2: No commit**

No edits made, skip commit.

---

## Task 3: Clean `rgb2ycrcb-arch.md`

**Files:**
- Modify: `docs/specs/rgb2ycrcb-arch.md`

**Reference:** design doc §3.2.

- [ ] **Step 1: Replace §5.4 title and drop TB line**

Edit `docs/specs/rgb2ycrcb-arch.md`:

Old:
```
### 5.4 Verified corner cases
```

New:
```
### 5.4 Design corner cases
```

Old (line 103, at end of §5.4 after the corner-cases table):
```
Unit testbench (`hw/ip/rgb2ycrcb/tb/tb_rgb2ycrcb.sv`) checks all 6 cases with ±1 LSB tolerance.
```

New: delete the line entirely (remove the line and the blank line above it that separates it from the table, if any remains at EOF of the section).

Also update the Contents TOC entry from `5.4 Verified corner cases` to `5.4 Design corner cases` (change the link text and the anchor to `#54-design-corner-cases`).

- [ ] **Step 2: Scope-audit grep**

Run: `Grep --pattern 'Python|python|py/models|testbench|tb_|plusarg|TOLERANCE|Verilator only|sim time' --path docs/specs/rgb2ycrcb-arch.md --output_mode content -n`

Expected: 0 matches.

- [ ] **Step 3: Commit**

```bash
git add docs/specs/rgb2ycrcb-arch.md
git commit -m "docs(rgb2ycrcb): drop TB tolerance note from spec

Specs describe design; TB tolerance belongs in the unit testbench.
Rename \"Verified corner cases\" → \"Design corner cases\". Per
docs/superpowers/specs/2026-04-21-specs-review-design.md §3.2."
```

---

## Task 4: Clean `vga_controller-arch.md`

**Files:**
- Modify: `docs/specs/vga_controller-arch.md`

**Reference:** design doc §3.3.

- [ ] **Step 1: Rewrite §9 Known Limitations first bullet tail**

Edit `docs/specs/vga_controller-arch.md`:

Old (line 153, tail of the first bullet):
```
 The `assert_no_output_underrun` SVA in `sparevideo_top` catches this at sim time.
```

New (replace that trailing sentence only; preserve the rest of the bullet):
```
 The top-level spec §8 formalizes an underrun invariant.
```

Exact `Edit.old_string`:
```
If the pixel stream goes out of sync with the VGA counters (e.g., missing pixels due to underrun), the display tears silently. The `assert_no_output_underrun` SVA in `sparevideo_top` catches this at sim time.
```

Exact `Edit.new_string`:
```
If the pixel stream goes out of sync with the VGA counters (e.g., missing pixels due to underrun), the display tears silently. The top-level spec §8 formalizes an underrun invariant.
```

- [ ] **Step 2: Scope-audit grep**

Run: `Grep --pattern 'Python|python|py/models|testbench|tb_|plusarg|TOLERANCE|Verilator only|sim time' --path docs/specs/vga_controller-arch.md --output_mode content -n`

Expected: 0 matches.

- [ ] **Step 3: Commit**

```bash
git add docs/specs/vga_controller-arch.md
git commit -m "docs(vga_controller): drop sim-time framing from underrun note

Per docs/superpowers/specs/2026-04-21-specs-review-design.md §3.3 —
specs describe design invariants, not simulator behavior. Point at the
top-spec assertion chapter instead."
```

---

## Task 5: Verify `axis_overlay_bbox-arch.md` is clean

**Files:**
- Verify: `docs/specs/axis_overlay_bbox-arch.md`

**Reference:** design doc §3.4.

- [ ] **Step 1: Scope-audit grep**

Run: `Grep --pattern 'Python|python|py/models|testbench|tb_|plusarg|TOLERANCE|Verilator only|sim time|sva_drain_mode' --path docs/specs/axis_overlay_bbox-arch.md --output_mode content -n`

Expected: 0 matches.

- [ ] **Step 2: No commit**

No edits made, skip commit.

---

## Task 6: Verify `axis_gauss3x3-arch.md` is clean

**Files:**
- Verify: `docs/specs/axis_gauss3x3-arch.md`

**Reference:** design doc §3.5.

- [ ] **Step 1: Scope-audit grep**

Run: `Grep --pattern 'Python|python|py/models|testbench|tb_|plusarg|TOLERANCE|Verilator only|sim time|sva_drain_mode' --path docs/specs/axis_gauss3x3-arch.md --output_mode content -n`

Expected: 0 matches.

- [ ] **Step 2: No commit**

No edits made, skip commit.

---

## Task 7: Verify `axis_motion_detect-arch.md` is clean

**Files:**
- Verify: `docs/specs/axis_motion_detect-arch.md`

**Reference:** design doc §3.6.

- [ ] **Step 1: Scope-audit grep**

Run: `Grep --pattern 'Python|python|py/models|testbench|tb_|plusarg|TOLERANCE|Verilator only|sim time|sva_drain_mode|scipy|cocotb' --path docs/specs/axis_motion_detect-arch.md --output_mode content -n`

Expected: 0 matches. (The `Yosys/Verilator infers a fixed wire routing` mention on line 314 is a *synthesis-tool* reference, not a simulator-verification one — out of scope of the purge list because `Verilator only` is the banned phrase, not `Verilator`.)

- [ ] **Step 2: No commit**

No edits made, skip commit.

---

## Task 8: Clean `sparevideo-top-arch.md`

**Files:**
- Modify: `docs/specs/sparevideo-top-arch.md`

**Reference:** design doc §3.8. Multiple edits — do them in the order below.

### 8.1 §1 Purpose — drop plusarg sentence

- [ ] **Step 1: Remove plusarg sentence in §1**

Edit `docs/specs/sparevideo-top-arch.md`:

§1 currently says (around line 34, the "CCL bbox" bullet end) contains "decoupling CCL verification from the overlay's interaction with live RGB." — keep.

The plusarg sentence lives in §3.1 not §1 (re-checked). Skip to Step 8.2 (§3.1).

### 8.2 §3.1 Parameters footnote — drop plusarg sentence

- [ ] **Step 2: Remove plusarg sentence in §3.1 footnote**

Old (line 104):
```
`ctrl_flow_i` is a quasi-static sideband signal (set before simulation, not changed mid-frame). It is driven by the testbench via the `+CTRL_FLOW=passthrough|motion|mask|ccl_bbox` plusarg. All defaults reference `sparevideo_pkg`.
```

New:
```
`ctrl_flow_i` is a quasi-static sideband signal (set before the frame, not changed mid-frame). All defaults reference `sparevideo_pkg`.
```

### 8.3 §4.2 V_BLANK — rewrite to real-hardware framing

- [ ] **Step 3: Rewrite V_BLANK statement in §4.2**

Old (line 162, tail of the §4.2 third numbered invariant):
```
 The testbench's V_BLANK (2+2+16 lines) is sized to cover the worst-case cycle budget at 320×240.
```

New:
```
 Vblank headroom must exceed the CCL worst-case EOF-FSM cycle budget (see [axis_ccl-arch.md](axis_ccl-arch.md) §6.7).
```

Exact `Edit.old_string` (to uniquely match the full invariant item):
```
3. **Adding stages to the mask path (Gaussian, future morphology, stricter CCL variants) just delays when the EOF resolution happens within the vblank.** As long as the full resolution FSM completes before the next frame's first pixel reaches the overlay, the bbox is ready in time. The testbench's V_BLANK (2+2+16 lines) is sized to cover the worst-case cycle budget at 320×240.
```

Exact `Edit.new_string`:
```
3. **Adding stages to the mask path (Gaussian, future morphology, stricter CCL variants) just delays when the EOF resolution happens within the vblank.** As long as the full resolution FSM completes before the next frame's first pixel reaches the overlay, the bbox is ready in time. Vblank headroom must exceed the CCL worst-case EOF-FSM cycle budget (see [axis_ccl-arch.md](axis_ccl-arch.md) §6.7).
```

### 8.4 §5.1 Submodule roles — compress

- [ ] **Step 4: Replace the entire numbered list under §5.1**

Edit `docs/specs/sparevideo-top-arch.md` replacing all 9 numbered bullets under §5.1 with compressed versions plus a new multi-consumer broadcast note.

Exact `Edit.old_string` (all 9 bullets verbatim — this is a contiguous block, lines ~270–278):
```
1. **u_fifo_in**: decouples the `clk_pix`-domain source from the DSP pipeline. Depth 32 entries. Overflow detected by SVA.
2. **u_fork**: zero-latency 1-to-2 broadcast fork. Splits the DSP-domain stream so that `fork_b` (RGB) feeds the overlay directly while `fork_a` (RGB) feeds the motion detect mask pipeline. Per-output acceptance tracking prevents duplicate transfers on asymmetric consumer stalls. Instantiated only in the motion pipeline path; the fork input `tvalid` is gated to 0 in passthrough mode.
3. **u_motion_detect**: converts each pixel to Y8 (`u_rgb2ycrcb`), reads the per-pixel background model from `u_ram` port A, computes `|Y_cur − bg|`, and emits a **1-bit motion mask**. The mask condition is `diff > THRESH` (polarity-agnostic — flags both arrival and departure pixels, works for bright-on-dark, dark-on-bright, and colour scenes). Writes an EMA-updated background value back to RAM on acceptance: `bg_new = bg + ((Y_cur - bg) >>> ALPHA_SHIFT)`. This temporally smooths the background model, suppressing sensor noise and adapting to gradual lighting changes. See [axis_motion_detect-arch.md](axis_motion_detect-arch.md) §4 for the EMA algorithm details.
4. **u_ram**: dual-port byte RAM (port A for motion detect background model, port B reserved). Zero-initialized so frame 0 reads all-motion (background starts at 0, converges via EMA over subsequent frames).
5. **u_ccl**: single-pass 8-connected streaming connected-component labeler. Walks the mask in raster order, assigns provisional labels with a 2-row neighbour window, maintains a union-find equivalence table (with a single equiv-write per pixel), and accumulates per-label bounding-box and area statistics in a label-indexed bank RAM. After EOF, a four-phase FSM (`PHASE_A` path-compression → `PHASE_B` fold statistics into roots → `PHASE_C` select top-`CCL_N_OUT` by area, filtering below `CCL_MIN_COMPONENT_PIXELS` → `PHASE_D` reset) runs inside the vertical blanking interval, followed by `PHASE_SWAP` which atomically promotes the resolved bbox set into a front register bank. The first `CCL_PRIME_FRAMES` frames after reset are suppressed (all `valid` bits forced 0) so the EMA background model has time to converge. `msk_tready` is beat-strobe gated (`msk_tvalid && msk_tready_final`) inside the multi-consumer broadcast. See [axis_ccl-arch.md](axis_ccl-arch.md).
6. **u_overlay_bbox**: receives RGB pixels on its AXI4-Stream input (`ovl_in` = `fork_b` in motion mode, or `mask_grey_rgb` in ccl_bbox mode) and an `N_OUT`-wide packed-array bbox sideband from `u_ccl`. For each pixel, combinationally ORs an `N_OUT`-wide rectangle-edge hit test across all valid slots; on a hit, the pixel is replaced with `BBOX_COLOR` (bright green), otherwise pass-through. Zero added latency on the data path.
7. **u_fifo_out**: crosses the overlaid RGB stream back to `clk_pix`. Depth 32 entries.
8. **vga_rst_n gating**: the VGA controller is held in reset until the first `tuser=1` pixel exits `u_fifo_out`. This aligns the VGA scan to a frame boundary regardless of FIFO fill time.
9. **u_vga**: drives horizontal/vertical counters, asserts `pixel_ready_o` during the active region, gates RGB output to 0 during blanking.
```

Exact `Edit.new_string`:
```
1. **u_fifo_in**: CDC from `clk_pix` to `clk_dsp`; depth 32. Overflow detected by SVA (§8).
2. **u_fork**: zero-latency 1-to-2 broadcast with per-output acceptance tracking, so asymmetric consumer stalls do not corrupt data. Instantiated in the motion pipeline path only; fork input `tvalid` is gated to 0 in passthrough mode.
3. **u_motion_detect**: consumes `fork_a` RGB, emits a 1-bit motion mask via a polarity-agnostic luma-difference test against an EMA background model held in `u_ram` port A. See [axis_motion_detect-arch.md](axis_motion_detect-arch.md).
4. **u_ram**: dual-port byte RAM. Port A owned by `u_motion_detect` for the EMA background model; port B reserved. Zero-initialized. See [ram-arch.md](ram-arch.md).
5. **u_ccl**: single-pass 8-connected streaming connected-component labeler. Emits `N_OUT` packed bounding-box slots plus a `bbox_swap_o` strobe on the sideband; deasserts `tready` during its EOF resolution FSM so upstream stalls through vblank. See [axis_ccl-arch.md](axis_ccl-arch.md).
6. **u_overlay_bbox**: receives RGB on its AXI4-Stream input (`ovl_in` = `fork_b` in motion mode, or `mask_grey_rgb` in ccl_bbox mode) and the `N_OUT`-wide bbox sideband from `u_ccl`; replaces pixels on any valid slot's rectangle edge with `BBOX_COLOR`, pass-through otherwise. Zero added latency. See [axis_overlay_bbox-arch.md](axis_overlay_bbox-arch.md).
7. **u_fifo_out**: CDC from `clk_dsp` to `clk_pix`; depth 32.
8. **vga_rst_n gating**: VGA held in reset until the first `tuser=1` pixel exits `u_fifo_out`, aligning the VGA scan to a frame boundary regardless of FIFO fill time.
9. **u_vga**: VGA timing + RGB output — horizontal/vertical counters, active-region `pixel_ready_o`, RGB gated to 0 during blanking. See [vga_controller-arch.md](vga_controller-arch.md).

**Multi-consumer mask broadcast (mask / ccl_bbox modes).** The 1-bit mask is consumed by two paths simultaneously (the B/W or grey-canvas expansion feeding `u_fifo_out`, and `u_ccl`). `msk_tready` is the AND of both consumers' readies so upstream stalls when either is not ready; `u_ccl` is fed `ccl_beat_strobe = msk_tvalid && msk_tready` as its `tvalid` so its internal `col`/`row` counters advance exactly once per globally-accepted beat.
```

### 8.5 §8 Assertions — drop "Verilator only" and the TB knob line

- [ ] **Step 5: Rename §8 heading**

Old:
```
## 8. Assertions (SVA, Verilator only)
```

New:
```
## 8. Assertions
```

- [ ] **Step 6: Update Contents TOC anchor to match**

Find the existing Contents line (around line 19):
```
- [8. Assertions (SVA, Verilator only)](#8-assertions-sva-verilator-only)
```

Replace with:
```
- [8. Assertions](#8-assertions)
```

- [ ] **Step 7: Drop the `sva_drain_mode` line at end of §8**

Old (line 334, the trailing sentence after the SVA table):
```
`sva_drain_mode` (default 0) disables the underrun assertion after the testbench stops feeding pixels.
```

New: delete the line entirely (including the blank line following it if it becomes a double blank before the `---`).

### 8.6 §9 Known Limitations — drop model/plusarg references

- [ ] **Step 8: Rewrite Frame-0 bullet**

Old (line 341):
```
- **Frame-0 full-frame border**: the zero-initialized RAM means every pixel on frame 0 reads as motion. The bounding box would span the full frame and the overlay would draw a border around the image edge. This is a known cosmetic artifact. `axis_ccl` suppresses bboxes for the first 2 frames (`PRIME_FRAMES`), matching the Python motion model, so no rectangle is drawn during EMA convergence.
```

New:
```
- **Frame-0 full-frame border**: the zero-initialized RAM means every pixel on frame 0 reads as motion. The bounding box would span the full frame and the overlay would draw a border around the image edge. This is a known cosmetic artifact. `axis_ccl` suppresses bboxes for the first `CCL_PRIME_FRAMES` frames so no rectangle is drawn until the EMA background has converged.
```

- [ ] **Step 9: Rewrite No-AXI-Lite bullet**

Old (line 344):
```
- **No AXI-Lite control**: `MOTION_THRESH` and `BBOX_COLOR` are compile-time parameters. Runtime override requires a simulation plusarg and recompile for RTL.
```

New:
```
- **No AXI-Lite control**: `MOTION_THRESH` and `BBOX_COLOR` are compile-time parameters. Runtime override requires synthesizing a CSR slave (see §7.1).
```

### 8.7 §10 Resources — drop the nested `u_ram` subsection

- [ ] **Step 10: Replace the nested subsection with one sentence**

Exact `Edit.old_string` (the whole nested block, lines ~373–379):
```
### `u_ram` — EMA background model

`u_ram` is a dual-port byte RAM of depth `H_ACTIVE × V_ACTIVE`. It is the dominant on-chip memory and the only one that maps to BRAM on an FPGA.

Port A is exclusively owned by `axis_motion_detect` (one read + one conditional write per accepted pixel; ≤ 25% of `clk_dsp` cycles at 100 MHz). Port B is reserved for future host clients.

The behavioral `ram.sv` requires substitution with a vendor true-dual-port BRAM primitive (`xpm_memory_tdpram`) for synthesis. See [ram-arch.md](ram-arch.md) §5.4.
```

Exact `Edit.new_string`:
```
See [ram-arch.md](ram-arch.md) for port ownership semantics and the behavioral-to-BRAM substitution note.
```

### 8.8 Verify and commit

- [ ] **Step 11: Scope-audit grep**

Run: `Grep --pattern 'Python|python|py/models|testbench|tb_|plusarg|TOLERANCE|Verilator only|sim time|sva_drain_mode' --path docs/specs/sparevideo-top-arch.md --output_mode content -n`

Expected: 0 matches.

- [ ] **Step 12: Commit**

```bash
git add docs/specs/sparevideo-top-arch.md
git commit -m "docs(top-arch): purge TB narrative, compress §5.1 submodule roles

- §3.1: drop +CTRL_FLOW plusarg mention
- §4.2: frame vblank headroom as a hardware constraint, not a TB sizing
- §5.1: compress submodule bullets to role + interface + child-spec link;
  add multi-consumer broadcast note (moved from axis_ccl)
- §8: drop \"Verilator only\" subtitle and sva_drain_mode TB knob
- §9: rephrase PRIME_FRAMES rationale and drop plusarg mention
- §10: collapse nested u_ram subsection to a single pointer

Per docs/superpowers/specs/2026-04-21-specs-review-design.md §3.8."
```

---

## Task 9: Clean `axis_ccl-arch.md`

**Files:**
- Modify: `docs/specs/axis_ccl-arch.md`

**Reference:** design doc §3.7. Multiple edits — do them in order so line numbers don't drift.

### 9.1 §2 Module Hierarchy — drop the tree redraw

- [ ] **Step 1: Replace §2 content with one sentence**

Exact `Edit.old_string` (the hierarchy block, lines ~55–62):
```
`axis_ccl` is a leaf module — no submodules. It is instantiated in [`sparevideo_top`](sparevideo-top-arch.md) as `u_ccl`, downstream of the motion-detect mask output and in parallel with the RGB path that feeds [`axis_overlay_bbox`](axis_overlay_bbox-arch.md).

```
sparevideo_top
├── axis_motion_detect (u_motion_detect)  ← produces msk_*
├── axis_ccl           (u_ccl)            ← this module
└── axis_overlay_bbox  (u_overlay)        ← consumes N_OUT × {min_x,max_x,min_y,max_y,valid}
```
```

Exact `Edit.new_string`:
```
`axis_ccl` is a leaf module. It is instantiated in [`sparevideo_top`](sparevideo-top-arch.md) as `u_ccl`, between [`axis_motion_detect`](axis_motion_detect-arch.md) (producer of the mask stream) and [`axis_overlay_bbox`](axis_overlay_bbox-arch.md) (consumer of the `N_OUT` bbox sideband).
```

### 9.2 §3.1 PRIME_FRAMES row — drop Python reference

- [ ] **Step 2: Rewrite PRIME_FRAMES parameter description**

Old (line 78):
```
| `PRIME_FRAMES` | 2 (from pkg) | Number of initial frames for which PHASE_SWAP skips the front-buffer update. Matches `motion` Python model so the EMA has time to converge before any bbox is reported. |
```

New:
```
| `PRIME_FRAMES` | 2 (from pkg) | Number of initial frames for which PHASE_SWAP skips the front-buffer update, giving the upstream EMA background model time to converge before any bbox is reported. |
```

### 9.3 §3.2 post-ports paragraph — shrink to pointer

- [ ] **Step 3: Replace the multi-consumer broadcast paragraph**

Exact `Edit.old_string` (line 102, the whole paragraph after the ports table):
```
`s_axis_tready_o` is high during streaming and low during the EOF resolution FSM (§6.7). In the multi-consumer broadcast in `sparevideo_top` (mask display and CCL_BBOX modes) the mask stream is consumed by both `axis_ccl` and a passthrough path; the top-level AND-combines the tready signals so the upstream stalls when *either* consumer is not ready. `axis_ccl` is additionally fed a `ccl_beat_strobe = msk_tvalid && msk_tready` as its `tvalid` so it advances exactly once per globally-accepted beat, rather than once per raw-upstream beat — without this, cycles stalled by the other consumer would be double-counted by the internal col/row counters. See `sparevideo_top.sv` `ccl_beat_strobe`.
```

Exact `Edit.new_string`:
```
`s_axis_tready_o` is high during streaming and low during the EOF resolution FSM (§6.7). For how the parent wires this module into a multi-consumer broadcast in mask-display and ccl_bbox modes, see [sparevideo-top-arch.md](sparevideo-top-arch.md) §5.1.
```

### 9.4 §4.0 Glossary — drop model-matching clause

- [ ] **Step 4: Rewrite Prime frames glossary row**

Old (line 125):
```
| **Prime frames** | The first `PRIME_FRAMES` frames after reset, during which the module computes bboxes internally but hides them (the front buffer stays empty). `axis_motion_detect`'s EMA background starts at zero, so early frames read as mostly-foreground and would produce huge spurious bboxes; suppressing output until the EMA has converged avoids that — and matches the Python `motion` model's own warm-up window so RTL and model agree bit-for-bit. See §6.6. |
```

New:
```
| **Prime frames** | The first `PRIME_FRAMES` frames after reset, during which the module computes bboxes internally but hides them (the front buffer stays empty). `axis_motion_detect`'s EMA background starts at zero, so early frames read as mostly-foreground and would produce huge spurious bboxes; suppressing output until the EMA has converged avoids that. See §6.6. |
```

### 9.5 §4.3 — remove the Python reference paragraph

- [ ] **Step 5: Drop the trailing paragraph from §4.3**

Exact `Edit.old_string` (line 244 and its surrounding blank line / paragraph — a standalone paragraph at the end of §4.3):
```
The Python reference model in `py/models/ccl.py` matches this discipline exactly — a single `equiv[hi] = lo` write on merge, no pre-chase. Chasing in the model would over-merge compared to the RTL on adversarial noisy masks where two labels that would later unify have not yet been chained by pixel order.
```

Exact `Edit.new_string`: (empty string — delete the paragraph)
```

```

Note: after deletion, ensure there is still exactly one blank line before §4.4 heading. If two blanks remain, remove one.

### 9.6 §6.6 — drop the Python-match clause

- [ ] **Step 6: Rewrite the §6.6 "Why this exists" paragraph**

Exact `Edit.old_string` (line 541):
```
*Why this exists.* `axis_motion_detect`'s EMA background model starts at zero. On frame 0 every pixel differs maximally from the (empty) background, so the mask is mostly foreground and CCL would report one or more frame-filling bboxes — an obvious visual artifact. The EMA converges within `~1/ALPHA` frames; with the default `ALPHA_SHIFT=2` (α=1/4), two frames is enough to suppress the worst of it. Matching `PRIME_FRAMES` to the Python `motion` model's prime window also keeps RTL and model bit-identical at `TOLERANCE=0`; without the match, the first two frames would flag as verification diffs even though the RTL is correct.
```

Exact `Edit.new_string`:
```
*Why this exists.* `axis_motion_detect`'s EMA background model starts at zero. On frame 0 every pixel differs maximally from the (empty) background, so the mask is mostly foreground and CCL would report one or more frame-filling bboxes — an obvious visual artifact. The EMA converges within `~1/ALPHA` frames; with the default `ALPHA_SHIFT=2` (α=1/4), two frames is enough to suppress the worst of it.
```

### 9.7 §6.7 Cycle budget prose — drop TB numbers, drop Verilator-only, trim integrator advice

- [ ] **Step 7: Rewrite the §6.7 post-table paragraph (real-VGA + TB numbers)**

Exact `Edit.old_string` (line 554):
```
Vblank at real VGA 640×480 @ 60 Hz on a 100 MHz DSP clock is ~144 kcycles — ~100× headroom. The project TB uses `V_BLANK_TOTAL = V_FRONT_PORCH + V_SYNC_PULSE + V_BACK_PORCH = 20` lines at 320×240 with `H_TOTAL ≈ 336` — ~6.7 kcycles, ~5× headroom.
```

Exact `Edit.new_string`:
```
Vblank at real VGA 640×480 @ 60 Hz on a 100 MHz DSP clock is ~144 kcycles — ~100× headroom.
```

- [ ] **Step 8: Rewrite the §6.7 correctness-constraint paragraph**

Exact `Edit.old_string` (line 556):
```
This headroom is a **correctness** constraint, not just a throughput one: the per-pixel writes to `equiv[]`, `acc_*[]`, and `next_free` are gated on `phase == PHASE_IDLE`. If a pixel is accepted while the FSM is still in any of `PHASE_A..PHASE_SWAP`, its label/accumulator update is silently dropped, while `line_buf`, `w_label`, and `col`/`row` still advance — corrupting the labeling state when streaming resumes. The RTL defends against this two ways: (a) `s_axis_tready_o = (phase == PHASE_IDLE)` structurally back-pressures the upstream for the FSM duration; (b) a Verilator-only SVA `assert_no_accept_during_eof_fsm` traps any handshake that sneaks through. Integrators must still size their inter-frame idle window to exceed the cycle budget above — the FIFOs in front of `axis_ccl` have finite depth and will eventually reflect the stall upstream.
```

Exact `Edit.new_string`:
```
This headroom is a **correctness** constraint, not just a throughput one: the per-pixel writes to `equiv[]`, `acc_*[]`, and `next_free` are gated on `phase == PHASE_IDLE`. If a pixel is accepted while the FSM is still in any of `PHASE_A..PHASE_SWAP`, its label/accumulator update is silently dropped, while `line_buf`, `w_label`, and `col`/`row` still advance — corrupting the labeling state when streaming resumes. The RTL defends against this two ways: (a) `s_axis_tready_o = (phase == PHASE_IDLE)` structurally back-pressures the upstream for the FSM duration; (b) an SVA `assert_no_accept_during_eof_fsm` traps any handshake during the FSM. Integrating designs must still size the inter-frame idle window to exceed the cycle budget above, since the FIFOs in front of `axis_ccl` have finite depth.
```

### 9.8 §9 Known Limitations — drop the model-matches clause

- [ ] **Step 9: Rewrite the "Single equiv write per pixel" bullet**

Exact `Edit.old_string` (line 588):
```
- **Single equiv write per pixel can over-split vs. full union-find.** On noisy masks, two labels that would eventually unify via a third label may not merge within one frame if the chains haven't been built up by raster order. This is an accepted spec trade-off: the 1W port budget is tight, and over-splitting is safer than mis-merging. The Python model matches this exactly, so RTL and model agree bit-for-bit.
```

Exact `Edit.new_string`:
```
- **Single equiv write per pixel can over-split vs. full union-find.** On noisy masks, two labels that would eventually unify via a third label may not merge within one frame if the chains haven't been built up by raster order. This is an accepted spec trade-off: the 1W port budget is tight, and over-splitting is safer than mis-merging.
```

### 9.9 §10 References — drop plan links and py/models line

- [ ] **Step 10: Rewrite §10 References**

Exact `Edit.old_string` (lines 599–603):
```
- **Block 4 short plan:** [docs/plans/old/2026-04-20_block4-ccl.md](../plans/old/2026-04-20_block4-ccl.md) — motivation, algorithm, cycle budget, verification plan.
- **Detailed implementation plan:** [docs/plans/old/2026-04-20_block4-ccl-implementation.md](../plans/old/2026-04-20_block4-ccl-implementation.md) — task-by-task plan used to drive the implementation.
- **Parent pipeline:** [axis_motion_detect-arch.md](axis_motion_detect-arch.md), [axis_overlay_bbox-arch.md](axis_overlay_bbox-arch.md), [sparevideo-top-arch.md](sparevideo-top-arch.md).
- **Python reference model:** `py/models/ccl.py` — algorithm-equivalent to the RTL; cross-checked against `scipy.ndimage.label` for refinement (our bboxes ⊆ scipy's components) on sparse synthetic masks.
- **Rosenfeld, A. & Pfaltz, J.L., "Sequential operations in digital picture processing," JACM 13(4), 1966** — classical two-pass raster CCL with equivalence table. This module's per-pixel logic is the streaming adaptation.
```

Exact `Edit.new_string`:
```
- **Parent pipeline:** [axis_motion_detect-arch.md](axis_motion_detect-arch.md), [axis_overlay_bbox-arch.md](axis_overlay_bbox-arch.md), [sparevideo-top-arch.md](sparevideo-top-arch.md).
- **Rosenfeld, A. & Pfaltz, J.L., "Sequential operations in digital picture processing," JACM 13(4), 1966** — classical two-pass raster CCL with equivalence table. This module's per-pixel logic is the streaming adaptation.
```

### 9.10 Verify and commit

- [ ] **Step 11: Scope-audit grep**

Run: `Grep --pattern 'Python|python|py/models|testbench|tb_|plusarg|TOLERANCE|Verilator only|sim time|scipy|cocotb' --path docs/specs/axis_ccl-arch.md --output_mode content -n`

Expected: 0 matches.

- [ ] **Step 12: Commit**

```bash
git add docs/specs/axis_ccl-arch.md
git commit -m "docs(ccl-arch): purge Python/TB references, shrink parent-wiring note

- §2: collapse tree redraw to one sentence pointing at the parent
- §3.1/§4.0 glossary/§4.3/§6.6/§9: drop Python-model and TOLERANCE references
- §3.2: move multi-consumer wiring narrative to parent spec, leave pointer
- §6.7: drop TB-specific cycle math and \"Verilator only\" framing;
  keep the real-VGA-timing headroom and the correctness-constraint SVA
- §10: drop implementation-plan and py/models links; keep parent-spec
  links and the Rosenfeld-Pfaltz paper

Per docs/superpowers/specs/2026-04-21-specs-review-design.md §3.7."
```

---

## Task 10: Final global scope audit

**Files:**
- All: `docs/specs/*.md`

**Reference:** design doc §5 step 5; skill After-Writing item 6.

- [ ] **Step 1: Run the scope-audit grep across all specs**

Run: `Grep --pattern 'Python|python|py/models|pytest|testbench|tb_|plusarg|TOLERANCE|Verilator only|sva_drain_mode|sim time|scipy|cocotb' --path docs/specs --output_mode content -n`

Expected: 0 matches.

If any match survives, classify it:
- **Design-justified** (SVA note, synthesis/behavioral note, real-VGA timing) → leave as-is, record the rationale in the design doc.
- **Narrative residue** → remove and re-commit under the corresponding per-spec task name (e.g., `docs(top-arch): follow-up purge of ...`).

- [ ] **Step 2: Run the structural audit**

Run: `Grep --pattern '^##+ ' --path docs/specs --output_mode content -n`

Visually confirm each spec has `Contents → 1. Purpose and Scope → 2. Module Hierarchy → 3. Interface Specification → 4. Concept Description → 5. Internal Architecture → 6. Control Logic and State Machines → 7. Timing → 8. Shared Types → 9. Known Limitations → 10. References`, with the top spec having extras (Clock Domains, Region Descriptor, Assertions, Resources) — matching design doc §2.4.

- [ ] **Step 3: Quick cross-reference audit**

Run: `Grep --pattern 'docs/plans/' --path docs/specs --output_mode content -n`

Expected: 0 matches (no implementation-plan refs remain).

- [ ] **Step 4: No commit needed if audit is clean**

If all three audits pass, the work is done. If a fix was committed under Step 1, that is its own commit; nothing further.

---

## Self-Review Checklist

1. **Spec coverage.** Every bullet in design doc §3.1–§3.8 maps to a task (§3.1 → Task 2, §3.2 → Task 3, §3.3 → Task 4, §3.4 → Task 5, §3.5 → Task 6, §3.6 → Task 7, §3.7 → Task 9, §3.8 → Task 8). Design doc §4 → Task 1. Design doc §5 ordering → task order. ✓
2. **Placeholders.** No TBD / TODO / "similar to" / "implement later" in the plan. Every edit gives exact old and new text. ✓
3. **Commands.** Every grep has concrete flags; every commit has a full message. ✓
4. **Line numbers drift.** Tasks 8 and 9 list edits in top-to-bottom order so later edits don't invalidate earlier line references. Within each task the engineer applies edits sequentially. ✓
