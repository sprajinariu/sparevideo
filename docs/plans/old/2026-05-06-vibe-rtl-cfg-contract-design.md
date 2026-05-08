# ViBe RTL `cfg_t` Contract — Design Spec

**Date:** 2026-05-06
**Status:** Design only. Not yet implemented. Captured here so the future Phase 2 plan inherits these decisions instead of relitigating them.
**Companion master design:** [`2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md) — see §9 (migration phasing).
**Companion Phase 1 plan:** [`old/2026-05-06-vibe-phase-1-plan.md`](old/2026-05-06-vibe-phase-1-plan.md).

---

## 1. Context — why this exists

Phase 1 added 11 fields to `cfg_t` in `hw/top/sparevideo_pkg.sv`: a `bg_model` selector + 10 ViBe knobs. Of those 10 ViBe knobs, several are **software-experimentation knobs** that the RTL has no business carrying:

- `vibe_init_scheme` — selects between three frame-0 init schemes ((a) neighborhood, (b) degenerate stack, (c) current ± noise). The Phase-0 experiments showed scheme (c) is the upstream-canonical choice and the only one we'd ever ship in RTL. Schemes (a) and (b) survive in Python only for ablations.
- `vibe_prng_seed` — a 32-bit Xorshift seed. Determinism / seed-sweep is a Python concern; the RTL needs *a* seed but doesn't need it to be a runtime profile knob.
- `vibe_coupled_rolls` — toggles between upstream-canonical "one roll per pixel, both fires together" and the Doc-B-§2 generalized "two independent phi rolls". Phase-0 cross-check landed on `True` (canonical) as the only RTL-supported value; `False` survives in Python for the no-diffuse ablation.
- `vibe_bg_init_lookahead_n` — a sentinel for "how many frames to median over when seeding the bank". Always a software-side computation. RTL receives the *result* (an init buffer), not the policy.

Carrying these in RTL `cfg_t` costs lines in the package, in every `CFG_*` localparam, in the parity test, and in eventual RTL plumbing — for zero RTL benefit. This spec records the trim that lands in Phase 2.

**Today (post-Phase-1) status:** these four fields are still in `cfg_t`. No code change yet. Phase 2 implements the trim alongside the RTL ViBe block.

---

## 2. Decision — RTL `cfg_t` shape after Phase 2

### 2.1 Sections and field counts

| Section | Fields | Count |
|---|---|---|
| **General** (apply to all `bg_model` values) | `bg_model`, `gauss_en`, `morph_open_en`, `morph_close_en`, `morph_close_kernel`, `hflip_en`, `gamma_en`, `scaler_en`, `hud_en`, `bbox_color` | 10 |
| **EMA-specific** (consumed only when `bg_model == BG_MODEL_EMA`) | `motion_thresh`, `alpha_shift`, `alpha_shift_slow`, `grace_frames`, `grace_alpha_shift` | 5 |
| **ViBe-specific** (consumed only when `bg_model == BG_MODEL_VIBE`) | `vibe_K`, `vibe_R`, `vibe_min_match`, `vibe_phi_update`, `vibe_phi_diffuse`, `vibe_bg_init_external` | 6 |

**Total: 21 fields** (Phase 1 has 25; net −4).

### 2.2 The new binary knob `vibe_bg_init_external`

Replaces today's `vibe_bg_init_mode` field with sharper semantics aligned to the RTL question being answered.

```sv
logic vibe_bg_init_external;
// 0 = RTL self-initializes the sample bank from the input stream's frame 0
//     (canonical Barnich init: each slot = clamp(frame0_pixel ± noise, 0, 255)).
// 1 = RTL receives the initial bank from a software-prepared external source
//     (e.g. a host-loaded BRAM region or pre-stream init pulse). RTL does not
//     care what the host computed — the externally supplied bank is taken as-is.
```

The exact "external source" interface (memory-mapped BRAM region, AXI4-Lite write-then-stream, sideband AXI-Stream init beat, …) is **out of scope here**. It's an RTL-architecture decision for the Phase 2 design / arch-doc step. This spec only commits to the binary contract.

### 2.3 RTL hardcoded constants (no longer in `cfg_t`)

The RTL ViBe module commits to one fixed value for each of the dropped fields:

| Hardcoded in RTL | Value | Rationale |
|---|---|---|
| `init_scheme` | `2` (current ± noise, scheme c) | Phase-0 cross-check matches upstream verbatim under this scheme. |
| `coupled_rolls` | `1` (upstream-canonical) | Phase-0 cross-check passed only after switching to coupled rolls. |
| `prng_seed` | compile-time SV parameter on `axis_motion_detect_vibe` (default `32'hDEADBEEF`) | Synthesis can override; runtime/profile cannot. |

These are not part of `cfg_t`. They live in the RTL module's own `localparam` / `parameter` declarations.

---

## 3. Python-only profile fields

The four dropped-from-RTL fields stay in `py/profiles.py` so the Python reference model can run experiments the RTL cannot:

| Field | Python use |
|---|---|
| `vibe_init_scheme` | A/B between schemes (a/b/c) on the same source. |
| `vibe_prng_seed` | Determinism + seed-sweep characterization. |
| `vibe_coupled_rolls` | Two-phi vs coupled-rolls ablation. |
| `vibe_bg_init_lookahead_n` | Sweep "how much history to median over" when `bg_init_external = 1`. |

These fields exist in every `PROFILES[*]` dict (inherited from `DEFAULT_VIBE`) but are **excluded from the SV parity test**.

### 3.1 Parity-test machinery

Update `py/tests/test_profiles.py` to skip Python-only fields when iterating the dict for SV comparison:

```python
PYTHON_ONLY_FIELDS = frozenset({
    "vibe_init_scheme",
    "vibe_prng_seed",
    "vibe_coupled_rolls",
    "vibe_bg_init_lookahead_n",
})

# inside test_profile_matches_sv:
for field, py_val in py_cfg.items():
    if field in PYTHON_ONLY_FIELDS:
        continue
    sv_raw = _sv_field(block, field)
    ...
```

A second small test asserts `PYTHON_ONLY_FIELDS` is exactly the set of keys in `DEFAULT_VIBE` that are NOT in `cfg_t` after the Phase 2 trim. This catches drift if someone later moves a field between RTL and Python without updating the allowlist.

### 3.2 Realizability convention for ViBe profiles

When a Python profile sets `bg_model = BG_MODEL_VIBE`, the values it supplies for the four Python-only fields fall into two categories:

- **RTL-realizable values.** `vibe_init_scheme=2`, `vibe_coupled_rolls=True`, `vibe_prng_seed=0xDEADBEEF`, `vibe_bg_init_lookahead_n` whatever the host's external-init policy uses. Profile is fully RTL-equivalent (post Phase 2).
- **Python-only ablation values.** Anything else (e.g. `vibe_coupled_rolls=False`, `vibe_init_scheme=0`). Profile only makes sense in Python — RTL ignores those fields.

We do **not** add a hard test asserting "all profiles are RTL-realizable". The freedom to ablate is the entire point. Profile authors who want RTL parity stick to the canonical values; profile authors running experiments don't.

---

## 4. Profile fallout under the new contract

| Phase 1 profile | What changes in Phase 2 |
|---|---|
| `default_vibe`, `vibe_k20` | Values unchanged. `vibe_bg_init_mode = 1` becomes `vibe_bg_init_external = 1`. The four Python-only fields stay in the dict but no longer appear in `cfg_t` / parity test. |
| `vibe_no_diffuse` | `coupled_rolls = False` override **dropped**. Profile becomes "phi_diffuse = 0 only". Accepted as a deliberate semantic shift — still a valid negative-control ablation, just exercises one mechanism instead of two. Future "two-mechanism off" experiments can be added as a new Python-only profile if needed. |
| `vibe_no_gauss` | Unchanged. |
| `vibe_init_frame0` | Renamed semantically: `vibe_bg_init_mode = 0` becomes `vibe_bg_init_external = 0`. Same intent (canonical RTL self-init). |

---

## 5. Out of scope (Phase 2 RTL decisions, NOT this spec)

- **External-init interface.** When `vibe_bg_init_external = 1`, *how* does the RTL receive the bank? AXI4-Lite-mapped BRAM that the host writes before deassertion? AXI-Stream init beat? Pre-loaded ROM? — Phase 2 RTL design decides. This spec only commits that the boolean exists.
- **Sample-bank BRAM layout.** §6.1 of the master design doc covers this. Trimming `cfg_t` doesn't change it.
- **The `vibe_K` / `vibe_R` / `vibe_phi_update` / `vibe_phi_diffuse` ranges that RTL accepts.** Those are RTL-implementation constraints (e.g. K must be a power of 2 for slot indexing) decided in the Phase 2 arch doc.
- **Any change to EMA fields.** EMA section is RTL-stable; not touched here.

---

## 6. Migration discipline

This trim lands as part of the Phase 2 RTL plan, NOT as a standalone refactor. Bundling it with the RTL means:

- One PR proves the contract by exercising it (RTL consumes the trimmed `cfg_t`; Python profiles still produce identical results because the dropped fields' Python defaults match the RTL-hardcoded values).
- The parity-test refactor lands alongside the cfg_t shape change, so the PR is verifier-clean from commit 1.
- No interim "Phase 1.5" branch needed.

The future Phase 2 plan should explicitly cite this spec when describing the `sparevideo_pkg.sv` and `py/profiles.py` edits.

---

## 7. Risks / open questions

1. **Has anyone come to depend on `vibe_no_diffuse`'s current dual-override semantics?** A grep of `py/experiments/` and `py/tests/` should be part of the Phase 2 plan's preflight; if any test or experiment script encodes "vibe_no_diffuse means BOTH `phi_diffuse=0` AND `coupled_rolls=False`", that callsite needs adjusting before the trim lands.

2. **The compile-time `PRNG_SEED` parameter on `axis_motion_detect_vibe` must equal the Python ref's `vibe_prng_seed`** for any TOLERANCE=0 verify to pass. The Phase 2 plan should pin this with a one-line comment in `axis_motion_detect_vibe.sv` and a matching assertion in `test_motion_vibe.py`. Today's pinning value: `32'hDEADBEEF`.

3. **External-init interface design** is the highest-leverage open question. The contract here intentionally defers it, but the Phase 2 arch doc cannot. Default expectation: a small (K × W × H bytes) BRAM region, host-writable via the existing AXI4-Lite control plane (whichever the project ends up using), latched into the ViBe sample bank before the first input frame.

---

## 8. References

- [`docs/plans/2026-05-01-vibe-motion-design.md`](2026-05-01-vibe-motion-design.md) — master ViBe design (§9 migration phasing, §6 sample storage, §10 open questions).
- [`docs/plans/2026-05-04-vibe-phase-0-results.md`](2026-05-04-vibe-phase-0-results.md) — the PASS verdict that locks scheme=c and coupled_rolls=1 as the canonical defaults this spec hardcodes into RTL.
- [`docs/plans/2026-05-05-vibe-lookahead-init-results.md`](2026-05-05-vibe-lookahead-init-results.md) — the experiment that motivated `bg_init_external=1`'s look-ahead-median use case.
