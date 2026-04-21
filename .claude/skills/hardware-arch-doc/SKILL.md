---
name: hardware-arch-doc
description: Use when starting a new hardware stage or module before implementation begins, to produce a detailed architecture document covering module hierarchy, signal interfaces, state machines, datapath, and timing.
---

# Hardware Architecture Documentation

## Overview

Produce a detailed architecture document for a hardware stage or module before writing any RTL. The document is the contract between design intent and implementation — if something is in the document, it should be reflected in the RTL.


## When to Use
- Before starting any new module.
- Before adding a new submodule to an existing stage
- When a module's design changes significantly during implementation

## Document Structure
The top level architecture document (`sparevideo-top-arch.md`) contains major architecture specification, strategies, decisions.
The detailed specification for each module is written in their own module architecture document. 
Write one architecture document per module under `docs/specs/`. Name it `<module>-arch.md`. Create the `docs/specs/` directory if it does not yet exist.

### Required Sections

**1. Purpose and Scope**
One paragraph: what this module does and what it does not do. State the function it implements and the bus interface it uses.

**2. Module Hierarchy**
A block diagram as ASCII or text tree showing every module and its instantiation name. Current top-level hierarchy for reference:

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

**3. Interface Specification**
A table for every port on the top-level module:

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| Clocks and resets |
| `clk_i` | input | 1 | System clock, rising edge |
| `rst_ni` | input | 1 | Async active-low reset |
| AXI stream input |
| `s_axis_tdata_i` | input | 1 | Mask pixel (1 = motion) |
| `s_axis_tvalid_i` | input | 1 | AXI4-Stream valid |
| `s_axis_tready_o` | output | 1 | Always 1 — this module never back-pressures |
| `s_axis_tlast_i` | input | 1 | End-of-line |
| `s_axis_tuser_i` | input | 1 | Start-of-frame |


Repeat for every submodule's interface that is non-obvious.

**4. Concept Description**
Describe the high level algorithm/protocol implemented in the module.
Focus on concept, mathematical algorithm (if applicable), without too much coupling to the actual implementation.
Give theoretical context on what the module does, and why is it useful in the overall function of the design.
Scope rules in "Scope and Content Rules" below apply — no Python/TB narrative; no child-internal duplication in parent spec.

**5. Internal architecture**
Describe how data flows through the module.
Anything related to resource cost, placement, implementation decisions.
In case of the top-level architecture document, write about each submodule in the context of the larger top-level.
Scope rules in "Scope and Content Rules" below apply — no Python/TB narrative; no child-internal duplication in parent spec.

**6. Control logic and State Machines**
For every FSM in the module, document:
- States (name + meaning)
- Transitions (condition → next state)
- Outputs per state

Use a table or DOT diagram.

**7. Timing**
State the number of clock cycles each operation takes. In case of pipeline modules, state latency in clock cycles.

**8. Shared Types**
List every type from `sparevideo_pkg` used in this module and what each field means.

**9. Known Limitations**
Anything the current implementation does not handle that a future implementation will address.
Any assumption on how signals and data should behave outside of this module, that is required for the normal operation of the module. 

**10. References**
Link online links that were used as reference for this module.


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

## Style Rules

- Keep each section short — one screenful maximum.
- Write in present tense ("the decoder produces", not "the decoder will produce").
- Every signal mentioned in the document must match exactly the RTL port name.
- Update this document whenever the RTL interface changes — the document and the RTL must stay in sync.
- **Contents section**: add a `## Contents` table of contents immediately after the title, with markdown anchor links to every section and sub-section. Place a `---` separator between Contents and section 1.
- **Sub-header numbering**: number sub-headers with the full `H.SH` scheme (e.g. `### 3.1 Parameters`, `### 3.2 Ports`). Use this scheme whenever a section has sub-headers; omit numbering only for sections with no sub-headers at all.

## After Writing

1. Cross-check every module port against the interface table — no port should be absent.
2. Update `README.md` to reflect the new module status.
3. Update the top-level design spec (`sparevideo-top-arch.md`) if the module design deviates from it.
4. Update the architecture doc to reflect any RTL update.
5. Update the Contents section to reflect any new sections or sub-sections added during writing.
6. Scope audit: grep the spec for `python`, `pytest`, `plusarg`, `tb_`, `testbench`, `TOLERANCE`, `py/models`. Each hit must either be removed or justified by the Scope and Content Rules above.
