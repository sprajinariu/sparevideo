# AXI-Stream as SystemVerilog `interface` — design

Date: 2026-04-27

## Goal

Replace the project's flat AXI4-Stream port style (`s_axis_tdata_i`, `s_axis_tvalid_i`, ...) with a SystemVerilog `interface` (`axis_if`) on every AXI-Stream-bearing module. Promote the `axis_ccl` → `axis_overlay_bbox` bbox sideband to its own `bbox_if` interface. Convert all unit and integration testbenches to match. Formally retire Icarus Verilog support, which has been documented as unmaintained for some time and which cannot compile the resulting code (Verilator handles SV interfaces fine; this is the project's required and only supported simulator).

The conversion is mechanical — module bodies do not change shape, all stall-correctness invariants documented in `CLAUDE.md` carry through unchanged. The win is at module signatures: a 13-port AXI-Stream module collapses to 4–5 ports, future protocol additions (e.g. a `tkeep` field, a TID, a new sideband signal) become a single edit on the interface declaration rather than a sweep across every module signature in the chain.

## Decisions (settled during brainstorming)

1. **Scope: full conversion.** Every AXI-Stream port across `hw/ip/**/rtl/*.sv` and `hw/top/sparevideo_top.sv` switches to the interface. The two coexist styles approach was rejected — the interface only pays off when both ends speak it.
2. **Vendored adapter location: `hw/ip/axis/`.** Only one vendored module is instantiated (`axis_async_fifo`, twice in `sparevideo_top.sv`). A single thin wrapper (`axis_async_fifo_ifc`) handles the flat-port translation; the vendored core is untouched.
3. **Sideband `bbox` bundle: promoted to `bbox_if`.** Same hygiene benefits as `axis_if`. Used only by the one producer/consumer pair, but the user wants the unified bundle convention.
4. **Modport convention: `tx` / `rx` / `mon`.** Applied uniformly to both `axis_if` and `bbox_if`. Matches the recent `axis_hflip` `RECV/XMIT → RX/TX` rename, terse at instantiation, generalizes to any data-flow bundle. (Considered: `producer/consumer/mon`, `src/snk/mon`, `initiator/target/mon`. tx/rx wins on terseness + project consistency.)
5. **Minimal `axis_if`: tdata, tvalid, tready, tlast, tuser.** Exactly what the project uses today. `USER_W` parameterized (default 1 to match the SOF semantics every existing stage uses). `tkeep`/`tdest`/`tid` are NOT pre-added — add them when an actual consumer needs them.
6. **`clk` / `rst_n` stay outside the interface.** Preserves the project's `clk_i` / `rst_n_i` port convention and avoids ambiguity at CDC bridges (one interface bundle, two clocks at its endpoints).
7. **Convert all testbenches.** Mixed flat/interface TB style was rejected. The `drv_*` + negedge-driver pattern documented in `CLAUDE.md` is preserved unchanged (it's about *when* DUT inputs land, not the port style).
8. **Hard-remove Icarus.** Drop the unmaintained Icarus Makefile branch, `iverilog` from apt install, the `(wall-clock N/A on Icarus)` strings in `tb_sparevideo.sv`, and the README/CLAUDE references.
9. **Naming hygiene for `axis_window3x3` / `axis_gauss3x3`: deferred.** These modules use a window-style internal protocol (`valid_i`/`stall_i`/`sof_i`/`busy_o`), not AXI-Stream. The `axis_` prefix is misleading and should be renamed in a follow-up plan; out of scope for this one to keep focus tight.

## Interface definitions — `hw/top/sparevideo_if.sv`

Single file, two `interface` declarations as siblings. Mirrors the one-file pattern of `sparevideo_pkg.sv`.

```sv
// Project-wide SystemVerilog interfaces.
//
// Two top-level interface declarations live in this single file, mirroring the
// one-file pattern of sparevideo_pkg.sv. Both interfaces follow a uniform
// modport convention:
//
//   tx  — produces the bundle (drives data, reads back-pressure where present)
//   rx  — consumes the bundle (reads data, drives back-pressure where present)
//   mon — passive observer (all signals input); for testbench monitors
//
// Convention: clk/rst_n are NOT carried inside the interface. They remain
// explicit clk_i/rst_n_i ports on every module so that
//   (a) the project's existing port-naming convention is preserved, and
//   (b) a single interface bundle can cross a clock domain (e.g. the producer
//       is in clk_pix and the consumer in clk_proc, with axis_async_fifo_ifc
//       between them) without ambiguity about which clock owns the interface.

// AXI4-Stream — minimal subset used by this project (tdata, tvalid, tready,
// tlast, tuser). Add tkeep / tdest / tid here when an actual consumer needs
// them; do not pre-add. USER_W defaults to 1 to match the SOF semantics used
// by every current AXI-Stream stage in the pipeline.
interface axis_if #(
    parameter int DATA_W = 24,
    parameter int USER_W = 1
);
    logic [DATA_W-1:0] tdata;
    logic              tvalid;
    logic              tready;
    logic              tlast;
    logic [USER_W-1:0] tuser;

    modport tx  (output tdata, tvalid, tlast, tuser, input  tready);
    modport rx  (input  tdata, tvalid, tlast, tuser, output tready);
    modport mon (input  tdata, tvalid, tready, tlast, tuser);
endinterface

// Sideband bbox bundle from axis_ccl to axis_overlay_bbox. N_OUT slots, each
// with a valid bit and four coordinates. Latched per-frame, not per-beat —
// hence no handshake signals on this interface.
interface bbox_if #(
    parameter int N_OUT = sparevideo_pkg::CCL_N_OUT,
    parameter int H_W   = $clog2(sparevideo_pkg::H_ACTIVE),
    parameter int V_W   = $clog2(sparevideo_pkg::V_ACTIVE)
);
    logic [N_OUT-1:0]           valid;
    logic [N_OUT-1:0][H_W-1:0]  min_x;
    logic [N_OUT-1:0][H_W-1:0]  max_x;
    logic [N_OUT-1:0][V_W-1:0]  min_y;
    logic [N_OUT-1:0][V_W-1:0]  max_y;

    modport tx  (output valid, min_x, max_x, min_y, max_y);
    modport rx  (input  valid, min_x, max_x, min_y, max_y);
    modport mon (input  valid, min_x, max_x, min_y, max_y);
endinterface
```

## Vendored adapter — `hw/ip/axis/rtl/axis_async_fifo_ifc.sv`

Thin wrapper around the vendored `verilog-axis` `axis_async_fifo`. Adapts both flat ports → interface bundles and active-high `s_rst`/`m_rst` → project-convention `s_rst_n`/`m_rst_n`. Status-depth ports exposed even though the project doesn't currently use them — anticipated future use, and adding them now is one line each.

```sv
// Interface-port wrapper around the vendored verilog-axis axis_async_fifo.
// The vendored core uses flat ports and active-high reset; this wrapper
// adapts both to the project conventions (interface bundles + active-low
// rst_n_i) without modifying the vendored source.

module axis_async_fifo_ifc #(
    parameter int DEPTH          = 1024,
    parameter int DATA_W         = 24,
    parameter int USER_W         = 1,
    parameter int RAM_PIPELINE   = 2,
    parameter bit FRAME_FIFO     = 1'b0,
    parameter bit DROP_BAD_FRAME = 1'b0,
    parameter bit DROP_WHEN_FULL = 1'b0
) (
    input  logic                       s_clk,
    input  logic                       s_rst_n,
    input  logic                       m_clk,
    input  logic                       m_rst_n,

    axis_if.rx                         s_axis,
    axis_if.tx                         m_axis,

    // Status / occupancy. Width follows the vendored core ($clog2(DEPTH)+1).
    // Note (per CLAUDE.md): these depths do NOT include the internal output
    // pipeline FIFO (~16 entries with default RAM_PIPELINE=2). Do not use
    // them as the sole signal for tight back-pressure thresholds.
    output logic [$clog2(DEPTH):0]     s_status_depth,
    output logic [$clog2(DEPTH):0]     m_status_depth
);

    // Adapt project-convention active-low reset to the vendored active-high.
    logic s_rst, m_rst;
    assign s_rst = ~s_rst_n;
    assign m_rst = ~m_rst_n;

    axis_async_fifo #(
        .DEPTH         (DEPTH),
        .DATA_WIDTH    (DATA_W),
        .USER_ENABLE   (1),
        .USER_WIDTH    (USER_W),
        .RAM_PIPELINE  (RAM_PIPELINE),
        .FRAME_FIFO    (FRAME_FIFO),
        .DROP_BAD_FRAME(DROP_BAD_FRAME),
        .DROP_WHEN_FULL(DROP_WHEN_FULL)
    ) u_fifo (
        .s_clk          (s_clk),
        .s_rst          (s_rst),
        .s_axis_tdata   (s_axis.tdata),
        .s_axis_tvalid  (s_axis.tvalid),
        .s_axis_tready  (s_axis.tready),
        .s_axis_tlast   (s_axis.tlast),
        .s_axis_tuser   (s_axis.tuser),
        .s_status_depth (s_status_depth),

        .m_clk          (m_clk),
        .m_rst          (m_rst),
        .m_axis_tdata   (m_axis.tdata),
        .m_axis_tvalid  (m_axis.tvalid),
        .m_axis_tready  (m_axis.tready),
        .m_axis_tlast   (m_axis.tlast),
        .m_axis_tuser   (m_axis.tuser),
        .m_status_depth (m_status_depth)
    );

endmodule
```

## RTL conversion list (9 files)

| File | Streams | Notes |
|---|---|---|
| `hw/ip/axis/rtl/axis_fork.sv` | 1× rx, 2× tx | broadcast utility |
| `hw/ip/hflip/rtl/axis_hflip.sv` | 1× rx, 1× tx | DATA_W=24 |
| `hw/ip/filters/rtl/axis_morph3x3_erode.sv` | 1× rx, 1× tx | DATA_W=1 |
| `hw/ip/filters/rtl/axis_morph3x3_dilate.sv` | 1× rx, 1× tx | DATA_W=1 |
| `hw/ip/filters/rtl/axis_morph3x3_open.sv` | 1× rx, 1× tx | DATA_W=1 |
| `hw/ip/motion/rtl/axis_motion_detect.sv` | 1× rx (24-bit RGB), 1× tx (1-bit mask) | mixed widths |
| `hw/ip/ccl/rtl/axis_ccl.sv` | 1× rx (mask), 1× **bbox_if.tx** | new sideband interface |
| `hw/ip/overlay/rtl/axis_overlay_bbox.sv` | 1× rx (RGB), 1× tx (RGB), 1× **bbox_if.rx** | |
| `hw/top/sparevideo_top.sv` | many — full reweave | declares `axis_if` instances; instances `axis_async_fifo_ifc`, `axis_fork`, every IP |

### Stays as-is (3 files — non-AXI-Stream)

| File | Actual protocol |
|---|---|
| `hw/ip/window/rtl/axis_window3x3.sv` | window-style: `valid_i`/`sof_i`/`stall_i`/`busy_o`. Back-pressure direction inverted vs AXI-Stream (caller drives `stall_i` INTO the module). No `tlast`. |
| `hw/ip/filters/rtl/axis_gauss3x3.sv` | window-style (thin wrapper over `axis_window3x3`) |
| `hw/ip/motion/rtl/motion_core.sv` | pure combinational, no streams |

### Conversion mechanics (uniform across all 9)

- Replace each `s_axis_tdata_i` / `s_axis_tvalid_i` / `s_axis_tready_o` / `s_axis_tlast_i` / `s_axis_tuser_i` group with one `axis_if.rx s_axis` port. Symmetric for `m_axis_*` → `axis_if.tx m_axis`.
- Body: `s_axis_tdata_i` → `s_axis.tdata`, `m_axis_tvalid_o` → `m_axis.tvalid`, etc. Pure rename — no logic changes.
- `bbox_if` analogous for the `axis_ccl` → `axis_overlay_bbox` sideband (`bbox_valid_i` → `bboxes.valid`, `bbox_min_x_i` → `bboxes.min_x`, etc.).
- `clk_i` / `rst_n_i` ports unchanged.
- Scalar parameters (DATA_W, USER_W, H_ACTIVE, etc.) set on the `axis_if #(...) u_xxx ()` declaration site (typically `sparevideo_top.sv`), not on the consuming module's port.
- Stall-correctness invariants from `CLAUDE.md` ("Pipeline stall pitfalls" §1–6) and the `axis_ccl` tready-deassert during the EOF FSM apply unchanged — they are behavioral, not structural.

## Testbench conversion list

### Converts (7 unit + 1 integration)

| File |
|---|
| `hw/ip/ccl/tb/tb_axis_ccl.sv` |
| `hw/ip/filters/tb/tb_axis_morph3x3_dilate.sv` |
| `hw/ip/filters/tb/tb_axis_morph3x3_erode.sv` |
| `hw/ip/filters/tb/tb_axis_morph3x3_open.sv` |
| `hw/ip/hflip/tb/tb_axis_hflip.sv` |
| `hw/ip/motion/tb/tb_axis_motion_detect.sv` |
| `hw/ip/overlay/tb/tb_axis_overlay_bbox.sv` |
| `dv/sv/tb_sparevideo.sv` |

### Stays as-is

`hw/ip/filters/tb/tb_axis_gauss3x3.sv` — DUT (`axis_gauss3x3`) is window-style.

### Conversion mechanics

The `drv_*` pattern is preserved exactly. Only the assignment target changes:

```sv
// before:
always_ff @(negedge clk) begin
    s_axis_tdata  <= drv_tdata;
    s_axis_tvalid <= drv_tvalid;
end
dut u_dut ( .s_axis_tdata_i (s_axis_tdata), .s_axis_tvalid_i (s_axis_tvalid), ... );

// after:
axis_if #(.DATA_W(24), .USER_W(1)) s_axis ();

always_ff @(negedge clk) begin
    s_axis.tdata  <= drv_tdata;
    s_axis.tvalid <= drv_tvalid;
end
dut u_dut ( .s_axis (s_axis), ... );
```

Output capture (`cap_*` regs sampled on negedge from `m_axis.tdata` etc.) follows the same pattern. Symmetric and asymmetric stall test patterns from `CLAUDE.md` ("Unit-test fork consumer stalls explicitly") carry through unchanged.

## `.core` file updates (FuseSoC)

- `sparevideo_top.core` — add `hw/top/sparevideo_if.sv` to the file list.
- `hw/ip/axis/axis.core` — add `hw/ip/axis/rtl/axis_async_fifo_ifc.sv`. Cross-IP dependency: every IP fileset transitively needs `sparevideo_if.sv` to declare its port types. Cleanest split (to be finalized in the implementation plan): `sparevideo_if.sv` belongs in a base / top fileset that all IPs already depend on (same as `sparevideo_pkg.sv`). If the existing `.core` graph doesn't naturally accommodate that, the implementation plan resolves it.

## Documentation updates

### `CLAUDE.md`

| Where | Change |
|---|---|
| Line 29 | Drop "no interfaces/modports" from the prohibition list. Drop the "Icarus Verilog 12 compatibility" justification. Keep "no SVA assertions, no classes". |
| Line 182 | "Simulator: **Verilator only** for all required checks. Icarus commands exist..." → "Simulator: **Verilator only**." |
| Project Structure | Add `hw/top/sparevideo_if.sv` ("Project-wide SV interfaces: `axis_if`, `bbox_if`"). Add `axis_async_fifo_ifc` mention alongside `axis_fork` under `hw/ip/axis/rtl/`. |
| RTL Conventions | New bullet: "AXI-Stream ports use the `axis_if` interface (modports `tx`/`rx`/`mon`); the bbox sideband uses `bbox_if`. clk/rst stay as separate `clk_i`/`rst_n_i` ports." |
| RTL Conventions | New bullet: "`axis_window3x3` and `axis_gauss3x3` keep an internal window-style protocol (`valid_i`/`stall_i`/`sof_i`/`busy_o`) — the `axis_` prefix is historical and does NOT mean AXI-Stream." |

### `README.md`

Line 249: drop the "Icarus not maintained" parenthetical from the SIMULATOR row → just `verilator`.

### `docs/specs/` arch docs — port-table refresh only

Update the port-table sections in: `axis_ccl-arch.md`, `axis_hflip-arch.md`, `axis_morph3x3_open-arch.md`, `axis_motion_detect-arch.md`, `axis_overlay_bbox-arch.md`, `sparevideo-top-arch.md`.

Stay as-is: `axis_gauss3x3-arch.md`, `axis_window3x3-arch.md` (window-style; not AXI-Stream).

No new arch docs — the interface file's header comments and the wrapper's inline notes carry the contract.

## Icarus removal

| File | Action |
|---|---|
| `Makefile:74` | Drop "or icarus" from the help text. |
| `Makefile:171` | Drop `iverilog` from `apt install`. |
| `dv/sim/Makefile:48–116` | Delete the entire `ifeq ($(SIMULATOR),icarus)` branch and the unknown-simulator error referencing icarus. |
| `dv/sv/tb_sparevideo.sv:379, 382` | Drop "(wall-clock N/A on Icarus)" parentheticals from `$display` strings. |
| `hw/ip/vga/rtl/pattern_gen.sv:76` | Leave the comment ("avoids Icarus part-select warning") in place — the construct is still valid SV and the comment is harmless historical context. |

## Cleanup

`rm -rf experiments/sv_interface/` — superseded by the real implementation.

## Out of scope

- **Window-style → AXI-Stream conversion of `axis_window3x3` / `axis_gauss3x3`.** Different protocol contract (back-pressure direction, `tlast` reconstruction, `busy_o` semantics); meaningful redesign with regression risk. Worth its own plan if pursued.
- **Renaming `axis_window3x3` / `axis_gauss3x3` to drop the misleading prefix.** Tangential cleanup; defer to a small follow-up plan.
- **Adding `tkeep` / `tdest` / `tid` to `axis_if`.** No consumer needs them today.

## Verification gates

The conversion is complete and ready to merge when:

1. `make lint` is clean (no Verilator warnings).
2. `make test-ip` passes for every per-IP unit testbench (the converted seven plus the unchanged `tb_axis_gauss3x3`).
3. `make run-pipeline` passes at TOLERANCE=0 for the matrix:
   - 4 control flows: `passthrough`, `motion`, `mask`, `ccl_bbox`
   - 5 profiles: `default`, `default_hflip`, `no_ema`, `no_morph`, `no_gauss`
   - At least 2 sources covering the EMA / morph / hflip behavior (e.g. `synthetic:moving_box`, `synthetic:noisy_moving_box`).
4. The `experiments/sv_interface/` directory is removed.
5. The two `axis_async_fifo_ifc` instances in `sparevideo_top.sv` produce identical waveforms to the pre-refactor flat-port instances under the same input vectors (sanity check; the underlying core is unchanged).

## Branch + commit hygiene (per `CLAUDE.md`)

- New branch off `origin/main` (after fetch). Suggested name: `refactor/axis-sv-interface`.
- One squashed commit at plan completion.
- After implementation lands, move this design doc to `docs/plans/old/2026-04-27-axis-sv-interface-design.md` (date stamp preserved).
