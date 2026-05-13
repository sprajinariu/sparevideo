# ViBe + Persistence-Based FG Demotion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing ViBe Python operator with a persistence-based foreground-demotion path (B'), gated by `vibe_demote_en`, and run a 4-method empirical comparison on real-clip sources to decide whether the mechanism justifies an RTL follow-up.

**Architecture:** Single new uint8/pixel state (`fg_count`) on top of canonical ViBe. Demotion fires when `fg_count ≥ K_persist` AND any 3×3 BG-classified neighbor's bank holds a sample within R of the current Y. Action: deterministically write the current Y into one bank slot of the firing pixel; force `final_bg = canonical_bg OR demote_fire` for both output and next-frame neighbor-check use.

**Tech Stack:** Python 3 (numpy, Pillow), SystemVerilog (shadow cfg_t fields only — no RTL behavior changes in this plan).

**Spec:** [`docs/plans/2026-05-12-vibe-demote-python-design.md`](2026-05-12-vibe-demote-python-design.md)

---

## Files modified / created

**Modify:**
- `hw/top/sparevideo_pkg.sv` — add 4 new `vibe_demote_*` `cfg_t` fields with disabled-sentinel defaults across every named `CFG_*` localparam, add one new constant `CFG_VIBE_DEMOTE`.
- `py/profiles.py` — mirror the 4 new fields in `DEFAULT` (inherited by every existing profile via `dict(DEFAULT, ...)`); add `VIBE_DEMOTE` profile; register `"vibe_demote"` in `PROFILES`.
- `py/tests/test_profiles.py` — extend `EXPECTED_PROFILES` set with `"vibe_demote"`.
- `py/models/ops/vibe.py` — add 4 new `__init__` kwargs (`demote_en`, `demote_K_persist`, `demote_kernel`, `demote_consistency_thresh`); per-pixel `fg_count` state; consistency-check + bank-write logic gated by `demote_en`; `prev_final_bg` register for next-frame neighbor read.
- `py/models/_vibe_mask.py` — plumb the 4 new kwargs from the profile dict into the `ViBe(...)` constructor.

**Create:**
- `py/tests/test_vibe_demote.py` — 8 unit tests (regression, counter, demotion firing, wavefront, no-demote-without-bg-neighbor, slow-object preservation, consistency_thresh wiring, determinism).
- `py/experiments/run_vibe_demote_compare.py` — 4-method comparison runner (`vibe_init_frame0`, `vibe_init_external`, `pbas_default`, `vibe_demote`).
- `py/viz/render_vibe_demote_compare_webp.py` — labelled animated WebP renderer (mirrors `render_pbas_compare_webp.py`).
- `docs/plans/2026-05-XX-vibe-demote-python-results.md` — results doc (date placeholder; populate with actual completion date).

**Out of scope (do not touch):**
- RTL behavioural changes — only the cfg_t shadow fields and one new constant are added; no module behaviour changes.
- PBAS code path or operator — comparison consumes it as-is.
- RGB extension — deferred to a separate Phase 2 plan contingent on this plan's GO outcome.
- A `vibe_demote_external` profile combining B' with lookahead — out of scope per the spec §2.

---

## Task 1: `cfg_t` `vibe_demote_*` shadow fields + Python profile mirror

**Files:**
- Modify: `hw/top/sparevideo_pkg.sv`
- Modify: `py/profiles.py`
- Modify: `py/tests/test_profiles.py`

- [ ] **Step 1: Append 4 `vibe_demote_*` fields to `cfg_t` typedef in `hw/top/sparevideo_pkg.sv`**

Immediately after the existing `pbas_R_upper` field (just before `} cfg_t;`):

```systemverilog
        // ---- ViBe persistence-based FG demotion (Phase 1: Python-only) ----
        // Demote_en=0 → canonical ViBe (bit-exact regression preserved).
        // Demote_en=1 → after demote_K_persist FG-classified frames, if any
        // 3x3 BG-classified neighbor's bank holds a sample within R of the
        // current Y (at >= demote_consistency_thresh slots), force-write the
        // current Y into one slot and OR the demote-fire bit into final_bg.
        logic        vibe_demote_en;
        logic [7:0]  vibe_demote_K_persist;
        logic [3:0]  vibe_demote_kernel;            // 3 or 5 (5 reserved for Phase 2)
        logic [3:0]  vibe_demote_consistency_thresh;
```

- [ ] **Step 2: Append the 4 fields with disabled-sentinel defaults to every existing `CFG_*` localparam**

Open `hw/top/sparevideo_pkg.sv` and find every `localparam cfg_t CFG_* = '{ ... };` (there are 17 of them per `grep -n "localparam cfg_t CFG_" hw/top/sparevideo_pkg.sv`). Append the following lines to each, immediately after the existing `pbas_R_upper` line — being careful to preserve the trailing `}` and to insert a comma after the prior `pbas_R_upper` field:

```systemverilog
        pbas_R_upper:              8'd0,
        vibe_demote_en:                 1'b0,
        vibe_demote_K_persist:          8'd0,
        vibe_demote_kernel:             4'd0,
        vibe_demote_consistency_thresh: 4'd0
```

(The last existing field used a trailing newline without a comma; the comma now belongs to `pbas_R_upper` and the new last field `vibe_demote_consistency_thresh` carries no trailing comma.)

- [ ] **Step 3: Add the new `CFG_VIBE_DEMOTE` constant**

