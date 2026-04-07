# Move pipeline to AXI4-Stream

## Context

`sparesoc_top` is currently a single-clock RGB-plus-sync passthrough with an ad-hoc signal bundle (`vid_i_data`, `vid_i_valid`, `vid_i_hsync`, `vid_i_vsync`). Every downstream addition — CDC, FIFOs, arbiters, new pipeline blocks — would need to re-invent the wheel against this non-standard interface. Moving to AXI4-Stream now pays for itself immediately because we can vendor a well-tested open-core library and stop writing handshake logic by hand.

## Goals

- Rework the pipeline architecture around AXI4-Stream signalling.
- Vendor well-tested open-source AXI4-Stream IP (FIFOs, register slices, etc.) rather than writing them from scratch.
- Exercise real clock-domain crossing by running processing on a faster `clk_dsp` than the pixel clock.
- Instantiate the retained `hw/ip/vga/rtl/vga_controller.sv` inside `sparesoc_top` so the DUT owns the full stream→display path.

## Non-Goals

- Real video processing (FPN/PRNU, motion detection, bbox overlay — that lives in `arch_thoughts__axi4-stream_video_motion_detection.md`).
- Multi-port frame buffer RAM with arbitration (deferred; see "Open Questions" below).
- Independent input and output pixel clocks (deferred; both share `clk_pix` for now).
- Switching simulator from Icarus to Verilator (tracked separately in `prio2_switch_from_icarus_to_verilator.md`).

## Target Architecture

```
TB --axis(clk_pix)--> async_fifo --> proc_chain (clk_dsp) --> async_fifo --axis(clk_pix)--> vga_controller --RGB+hsync/vsync--> TB
```

- `clk_pix` = 25 MHz (input axi4s + VGA output domain)
- `clk_dsp` = 100 MHz (processing domain)
- Dummy processing: a 4-stage register-slice chain on `clk_dsp` to add measurable latency without doing anything functional.
- Starts with two clocks (not three) to keep the TB simple while still exercising real CDC. Splitting input/output into independent 25 MHz domains can follow later.

## IP Vendoring

**Choice: `alexforencich/verilog-axis`** (MIT, pure Verilog-2001, Icarus 12-compatible).

### Why not `fpganinja/taxi`?
`taxi` is the author's declared successor to `verilog-axis` and is under active development, but it is disqualified here for two independent reasons:

1. **Language.** `taxi` is SystemVerilog and uses interfaces and modports. Icarus Verilog 12 does not support SV interfaces/modports, so the files will not parse. Switching to Verilator as the simulator would unblock this — but that's a separate plan and not in scope here.
2. **License.** `taxi` is CERN-OHL-S 2.0 (strongly reciprocal). `verilog-axis` is MIT. MIT is the better fit for this repo's Apache-2.0 code.

`verilog-axis`'s own README explicitly marks itself as deprecated in favor of `taxi`, but "deprecated" here means "no new features" — the existing modules are stable, well-tested, and exactly what we need. Revisit this decision if and when we migrate the simulator.

### What to vendor
Vendor the **entire `rtl/` folder** (~32 Verilog-2001 files), not just the two modules we'll wire up immediately. The folder is self-contained (no external dependencies) and small; having the full library available unblocks future work (width adapters, arbiters, muxes, frame-length adjusters) without a second vendoring round.

Layout:
```
third_party/verilog-axis/
  LICENSE                # MIT, copied verbatim from upstream
  README.md              # source URL, pinned commit SHA, file list
  COMMIT                 # upstream commit SHA on one line (for audit)
  rtl/
    axis_*.v             # ~28 axis modules
    arbiter.v            # shared utility
    priority_encoder.v   # shared utility
    sync_reset.v         # shared utility
verilog-axis.core        # FuseSoC core (VLNV: sparevideo:third_party:verilog-axis)
```

