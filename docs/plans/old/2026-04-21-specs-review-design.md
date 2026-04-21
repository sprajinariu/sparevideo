# Specs Review and Cleanup — Design

**Date:** 2026-04-21
**Scope:** All 8 files under `docs/specs/`
**Goal:** Enforce a consistent definition of "design spec" across the project. A spec is the design contract for one RTL module; it does not describe how the module is verified.

## Contents

- [1. Objectives](#1-objectives)
- [2. Cleanup Policy](#2-cleanup-policy)
  - [2.1 What to purge](#21-what-to-purge)
  - [2.2 What to keep](#22-what-to-keep)
  - [2.3 Cross-document dependency rules](#23-cross-document-dependency-rules)
  - [2.4 Structural normalization](#24-structural-normalization)
- [3. Per-Spec Findings](#3-per-spec-findings)
  - [3.1 `ram-arch.md`](#31-ram-archmd)
  - [3.2 `rgb2ycrcb-arch.md`](#32-rgb2ycrcb-archmd)
  - [3.3 `vga_controller-arch.md`](#33-vga_controller-archmd)
  - [3.4 `axis_overlay_bbox-arch.md`](#34-axis_overlay_bbox-archmd)
  - [3.5 `axis_gauss3x3-arch.md`](#35-axis_gauss3x3-archmd)
  - [3.6 `axis_motion_detect-arch.md`](#36-axis_motion_detect-archmd)
  - [3.7 `axis_ccl-arch.md`](#37-axis_ccl-archmd)
  - [3.8 `sparevideo-top-arch.md`](#38-sparevideo-top-archmd)
- [4. `hardware-arch-doc` Skill Update](#4-hardware-arch-doc-skill-update)
- [5. Implementation Ordering](#5-implementation-ordering)

---

## 1. Objectives

1. **Consistency.** All specs follow the same section template, TOC style, numbering, tone, and length norms.
2. **Decoupling.** Parent specs describe interfaces and interconnect only. Children describe internals only. No parent-re-describes-child duplication; no child re-drawing parent hierarchy.
3. **Design-only content.** Remove Python-model references, testbench narrative, implementation-plan links, simulator-specific framing, and unit-TB tolerance statements. Keep SVA assertions, behavioral-vs-synthesizable notes, and real-hardware timing budgets.
4. **Durable rules.** Codify the above in `.claude/skills/hardware-arch-doc/SKILL.md` so future specs are written to the same standard.

## 2. Cleanup Policy

### 2.1 What to purge

- **Python reference models.** Any mention of `py/models/*`, scipy/OpenCV/numpy cross-checks, tolerance statements ("matches Python model", "RTL and model agree bit-for-bit", "cross-checked against `scipy.ndimage.label`", "TOLERANCE=0").
- **Testbench narrative.** Plusargs (`+CTRL_FLOW=`, `+DUMP_VCD`, `sva_drain_mode`), TB V_BLANK sizing statements, `tb_sparevideo`, TB-specific cycle numbers, drain-mode flags.
- **Implementation-plan links.** `docs/plans/old/*`, "Block N short plan", "task-by-task plan used to drive the implementation".
- **Unit-TB tolerance statements.** "checked with ±1 LSB tolerance in TB" belongs in the TB, not in the spec.
- **Simulator-specific framing.** "Verilator only", "catches this at sim time", "assertion traps the case during Verilator simulation".

### 2.2 What to keep

- **SVA assertions.** They formalize design invariants and are part of the RTL deliverable. The top spec's Assertions chapter stays; just drop the "Verilator only" subtitle.
- **Behavioral vs. synthesizable RTL notes.** E.g., `ram.sv` is a behavioral stand-in; synthesis needs `xpm_memory_tdpram`. This is a design-integration constraint.
- **Real-VGA-timing cycle budgets.** E.g., "vblank at 640×480 @ 60 Hz on a 100 MHz DSP clock is ~144 kcycles — ~100× headroom". This is a hardware constraint.
- **Design-driven parameter values that happen to match the model.** Phrase as design rationale only (e.g., "`PRIME_FRAMES=2` gives the EMA time to converge"), never as model-matching.
- **Concept references** (specs, papers, vendor docs) — AXI4-Stream spec, Rosenfeld-Pfaltz CCL paper, OpenCV background-subtraction tutorial as a concept anchor.

### 2.3 Cross-document dependency rules

- **Parent spec describes interfaces and interconnect only.** §5 of the top spec lists submodule roles in ≤3 sentences each and links to the child spec. It does not re-describe child internals (no FSMs, no RMW formulas, no pipeline timing belonging to the child).
- **Child spec may include a one-paragraph parent-context note** in §1 or §2 for orientation, linking up. No ASCII re-draw of the parent's module tree.
- **Lateral sibling refs** allowed only when one module's design actively constrains another (e.g., the host-responsibility rule in `ram-arch` governing `axis_motion_detect`).
- **Forward refs to deferred work** allowed only when they explain a current design choice (e.g., "the region-descriptor model exists because these params will migrate to CSRs later").
- **No implementation-plan links.** Plans are process artifacts; specs are design contracts.

### 2.4 Structural normalization

All specs follow the `hardware-arch-doc` template:

```
Contents
---
1. Purpose and Scope
2. Module Hierarchy
3. Interface Specification
   3.1 Parameters
   3.2 Ports
4. Concept Description
5. Internal Architecture
6. Control Logic and State Machines
7. Timing
8. Shared Types
9. Known Limitations
10. References
```

**Top spec keeps its extra chapters.** `sparevideo-top` is the top-level design, not a module. Its numbering is:

```
1. Purpose and Scope
2. Module Hierarchy
3. Interface Specification
4. Concept Description
5. Internal Architecture
6. Clock Domains
7. Region Descriptor Model
8. Assertions
9. Known Limitations
10. Resources
11. References
```

**Formatting rules.**
- TOC with anchor links, `---` separator after TOC.
- `### H.SH` sub-numbering (e.g., `### 3.1 Parameters`).
- Present tense, short sections (one screenful maximum), no emoji.
- Every signal mentioned must match the RTL port name exactly.

## 3. Per-Spec Findings

Flag key: **[P]** purge content, **[D]** de-duplicate with other specs, **[N]** normalize structure.

### 3.1 `ram-arch.md`

Clean. No action required.

### 3.2 `rgb2ycrcb-arch.md`

- **[P]** §5.4 "Verified corner cases" — rename to "Design corner cases". Drop the line "Unit testbench (`hw/ip/rgb2ycrcb/tb/tb_rgb2ycrcb.sv`) checks all 6 cases with ±1 LSB tolerance." The 6 cases themselves are design-level content (what the math must produce at corners); the TB reference is verification.

### 3.3 `vga_controller-arch.md`

- **[P]** §9 "The `assert_no_output_underrun` SVA in `sparevideo_top` catches this at sim time." Rephrase: "The top-level spec §8 formalizes an underrun invariant." Drops "at sim time" framing; keeps the design reference.

### 3.4 `axis_overlay_bbox-arch.md`

Clean on spot-check.

### 3.5 `axis_gauss3x3-arch.md`

Clean on spot-check. §1 cleanly defers role/motivation to `axis_motion_detect`.

### 3.6 `axis_motion_detect-arch.md`

Clean on verification (grep found no Python / TB / plusarg matches). §10 References' OpenCV Background Subtraction tutorial link stays — it is a concept reference, same class as the AXI4-Stream spec link.

### 3.7 `axis_ccl-arch.md`

Largest cleanup target.

- **[D]** §2 Module Hierarchy redraws the top-spec tree. Trim to: "Instantiated in `sparevideo_top` as `u_ccl`, between `axis_motion_detect` and `axis_overlay_bbox`." Drop the tree diagram.
- **[P]** §3.1 `PRIME_FRAMES` row — drop "Matches `motion` Python model so the EMA has time to converge before any bbox is reported"; keep "Number of initial frames suppressed so the EMA background model has time to converge."
- **[P]** §3.2 after the ports table: the long paragraph about `msk_tready` / `ccl_beat_strobe` / multi-consumer broadcast describes **how the parent wires this module**, not the module's own behavior. Move the parent-wiring note to `sparevideo-top §5.1`. Keep a one-liner pointer here: "See `sparevideo-top` §5.1 for multi-consumer broadcast wiring."
- **[P]** §4.0 Glossary "Prime frames" row — drop "and matches the Python `motion` model's own warm-up window so RTL and model agree bit-for-bit". Keep the EMA convergence explanation.
- **[P]** §4.3 final paragraph beginning "The Python reference model in `py/models/ccl.py` matches this discipline exactly..." — remove entire paragraph.
- **[P]** §6.6 final sentence "Matching `PRIME_FRAMES` to the Python `motion` model's prime window also keeps RTL and model bit-identical at `TOLERANCE=0`..." — remove.
- **[P]** §6.7 final paragraph — trim to the SVA invariant only. Keep: "An SVA traps any handshake during the FSM." Drop: "Verilator-only" framing; drop the "Integrators must still size their inter-frame idle window..." integration advice (this is a synthesis/integration note, not a design one — unless phrased as the invariant that surrounding logic must ensure vblank ≥ cycle budget).
- **[P]** §6.7 TB-specific cycle math (the 320×240 / 6.7 kcycles / 5× headroom line). Remove; keep only the real-VGA-timing headroom figure.
- **[P]** §10 References: drop the two `docs/plans/old/*` implementation-plan links. Drop the `py/models/ccl.py` line. **Keep** parent-pipeline spec links and the Rosenfeld-Pfaltz paper.

### 3.8 `sparevideo-top-arch.md`

- **[P]** §1 Purpose: drop "It is driven by the testbench via the `+CTRL_FLOW=...` plusarg." sentence.
- **[P]** §3.1 params footnote: drop the same plusarg sentence.
- **[P]** §4.2 Mask/video latency independence: rewrite "The testbench's V_BLANK (2+2+16 lines) is sized to cover the worst-case cycle budget at 320×240" as "Vblank headroom must exceed the CCL worst-case EOF-FSM cycle budget (see `axis_ccl-arch.md §6.7`)."
- **[P]** §8 chapter title: "Assertions (SVA, Verilator only)" → "Assertions". Drop the `sva_drain_mode` line at the end (TB-only knob).
- **[P]** §9 Known Limitations: the "matching the Python motion model" clause — rephrase as design rationale (EMA convergence, not model-matching). The "Runtime override requires a simulation plusarg and recompile for RTL" line — drop the plusarg half; keep "compile-time parameter".
- **[D]** §5.1 Submodule roles: long. Compress each submodule bullet to ≤3 sentences. Current u_motion_detect bullet has ~6 lines of EMA algorithm (belongs in `axis_motion_detect-arch §4.4 / §5.4`); u_ccl bullet has ~10 lines of FSM description (belongs in `axis_ccl-arch §6`). Replace with: role + one-sentence interface + link to child spec.
- **[N]** §10 Resources: the nested `### u_ram — EMA background model` subsection is unnumbered. Either promote to `### 10.1 u_ram — EMA background model` or drop it (it restates `ram-arch.md §5.4`). Recommendation: drop — the resources table + formulas already cover it; keep one sentence: "See `ram-arch.md` for port semantics and the behavioral-to-BRAM substitution note."

## 4. `hardware-arch-doc` Skill Update

File: `.claude/skills/hardware-arch-doc/SKILL.md`.

**Insert new section "Scope and Content Rules"** between "Document Structure" and "Style Rules":

> A spec is the **design contract** for one RTL module. It describes what the module does, its interface, its internal structure, its timing, and its invariants. It does not describe how the module is verified.
>
> **Do not include:**
> - Python reference models (`py/models/*`), scipy/OpenCV/numpy cross-checks, tolerance statements, "RTL matches model bit-for-bit" claims.
> - Testbench narrative: plusargs (`+CTRL_FLOW=`, `+DUMP_VCD`, `sva_drain_mode`), TB V_BLANK sizing, `tb_sparevideo`, TB-specific cycle numbers.
> - Implementation-plan links (`docs/plans/*`).
> - Unit-TB tolerance (belongs in the TB, not the spec).
> - Simulator-specific framing ("Verilator only", "at sim time").
>
> **Do include:**
> - SVA assertions — they formalize design invariants and are part of the RTL deliverable. A dedicated chapter in the top spec is appropriate.
> - Behavioral vs. synthesizable RTL notes (e.g., `ram.sv` is behavioral; synthesis needs `xpm_memory_tdpram`).
> - Real-hardware timing and cycle-budget statements (at spec'd clock and resolution, not TB values).
> - One-sentence design rationale when a parameter was chosen for a design reason that also happens to match a model — phrase as design rationale, not model reference.

**Insert new section "Cross-Document Dependency Rules"** after the above:

> - **Parent spec describes interfaces and interconnect only** for its children. §5 lists submodule roles in ≤3 sentences each and links to the child spec. Do not re-describe child internals.
> - **Child spec may include a one-paragraph parent-context note** in §1 or §2 for orientation, linking up. No ASCII re-draw of the parent's tree.
> - **Lateral sibling refs** allowed only when one module's design actively constrains another.
> - **Forward refs** to deferred work allowed only when they explain a current design choice.
> - **No implementation-plan links.** Plans are process artifacts; specs are design contracts.

**Amend "Required Sections" §4 and §5** with one closing line each:

> Scope rules above apply — no Python/TB narrative; no child-internal duplication in parent spec.

**Amend "After Writing" checklist** with a new item:

> 6. Scope audit: grep the spec for `python`, `pytest`, `plusarg`, `tb_`, `testbench`, `TOLERANCE`, `py/models`. Each hit must either be removed or justified by the Scope and Content Rules above.

**Refresh the stale hierarchy example in §2.** The current example shows `axis_bbox_reduce` as a submodule of `sparevideo_top`; the codebase has replaced it with `axis_ccl` + `axis_overlay_bbox`. Update to match the current RTL (mirroring `sparevideo-top-arch.md §2`).

## 5. Implementation Ordering

The skill update and spec edits are independent content, but the skill update is the durable artifact and should land first so it can be cited as the reason for each spec edit.

1. **Update the skill** (`.claude/skills/hardware-arch-doc/SKILL.md`) with the new Scope and Cross-Doc sections, the §4/§5 line amendments, the After-Writing audit item, and the refreshed hierarchy example.
2. **Small specs first** (lowest risk, easiest to verify): `ram`, `rgb2ycrcb`, `vga_controller`, `axis_overlay_bbox`.
3. **Medium specs next**: `axis_gauss3x3`, `axis_motion_detect`.
4. **Large specs last**: `sparevideo-top`, `axis_ccl`. These get the biggest cleanups; do them with full context of what the other specs now look like.
5. **Final sweep:** grep-audit (as per the new After-Writing checklist item) across all 8 specs for residual `python`, `plusarg`, `tb_`, `TOLERANCE`, `py/models`, `Verilator only` matches. Every hit must either be removed or pointed at the scope-rules rationale.

Each step is a separate commit so the history shows *policy → application* progression.
