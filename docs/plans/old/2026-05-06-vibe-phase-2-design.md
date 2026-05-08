# ViBe Phase 2 — Design Spec

**Date:** 2026-05-06
**Status:** Design only. Not yet implemented. The implementation plan that consumes this spec is the next artifact in the chain.
**Companion master design:** [`2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md) — see §3 datapath, §6 sample storage, §7 PRNG, §9 migration phasing.
**Companion contract spec:** [`2026-05-06-vibe-rtl-cfg-contract-design.md`](2026-05-06-vibe-rtl-cfg-contract-design.md) — `cfg_t` field-list trim that this phase implements.
**Phase 1 plan (now landed):** [`old/2026-05-06-vibe-phase-1-plan.md`](old/2026-05-06-vibe-phase-1-plan.md).

---

## 1. Scope

Phase 2 lands two deliverables in one PR per [contract spec §6](2026-05-06-vibe-rtl-cfg-contract-design.md):

1. **`cfg_t` contract trim.** 25 → 21 fields, Python-only field allowlist, parity-test refactor, profile fallout. Spec'd entirely in the contract design doc; this Phase 2 spec implements it without re-specifying.

2. **RTL ViBe block.** New `axis_motion_detect_vibe` + `motion_core_vibe` modules, a unit testbench, a per-module arch doc (`docs/specs/axis_motion_detect_vibe-arch.md`), top-level `bg_model` generate gate, and a Python helper for external-init ROM generation. This document is the design spec for that block.

The master design's §3/§6/§7 sections cover the algorithm, the BRAM layout, and the PRNG at the K=8 reference shape. This Phase 2 spec captures the deltas / decisions on top of that baseline:

- Parametric K ∈ {8, 20}
- External-init via `$readmemh`-loaded ROM file
- Multi-stream PRNG construction at K=20 (B1, see §3.2)
- Verification strategy across SV/Python parity for a stochastic algorithm
- Make integration for the ROM-generation helper

---

## 2. Module hierarchy

Mirror the EMA path's wrapper/core split:

| Module | Role |
|---|---|
| `axis_motion_detect_vibe.sv` | AXIS wrapper. Y-extract, optional Gauss pre-filter (reused), parameter unpacking, single-output backpressure shell, frame counter, instantiates one `motion_core_vibe`. |
| `motion_core_vibe.sv` | Algorithm core. Sample-bank BRAM, K parallel L1-distance comparators, match counter, Xorshift32 PRNG, per-pixel update + diffusion logic, defer-FIFO, init FSM. |

Wrapper holds the AXIS protocol; core holds the ViBe-specific datapath. Same shape as `axis_motion_detect` / `motion_core`, `axis_morph_clean`, `axis_overlay_bbox`. The split keeps the core unit-testable without AXIS plumbing.

External contract (both wrapper-level): one `axis_if` pixel input, one `axis_if` mask output. Identical to `axis_motion_detect` so the top-level `bg_model` generate gate is a substitution-principle swap with no downstream impact.

---

## 3. Sample storage & BRAM layout

### 3.1 Inherits master design §6 verbatim

For K=8: single dual-port BRAM, Port A READ_FIRST, Port B registered-write with byte-enables, 4-deep defer-FIFO for the ~0.4% joint-fire collision case. Already validated in Phase 0 against the upstream PyTorch reference.

### 3.2 Parametric extension to K=20

| Quantity | K=8 | K=20 |
|---|---|---|
| BRAM word width | 64 b | 160 b |
| Byte-enable width | 8 | 20 |
| BRAM bits at 320×240 | 4.92 Mb | 12.3 Mb |
| Init-time PRNG advances per pixel | 1 | 3 (multi-stream) |

Both widths instantiate as inferred dual-port BRAM; the synth tool cascades primitive 36-Kb BRAM tiles. No exotic SV.

### 3.3 Multi-stream PRNG at K=20 (option B1 from brainstorming)

Frame-0 self-init at K=20 needs 80 bits of noise jitter per pixel. Three options were considered:

- **B3 — chain a single Xorshift32 three times per pixel.** Cheapest, but has known serial correlation between consecutive outputs.
- **B2 — switch to Xorshift128.** Larger state, but still needs chaining for 80 bits at K=20. Doesn't actually solve the correlation issue.
- **B1 — three parallel Xorshift32 streams, different seeds.** Each advances once per pixel during frame 0. Streams have no analytically derivable correlation. Cost: 64 extra register bits + 2× combinational xorshift. **Selected.**

K=8 path is unchanged from master design §6.5 — single stream, slice 32 bits 8 ways.

K=20 stream seed construction (mirrored exactly in Python ref):

```sv
localparam logic [31:0] PRNG_SEED   = 32'hDEADBEEF;        // module parameter, default
localparam logic [31:0] SEED_INIT_0 = PRNG_SEED;
localparam logic [31:0] SEED_INIT_1 = PRNG_SEED ^ 32'h9E3779B9;  // golden-ratio constant
localparam logic [31:0] SEED_INIT_2 = PRNG_SEED ^ 32'hD1B54A32;  // arbitrary, fixed
```

The two extra streams are active only during frame 0 and only when `K == 20`. After frame 0, all PRNG decisions go through the single runtime stream (master design §7 — unchanged).

### 3.4 External-init path

When `vibe_bg_init_external == 1`, the BRAM is preloaded at elaboration:

```sv
if (vibe_bg_init_external) begin : g_external_init
    initial begin
        if (INIT_BANK_FILE == "")
            $error("vibe_bg_init_external=1 requires non-empty INIT_BANK_FILE");
        $readmemh(INIT_BANK_FILE, sample_bank);
    end
end
```

Self-init's frame-0 byte-enable is held at 0 in this mode (`init_be_active = (frame_count == 0) && !vibe_bg_init_external`). The two paths are mutually exclusive at elaboration.

**File format:**
- One BRAM word per line, raster-scan order (`addr 0 = (y=0, x=0)`, ..., `addr H*W-1 = (y=H-1, x=W-1)`).
- Each line: `8*K`-bit hex value, MSB-first matching SV `{slot_{K-1}, ..., slot_0}` concat. 16 hex chars/line at K=8, 40 at K=20.
- Standard `$readmemh` syntax — `//` comments and blank lines OK.
- Header comment line: `// width=W height=H K=K seed=0x... lookahead_n=N` for human inspection. Ignored by `$readmemh`.

No SV-side header validation. Make-target dependency tracking keeps the file in sync with the active CFG.

---

## 4. Pipeline & backpressure

### 4.1 Stage layout

| Stage | Cycle | Action |
|---|---|---|
| S0 | 0 | Accept AXIS pixel beat. Latch `held_tdata`. Issue Port-A read at `pix_addr`. |
| S1 | 1 | Samples land. K parallel L1-distance comparators run combinationally. PRNG advance + decision rolls. |
| S2 | 2 | `mask = (match_count < min_match)`. Compute Port-B write parameters, push diffusion to defer-FIFO if joint-fire. |
| S3 | 3 | AXIS-out beat valid. Port-B write commits. |

**Total wrapper-to-wrapper latency: 3 cycles.** Same as `axis_motion_detect`; the `bg_model` generate gate is latency-neutral, no downstream skid buffer needed.

The K parallel comparators are pure combinational on stage S1. Tree-reduce on `match_count` is `$clog2(K+1)` levels (4 for K=8, 5 for K=20). Single-cycle timing at 100 MHz is comfortable. If fmax becomes an issue post-synth, an S1→S1.5 split is a deferred optimization.

### 4.2 Backpressure — single-output stall

CLAUDE.md "AXI4-Stream pipeline stall — known pitfalls" applies in full:

1. `pipe_stall = mask_valid && !m_axis_msk_tready` gates every pipeline `always_ff`.
2. Live-input mux on Y: `y_in_pipe = pipe_stall ? held_tdata_y : s_axis_tdata_y`.
3. `pix_addr_hold` register, enable `!pipe_stall`, drives Port-A `mem_rd_addr` during stalls.
4. `mem_wr_en = pipe_valid && m_axis_msk_tready` — Port-B writes (and defer-FIFO drains) gated on the actual handshake.
5. Defer-FIFO push gated on `!pipe_stall` — joint-fire detection during a stall doesn't double-push.

**Critically:** the runtime PRNG must NOT advance during a stalled cycle. This is enforced by gating the PRNG state register on `!pipe_stall`. A stall that advances the PRNG would cause SV-vs-Python frame-N drift (Section 6 — verification).

### 4.3 sof/tuser gating

The optional Gauss pre-filter uses `axis_window3x3`, which already has the correct `sof_i && valid_i` gating. ViBe wrapper itself does not instantiate any sliding-window primitive directly — no new gating concerns.

---

## 5. Top-level integration

### 5.1 `bg_model` generate gate at `sparevideo_top.sv`

`CFG.bg_model` is a compile-time field. A `generate-if` selects exactly one motion block:

```sv
generate
    if (CFG.bg_model == BG_MODEL_EMA) begin : g_ema
        axis_motion_detect #(...) u_motion (.s_axis_pix(gauss_in), .m_axis_msk(msk_raw));
    end
    else if (CFG.bg_model == BG_MODEL_VIBE) begin : g_vibe
        axis_motion_detect_vibe #(
            .K                    (CFG.vibe_K),
            .R                    (CFG.vibe_R),
            .MIN_MATCH            (CFG.vibe_min_match),
            .PHI_UPDATE           (CFG.vibe_phi_update),
            .PHI_DIFFUSE          (CFG.vibe_phi_diffuse),
            .GAUSS_EN             (CFG.gauss_en),
            .VIBE_BG_INIT_EXTERNAL(CFG.vibe_bg_init_external),
            .PRNG_SEED            (32'hDEADBEEF),
            .INIT_BANK_FILE       (`VIBE_INIT_BANK_FILE)
        ) u_motion (.s_axis_pix(gauss_in), .m_axis_msk(msk_raw));
    end
    else begin : g_unknown
        initial $error("Unsupported CFG.bg_model = %0d", CFG.bg_model);
    end
