# VGA Frame-Alignment Encapsulation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the SOF-gating logic (`vga_started`/`vga_rst_n`) from `sparevideo_top` into `vga_controller`, giving the controller full ownership of its startup frame alignment.

**Architecture:** Add a `pixel_tuser_i` port to `vga_controller`; internally track `frame_seen` (a one-way latch that sets on the first `pixel_valid_i && pixel_tuser_i` beat); gate the h/v counters and `pixel_ready_o` on `frame_seen`. In `sparevideo_top`, drop the three local signals (`vga_started`, `vga_rst_n`, `vga_pixel_ready`), pass `rst_pix_n_i` directly to the VGA reset, wire `pix_out_tuser` to the new port, and connect `pixel_ready_o` directly to `pix_out_tready`.

**Tech Stack:** SystemVerilog, Verilator (lint + sim), Python reference models, `make` targets

---

### Task 1: Update `vga_controller.sv` — add `pixel_tuser_i` and `frame_seen`

**Files:**
- Modify: `hw/ip/vga/rtl/vga_controller.sv`

- [ ] **Step 1: Add the new port after `pixel_valid_i` (line 23 area)**

```sv
    input  logic        pixel_valid_i,   // upstream has pixel data
    input  logic        pixel_tuser_i,   // start-of-frame marker; frame_seen latches on first beat
    output logic        pixel_ready_o,   // controller accepting pixels (active area)
```

- [ ] **Step 2: Add `frame_seen` signal declaration after the `active` signal (around line 53)**

```sv
    // Active region flag
    logic active;
    // One-way latch: set on first SOF pixel, cleared only by reset
    logic frame_seen;
```

- [ ] **Step 3: Add the `frame_seen` always_ff block after the existing v_count block**

```sv
    // Frame alignment — hold counters at 0 until first SOF pixel
    always_ff @(posedge clk_i) begin
        if (!rst_n_i)
            frame_seen <= 1'b0;
        else if (!frame_seen && pixel_valid_i && pixel_tuser_i)
            frame_seen <= 1'b1;
    end
```

- [ ] **Step 4: Gate h_count on `frame_seen` (replace the existing h_count always_ff)**

```sv
    // Horizontal counter
    always_ff @(posedge clk_i) begin
        if (!rst_n_i || !frame_seen) begin
            h_count <= '0;
        end else if (h_count == ($bits(h_count))'(H_TOTAL - 1)) begin
            h_count <= '0;
        end else begin
            h_count <= h_count + 1'b1;
        end
    end
```

- [ ] **Step 5: Gate v_count on `frame_seen` (replace the existing v_count always_ff)**

```sv
    // Vertical counter
    always_ff @(posedge clk_i) begin
        if (!rst_n_i || !frame_seen) begin
            v_count <= '0;
        end else if (h_count == ($bits(h_count))'(H_TOTAL - 1)) begin
            if (v_count == ($bits(v_count))'(V_TOTAL - 1))
                v_count <= '0;
            else
                v_count <= v_count + 1'b1;
        end
    end
```

- [ ] **Step 6: Gate `pixel_ready_o` on `frame_seen` (replace line 85)**

```sv
    assign pixel_ready_o = active && frame_seen;
```

---

### Task 2: Update `sparevideo_top.sv` — remove the three local signals

**Files:**
- Modify: `hw/top/sparevideo_top.sv`

- [ ] **Step 1: Delete the shim comment block and local signal declarations (lines 507–527)**

Remove the entire block:
```sv
    // -----------------------------------------------------------------
    // axis-to-pixel shim + VGA-controller reset gating.
    //
    // Hold the VGA controller in reset until a start-of-frame pixel
    // arrives at the FIFO output (tuser=1). This ensures the VGA
    // begins on a frame boundary.
    // -----------------------------------------------------------------
    logic vga_rst_n;
    logic vga_started;
    logic vga_pixel_ready;

    always_ff @(posedge clk_pix_i) begin
        if (!rst_pix_n_i) begin
            vga_started <= 1'b0;
        end else if (!vga_started && pix_out_tvalid && pix_out_tuser) begin
            vga_started <= 1'b1;
        end
    end

    assign vga_rst_n      = rst_pix_n_i & vga_started;
    assign pix_out_tready = vga_pixel_ready & vga_started;
```

- [ ] **Step 2: Replace the `u_vga` instantiation with the updated version**

```sv
    vga_controller #(
        .H_ACTIVE      (H_ACTIVE),
        .H_FRONT_PORCH (H_FRONT_PORCH),
        .H_SYNC_PULSE  (H_SYNC_PULSE),
        .H_BACK_PORCH  (H_BACK_PORCH),
        .V_ACTIVE      (V_ACTIVE),
        .V_FRONT_PORCH (V_FRONT_PORCH),
        .V_SYNC_PULSE  (V_SYNC_PULSE),
        .V_BACK_PORCH  (V_BACK_PORCH)
    ) u_vga (
        .clk_i         (clk_pix_i),
        .rst_n_i       (rst_pix_n_i),
        // Streaming pixel input (from output async FIFO, clk_pix domain)
        .pixel_data_i  (pix_out_tdata),
        .pixel_valid_i (pix_out_tvalid),
        .pixel_tuser_i (pix_out_tuser),
        .pixel_ready_o (pix_out_tready),
        // Synchronization outputs to upstream
        .frame_start_o (),
        .line_start_o  (),
        // VGA output
        .vga_hsync_o   (vga_hsync_o),
        .vga_vsync_o   (vga_vsync_o),
        .vga_r_o       (vga_r_o),
        .vga_g_o       (vga_g_o),
        .vga_b_o       (vga_b_o)
    );
```