### VLNV namespace
All new FuseSoC cores use the `sparevideo:*` namespace (this repo's own). This plan does NOT introduce any new `opensoc:*` references.

The existing `sparevideo_top.core` and `hw/ip/vga/vga.core` currently use `opensoc:*` names (carry-over from another project). Renaming those is worth doing but is intentionally out of scope here to keep the diff focused — it can be a small follow-up PR.

### Lint handling
Vendored files must not fail Verilator lint. Add `hw/lint/third_party_waiver.vlt` that lint-waives everything under `third_party/`. We don't own the code, we shouldn't be policing its style.

### Modules actually instantiated in this PR
- `rtl/axis_async_fifo.v` — CDC FIFO (gray-coded pointers, 2FF synchronizers). Used twice: `clk_pix → clk_dsp`, `clk_dsp → clk_pix`. `DEPTH=32`, `DATA_WIDTH=24`, `USER_WIDTH=1`, `LAST_ENABLE=1`.
- `rtl/axis_register.v` — register slice used as the 4-stage dummy processing pipeline on `clk_dsp`.

The other ~30 files ride along as available-but-unused library.

## RTL Changes

### `hw/top/sparesoc_top.sv` — full rewrite

```systemverilog
module sparesoc_top (
    input  logic        clk_pix,         // 25 MHz pixel clock (in + out)
    input  logic        clk_dsp,         // 100 MHz processing clock
    input  logic        rst_pix_n,
    input  logic        rst_dsp_n,

    // AXI4-Stream video input (clk_pix domain)
    input  logic [23:0] s_axis_tdata,    // {R, G, B}
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,    // end-of-line
    input  logic        s_axis_tuser,    // bit 0 = start-of-frame

    // VGA output (clk_pix domain)
    output logic        vga_hsync,
    output logic        vga_vsync,
    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b
);
```

Internals:
- `u_fifo_in` : `axis_async_fifo`, `S_CLK=clk_pix`, `M_CLK=clk_dsp`.
- `u_proc_chain` : 4-stage chain of `axis_register` on `clk_dsp`.
- `u_fifo_out` : `axis_async_fifo`, `S_CLK=clk_dsp`, `M_CLK=clk_pix`.
- `u_vga` : existing `vga_controller` from `hw/ip/vga/rtl/vga_controller.sv`, parameterised to the same small blanking values the TB currently uses (H: 4+8+4, V: 2+2+2) to keep sim fast.
- Inline `axis_to_pixel` shim (~20 lines, combinational) that converts the output-side axi4s handshake into the VGA controller's existing `pixel_data/pixel_valid/pixel_ready` interface. No new module file.

### `sparevideo_top.core`
Add dependencies on the VGA core and on `sparevideo:third_party:verilog-axis`. Update `files_rtl` to include the new top.

### `hw/lint/third_party_waiver.vlt`
New file that lint-waives the vendored tree.

### Nothing deleted
`hw/ip/vga/rtl/pattern_gen.sv` stays (unused but harmless).

## Testbench Changes

`dv/sv/tb_sparevideo.sv` rewritten around the new interface:

- **Two clocks.** Add `clk_dsp` at 100 MHz (`#5` half-period) alongside `clk_pix` at 25 MHz (`#20` half-period).
- **Drive AXI4-Stream, not VGA timing.** The main stimulus loop reads a pixel from the input file and drives `s_axis_tdata/tvalid`, respecting `s_axis_tready` backpressure. `tuser` asserted on the first pixel of each frame; `tlast` asserted on the last pixel of each line. No more `vid_i_hsync`/`vid_i_vsync` generation.
- **Capture VGA output, not axi4s.** The output-side capture block samples `vga_hsync/vga_vsync/vga_r/vga_g/vga_b` on the pixel clock, extracts pixels from the active region, and writes them to the output file in the same text/binary format the Python harness already consumes.
- **`sw_dry_run` path** unchanged (pure file I/O, no DUT).
- **Per-frame wall-clock printing** preserved.
- **Watchdog** timeout recalculated for the new frame duration (`H_TOTAL × V_TOTAL` cycles of `clk_pix`).

AXI4-Stream driver and VGA capture implemented as plain SystemVerilog `task` blocks inside the testbench. No cocotb, no Python-side changes.

## Clocks and Reset

- `clk_pix` = 25 MHz, `clk_dsp` = 100 MHz.
- Two synchronous resets, one per domain: `rst_pix_n` and `rst_dsp_n`.
- `axis_async_fifo` handles CDC reset internally — no external reset synchronizer needed.
- TB deasserts both resets after 10 cycles of the slower clock.

## File Checklist

| Path | Action |
|---|---|
| `third_party/verilog-axis/LICENSE` | new (vendored MIT) |
| `third_party/verilog-axis/README.md` | new (source URL + pinned commit + file list) |
| `third_party/verilog-axis/COMMIT` | new (upstream commit SHA) |
| `third_party/verilog-axis/rtl/*.v` | new (full vendored folder, ~32 files) |
| `hw/lint/third_party_waiver.vlt` | new (lint-waives `third_party/`) |
| `verilog-axis.core` | new (FuseSoC wrapper) |
| `hw/top/sparesoc_top.sv` | rewrite |
| `sparevideo_top.core` | add deps on VGA + verilog-axis |
| `dv/sv/tb_sparevideo.sv` | rewrite (keeps `sw_dry_run` path) |
| `CLAUDE.md` | update Project Overview + Project Structure |
| `README.md` | update structure tree + design interface block |

## Verification

Existing regression (`make lint`, `make compile`, `make sw-dry-run`, `make test-py`, `make run-pipeline` with text + binary + gradient variants) is the acceptance bar:

1. `make lint` passes with no new warnings. Vendored files lint-waived via `third_party_waiver.vlt`.
2. `make compile` succeeds under Icarus 12 against the new `sparesoc_top` + vendored FIFOs.
3. `make sw-dry-run` unaffected (pure file loopback).
4. `make run-pipeline` end-to-end passthrough passes **bit-exact** for `color_bars`, `gradient`, and binary mode. Passthrough is still passthrough, despite two FIFOs + 4 register stages of latency.
5. `make test-py` passes (Python untouched).
6. Manual sanity: open `dv/data/renders/comparison.png` and confirm input/output match visually.

CI workflow at `.github/workflows/regression.yml` needs no changes — it already runs all of the above.

## Risks

- **Bit-exactness under CDC.** Async FIFOs don't reorder, so passthrough should remain lossless. If output is off-by-one at line boundaries, expect the fix in the `axis_to_pixel` shim's handling of `tlast` around the VGA active-region transition.
- **Icarus compatibility of `axis_async_fifo.v`.** The file is pure Verilog-2001 but not personally verified under Icarus 12. If it trips on an unsupported construct, fall back to `dpretet/async_fifo` + a thin AXI4-Stream wrapper.
- **Simulation runtime.** Adding a 100 MHz clock multiplies event count. Keep blanking small and iterate with `FRAMES=2`.

## Open Questions / Deferred

- **Frame buffer RAM with multi-port arbitration.** Not needed yet — dummy processing is just pipeline stages. When we do need it (for real processing blocks), the short-list candidate is `alexforencich/verilog-axi/axi_ram.v`. FF-based is fine since we only care about simulation, but the multi-R/W and arbitration logic is what we actually want from digital.
- **Independent input vs output pixel clocks.** Both share `clk_pix` for now. Split when asymmetric-rate processing becomes real.
- **Renaming existing `opensoc:*` VLNV names to `sparevideo:*`.** Separate follow-up PR.

## Execution Order

1. Vendor the full `verilog-axis/rtl/` folder under `third_party/verilog-axis/`, copy LICENSE, write the README with pinned upstream commit SHA, add `third_party_waiver.vlt`, create `verilog-axis.core`. Confirm `fusesoc` sees the new core and `make lint` still passes against the untouched `sparesoc_top`.
2. Write the new `sparesoc_top.sv` with its inline `axis_to_pixel` shim. `make compile`.
3. Rewrite `tb_sparevideo.sv`. `make sim` with `FRAMES=1`, eyeball the output file.
4. Run the full regression (`make run-pipeline`, text + binary + gradient).
5. Update `CLAUDE.md` and `README.md`.
6. Open PR against `main`.