endgenerate
```

Both blocks present the same external contract. Downstream morph/CCL/overlay sees no shape difference.

### 5.2 Compile-time validation

```sv
// vibe_K must be a Phase-2-supported value
generate
    if (CFG.bg_model == BG_MODEL_VIBE && CFG.vibe_K != 8 && CFG.vibe_K != 20)
        initial $error("vibe_K must be 8 or 20, got %0d", CFG.vibe_K);
endgenerate

// External-init requires a file path
generate
    if (CFG.bg_model == BG_MODEL_VIBE && CFG.vibe_bg_init_external && `VIBE_INIT_BANK_FILE == "")
        initial $error("vibe_bg_init_external=1 requires +define+VIBE_INIT_BANK_FILE=...");
endgenerate
```

### 5.3 `INIT_BANK_FILE` plumbing

The file path can't live in `cfg_t` (struct fields can't be SV strings). It's a Verilator `+define+` macro:

```sv
`ifndef VIBE_INIT_BANK_FILE
  `define VIBE_INIT_BANK_FILE ""
`endif
```

The Make target sets `+define+VIBE_INIT_BANK_FILE=$(DV_DATA_DIR)/init_bank.mem` when the active CFG has `vibe_bg_init_external=1`. Otherwise the default empty string flows through and the wrapper's self-init path runs.

### 5.4 `motion.core` (FuseSoC) updates

Add the new files to the existing `motion.core`:

```yaml
filesets:
  rtl:
    files:
      - hw/ip/motion/rtl/axis_motion_detect.sv
      - hw/ip/motion/rtl/motion_core.sv
      - hw/ip/motion/rtl/axis_motion_detect_vibe.sv  # NEW
      - hw/ip/motion/rtl/motion_core_vibe.sv         # NEW
    file_type: systemVerilogSource
