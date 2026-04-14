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
├── axis_async_fifo         (u_fifo_in)     — clk_pix → clk_dsp CDC
├── axis_motion_detect      (u_motion)      — clk_dsp; Y8 diff, mask output
│   └── rgb2ycrcb           (u_rgb2y)       — pixel→luma conversion
├── ram                     (u_ram)         — shared Y8 frame buffer (port A: motion, port B: unused)
├── axis_bbox_reduce        (u_bbox)        — clk_dsp; reduces mask to bounding box
├── axis_overlay_bbox       (u_overlay)     — clk_dsp; draws bbox rect on video
├── axis_async_fifo         (u_fifo_out)    — clk_dsp → clk_pix CDC
└── vga_controller          (u_vga)         — clk_pix; produces hsync/vsync/RGB
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

**4. Datapath Description**
Describe how data flows through the module. 

**5. Control logic and State Machines**
For every FSM in the module, document:
- States (name + meaning)
- Transitions (condition → next state)
- Outputs per state

Use a table or DOT diagram.

**6. Timing**
State the number of clock cycles each operation takes. In case of pipeline modules, state latency in clock cycles.

**7. Shared Types**
List every type from `sparevideo_pkg` used in this module and what each field means.

**8. Known Limitations**
Anything the current implementation does not handle that a future implementation will address.
Any assumption how signals and data should behave outside of this module, that is required for the normal operation of the module. 

## Style Rules

- Keep each section short — one screenful maximum.
- Write in present tense ("the decoder produces", not "the decoder will produce").
- Every signal mentioned in the document must match exactly the RTL port name.
- Update this document whenever the RTL interface changes — the document and the RTL must stay in sync.

## After Writing

1. Cross-check every module port against the interface table — no port should be absent.
2. Update `README.md` to reflect the new module status.
3. Update the top-level design spec (`sparevideo-top-arch.md`) if the module design deviates from it.
4. Update the architecture doc to reflect any RTL update.
