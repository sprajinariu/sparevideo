# `axis_morph_clean` Architecture

## Contents

- [1. Purpose and Scope](#1-purpose-and-scope)
- [2. Module Hierarchy](#2-module-hierarchy)
- [3. Interface Specification](#3-interface-specification)
  - [3.1 Parameters](#31-parameters)
  - [3.2 Ports](#32-ports)
- [4. Concept Description](#4-concept-description)
  - [4.1 Erosion, dilation, opening, closing](#41-erosion-dilation-opening-closing)
  - [4.2 Why open then close](#42-why-open-then-close)
  - [4.3 Minkowski composition for the 5×5 close](#43-minkowski-composition-for-the-55-close)
  - [4.4 Per-stage runtime bypass](#44-per-stage-runtime-bypass)
- [5. Internal Architecture](#5-internal-architecture)
  - [5.1 Block diagram](#51-block-diagram)
  - [5.2 Stage roles](#52-stage-roles)
  - [5.3 Resource cost summary](#53-resource-cost-summary)
- [6. Control Logic and State Machines](#6-control-logic-and-state-machines)
- [7. Timing](#7-timing)
  - [7.1 Latency](#71-latency)
  - [7.2 Blanking requirements](#72-blanking-requirements)
- [8. Shared Types](#8-shared-types)
- [9. Known Limitations](#9-known-limitations)
- [10. References](#10-references)

---

## 1. Purpose and Scope

`axis_morph_clean` is the mask-cleanup stage between `axis_motion_detect` and `axis_ccl` in the motion-mask path. It applies a fixed 3×3 morphological **opening** followed by a parametrizable 3×3 or 5×5 morphological **closing** to a 1-bit motion mask AXI4-Stream. Opening removes salt noise and thin features; closing bridges small intra-object gaps so a single moving object produces a single connected blob in CCL rather than a fragmented set of bboxes.

The module is a pure structural composition of existing 3×3 erode and dilate primitives (`axis_morph3x3_erode`, `axis_morph3x3_dilate`). No new sliding-window primitive is required: the 5×5 close is built from cascaded 3×3 stages via Minkowski composition. Each of the two cleanup stages (open, close) has an independent runtime enable; when a stage is disabled, every sub-module within it falls back to its own zero-latency combinational passthrough (the `enable_i=0` path of the underlying erode/dilate primitive).

The block runs in the `clk_dsp` (100 MHz) domain, accepts one mask pixel per cycle on a 1-bit AXI4-Stream interface, and emits one cleaned mask pixel per cycle on a 1-bit AXI4-Stream interface with the same `tuser`=SOF and `tlast`=EOL conventions. It performs no operations on luma or RGB data, no adaptive thresholding, and no CCL or bbox post-processing.

For the role of this stage in the larger pipeline (its position relative to `axis_motion_detect`, the mask broadcast fork, and `axis_ccl`), see [`sparevideo-top-arch.md`](sparevideo-top-arch.md) §5.

---

## 2. Module Hierarchy

```
axis_morph_clean                (u_morph_clean in sparevideo_top)
├── axis_morph3x3_erode         (u_open_erode)         — open stage 1
├── axis_morph3x3_dilate        (u_open_dilate)        — open stage 2
├── axis_morph3x3_dilate × N    (g_close_dilate[i].u_d) — close dilate cascade, N = (CLOSE_KERNEL−1)/2
└── axis_morph3x3_erode  × N    (g_close_erode[i].u_e)  — close erode cascade,  N = (CLOSE_KERNEL−1)/2
```

`N = 1` for `CLOSE_KERNEL = 3`; `N = 2` for `CLOSE_KERNEL = 5`. Each sub-stage in turn instantiates one `axis_window3x3<DATA_WIDTH=1, EDGE_REPLICATE>`; see [`axis_window3x3-arch.md`](axis_window3x3-arch.md) for the sliding-window primitive structure.

---

## 3. Interface Specification

### 3.1 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `H_ACTIVE` | 320 | Active pixels per line. Forwarded to every sub-stage as the line-buffer depth and column-counter range. |
| `V_ACTIVE` | 240 | Active lines per frame. Forwarded to every sub-stage as the row-counter range. |
| `CLOSE_KERNEL` | 3 | Close kernel size, ∈ {3, 5}. Selects `N = (CLOSE_KERNEL − 1) / 2` cascaded 3×3 dilates followed by `N` cascaded 3×3 erodes. Validated by an elaboration-time `assert`; any other value is an `$error`. |

### 3.2 Ports

| Signal | Direction | Type | Description |
|--------|-----------|------|-------------|
| `clk_i`             | input  | `logic`      | DSP clock (`clk_dsp`), rising edge active. |
| `rst_n_i`           | input  | `logic`      | Active-low synchronous reset. |
| `morph_open_en_i`   | input  | `logic`      | Runtime gate for the 3×3 open stage. Forwarded to both `u_open_erode` and `u_open_dilate`. When 0, the open stage forwards its input combinationally with no line-buffer fill. Must be frame-stable. |
| `morph_close_en_i`  | input  | `logic`      | Runtime gate for the close stage. Forwarded to every sub-stage in `g_close_dilate` and `g_close_erode`. When 0, the close stage forwards combinationally. Must be frame-stable. |
| `s_axis`            | input  | `axis_if.rx` | 1-bit mask input (DATA_W=1, USER_W=1). `tdata[0]` = mask pixel; `tuser` = SOF; `tlast` = EOL. `tready` is driven by the first sub-stage. |
| `m_axis`            | output | `axis_if.tx` | 1-bit cleaned mask output (DATA_W=1, USER_W=1). Driven by the last sub-stage in the cascade. `tlast`/`tuser` regenerated at each enabled sub-stage's output counter; passed through unchanged on disabled sub-stages. |

The module exposes no `busy_o`. Standard VGA-timed integration keeps every internal `busy_o` low because blanking always provides the phantom-drain cycles required by each `axis_window3x3` sub-stage; see [`axis_window3x3-arch.md`](axis_window3x3-arch.md) §7.

---

## 4. Concept Description

### 4.1 Erosion, dilation, opening, closing

For a 1-bit mask `M` and a 3×3 square structuring element `B`:

- **Erosion** `M ⊖ B` is a 9-input AND over the window: output = 1 only when all 9 taps are 1.
- **Dilation** `M ⊕ B` is a 9-input OR over the window: output = 1 when at least one tap is 1.
- **Opening** `γ(M) = (M ⊖ B) ⊕ B`: erosion followed by dilation.
- **Closing** `φ(M) = (M ⊕ B) ⊖ B`: dilation followed by erosion.

Opening is anti-extensive (`γ(M) ⊆ M`) — it only ever removes foreground. Closing is extensive (`M ⊆ φ(M)`) — it only ever adds foreground. Both are idempotent under their own structuring element.

### 4.2 Why open then close

Open-then-close (`φ ∘ γ`) is the canonical binary mask cleanup sequence (Soille §8.2; Gonzalez & Woods Ch. 9). Opening first removes salt noise and thin features that should not have entered the mask. Closing then bridges small holes inside the surviving foreground regions so each connected object produces one connected component, not a constellation of fragments. Applying close before open would risk merging adjacent salt pixels into a small blob that the subsequent open could no longer distinguish from a real thin feature.

For the motion-detect mask in this pipeline, the practical effect of the close stage is that a single moving object — which the upstream stages may register as a cluster of disjoint mask pixels separated by 1- to 2-pixel background gaps — emerges from `axis_morph_clean` as one connected blob. CCL then produces one bbox per object instead of several overlapping or nested bboxes.

### 4.3 Minkowski composition for the 5×5 close

The Minkowski sum of two 3×3 square structuring elements is a 5×5 square: `B₃ ⊕ B₃ = B₅`. Applying dilation twice with `B₃` is therefore equivalent to one dilation with `B₅`, and the same composition holds for erosion. A 5×5 close `(M ⊕ B₅) ⊖ B₅` is exact-equivalent to `(((M ⊕ B₃) ⊕ B₃) ⊖ B₃) ⊖ B₃` — two cascaded 3×3 dilates followed by two cascaded 3×3 erodes. This is what the `CLOSE_KERNEL = 5` configuration of `axis_morph_clean` builds. No native 5×5 sliding-window primitive is required.

Generalising, kernel size `2N + 1` is built from `N` cascaded 3×3 dilates and `N` cascaded 3×3 erodes. Only `N ∈ {1, 2}` (kernels 3 and 5) are accepted at elaboration today.

### 4.4 Per-stage runtime bypass

`morph_open_en_i` and `morph_close_en_i` are independent runtime gates. They are forwarded as `enable_i` to every sub-stage in their respective stage. Each `axis_morph3x3_erode` and `axis_morph3x3_dilate` implements an `enable_i = 0` zero-latency combinational passthrough that mirrors `s_axis` to `m_axis` with no line-buffer fill. When a whole stage is gated off, every sub-stage in it independently falls back to that combinational passthrough. Both gates must be held stable across an entire frame; toggling mid-frame leaves line buffers and output counters inconsistent in any sub-stage that is mid-fill.

---

## 5. Internal Architecture

### 5.1 Block diagram

```
                    open                              close
              ┌─────────────┐               ┌──────────────────────────┐
s_axis ────►  │ erode → dil │  ──────────►  │ dilate × N  →  erode × N │  ────► m_axis
              └─────────────┘               └──────────────────────────┘
              morph_open_en_i                  morph_close_en_i
```

`N = (CLOSE_KERNEL − 1) / 2`. The stages are connected in a straight pipeline through internal `axis_if` instances; the close stage immediately follows the open stage with no buffering or arbitration between them.

### 5.2 Stage roles

| Stage | Sub-stages (in raster order) | Role |
|-------|------------------------------|------|
| Open  | `u_open_erode` → `u_open_dilate` | Salt-noise and thin-feature removal (3×3 opening). Always present; runtime-bypassed by `morph_open_en_i = 0`. |
| Close | `g_close_dilate[0..N-1]` → `g_close_erode[0..N-1]` | Hole-bridging and intra-object reconnect (3×3 or 5×5 closing). Generated; runtime-bypassed by `morph_close_en_i = 0`. |

A `generate` block expands the close stage into `N` cascaded `axis_morph3x3_dilate` instances followed by `N` cascaded `axis_morph3x3_erode` instances. Each sub-stage's `clk_i`, `rst_n_i`, `H_ACTIVE`, and `V_ACTIVE` come from the parent ports/parameters; the open sub-stages take `enable_i = morph_open_en_i`, the close sub-stages take `enable_i = morph_close_en_i`.

### 5.3 Resource cost summary

Each `axis_morph3x3_*` sub-stage owns one `axis_window3x3<DATA_WIDTH=1>`, which contains 2 line buffers of `H_ACTIVE × 1` bits.

| `CLOSE_KERNEL` | Total sub-stages | Total line buffers | Line-buffer storage at `H_ACTIVE = 320` |
|----------------|------------------|--------------------|-----------------------------------------|
| 3              | 4 (erode, dilate, dilate, erode)              | 8  | 8 × 320 × 1 = 2,560 bits |
| 5              | 6 (erode, dilate, dilate, dilate, erode, erode) | 12 | 12 × 320 × 1 = 3,840 bits |

Distributed RAM is the expected synthesis target at 320 px; wider resolutions should infer BRAM. Per-sub-stage column shift FFs, output counters, and output registers add a small fixed overhead on top of the line-buffer storage.

---

## 6. Control Logic and State Machines

None. `axis_morph_clean` is a pure structural composition. The wrapper introduces no FSM, no shared counter, and no arbitration logic. Each underlying sub-stage owns its own column/row counter (see [`axis_window3x3-arch.md`](axis_window3x3-arch.md)); downstream stall freezes the entire cascade.

---

## 7. Timing

### 7.1 Latency

Each `axis_morph3x3_*` sub-stage adds `H_ACTIVE + 3` cycles when its `enable_i = 1`, and 0 cycles when `enable_i = 0` (combinational pass-through within that sub-stage).

| Configuration | Number of fully enabled sub-stages | End-to-end latency |
|---------------|-------------------------------------|--------------------|
| `morph_open_en = 1`, `morph_close_en = 1`, `CLOSE_KERNEL = 3` | 4  | `4 × (H_ACTIVE + 3)` cycles |
| `morph_open_en = 1`, `morph_close_en = 1`, `CLOSE_KERNEL = 5` | 6  | `6 × (H_ACTIVE + 3)` cycles |
| `morph_open_en = 1`, `morph_close_en = 0`, any `CLOSE_KERNEL` | 2  | `2 × (H_ACTIVE + 3)` cycles |
| `morph_open_en = 0`, `morph_close_en = 1`, `CLOSE_KERNEL = 3` | 2  | `2 × (H_ACTIVE + 3)` cycles |
| `morph_open_en = 0`, `morph_close_en = 1`, `CLOSE_KERNEL = 5` | 4  | `4 × (H_ACTIVE + 3)` cycles |
| `morph_open_en = 0`, `morph_close_en = 0`, any `CLOSE_KERNEL` | 0  | 0 cycles (combinational) |

Steady-state throughput is 1 pixel/cycle in every configuration. At `H_ACTIVE = 320`/100 MHz the worst case (5×5 fully enabled) is roughly 19 µs of fill — a one-time cost per frame, invisible at 60 fps.

### 7.2 Blanking requirements

Each enabled sub-stage drains its phantom cycles sequentially during V-blank. Drains do not compound: any one sub-stage finishes its drain before the next begins, so the union budget is the same `≥ H_ACTIVE + 1` cycles of V-blank required by a single `axis_window3x3` instance. Standard VGA timing for 320×240 leaves on the order of `144 × H_TOTAL` cycles of vblank — many orders of magnitude beyond the worst-case `6 × (H_ACTIVE + 3)` end-to-end latency, let alone the per-stage drain. See [`axis_ccl-arch.md`](axis_ccl-arch.md) §6.7 for the binding vblank budget elsewhere in the pipeline.

---

## 8. Shared Types

The module reads three fields from `cfg_t` (in `hw/top/sparevideo_pkg.sv`); the parent (`sparevideo_top`) unpacks them and drives the corresponding ports/parameters:

| `cfg_t` field | Type | Wired to | Meaning |
|---------------|------|----------|---------|
| `morph_open_en`     | `logic` | `morph_open_en_i`  | Runtime gate for the open stage. `0` bypasses both open sub-stages. |
| `morph_close_en`    | `logic` | `morph_close_en_i` | Runtime gate for the close stage. `0` bypasses every close sub-stage. |
| `morph_close_kernel`| `int`   | `CLOSE_KERNEL` parameter | Compile-time (per-profile) close kernel size, ∈ {3, 5}. |

`morph_close_kernel` becomes a parameter rather than a port because the cascade depth `N` is fixed by `generate`. Switching between 3 and 5 requires recompilation under the appropriate profile.

---

## 9. Known Limitations

- **Kernel sizes restricted to 3 and 5.** Larger kernels (7×7 and beyond) would require `N = 3` or more cascaded sub-stages on each half of the close. They are not supported today; the elaboration `assert` rejects any value other than 3 or 5. Adding 7×7 is purely a parameter-table change once the additional latency and line-buffer cost are deemed acceptable.
- **Gap-bridging capacity bounded by kernel size.** A 3×3 close bridges intra-object background gaps of width ≤ 1 pixel; a 5×5 close bridges gaps of width ≤ 2 pixels. Larger gaps fragment the mask and produce multiple CCL components for what is logically one object. Gap widths approaching the kernel size also raise the risk of merging genuinely distinct adjacent objects.
- **Thin-feature deletion inherited from the open stage.** The 3×3 open removes any foreground feature narrower than 3 pixels. The downstream close cannot resurrect what the open has erased, so thin real objects (e.g., far-field 1- or 2-pixel targets) are lost when the open is enabled. Disable via `morph_open_en_i = 0`.
- **Compile-time kernel selection only.** `morph_close_kernel` is a parameter, not a runtime gate. Selecting a different kernel between frames requires a profile switch and recompilation.
- **Frame-stable enables.** Toggling either enable mid-frame leaves the line buffers and output counters in whichever sub-stages were actively filling in an inconsistent state. Both gates are profile-stable in practice.
- **No `busy_o` exposure.** The composite assumes standard VGA-timed integration where every internal `busy_o` stays low. A high-throughput integration without blanking would need to unwrap the composite and surface each sub-stage's `busy_o`.
- **Edge replication is the only edge policy.** Inherited from `axis_window3x3<EDGE_REPLICATE>`; corner and border behaviour at each sub-stage follows the edge-replication rules documented in [`axis_window3x3-arch.md`](axis_window3x3-arch.md).

---

## 10. References

- [`axis_window3x3-arch.md`](axis_window3x3-arch.md) — Sliding-window primitive that backs every sub-stage: line buffers, phantom-cycle drain, blanking requirements, edge replication.
- [`sparevideo-top-arch.md`](sparevideo-top-arch.md) — Top-level pipeline; shows where the cleanup stage sits between `axis_motion_detect` and the mask broadcast feeding `axis_ccl` and the mask-display path.
- [`axis_ccl-arch.md`](axis_ccl-arch.md) §6.7 — Binding vblank cycle budget for the downstream CCL stage; the cleanup-stage latency fits comfortably inside it.
- **Soille, P. (2003). *Morphological Image Analysis: Principles and Applications* (2nd ed.), Springer.** §8.2 — alternating sequential filters and the algebra of compositions; theoretical basis for cascaded 3×3 stages building a 5×5 effective kernel.
- **Gonzalez, R. C. & Woods, R. E. (2018). *Digital Image Processing* (4th ed.), Pearson.** Chapter 9 — open-then-close as the canonical binary-mask cleanup pipeline.
- **OpenCV Background Subtraction tutorial** — [https://docs.opencv.org/4.x/db/d5c/tutorial_py_bg_subtraction.html](https://docs.opencv.org/4.x/db/d5c/tutorial_py_bg_subtraction.html) — practitioner-side justification for asymmetric open/close on motion masks.