```

Unit TB lands in a separate fileset/target so `make test-ip` picks it up.

---

## 6. Verification

### 6.1 Layer 1 — unit testbench

`hw/ip/motion/tb/tb_axis_motion_detect_vibe.sv`. Picked up by `make test-ip`. Drives the DUT directly via `axis_if`.

| # | Scenario | K | Init mode | Source frames | Pass criterion |
|---|---|---|---|---|---|
| 1 | Self-init, K=8, static bg | 8 | external=0 | 16 frames of constant gray | All masks = 0 after frame 0 |
| 2 | Self-init parity vs Python ref | 8 | external=0 | `synthetic:ghost_box_disappear`, 200 frames | Per-pixel mask match Python golden, all 200 frames |
| 2b | Self-init diffusion progress | 8 | external=0 | `synthetic:ghost_box_disappear`, 200 frames | `avg_coverage(150..200) <= 0.7 * avg_coverage(10..30)` over the ghost ROI |
| 3 | Self-init, K=20 (B1 PRNG), parity | 20 | external=0 | static bg + injected motion at frame 5 | Per-pixel mask match Python golden |
| 4 | External-init, K=8, ghost suppression | 8 | external=1, lookahead-median ROM | `synthetic:ghost_box_disappear`, 60 frames | Frame-0 mask coverage < 1% in the ghost ROI |
| 5 | Backpressure (symmetric) | 8 | external=0 | Static bg, `tready` randomly deasserted | Beat-by-beat correctness, no FIFO drop |
| 6 | Backpressure / PRNG-no-drift | 8 | external=0 | `tready` held low for 16 cycles at EOF | Frame-N+1 deterministic; PRNG state did not advance during the stall |
| 7 | Misconfigured external init | 8 | external=1, `INIT_BANK_FILE=""` | n/a | `$error` at elaboration |
| 8 | Misconfigured K | 7 | external=0 | n/a | `$error` at elaboration |

**Test #2 vs #2b rationale:** Phase 1's lookahead-init experiment showed canonical self-init does NOT fully dissolve frame-0 ghosts ([results doc §44](2026-05-05-vibe-lookahead-init-results.md) shows a "visible non-zero plateau" on `ghost_box_disappear`). Test #2 asserts SV-vs-Python parity, not algorithm correctness. Test #2b asserts the diffusion mechanism is wired up by checking measurable late-vs-early coverage decay; the 0.7 threshold is a placeholder pinned during plan execution to ~0.8× the actual measured Python-ref ratio.

**Bit-exact goldens:** Each parity test has a Python-generated golden mask file. Goldens regenerate via a `make golden-vibe` Make target running `py/models/motion_vibe.py` with the same seed.

### 6.2 Layer 2 — integration via `make run-pipeline`

Same flow as today, no shape change. New ViBe profiles:

```
make run-pipeline CTRL_FLOW=motion CFG=default_vibe        SOURCE=... TOLERANCE=0
make run-pipeline CTRL_FLOW=motion CFG=vibe_k20            SOURCE=... TOLERANCE=0
make run-pipeline CTRL_FLOW=motion CFG=vibe_init_external  SOURCE=... TOLERANCE=0
make run-pipeline CTRL_FLOW=motion CFG=vibe_no_gauss       SOURCE=... TOLERANCE=0
```

When the active CFG has `vibe_bg_init_external=1`, `make prepare` extends to also generate `dv/data/init_bank.mem` (§7). The compile step's `+define+VIBE_INIT_BANK_FILE=...` is set conditionally by the same Make logic.

**Existing EMA profiles must continue to pass unchanged.** Single biggest non-regression check.

### 6.3 Layer 3 — Python parity (`py/tests/`)

- `test_profiles.py` — gains `PYTHON_ONLY_FIELDS` skip-set, plus a guard test asserting that set equals exactly the cfg_t-absent fields in `DEFAULT_VIBE`. Per [contract spec §3.1](2026-05-06-vibe-rtl-cfg-contract-design.md).
- `test_motion_vibe.py` — gains a static check that the literal `32'hDEADBEEF` in `axis_motion_detect_vibe.sv`'s `PRNG_SEED` parameter equals `0xDEADBEEF` in `DEFAULT_VIBE`'s `vibe_prng_seed`. Frame-by-frame drift catcher.
- `test_vibe_init_rom.py` (new) — calls `gen_vibe_init_rom.py` programmatically, loads the produced `.mem` as bytes, independently runs the Python ref's lookahead-median init, asserts byte equality.