---

### Task 3: Lint and integration test

- [ ] **Step 1: Run lint**

```bash
make lint
```
Expected: exits 0, no errors or new warnings related to `vga_controller` or `sparevideo_top`.

- [ ] **Step 2: Run passthrough pipeline (zero-tolerance)**

```bash
make run-pipeline CTRL_FLOW=passthrough TOLERANCE=0
```
Expected: verify step exits 0, all frames match.

- [ ] **Step 3: Run motion pipeline**

```bash
make run-pipeline CTRL_FLOW=motion
```
Expected: exits 0.

- [ ] **Step 4: Commit RTL changes**

```bash
git add hw/ip/vga/rtl/vga_controller.sv hw/top/sparevideo_top.sv
git commit -m "refactor(vga): move frame-alignment into vga_controller

vga_started/vga_rst_n logic removed from sparevideo_top.
vga_controller gains pixel_tuser_i port and frame_seen register.
Counters and pixel_ready_o are gated on frame_seen so (0,0) aligns
with the first SOF pixel regardless of upstream pipeline latency."
```

---

### Task 4: Update `vga_controller-arch.md`

**Files:**
- Modify: `docs/specs/vga_controller-arch.md`

- [ ] **Step 1: Add `pixel_tuser_i` to the port table in §3.2**

In the streaming pixel input section of the table, add after `pixel_valid_i`:
```markdown
| `pixel_tuser_i` | input | 1 | Start-of-frame marker; `frame_seen` latches on the first `pixel_valid_i && pixel_tuser_i` beat |
```

Also update the `rst_n_i` row description — remove "held until first SOF in `sparevideo_top`", replace with "Active-low synchronous reset":
```markdown
| `rst_n_i` | input | 1 | Active-low synchronous reset |
```

- [ ] **Step 2: Renumber §5.5 Resource cost → §5.6, and insert new §5.5 Frame alignment**

Add before the old §5.5 (Resource cost):
```markdown
### 5.5 Frame alignment

A `frame_seen` flip-flop holds the counters at `(0, 0)` and forces `pixel_ready_o = 0`
until the first start-of-frame pixel arrives (`pixel_valid_i && pixel_tuser_i`). This
guarantees that counter origin `(0, 0)` coincides with the first pixel of a frame,
regardless of how long the upstream pipeline takes to produce its first output.

Counters are gated by extending their reset branch:

```
if (!rst_n_i || !frame_seen) h_count <= '0;
```

`frame_seen` is a one-way latch: it sets on the first SOF beat and only clears on `rst_n_i`.

### 5.6 Resource cost
```

- [ ] **Step 3: Update §6 Control Logic**

Replace:
```
No FSM. The only state is `h_count` and `v_count`. All other outputs are combinational or directly registered from counter comparisons.
```
With:
```
No FSM. The state consists of `h_count`, `v_count`, and `frame_seen`. All other outputs are combinational or directly registered from counter comparisons. `frame_seen` is a one-way latch — it sets on the first `pixel_valid_i && pixel_tuser_i` beat and only clears on reset.
```

- [ ] **Step 4: Update §9 Known Limitations**

Remove the bullet:
```
- **`rst_n_i` held externally**: `sparevideo_top` keeps `rst_n_i` deasserted until the first SOF pixel exits the output FIFO (`vga_started` logic). If the VGA controller is reset mid-stream (e.g., mid-frame), the counters restart from 0 immediately, causing a partial frame of corruption.
```

Add:
```
- **`frame_seen` clears on reset**: if `rst_n_i` is asserted mid-stream, `frame_seen` clears and the controller stalls `pixel_ready_o` until the next SOF pixel. Any partial-frame data held in the upstream FIFO will be consumed only after the FIFO is refilled to a SOF boundary.
```

- [ ] **Step 5: Commit doc update**

```bash
git add docs/specs/vga_controller-arch.md
git commit -m "docs(vga): document frame_seen alignment port and behavior"
```

---

### Task 5: Update `sparevideo-top-arch.md`

**Files:**
- Modify: `docs/specs/sparevideo-top-arch.md`

- [ ] **Step 1: Remove item 8 from §5.1 Submodule roles**

Delete the line:
```
8. **vga_rst_n gating**: the VGA controller is held in reset until the first `tuser=1` pixel exits `u_fifo_out`. This aligns the VGA scan to a frame boundary regardless of FIFO fill time.
```

Renumber item 9 (`u_vga`) to item 8.

- [ ] **Step 2: Add frame-alignment note to §6 Clock Domains**

Append to the end of §6:
```markdown
> **VGA frame alignment:** `u_vga` holds its h/v counters at (0, 0) and keeps `pixel_ready_o = 0` until the first `tuser=1` pixel exits `u_fifo_out`. This is handled internally by `vga_controller` via its `pixel_tuser_i` port — see [vga_controller-arch.md](vga_controller-arch.md) §5.5.
```

- [ ] **Step 3: Commit doc update**

```bash
git add docs/specs/sparevideo-top-arch.md
git commit -m "docs(top): move vga frame-alignment note from submodule list to clock domains"
```