After the existing `CFG_VIBE_INIT_EXTERNAL` localparam in `hw/top/sparevideo_pkg.sv`, add a new constant. Practically: copy `CFG_DEFAULT_VIBE` verbatim, set `vibe_bg_init_external` to `1'b0` (so it's frame-0 hard-init per the spec §3.3), and override the 4 new demote fields:

```systemverilog
    // ViBe + persistence-based FG demotion (Phase 1 candidate). Inherits
    // every CFG_DEFAULT_VIBE field except: frame-0 hard-init (no lookahead),
    // demote enabled with K_persist=30, kernel=3, consistency_thresh=1.
    localparam cfg_t CFG_VIBE_DEMOTE = '{
        // ... [all CFG_DEFAULT_VIBE fields here verbatim] ...
        vibe_bg_init_external:          1'b0,
        // ... [all other fields up to the demote block] ...
        vibe_demote_en:                 1'b1,
        vibe_demote_K_persist:          8'd30,
        vibe_demote_kernel:             4'd3,
        vibe_demote_consistency_thresh: 4'd1
    };
```

Write out every cfg_t field literally (no SV inheritance). The simplest copy-pattern: open `CFG_DEFAULT_VIBE`, copy its body, paste, then patch the 5 fields above.

- [ ] **Step 4: Run lint**

Run: `make lint`
Expected: PASS, no new warnings.

- [ ] **Step 5: Mirror fields in `py/profiles.py` — append to `DEFAULT`**

Inside the `DEFAULT` dict in `py/profiles.py`, immediately after `pbas_R_upper=0`:

```python
    # ---- ViBe persistence-based FG demotion (Phase 1: Python-only) ----
    vibe_demote_en=False,
    vibe_demote_K_persist=0,
    vibe_demote_kernel=0,
    vibe_demote_consistency_thresh=0,
```

(All zero / False in DEFAULT — disabled sentinels.)

- [ ] **Step 6: Add `VIBE_DEMOTE` profile**

Append in `py/profiles.py` below `PBAS_DEFAULT_RAUTE4_RCAP`:

```python
# ViBe + persistence-based foreground demotion (B'). Inherits DEFAULT_VIBE's
# bg-model and cleanup pipeline; toggles vibe_bg_init_external OFF (frame-0
# hard-init — no lookahead crutch) and enables the demote mechanism with the
# spec's defaults: K_persist=30 (~1s @30fps), kernel=3, consistency_thresh=1
# (1-ring-per-frame wavefront after K_persist).
VIBE_DEMOTE: ProfileT = dict(
    DEFAULT_VIBE,
    vibe_bg_init_external=0,             # frame-0 hard-init
    vibe_bg_init_lookahead_n=0,          # unused under frame-0 init; keep sentinel
    vibe_demote_en=True,
    vibe_demote_K_persist=30,
    vibe_demote_kernel=3,
    vibe_demote_consistency_thresh=1,
)
```

And in the `PROFILES` dict at the bottom of the file, add:

```python
    "vibe_demote":                  VIBE_DEMOTE,
```

- [ ] **Step 7: Update `test_profiles.py` `EXPECTED_PROFILES` set**

In `py/tests/test_profiles.py`, find the `EXPECTED_PROFILES` set (around line 65) and add `"vibe_demote"` to it:

```python
EXPECTED_PROFILES = {
    "default", "default_hflip", "no_ema", "no_morph", "no_gauss",
    "no_gamma_cor", "no_scaler", "demo", "no_hud",
    "default_vibe", "vibe_k20", "vibe_no_diffuse", "vibe_no_gauss",
    "vibe_init_frame0", "vibe_init_external", "vibe_demote",
    "pbas_default", "pbas_lookahead",
    "pbas_default_raute4", "pbas_default_raute4_rcap",
}
```

- [ ] **Step 8: Run parity test**

Run: `source .venv/bin/activate && python -m pytest py/tests/test_profiles.py -v`
Expected: ALL PASS — every profile (including `vibe_demote`) lines up with the SV `cfg_t` fields. Any failure indicates a field name typo or a `CFG_*` localparam where the 4 new fields were missed.

- [ ] **Step 9: Run full Python regression**

Run: `source .venv/bin/activate && python -m pytest py/tests -v`
Expected: ALL PASS — no existing tests break because every existing profile has `vibe_demote_en=False`.

- [ ] **Step 10: Commit**

```bash
git add hw/top/sparevideo_pkg.sv py/profiles.py py/tests/test_profiles.py
git commit -m "feat(motion/vibe): add vibe_demote_* cfg_t shadow + vibe_demote profile"
```

---

## Task 2: `fg_count` state + bit-exact regression test

**Files:**
- Modify: `py/models/ops/vibe.py`
- Create: `py/tests/test_vibe_demote.py`

- [ ] **Step 1: Write the bit-exact regression test (the core gate)**

Create `py/tests/test_vibe_demote.py`:

```python
"""Unit tests for the ViBe + persistence-based FG demotion (B') path.

Companion design: docs/plans/2026-05-12-vibe-demote-python-design.md
"""
from __future__ import annotations

import numpy as np
import pytest

from models.ops.vibe import ViBe


def _random_frames(n: int, h: int = 16, w: int = 16, seed: int = 0) -> list[np.ndarray]:
    rng = np.random.default_rng(seed)
    return [rng.integers(0, 256, (h, w), dtype=np.uint8) for _ in range(n)]


def _const_frame(val: int, h: int = 8, w: int = 8) -> np.ndarray:
    return np.full((h, w), val, dtype=np.uint8)


def test_demote_disabled_bit_exact_canonical_vibe():
    """With demote_en=False, ViBe.process_frame() is byte-for-byte equal
    to a parallel ViBe instance with no demote kwargs at all. This is the
    core regression gate — if any code path leaks under demote_en=False,
    every existing profile bit-exactly regresses."""
    frames = _random_frames(40, seed=0)
    a = ViBe(K=8, R=20, min_match=2, prng_seed=0xDEADBEEF)
    a.init_from_frame(frames[0])
    masks_a = [a.process_frame(f) for f in frames[1:]]

    b = ViBe(
        K=8, R=20, min_match=2, prng_seed=0xDEADBEEF,
        demote_en=False, demote_K_persist=30, demote_kernel=3,
        demote_consistency_thresh=1,
    )
    b.init_from_frame(frames[0])
    masks_b = [b.process_frame(f) for f in frames[1:]]

    for ma, mb in zip(masks_a, masks_b):
        assert np.array_equal(ma, mb), "demote_en=False must be bit-exact ViBe"
    assert np.array_equal(a.samples, b.samples), "bank state must be identical"
```

- [ ] **Step 2: Run test, verify it fails**

Run: `source .venv/bin/activate && python -m pytest py/tests/test_vibe_demote.py::test_demote_disabled_bit_exact_canonical_vibe -v`
Expected: FAIL — `ViBe.__init__()` doesn't accept the 4 new kwargs.

- [ ] **Step 3: Add the 4 new kwargs and `fg_count` state to `ViBe.__init__`**

Open `py/models/ops/vibe.py`. Modify `ViBe.__init__` signature and body. Add the new kwargs immediately after `coupled_rolls`:

```python
    def __init__(
        self,
        K: int = 8,
        R: int = 20,
        min_match: int = 2,
        phi_update: int = 16,
        phi_diffuse: int = 16,
        init_scheme: str = "c",
        prng_seed: int = 0xDEADBEEF,
        coupled_rolls: bool = False,
        # ---- Persistence-based FG demotion (B') ----
        demote_en: bool = False,
        demote_K_persist: int = 30,
        demote_kernel: int = 3,
        demote_consistency_thresh: int = 1,
    ):
        # Validate constraints from design doc
        assert K > 0, "K must be a positive integer"
        assert phi_update & (phi_update - 1) == 0, "phi_update must be a power of 2"
        if phi_diffuse != 0:
            assert phi_diffuse & (phi_diffuse - 1) == 0, "phi_diffuse must be a power of 2 or 0"
        assert init_scheme in ("a", "b", "c"), "init_scheme must be 'a', 'b', or 'c'"
        assert prng_seed != 0, "prng_seed must be non-zero (0 is Xorshift32 fixed point)"
        assert demote_kernel in (0, 3, 5), "demote_kernel must be 0/3/5 (0 = disabled sentinel)"
        assert demote_consistency_thresh >= 0, "demote_consistency_thresh must be >= 0"

        self.K = K
        self.R = R
        self.min_match = min_match
        self.phi_update = phi_update
        self.phi_diffuse = phi_diffuse
        self.init_scheme = init_scheme
        self.prng_state = prng_seed
        self.coupled_rolls = coupled_rolls
        # Persistence-based demotion config
        self.demote_en = bool(demote_en)
        self.demote_K_persist = int(demote_K_persist)
        self.demote_kernel = int(demote_kernel) if demote_kernel != 0 else 3
        self.demote_consistency_thresh = int(demote_consistency_thresh)

        self.samples: Optional[np.ndarray] = None  # shape (H, W, K), uint8
        # Per-pixel demote state — allocated by init_from_frame{,s} after H,W known.
        self.fg_count: Optional[np.ndarray] = None       # (H, W) uint8
        self.prev_final_bg: Optional[np.ndarray] = None  # (H, W) bool
        self.H = 0
        self.W = 0
```

- [ ] **Step 4: Allocate `fg_count` and `prev_final_bg` in `init_from_frame`**

In `py/models/ops/vibe.py`, modify `init_from_frame`. After the existing `self.samples = np.zeros((self.H, self.W, self.K), dtype=np.uint8)` line, add:

```python
        # Persistence-based demotion state. fg_count starts at 0; prev_final_bg
        # starts all-True (bg) so that on frame 1 the consistency check sees the
        # surrounding real-bg neighbors as previously-BG-classified.
        self.fg_count = np.zeros((self.H, self.W), dtype=np.uint8)
        self.prev_final_bg = np.ones((self.H, self.W), dtype=bool)
```

- [ ] **Step 5: Run regression test, verify it now passes**

Run: `source .venv/bin/activate && python -m pytest py/tests/test_vibe_demote.py::test_demote_disabled_bit_exact_canonical_vibe -v`
Expected: PASS — adding state without using it cannot change `process_frame` output.

- [ ] **Step 6: Run full Python suite**

Run: `source .venv/bin/activate && python -m pytest py/tests -v`
Expected: ALL PASS.

- [ ] **Step 7: Commit**

```bash
git add py/models/ops/vibe.py py/tests/test_vibe_demote.py
git commit -m "feat(motion/vibe): scaffold demote_* kwargs + fg_count state"
```

---

## Task 3: fg_count update + bit-exact still preserved

**Files:**
- Modify: `py/models/ops/vibe.py`
- Modify: `py/tests/test_vibe_demote.py`

- [ ] **Step 1: Write a fg_count behaviour test**

Append to `py/tests/test_vibe_demote.py`:

```python
def test_fg_count_increments_and_resets():
    """fg_count increments while FG-classified, resets to 0 on BG-classified,
    saturates at 255. Drive a known FG/BG sequence at one pixel and inspect.
    """
    # Use scheme 'b' (degenerate stack: all K slots = current pixel value)
    # so we can predict classification deterministically.
    v = ViBe(K=4, R=10, min_match=2, init_scheme="b",
             phi_update=16, phi_diffuse=16, prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=4, demote_kernel=3,
             demote_consistency_thresh=1)
    bg_frame = _const_frame(128, h=8, w=8)
    v.init_from_frame(bg_frame)            # bank = 128 everywhere
    # Drive a FG frame (value far from bank) — every pixel classifies FG.
    fg_frame = _const_frame(0, h=8, w=8)   # |0-128|=128 > R=10, no match
    m1 = v.process_frame(fg_frame)
    assert m1.all(), "all pixels should be FG on first FG frame"
    assert (v.fg_count == 1).all(), "fg_count should be 1 everywhere"
    m2 = v.process_frame(fg_frame)
    # The fg_count[r,c] reflects post-frame state — it counted this frame's classification.
    # Need to inspect a pixel that did NOT demote. Demotion requires a previously-BG
    # neighbor; after frame 1, prev_final_bg = canonical_FG OR demote_fire ... but
    # demote needs fg_count >= K_persist=4 to fire on frame 2, so all pixels still
    # FG-only and prev_final_bg = False everywhere → no demote can fire on frame 2.
    assert (v.fg_count == 2).all()
    m3 = v.process_frame(bg_frame)         # back to bg → fg_count resets
    assert (~m3).all(), "all pixels should be BG on bg frame"
    assert (v.fg_count == 0).all(), "fg_count should reset on BG classification"


def test_fg_count_saturates_at_255():
    """fg_count is uint8 and saturates at 255 without wrapping."""
    v = ViBe(K=4, R=10, min_match=2, init_scheme="b",
             phi_update=16, phi_diffuse=16, prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=300, demote_kernel=3,
             demote_consistency_thresh=1)  # K_persist > 255 to keep demote off
    bg_frame = _const_frame(128, h=4, w=4)
    v.init_from_frame(bg_frame)
    fg_frame = _const_frame(0, h=4, w=4)
    for _ in range(260):
        v.process_frame(fg_frame)
    # 260 FG frames → fg_count saturates at 255 (uint8).
    assert (v.fg_count == 255).all()
```

- [ ] **Step 2: Run, verify they fail**

Run: `source .venv/bin/activate && python -m pytest py/tests/test_vibe_demote.py -v -k fg_count`
Expected: FAIL — `fg_count` is never updated; both tests find it still all-zero.

- [ ] **Step 3: Add `fg_count` update + `prev_final_bg` register inside `process_frame`**

Open `py/models/ops/vibe.py`. Modify `process_frame` to update `fg_count` at the end. Replace the existing body (after the update calls) so it reads:

```python
    def process_frame(self, frame: np.ndarray) -> np.ndarray:
        """Process one frame: compute mask, then apply update.

        With coupled_rolls=True (upstream-canonical): one PRNG advance per
        pixel, both self-update and diffusion fire together at rate 1/phi_update.

        With coupled_rolls=False (Doc B §2 two-phi generalization): two
        independent PRNG advances per pixel, self-update at 1/phi_update and
        diffusion at 1/phi_diffuse independently.

        With demote_en=True: after the canonical update, persistence-based
        demotion may force-write the current pixel into one bank slot AND
        OR a `demote_fire` bit into the output (and registered) mask. See
        the design doc §3 for details.

        Args:
            frame: (H, W) uint8 Y frame.

        Returns:
            (H, W) bool mask. True = motion (FG), False = bg.
        """
        mask = self.compute_mask(frame)            # canonical FG/BG (True = FG)
        if self.coupled_rolls:
            self._apply_update_coupled(frame, mask)
        else:
            self._apply_self_update(frame, mask)
            self._apply_diffusion(frame, mask)

        if not self.demote_en:
            # Canonical ViBe: no demote, no state to update beyond the bank.
            return mask

        # Persistence-based demotion: compute demote_fire, force-write, OR into final.
        # demote_fire requires (canonical FG) AND fg_count >= K_persist AND
        # at least one BG-classified previous-frame neighbor whose bank has
        # >= demote_consistency_thresh slots matching current Y within R.
        canonical_fg = mask
        demote_fire = self._compute_demote_fire(frame, canonical_fg)
        # Apply demote action: deterministic single-slot write per firing pixel.
        self._apply_demote_write(frame, demote_fire)
        final_bg = (~canonical_fg) | demote_fire
        final_fg = ~final_bg
        # fg_count update uses the FINAL classification per the spec §3.2:
        # "If classified FG: fg_count += 1 (sat 255). If classified BG: reset to 0."
        # Here "classified" means the final classification.
        new_count = np.where(final_fg,
                              np.minimum(self.fg_count.astype(np.int32) + 1, 255),
                              0).astype(np.uint8)
        self.fg_count = new_count
        # Register the final classification for next-frame neighbor checks.
        self.prev_final_bg = final_bg.copy()
        return final_fg
```

- [ ] **Step 4: Add stub `_compute_demote_fire` and `_apply_demote_write` methods**

For Task 3 we only need them to return / do nothing (so fg_count update still works). They will be filled in in Task 4. Add inside `ViBe`:

```python
    def _compute_demote_fire(self, frame: np.ndarray, canonical_fg: np.ndarray) -> np.ndarray:
        """Stub — full implementation in Task 4. Currently always returns
        an all-False mask, which is equivalent to demote disabled."""
        return np.zeros_like(canonical_fg, dtype=bool)

    def _apply_demote_write(self, frame: np.ndarray, demote_fire: np.ndarray) -> None:
        """Stub — full implementation in Task 4."""
        return
```

- [ ] **Step 5: Run, verify both fg_count tests pass**

Run: `source .venv/bin/activate && python -m pytest py/tests/test_vibe_demote.py -v -k fg_count`
Expected: 2 PASS — the counter increments and saturates as specified.

- [ ] **Step 6: Re-run the bit-exact regression test from Task 2**

Run: `source .venv/bin/activate && python -m pytest py/tests/test_vibe_demote.py::test_demote_disabled_bit_exact_canonical_vibe -v`
Expected: PASS — the new code path is gated by `demote_en` and the early return preserves bit-exactness when disabled.

- [ ] **Step 7: Run full Python suite**

Run: `source .venv/bin/activate && python -m pytest py/tests -v`
Expected: ALL PASS.

- [ ] **Step 8: Commit**

```bash
git add py/models/ops/vibe.py py/tests/test_vibe_demote.py
git commit -m "feat(motion/vibe): fg_count update + prev_final_bg register (demote stubs)"
```

---

## Task 4: Neighbor-bank-consistency check + deterministic demote write

**Files:**
- Modify: `py/models/ops/vibe.py`
- Modify: `py/tests/test_vibe_demote.py`

- [ ] **Step 1: Write a "demote fires at the ghost edge" test**

Append to `py/tests/test_vibe_demote.py`:

```python
def test_demote_fires_after_K_persist_at_ghost_edge():
    """Construct a synthetic frame-0 ghost: a small object region whose bank
    holds the OBJECT's pixel value (200), surrounded by real-bg pixels whose
    bank holds the bg value (50). The current frame shows real bg everywhere
    (object has moved away). After K_persist frames, the outermost ghost
    ring's bank should receive a deterministic write of the real-bg value.
    """
    H, W = 8, 8
    K_persist = 4
    # Scheme 'b' so the bank is exactly the seed frame.
    v = ViBe(K=4, R=20, min_match=2, init_scheme="b",
             phi_update=1 << 30, phi_diffuse=1 << 30,  # disable canonical update writes
             prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=K_persist, demote_kernel=3,
             demote_consistency_thresh=1)
    # Seed bank: ghost region (rows 2-5, cols 2-5) holds OBJECT value 200,
    # everywhere else holds bg value 50.
    seed = np.full((H, W), 50, np.uint8)
    seed[2:6, 2:6] = 200
    v.init_from_frame(seed)
    # Now drive K_persist + 1 real-bg frames.
    bg_frame = np.full((H, W), 50, np.uint8)
    for _ in range(K_persist):
        v.process_frame(bg_frame)
    # After K_persist frames, outermost ghost ring (rows 2/5, cols 2/5) has
    # fg_count >= K_persist AND adjacent BG neighbors → demote should fire.
    # Check a specific ring pixel: (2, 2) — neighbors (1, 1), (1, 2), (1, 3),
    # (2, 1), (3, 1) are all bg-classified canonically (bank=50, frame=50).
    # Demote fires → samples[2,2,*] receives at least one '50' slot.
    assert 50 in v.samples[2, 2], \
        f"expected demote-write of real-bg value at ghost edge, got {v.samples[2,2]}"
```

- [ ] **Step 2: Run, verify it fails**

Run: `source .venv/bin/activate && python -m pytest py/tests/test_vibe_demote.py::test_demote_fires_after_K_persist_at_ghost_edge -v`
Expected: FAIL — `_compute_demote_fire` is a stub that returns all-False, no write happens.

- [ ] **Step 3: Implement `_compute_demote_fire`**

Open `py/models/ops/vibe.py`. Replace the stub with the full implementation:

```python
    def _compute_demote_fire(self, frame: np.ndarray, canonical_fg: np.ndarray) -> np.ndarray:
        """Per-pixel demote_fire bit. Fires when:
          - pixel classified FG canonically this frame, AND
          - fg_count[r,c] >= demote_K_persist, AND
          - at least one neighbor in the demote_kernel neighborhood was
            BG-classified per the previous-frame final_bg map, and that
            neighbor's bank holds >= demote_consistency_thresh slots within
            R of the current pixel value.
        """
        H, W = frame.shape
        eligible = canonical_fg & (self.fg_count >= self.demote_K_persist)
        if not eligible.any():
            return np.zeros((H, W), dtype=bool)
        radius = self.demote_kernel // 2
        fire = np.zeros((H, W), dtype=bool)
        # Short-circuit per-pixel scan. The image is small (≤ 320x240); explicit
        # pixel-level loops match the upstream ViBe code style and keep RTL parity
        # straightforward. Vectorisation is a future optimisation, not required for
        # the Python reference operator.
        R = self.R
        K = self.K
        thresh = self.demote_consistency_thresh
        for r in range(H):
            for c in range(W):
                if not eligible[r, c]:
                    continue
                y = int(frame[r, c])
                fired = False
                for dr in range(-radius, radius + 1):
                    if fired:
                        break
                    for dc in range(-radius, radius + 1):
                        if dr == 0 and dc == 0:
                            continue
                        nr = r + dr
                        nc = c + dc
                        if not (0 <= nr < H and 0 <= nc < W):
                            continue
                        if not self.prev_final_bg[nr, nc]:
                            continue
                        # Count matching slots in this neighbor's bank.
                        match_count = 0
                        for k in range(K):
                            if abs(int(self.samples[nr, nc, k]) - y) < R:
                                match_count += 1
                                if match_count >= thresh:
                                    break
                        if match_count >= thresh:
                            fire[r, c] = True
                            fired = True
                            break
        return fire
```

- [ ] **Step 4: Implement `_apply_demote_write`**

Replace the stub:

```python
    def _apply_demote_write(self, frame: np.ndarray, demote_fire: np.ndarray) -> None:
        """Deterministic single-slot write per firing pixel. The slot index
        is chosen from the existing PRNG stream (one advance per firing pixel,
        in raster order) to preserve determinism without disturbing the
        canonical update PRNG sequence beyond the existing pattern.
        """
        if not demote_fire.any():
            return
        H, W = frame.shape
        K = self.K
        log2_K = (K - 1).bit_length()
        for r in range(H):
            for c in range(W):
                if not demote_fire[r, c]:
                    continue
                state = self._next_prng()
                slot = ((state >> 0) % K)  # low log2(K) bits → slot
                self.samples[r, c, slot] = frame[r, c]
                # Silence unused-name warning for log2_K (kept for clarity / future use).
                _ = log2_K
```

- [ ] **Step 5: Run the ghost-edge test, verify it passes**

Run: `source .venv/bin/activate && python -m pytest py/tests/test_vibe_demote.py::test_demote_fires_after_K_persist_at_ghost_edge -v`
Expected: PASS — a real-bg sample (50) has been written into the ghost-ring pixel's bank after K_persist frames.

- [ ] **Step 6: Re-run the bit-exact regression test**

Run: `source .venv/bin/activate && python -m pytest py/tests/test_vibe_demote.py::test_demote_disabled_bit_exact_canonical_vibe -v`
Expected: PASS — `demote_en=False` still produces bit-exact canonical ViBe (the new code only runs under `demote_en=True`).

- [ ] **Step 7: Commit**

```bash
git add py/models/ops/vibe.py py/tests/test_vibe_demote.py
git commit -m "feat(motion/vibe): neighbor-bank consistency + deterministic demote write"
```

---

## Task 5: Wavefront, no-BG-neighbor, slow-object, consistency-thresh, determinism tests

**Files:**
- Modify: `py/tests/test_vibe_demote.py`

- [ ] **Step 1: Write the wavefront-propagation test**

Append to `py/tests/test_vibe_demote.py`:

```python
def test_wavefront_propagates_one_ring_per_frame():
    """A large ghost region dissolves outside-in at one ring per frame after
    K_persist (consistency_thresh=1). Verify Ring i has at least one
    real-bg sample by frame K_persist + i.
    """
    H, W = 16, 16
    K_persist = 3
    v = ViBe(K=4, R=20, min_match=2, init_scheme="b",
             phi_update=1 << 30, phi_diffuse=1 << 30,
             prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=K_persist, demote_kernel=3,
             demote_consistency_thresh=1)
    # Ghost = 6x6 region centered, rows/cols 5..10
    seed = np.full((H, W), 50, np.uint8)
    seed[5:11, 5:11] = 200
    v.init_from_frame(seed)
    bg_frame = np.full((H, W), 50, np.uint8)
    # After K_persist frames the outermost ring should fire.
    # After K_persist + 1, the second ring; etc.
    rings = [
        # ring 0: outermost band (row 5/10 or col 5/10)
        [(5, 5), (5, 10), (10, 5), (10, 10), (5, 7), (10, 7), (7, 5), (7, 10)],
        # ring 1: one step inward
        [(6, 6), (6, 9), (9, 6), (9, 9), (6, 7), (9, 7)],
        # ring 2: center
        [(7, 7), (8, 8)],
    ]
    for frame_offset in range(K_persist + len(rings)):
        v.process_frame(bg_frame)
        if frame_offset < K_persist - 1:
            continue
        ring_idx = frame_offset - (K_persist - 1)
        if ring_idx >= len(rings):
            break
        # After frame K_persist + ring_idx, ring `ring_idx` should have demoted.
        for (r, c) in rings[ring_idx]:
            assert 50 in v.samples[r, c], \
                f"ring {ring_idx} pixel ({r},{c}) not yet demoted at frame {frame_offset+1}"


def test_no_demotion_when_no_BG_neighbor():
    """A pixel surrounded entirely by FG-classified pixels never demotes,
    even if fg_count >> K_persist."""
    H, W = 8, 8
    # All pixels are 'object' (200) but bank seeded everywhere with 200,
    # so the current bg frame (50) is FG everywhere — every neighbor is FG.
    v = ViBe(K=4, R=20, min_match=2, init_scheme="b",
             phi_update=1 << 30, phi_diffuse=1 << 30, prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=3, demote_kernel=3,
             demote_consistency_thresh=1)
    seed = np.full((H, W), 200, np.uint8)
    v.init_from_frame(seed)
    bg_frame = np.full((H, W), 50, np.uint8)
    for _ in range(10):  # 10 frames, K_persist=3 → counter saturates
        v.process_frame(bg_frame)
    # No demote should have fired anywhere — bank is still all-200.
    assert (v.samples == 200).all(), \
        f"expected no demote firing (all FG neighbors); bank min={v.samples.min()}"


def test_slow_moving_uniform_object_not_demoted():
    """A uniform-color object interior whose color is far from the
    surrounding bg should NOT demote, even after K_persist FG frames,
    because BG neighbors' banks don't have slots matching the object color.
    """
    H, W = 12, 12
    K_persist = 3
    v = ViBe(K=4, R=10, min_match=2, init_scheme="b",
             phi_update=1 << 30, phi_diffuse=1 << 30, prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=K_persist, demote_kernel=3,
             demote_consistency_thresh=1)
    # Bank seeded everywhere with bg=50.
    v.init_from_frame(np.full((H, W), 50, np.uint8))
    # Drive frames with a stationary 4x4 OBJECT region at (4..7, 4..7).
    obj_frame = np.full((H, W), 50, np.uint8)
    obj_frame[4:8, 4:8] = 200
    for _ in range(K_persist + 5):
        v.process_frame(obj_frame)
    # Object interior pixel (5,5): neighbors include (4,4)..(6,6). Of those,
    # (4,4)/(4,5)/(5,4) are object pixels (FG), (3,3)..(3,5)/(5,3) are bg pixels.
    # The bg neighbors have bank value 50; current Y at (5,5) is 200 → |50-200|=150 > R=10.
    # No consistency match → no demote.
    assert v.samples[5, 5, 0] == 50 and v.samples[5, 5, 1] == 50, \
        f"object interior should not demote; got {v.samples[5,5]}"
    # Note: the OBJECT-EDGE pixels (e.g., (4,4)) DO have bg-classified neighbors
    # whose banks match each other's bg values. But (4,4)'s OWN current Y is 200,
    # and those bg neighbors' banks hold 50, so |50-200|>R → no fire there either.


def test_consistency_thresh_2_doubles_propagation_time():
    """With consistency_thresh=2, the wavefront needs 2 matching slots in
    a neighbor's bank → effectively 2 frames per ring instead of 1.

    Verify by comparing ring-1 demote latency at thresh=1 vs thresh=2 on a
    minimal ghost.
    """
    H, W = 10, 10
    K_persist = 3

    def run(thresh: int) -> int:
        """Return the smallest frame index at which Ring 1 pixel (4,4) has
        a real-bg (50) sample in its bank."""
        v = ViBe(K=4, R=20, min_match=2, init_scheme="b",
                 phi_update=1 << 30, phi_diffuse=1 << 30, prng_seed=0xDEADBEEF,
                 demote_en=True, demote_K_persist=K_persist, demote_kernel=3,
                 demote_consistency_thresh=thresh)
        seed = np.full((H, W), 50, np.uint8)
        seed[3:6, 3:6] = 200  # 3x3 ghost
        v.init_from_frame(seed)
        bg = np.full((H, W), 50, np.uint8)
        # Watch the center pixel (4,4) — wait until at least one slot becomes 50.
        for i in range(30):
            v.process_frame(bg)
            if 50 in v.samples[4, 4]:
                return i + 1   # frame index (1-based)
        return -1

    t1 = run(1)
    t2 = run(2)
    assert t1 > 0 and t2 > 0
    assert t2 > t1, f"consistency_thresh=2 should be slower than thresh=1; got t1={t1}, t2={t2}"


def test_demote_deterministic_under_fixed_seed():
    """Two runs of vibe_demote with the same seed produce bit-identical
    masks AND bank state. Ensures the demote code path didn't introduce
    non-determinism."""
    frames = _random_frames(40, seed=0)
    a = ViBe(K=4, R=20, min_match=2, prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=5, demote_kernel=3,
             demote_consistency_thresh=1)
    a.init_from_frame(frames[0])
    masks_a = [a.process_frame(f) for f in frames[1:]]
    b = ViBe(K=4, R=20, min_match=2, prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=5, demote_kernel=3,
             demote_consistency_thresh=1)
    b.init_from_frame(frames[0])
    masks_b = [b.process_frame(f) for f in frames[1:]]
    for ma, mb in zip(masks_a, masks_b):
        assert np.array_equal(ma, mb)
    assert np.array_equal(a.samples, b.samples)
    assert np.array_equal(a.fg_count, b.fg_count)
```

- [ ] **Step 2: Run all five new tests**

Run: `source .venv/bin/activate && python -m pytest py/tests/test_vibe_demote.py -v`
Expected: ALL 8 tests pass (2 from Task 2, 2 from Task 3, 1 from Task 4, 5 from Task 5 — wait, that's 10. Recount: regression, fg_count×2, ghost-edge, wavefront, no-BG-nbr, slow-obj, thresh2, determinism = 8 total. Plus the saturate test from Task 3 = 9. Verify by running.)

If any test fails, debug against the design doc §3.4 (wavefront math) and §3.6 (slow-object preservation). The most likely failure is a miscount of "rings" in the wavefront test — the test's `rings` lists may need refinement based on which pixels the 3×3 neighbor scan actually reaches first.

- [ ] **Step 3: Run full Python suite**

Run: `source .venv/bin/activate && python -m pytest py/tests -v`
Expected: ALL PASS.

- [ ] **Step 4: Commit**

```bash
git add py/tests/test_vibe_demote.py
git commit -m "test(motion/vibe): wavefront, slow-obj preservation, thresh wiring, determinism"
```

---

## Task 6: Plumb `vibe_demote_*` through `_vibe_mask.py`

**Files:**
- Modify: `py/models/_vibe_mask.py`
- Modify: `py/tests/test_vibe_demote.py`

- [ ] **Step 1: Write an end-to-end adapter test**

Append to `py/tests/test_vibe_demote.py`:

```python
def test_produce_masks_vibe_demote_profile_smoke():
    """End-to-end: a profile with vibe_demote_en=True must flow through
    _vibe_mask.produce_masks_vibe and produce per-frame boolean masks."""
    from models._vibe_mask import produce_masks_vibe
    rng = np.random.default_rng(0)
    frames = [rng.integers(0, 256, (16, 16, 3), dtype=np.uint8) for _ in range(40)]
    masks = produce_masks_vibe(
        frames,
        # canonical ViBe args
        vibe_K=8, vibe_R=20, vibe_min_match=2,
        vibe_phi_update=16, vibe_phi_diffuse=16,
        vibe_init_scheme=2, vibe_prng_seed=0xDEADBEEF,
        vibe_coupled_rolls=True,
        vibe_bg_init_external=0, vibe_bg_init_lookahead_n=0,
        # NEW demote args
        vibe_demote_en=True,
        vibe_demote_K_persist=5,
        vibe_demote_kernel=3,
        vibe_demote_consistency_thresh=1,
        gauss_en=False,
    )
    assert len(masks) == 40
    for m in masks:
        assert m.dtype == bool
        assert m.shape == (16, 16)


def test_produce_masks_vibe_demote_disabled_bit_exact():
    """With vibe_demote_en=False the adapter MUST produce byte-identical
    masks to today's canonical ViBe path (the regression gate at the
    adapter boundary)."""
    from models._vibe_mask import produce_masks_vibe
    rng = np.random.default_rng(1)
    frames = [rng.integers(0, 256, (16, 16, 3), dtype=np.uint8) for _ in range(30)]
    common = dict(
        vibe_K=8, vibe_R=20, vibe_min_match=2,
        vibe_phi_update=16, vibe_phi_diffuse=16,
        vibe_init_scheme=2, vibe_prng_seed=0xDEADBEEF,
        vibe_coupled_rolls=True,
        vibe_bg_init_external=0, vibe_bg_init_lookahead_n=0,
        gauss_en=False,
    )
    masks_a = produce_masks_vibe(
        frames, **common,
        vibe_demote_en=False,
        vibe_demote_K_persist=30, vibe_demote_kernel=3,
        vibe_demote_consistency_thresh=1,
    )
    masks_b = produce_masks_vibe(frames, **common)  # no demote kwargs at all
    for ma, mb in zip(masks_a, masks_b):
        assert np.array_equal(ma, mb)
```

- [ ] **Step 2: Run, verify both fail**

Run: `source .venv/bin/activate && python -m pytest py/tests/test_vibe_demote.py -v -k produce_masks`
Expected: FAIL — `produce_masks_vibe` doesn't accept the 4 new kwargs.

- [ ] **Step 3: Plumb the 4 new kwargs through `_vibe_mask.py`**

Open `py/models/_vibe_mask.py`. Add the new kwargs to `produce_masks_vibe`'s signature (immediately after `vibe_bg_init_lookahead_n`, before `gauss_en`) and pass them through to the `ViBe(...)` constructor.

The function signature changes to include:

```python
def produce_masks_vibe(
    frames: list[np.ndarray],
    *,
    vibe_K: int,
    vibe_R: int,
    vibe_min_match: int,
    vibe_phi_update: int,
    vibe_phi_diffuse: int,
    vibe_init_scheme: int,
    vibe_prng_seed: int,
    vibe_coupled_rolls: bool,
    vibe_bg_init_external: int,
    vibe_bg_init_lookahead_n: int,
    vibe_demote_en: bool = False,
    vibe_demote_K_persist: int = 30,
    vibe_demote_kernel: int = 3,
    vibe_demote_consistency_thresh: int = 1,
    gauss_en: bool = True,
    **_ignored,
) -> list[np.ndarray]:
```

(The default values preserve backwards compatibility — callers that don't supply demote kwargs get `vibe_demote_en=False`.)

And the `ViBe(...)` constructor call now reads:

```python
    v = ViBe(
        K=vibe_K,
        R=vibe_R,
        min_match=vibe_min_match,
        phi_update=vibe_phi_update,
        phi_diffuse=vibe_phi_diffuse,
        init_scheme=init_scheme,
        prng_seed=vibe_prng_seed,
        coupled_rolls=vibe_coupled_rolls,
        demote_en=vibe_demote_en,
        demote_K_persist=vibe_demote_K_persist,
        demote_kernel=vibe_demote_kernel,
        demote_consistency_thresh=vibe_demote_consistency_thresh,
    )
```

- [ ] **Step 4: Run, verify both tests pass**

Run: `source .venv/bin/activate && python -m pytest py/tests/test_vibe_demote.py -v -k produce_masks`
Expected: 2 PASS.

- [ ] **Step 5: Run full Python suite**

Run: `source .venv/bin/activate && python -m pytest py/tests -v`
Expected: ALL PASS — `_vibe_mask`'s backwards-compatible defaults keep existing tests green.

- [ ] **Step 6: Commit**

```bash
git add py/models/_vibe_mask.py py/tests/test_vibe_demote.py
git commit -m "feat(motion/vibe): plumb vibe_demote_* through _vibe_mask adapter"
```

---

## Task 7: Comparison experiment runner

**Files:**
- Create: `py/experiments/run_vibe_demote_compare.py`

- [ ] **Step 1: Inspect prior runner as template**

Run: `head -40 py/experiments/run_pbas_compare.py`

The shape we mirror: load source → run pipeline per profile → save coverage.png + convergence_table.csv. Same SOURCES, but 4 different methods.

- [ ] **Step 2: Create the runner**

Create `py/experiments/run_vibe_demote_compare.py`:

```python
"""Phase comparison: vibe_demote vs reference methods on real clips.

4 methods x 2 sources x 200 frames. Outputs under
py/experiments/our_outputs/vibe_demote_compare/<source>/:
  coverage.png            — 4-curve overlay (mean mask coverage vs frame)
  convergence_table.csv   — asymptote (frames 150-199) / peak / time-to-thresh per method

Companion design / plan:
  docs/plans/2026-05-12-vibe-demote-python-design.md
  docs/plans/2026-05-12-vibe-demote-python-plan.md
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # py/ on sys.path

from experiments.metrics import coverage_curve
from experiments.render import render_coverage_curves
from frames.video_source import load_frames
from models._pbas_mask import produce_masks_pbas
from models._vibe_mask import produce_masks_vibe
from profiles import resolve

SOURCES = [
    "media/source/birdseye-320x240.mp4",
    "media/source/people-320x240.mp4",
]
METHODS = [
    "vibe_init_frame0",
    "vibe_init_external",
    "pbas_default",
    "vibe_demote",
]
N_FRAMES = 200
OUT_ROOT = Path("py/experiments/our_outputs/vibe_demote_compare")
THRESHOLDS = [0.01, 0.001]
ASYMPTOTE_WINDOW = 50  # frames 150-199 of a 200-frame run


def _produce_masks(profile_name: str, frames: list[np.ndarray]) -> list[np.ndarray]:
    cfg = dict(resolve(profile_name))
    if profile_name.startswith("pbas_"):
        return produce_masks_pbas(
            frames,
            **{k: v for k, v in cfg.items() if k.startswith("pbas_") or k == "gauss_en"},
        )
    elif profile_name.startswith("vibe_"):
        return produce_masks_vibe(
            frames,
            **{k: v for k, v in cfg.items() if k.startswith("vibe_") or k == "gauss_en"},
        )
    else:
        raise ValueError(f"unknown profile family: {profile_name}")


def _time_to_threshold(curve: np.ndarray, t: float) -> int | None:
    below = np.where(curve < t)[0]
    return int(below[0]) if below.size else None


def _coverage_by_region(masks: list[np.ndarray]) -> tuple[float, float]:
    """Split coverage into (high-traffic, low-traffic) regions.

    A pixel is in the high-traffic region if its time-averaged FG-classification
    rate exceeds 50% across the run. The two returned values are the asymptote
    coverage (frames 150-199 mean) restricted to each region.
    """
    stack = np.stack([m.astype(np.uint8) for m in masks], axis=0)  # (T, H, W)
    time_avg = stack.mean(axis=0)                                  # (H, W)
    high_traffic = time_avg > 0.5
    tail = stack[-ASYMPTOTE_WINDOW:]                               # (50, H, W)
    if high_traffic.any():
        ht_cov = float(tail[:, high_traffic].mean())
    else:
        ht_cov = float("nan")
    low_traffic = ~high_traffic
    if low_traffic.any():
        lt_cov = float(tail[:, low_traffic].mean())
    else:
        lt_cov = float("nan")
    return ht_cov, lt_cov


def run_source(source: str, n_frames: int = N_FRAMES) -> None:
    frames = load_frames(source, width=320, height=240, num_frames=n_frames)
    if len(frames) < n_frames:
        raise SystemExit(f"{source}: only {len(frames)} frames available, need {n_frames}")
    out_dir = OUT_ROOT / source.replace(":", "_").replace("/", "_")
    out_dir.mkdir(parents=True, exist_ok=True)
    curves: dict[str, np.ndarray] = {}
    region_cov: dict[str, tuple[float, float]] = {}
    method_masks: dict[str, list[np.ndarray]] = {}
    for method in METHODS:
        masks = _produce_masks(method, frames)
        method_masks[method] = masks
        curves[method] = coverage_curve(masks)
        region_cov[method] = _coverage_by_region(masks)
    render_coverage_curves(
        curves, str(out_dir / "coverage.png"),
        title=f"ViBe-demote vs reference — {source}",
    )
    with (out_dir / "convergence_table.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(
            ["method", f"asymptote(last{ASYMPTOTE_WINDOW})", "peak"]
            + [f"t_to_{t:.4f}" for t in THRESHOLDS]
        )
        for m in METHODS:
            c = curves[m]
            row = [m, f"{c[-ASYMPTOTE_WINDOW:].mean():.4f}", f"{c.max():.4f}"]
            for t in THRESHOLDS:
                tt = _time_to_threshold(c, t)
                row.append(str(tt) if tt is not None else "")
            w.writerow(row)
    with (out_dir / "coverage_by_region.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["method", "asymptote_high_traffic", "asymptote_low_traffic"])
        for m in METHODS:
            ht, lt = region_cov[m]
            w.writerow([m, f"{ht:.4f}", f"{lt:.4f}"])
    print(f"[{source}] asymptote: " + ", ".join(
        f"{m}={curves[m][-ASYMPTOTE_WINDOW:].mean():.4f}" for m in METHODS), flush=True)
    print(f"[{source}] high-traffic asymptote: " + ", ".join(
        f"{m}={region_cov[m][0]:.4f}" for m in METHODS), flush=True)


def main() -> None:
    for src in SOURCES:
        run_source(src)


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Smoke-test at reduced frame count**

```bash
source .venv/bin/activate
python -c "
import sys; sys.path.insert(0, 'py')
from experiments.run_vibe_demote_compare import run_source
run_source('media/source/birdseye-320x240.mp4', n_frames=30)
"
```

Expected: produces `py/experiments/our_outputs/vibe_demote_compare/media_source_birdseye-320x240.mp4/{coverage.png, convergence_table.csv, coverage_by_region.csv}` without error.

(30 frames is too few to satisfy `vibe_init_external`'s lookahead window — if the smoke-test errors with "need more frames", bump to 60 frames.)

- [ ] **Step 4: Commit (smoke-test outputs are gitignored under `our_outputs/`)**

```bash
git add py/experiments/run_vibe_demote_compare.py
git commit -m "experiment(motion/vibe): 4-method comparison runner (vibe_demote vs reference)"
```

(The full 200-frame run is deferred to Task 9.)

---

## Task 8: Labelled WebP renderer

**Files:**
- Create: `py/viz/render_vibe_demote_compare_webp.py`

- [ ] **Step 1: Inspect the PBAS WebP renderer as template**

Run: `head -50 py/viz/render_pbas_compare_webp.py`

The structure is straightforward: import METHODS / SOURCES / `_produce_masks` from the runner, produce one labelled animated WebP per source.

- [ ] **Step 2: Create the renderer**

Create `py/viz/render_vibe_demote_compare_webp.py`:

```python
"""Render labelled side-by-side animated WebPs comparing vibe_demote vs reference.

One WebP per source under media/demo/vibe-demote-compare-<source>.webp. Each
WebP animates 200 frames, showing 4 method outputs left-to-right with method
labels above each panel.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # py/ on sys.path

from experiments.run_vibe_demote_compare import (
    METHODS,
    N_FRAMES,
    SOURCES,
    _produce_masks,
)
from frames.video_source import load_frames

OUT_DIR = Path("media/demo")
OUT_DIR.mkdir(parents=True, exist_ok=True)
LABEL_H = 24
FONT_PATHS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]


def _load_font(size: int) -> ImageFont.FreeTypeFont:
    for path in FONT_PATHS:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def _label_panel(panel: Image.Image, label: str, font: ImageFont.FreeTypeFont) -> Image.Image:
    w, h = panel.size
    out = Image.new("RGB", (w, h + LABEL_H), (40, 40, 40))
    draw = ImageDraw.Draw(out)
    bbox = draw.textbbox((0, 0), label, font=font)
    tx = (w - (bbox[2] - bbox[0])) // 2
    ty = (LABEL_H - (bbox[3] - bbox[1])) // 2
    draw.text((tx, ty), label, fill=(220, 220, 220), font=font)
    out.paste(panel, (0, LABEL_H))
    return out


def render(source: str, n_frames: int = N_FRAMES) -> None:
    frames = load_frames(source, width=320, height=240, num_frames=n_frames)
    if len(frames) < n_frames:
        raise SystemExit(f"{source}: only {len(frames)} frames available, need {n_frames}")
    streams: dict[str, list[np.ndarray]] = {}
    for method in METHODS:
        streams[method] = _produce_masks(method, frames)
    font = _load_font(14)
    pages = []
    for i in range(n_frames):
        labelled = []
        for method in METHODS:
            mask = streams[method][i].astype(np.uint8) * 255
            panel = Image.fromarray(mask, mode="L").convert("RGB")
            labelled.append(_label_panel(panel, method, font))
        strip_w = sum(p.size[0] for p in labelled)
        strip_h = labelled[0].size[1]
        strip = Image.new("RGB", (strip_w, strip_h), (40, 40, 40))
        x = 0
        for p in labelled:
            strip.paste(p, (x, 0))
            x += p.size[0]
        pages.append(strip)
    out_path = OUT_DIR / f"vibe-demote-compare-{source.replace(':', '_').replace('/', '_')}.webp"
    pages[0].save(
        out_path, format="WEBP", save_all=True,
        append_images=pages[1:], duration=33, loop=0,
        lossless=True, quality=80,
    )
    print(f"[{source}] -> {out_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", type=int, default=N_FRAMES)
    parser.add_argument("--source", type=str, default=None,
                        help="run a single source (full path) instead of all SOURCES")
    args = parser.parse_args()
    if args.source:
        render(args.source, args.frames)
    else:
        for src in SOURCES:
            render(src, args.frames)


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Smoke-test the renderer at reduced frame count**

```bash
source .venv/bin/activate
python py/viz/render_vibe_demote_compare_webp.py --frames 60 --source media/source/birdseye-320x240.mp4
```

Expected: produces `media/demo/vibe-demote-compare-media_source_birdseye-320x240.mp4.webp`. File size well under 2 MB at 60 frames.

- [ ] **Step 4: Commit (renderer only; clean up smoke-test WebP)**

```bash
rm -f media/demo/vibe-demote-compare-*.webp
git add py/viz/render_vibe_demote_compare_webp.py
git commit -m "demo(motion/vibe): labelled side-by-side vibe_demote WebP renderer"
```

---

## Task 9: Run experiment + write results doc + GO/NO-GO (HUMAN GATE)

**Files:**
- Create: `docs/plans/2026-05-XX-vibe-demote-python-results.md` (date placeholder; populate with actual run date)
- Create: `media/demo/vibe-demote-compare-*.webp` (2 WebPs; committed alongside the results doc)

- [ ] **Step 1: Run the full 200-frame comparison**

```bash
source .venv/bin/activate
python py/experiments/run_vibe_demote_compare.py
```

Expected: produces 2 directories under `py/experiments/our_outputs/vibe_demote_compare/`, each with `coverage.png` and `convergence_table.csv`. May take 60+ minutes in pure Python (per-pixel neighbor scan is the slowest path; the existing PBAS comparison took ~30 minutes and vibe_demote's neighbor scan adds similar overhead). Acceptable for a one-time experiment.

- [ ] **Step 2: Generate the WebPs**

```bash
python py/viz/render_vibe_demote_compare_webp.py
```

Expected: produces `media/demo/vibe-demote-compare-media_source_birdseye-320x240.mp4.webp` and the people equivalent. Each well under 10 MB.

- [ ] **Step 3: Aggregate the CSV results into a single markdown table**

Run: `cat py/experiments/our_outputs/vibe_demote_compare/*/convergence_table.csv`

Collect asymptote (frames 150-199 mean) / peak / time-to-1% per (source, method) into a single markdown table for the results doc.

- [ ] **Step 4: Write the results doc**

Create `docs/plans/<actual-date>-vibe-demote-python-results.md`. Replace `<actual-date>` with today's `YYYY-MM-DD`:

```markdown
# ViBe + persistence-based FG demotion (B') — Python results

**Date:** YYYY-MM-DD
**Branch:** feat/vibe-demote-python
**Companion design:** docs/plans/2026-05-12-vibe-demote-python-design.md
**Companion plan:** docs/plans/2026-05-12-vibe-demote-python-plan.md

## Decision

GO / NO-GO — recommend / hold on RTL follow-up for ViBe + B'.

## Headline 4-method coverage table (asymptote = mean of frames 150-199 of 200)

| Source | vibe_init_frame0 | vibe_init_external | pbas_default | vibe_demote |
|---|---|---|---|---|
| birdseye | ... | ... | ... | ... |
| people | ... | ... | ... | ... |

## Convergence speed — time-to-1%-coverage (frame index)

(Populate from convergence_table.csv per source.)

## High-traffic vs low-traffic region asymptotes

(Populate from coverage_by_region.csv per source. Directly tests the
"vibe_init_external bakes objects into median bg in high-traffic areas"
motivation from design §1.)

| Source | Region | vibe_init_frame0 | vibe_init_external | pbas_default | vibe_demote |
|---|---|---|---|---|---|
| birdseye | high-traffic | ... | ... | ... | ... |
| birdseye | low-traffic  | ... | ... | ... | ... |
| people   | high-traffic | ... | ... | ... | ... |
| people   | low-traffic  | ... | ... | ... | ... |

## Visual evidence

- py/experiments/our_outputs/vibe_demote_compare/<source>/coverage.png (linked)
- media/demo/vibe-demote-compare-<source>.webp (linked)

## Discussion

Did vibe_demote dissolve ghosts on real clips? At what frame number did the
wavefront fully complete? Did it preserve real moving objects (no FG suppression
during convergence)? Did high-traffic regions resolve differently than under
vibe_init_external (which bakes objects into the median bg)? Any qualitative
observations from the WebPs (mask sharpness, edge artefacts, slow-object
behaviour).

## Decision against the design-doc criteria

Per §7.5 of the design doc, vibe_demote is a GO iff, on BOTH real sources:
1. Lower asymptotic coverage (mean of frames 150-199) than vibe_init_external, AND
2. Lower asymptotic coverage than pbas_default, AND
3. No worse peak coverage during convergence than vibe_init_external.

Verdict: GO / PARTIAL GO / NO-GO.

## Caveats / open questions

(e.g., what does the K_persist sweep show? Does consistency_thresh=2 help? Is
the Y-only assumption a meaningful limitation that Phase 2 RGB would close?)

## Recommendation

GO → spin up the RTL follow-up plan for vibe_demote (small state delta over
existing axis_motion_detect_vibe).

PARTIAL GO → run the Phase 2 RGB extension first to see if it closes the gap.

NO-GO → fall back to vibe_init_external as the project's default; document
the finding; do not pursue RTL.
```

- [ ] **Step 5: Commit results doc + the two WebPs**

```bash
git add docs/plans/*-vibe-demote-python-results.md media/demo/vibe-demote-compare-*.webp
git commit -m "docs(plans): vibe_demote Python — empirical results + side-by-side WebPs"
```

- [ ] **Step 6: Decision gate**

Present the results doc to the human. Decision options:

- **GO:** `vibe_demote` beats both `vibe_init_external` and `pbas_default` on at least one real source per the criteria above → start a separate RTL implementation plan on a fresh branch off `origin/main`.
- **PARTIAL GO:** `vibe_demote` beats `pbas_default` but not `vibe_init_external` → defer RTL; spin up Phase 2 RGB extension plan (separate branch, contingent on this plan's results).
- **NO-GO:** `vibe_demote` doesn't beat either reference → fall back to shipping `vibe_init_external` as the project default. Document the finding; the experiment was still valuable as it eliminates the demotion mechanism (at Y-only resolution) from the option space.

This is a human-judgement gate. Do not proceed to RTL work without an explicit GO.

---

## Notes

- **Branch hygiene** (CLAUDE.md): All tasks land on `feat/vibe-demote-python`. RTL follow-up (if GO) gets its own fresh branch off `origin/main`.
- **Squash at PR time**: per CLAUDE.md, when the plan is fully implemented and tests pass, squash all of the plan's commits into a single PR commit. Verify every commit belongs to the plan (Tasks 1–9) before squashing.
- **Snapshot pre-existing state**: this plan does not change any existing ViBe / EMA / PBAS behavior. All `make test-ip`, `make lint`, `make run-pipeline` on existing profiles must continue to pass throughout (the bit-exact regression test from Task 2 is the gate).
- **Out of scope** (do not implement in this plan):
  - RTL changes beyond the cfg_t shadow.
  - New ctrl_flow modules.
  - RGB extension to ViBe or PBAS (separate Phase 2 plan).
  - Composition with `vibe_init_external` (a `vibe_demote_external` profile).