### 6.4 TOLERANCE=0 viability for stochastic ViBe

ViBe is stochastic but **deterministic given the seed and per-cycle PRNG advance schedule.** Both sides observe:

1. **PRNG_SEED parity.** Static check enforces SV parameter equals Python profile field. Drift = every frame mismatches at frame 0.
2. **Per-pixel PRNG advance schedule.** Both sides advance once per pixel in raster order. SV stalls during AXIS backpressure must NOT advance the PRNG (§4.2 enforces this; test #6 verifies it).
3. **K=20 multi-stream seeds.** SV `localparam`s `SEED_INIT_0/1/2 = PRNG_SEED ^ {0, 0x9E3779B9, 0xD1B54A32}` mirror the Python ref's stream construction.
4. **Frame-0 noise slicing.** Both sides extract `prng_state[i*4 +: 4] - 8` for lane `i`. Python uses numpy integer slicing matching SV bit indexing.

### 6.5 Out of scope

- Phase-0-style upstream-PyTorch parity (already passed in Phase 0; not re-verified here).
- Visual quality regression vs. EMA (different algorithm; product-evaluation concern, not RTL signoff).
- BRAM tile budget on real FPGA targets (master design §10.1 — synth-only check, not part of `make verify`).

---

## 7. Python helper & Make integration

### 7.1 `py/gen_vibe_init_rom.py`

Standalone CLI script. Peer of `py/gen_hud_font.py`. Reads `input.bin`, writes a `$readmemh`-format `.mem` file.

**Inputs:**
- `--input PATH` — `input.bin` produced by `make prepare`
- `--output PATH` — destination `.mem` file
- `--width W`, `--height H`, `--k K`
- `--lookahead-n N` — number of frames to median over (`0` = all available, sentinel matching `vibe_bg_init_lookahead_n`)
- `--seed SEED` — PRNG seed (int)

**Algorithm:**
1. Read first `min(N, available)` frames from `input.bin`, skipping the 12-byte header.
2. Convert each to luma (`Y = 0.299R + 0.587G + 0.114B`, integer rounded — same op as `rgb2ycrcb` SV-side).
3. Per-pixel temporal median across the N frames.
4. For each pixel `(y, x)`, generate K noise-jittered slot values using B1's three-stream construction (when K=20) or single-stream (when K=8). Seed domain offset by `0x4F495E11` from the runtime seed so external-init does not collide with self-init's PRNG state.
5. Pack each pixel's K bytes into one `8*K`-bit hex string, MSB-first.
6. Emit raster-scan-order hex words, one per line, with a header comment describing the file.

### 7.2 `py/profiles.py` `--query` CLI

One-liner addition: `argparse` with `--query NAME --field FIELD` → prints the value. Used by Makefile to extract `vibe_bg_init_external`, `vibe_K`, `vibe_bg_init_lookahead_n`, `vibe_prng_seed` for the active CFG without parsing Python dicts in shell.

### 7.3 `Makefile` `prepare` extension

```makefile
prepare:
    $(VENV_PY) py/harness.py prepare ...
    @if $(VENV_PY) py/profiles.py --query "$(CFG)" --field vibe_bg_init_external | grep -q "1"; then \
        $(VENV_PY) py/gen_vibe_init_rom.py \
            --input  $(DV_DATA_DIR)/input.bin \
            --output $(DV_DATA_DIR)/init_bank.mem \
            --width  $(WIDTH) --height $(HEIGHT) \
            --k      $$($(VENV_PY) py/profiles.py --query "$(CFG)" --field vibe_K) \
            --lookahead-n $$($(VENV_PY) py/profiles.py --query "$(CFG)" --field vibe_bg_init_lookahead_n) \
            --seed   $$($(VENV_PY) py/profiles.py --query "$(CFG)" --field vibe_prng_seed) ; \
    fi
```

`prepare` also writes `vibe_bg_init_external` and the `.mem` path into `dv/data/config.mk` so the compile step can pick them up.

### 7.4 `dv/sim/Makefile` `compile` extension

```makefile
EXTRA_DEFINES :=
ifeq ($(VIBE_BG_INIT_EXTERNAL),1)
EXTRA_DEFINES += +define+VIBE_INIT_BANK_FILE=\"$(DV_DATA_DIR)/init_bank.mem\"
endif
# Pass to verilator:
verilator $(EXTRA_DEFINES) ...
```

Existing config-stamp dependency triggers recompile when `VIBE_BG_INIT_EXTERNAL` flips.

### 7.5 `make demo` interaction

- EXP=0 (RTL backend): same prepare path → `.mem` generated when CFG has external=1, RTL reads via `$readmemh`. ✓
- EXP=1 (Python model backend): same prepare path → `.mem` generated when CFG has external=1, but the Python model computes the lookahead-median bank in-process (no file I/O). The generated `.mem` is unused on this path.

The unused-file cost on EXP=1 is accepted. Generation is gated on `vibe_bg_init_external=1`, not on EXP; the cost is paid only when the user explicitly opts into external init. For CFG profiles with `external=0` (incl. today's `default`/`demo`), no `.mem` is generated.

---

## 8. Profile fallout

After Phase 2 lands, the ViBe profile family looks like (per [contract spec §4](2026-05-06-vibe-rtl-cfg-contract-design.md) plus a new external-init profile):

| Profile | `bg_model` | `K` | `external` | RTL-realizable |
|---|---|---|---|---|
| `default_vibe` | VIBE | 8 | 0 | yes |
| `vibe_k20` | VIBE | 20 | 0 | yes |
| `vibe_no_diffuse` | VIBE | 8 | 0 | yes (semantic shift per contract spec §4 — `phi_diffuse=0` only, no `coupled_rolls=False` override) |
| `vibe_no_gauss` | VIBE | 8 | 0 | yes |
| `vibe_init_frame0` | VIBE | 8 | 0 | yes (renamed from old `vibe_bg_init_mode=0` — same intent, sharper name) |
| `vibe_init_external` (new) | VIBE | 8 | 1 | yes (exercises the `$readmemh` path end-to-end) |

`default` / `demo` / etc. remain on EMA — `bg_model=BG_MODEL_EMA` — and are unaffected.

---

## 9. Out of scope

- AXI4-Lite control plane / runtime-writable BRAM aperture for external init. Deferred per [contract spec §5](2026-05-06-vibe-rtl-cfg-contract-design.md). When the project gains a CSR plane, `vibe_bg_init_external=1` can be re-wired to an MMIO-loaded BRAM with no changes to the binary contract.
- Demo profile changes (e.g., flipping `CFG_DEMO` to ViBe). Phase 2 keeps `demo` on EMA; demo-with-ViBe is a follow-up.
- BRAM tile budget validation on a specific FPGA part. Master design §10.1 covers this; not blocking for sim.
- K values other than 8 and 20. Phase 2 explicitly constrains via `$error`; supporting K=6 / K=16 / K=32 is a follow-up.

---

## 10. Risks / open questions

1. **Phase-0-validated K=8 PRNG assumptions extending to K=20.** B1 mitigates serial correlation but isn't tested in Phase 0. The Phase 2 plan must include a Python-only ablation comparing single-stream chained vs three-stream B1 at K=20 to confirm B1 doesn't introduce its own bias. If it does, fall back to chained — the failure mode is "noise pattern visible in frame-0 mask," which the diffusion mechanism washes out within ~16 frames anyway.

2. **Defer-FIFO occupancy at K=20.** Master design §6.2 calculates ≤1 typical occupancy at K=8. K=20 doesn't change the joint-fire rate (still ~0.4%), so the 4-deep FIFO is still generous. No change expected, but worth instrumenting in the unit TB to confirm.

3. **`$readmemh` performance at large K=20 ROMs.** 320×240 × 160 b ROM = 1.5 MB hex file, ~76,800 lines. Verilator parses this at elaboration; expected cost is sub-second. Worth measuring in plan execution; if slow, use `$readmemb` (binary) instead — same shape, smaller files.

4. **Test #2b's 0.7 threshold.** Placeholder. Must be pinned to ~0.8× the measured Python-ref ratio during plan execution, not before. The plan should include a step "measure on Python ref, then set threshold."

5. **Make-target ordering when `external=1`.** `prepare` must run `gen_vibe_init_rom.py` AFTER `harness.py prepare` writes `input.bin`. The recipe order in §7.3 has this right, but the dependency must be explicit if `prepare` ever gets parallelized.

---

## 11. References

- [`docs/plans/2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md) — master ViBe design.
- [`docs/plans/2026-05-06-vibe-rtl-cfg-contract-design.md`](2026-05-06-vibe-rtl-cfg-contract-design.md) — `cfg_t` field-list contract spec.
- [`docs/plans/2026-05-04-vibe-phase-0-results.md`](2026-05-04-vibe-phase-0-results.md) — Phase 0 cross-check vs upstream PyTorch.
- [`docs/plans/2026-05-05-vibe-lookahead-init-results.md`](2026-05-05-vibe-lookahead-init-results.md) — empirical motivation for external-init / ROM path.
- [`docs/plans/old/2026-05-06-vibe-phase-1-plan.md`](old/2026-05-06-vibe-phase-1-plan.md) — Phase 1 plan (landed).
- [`docs/specs/axis_motion_detect-arch.md`](../specs/axis_motion_detect-arch.md) — the EMA module's arch doc, template for the new ViBe arch doc.
- `CLAUDE.md` "AXI4-Stream pipeline stall — known pitfalls" — backpressure rules enforced in §4.2.

---

## Update — 2026-05-07: Partially superseded

§3.3 (B1 multi-stream PRNG for K=20) was superseded during implementation. The
implemented scheme uses parallel Xorshift32 streams for ALL K (not just K=20),
seeded with magic-constant XORs of PRNG_SEED. See `docs/plans/old/2026-05-07-vibe-phase-2-randomness-and-fifo-redesign-plan.md`
for the redesign.

§4 / §5 / §6 references to "4-deep defer-FIFO with opportunistic per-pixel
drain" and "V-blank-batched FIFO" were both proposed but neither was retained.
The implemented scheme is a 64-deep delay FIFO with deadline counters; see the
redesign plan and `docs/specs/axis_motion_detect_vibe-arch.md` §5.5.
