# `stabilize_frames` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a post-grace **stabilize window** to `axis_motion_detect` that suppresses the slow-EMA branch so the grace→selective-EMA transition can't bake fresh contamination into a multi-frame ghost.

**Architecture:** New `cfg_t.stabilize_frames` field + new counter + new `in_stabilize` flag in `axis_motion_detect.sv`. While in the stabilize window, every pixel uses the fast EMA rate regardless of `raw_motion`, so any cliff residual decays below THRESH within ~4–5 frames before slow EMA can latch on it. Mask output is enabled (bboxes appear). When `stabilize_frames=0` the algorithm collapses to current behavior, so all existing regression vectors are bit-accurate.

**Tech Stack:** SystemVerilog (Verilator), Python 3 (NumPy + Pillow + OpenCV via the existing harness).

**Spec:** `docs/plans/2026-04-30-motion-stabilize-frames-design.md`.

---

## Preamble — Branch creation

Per CLAUDE.md, every plan gets its own fresh branch off `origin/main`. Before starting Task 1:

```bash
git fetch origin
git checkout -b feat/motion-stabilize-frames origin/main
```

Do **not** start this work on `feat/readme-demo` or any other in-flight branch. The dependency note: this plan is the algorithmic prerequisite for shipping the README-demo PR (`feat/readme-demo`) — once this plan merges, that branch should be rebased on top, the demo profile should be rebuilt with `stabilize_frames=8`, and the WebPs regenerated.

---

## Task 1: Add `stabilize_frames` field to `cfg_t` and propagate through profiles

**Files:**
- Modify: `hw/top/sparevideo_pkg.sv` — add field to struct, every existing `CFG_*` localparam gets `stabilize_frames: 0`.
- Modify: `py/profiles.py` — add `stabilize_frames=0` to `DEFAULT`; all derived profiles inherit.
- Test: `py/tests/test_profiles.py` (no code change needed — existing parity test catches the new field).

- [ ] **Step 1: Read existing `cfg_t` struct in `sparevideo_pkg.sv`**

Read the field list to confirm the order and types. The new field is `int stabilize_frames` placed adjacent to `grace_frames` for grouping with grace-related parameters.

- [ ] **Step 2: Add the field to the struct definition**

Edit `hw/top/sparevideo_pkg.sv`. Find the `typedef struct packed { ... } cfg_t;` block and insert `int stabilize_frames;` immediately after `int grace_alpha_shift;` (or wherever the grace-related fields cluster).

```systemverilog
        int         grace_frames;
        int         grace_alpha_shift;
        int         stabilize_frames;     // ← new
        logic       gauss_en;
```

- [ ] **Step 3: Add `stabilize_frames: 0` to every `CFG_*` localparam**

Find every `localparam cfg_t CFG_<name>` block (`CFG_DEFAULT`, `CFG_DEFAULT_HFLIP`, `CFG_NO_EMA`, `CFG_NO_MORPH`, `CFG_NO_GAUSS`, `CFG_NO_GAMMA_COR`, `CFG_NO_SCALER`, `CFG_DEMO`, `CFG_NO_HUD`). For each, insert `stabilize_frames: 0,` immediately after `grace_alpha_shift:`.

`CFG_DEMO` will get a non-zero value in Task 6 — leave it 0 for now so this task is purely a structural addition.

- [ ] **Step 4: Update Python profiles**

In `py/profiles.py`, add `stabilize_frames=0` to the `DEFAULT` dict (the master template that other profiles `dict()`-derive from). All derived profiles inherit automatically.

- [ ] **Step 5: Run profile parity test**

```bash
source .venv/bin/activate
pytest py/tests/test_profiles.py -v
```

Expected: PASS. The parity test verifies every Python profile dict has the same key set as the SV `cfg_t` struct.

- [ ] **Step 6: Run lint**

```bash
make lint
```

Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add hw/top/sparevideo_pkg.sv py/profiles.py
git commit -m "motion: add stabilize_frames field to cfg_t (zero-default everywhere)"
```

---

## Task 2: Propagate `STABILIZE_FRAMES` parameter through wrapper

**Files:**
- Modify: `hw/top/sparevideo_top.sv` — pass `CFG.stabilize_frames` as `.STABILIZE_FRAMES(...)` to the `axis_motion_detect` instance.
- Modify: `hw/ip/motion/rtl/axis_motion_detect.sv` — add `parameter int STABILIZE_FRAMES = 0` to the module port list. Don't use it yet (Task 3 will).

- [ ] **Step 1: Add the parameter to `axis_motion_detect`**

Find the existing parameter list at the top of `axis_motion_detect.sv` (it has `ALPHA_SHIFT`, `ALPHA_SHIFT_SLOW`, `GRACE_FRAMES`, `GRACE_ALPHA_SHIFT`, etc.). Add:

```systemverilog
    parameter int STABILIZE_FRAMES   = 0,   // post-grace fast-only window; 0 disables
```

Place it adjacent to `GRACE_FRAMES` for ordering.

- [ ] **Step 2: Wire it up in `sparevideo_top.sv`**

Find the `u_motion` (or similarly-named) instance of `axis_motion_detect`. Add the parameter line to the named-parameter list:

```systemverilog
    .STABILIZE_FRAMES   (CFG.stabilize_frames),
```

Place adjacent to `.GRACE_FRAMES(CFG.grace_frames)`.

- [ ] **Step 3: Compile + smoke**

```bash
make run-pipeline SOURCE=synthetic:moving_box CTRL_FLOW=motion CFG=default FRAMES=4
```

Expected: completes successfully. `STABILIZE_FRAMES=0` so no behavior change; this task is plumbing only.

- [ ] **Step 4: Lint**

```bash
make lint
```

Expected: clean. (Verilator may warn about unused `STABILIZE_FRAMES` parameter at this stage — that's fine, the next task uses it.)

- [ ] **Step 5: Commit**

```bash
git add hw/ip/motion/rtl/axis_motion_detect.sv hw/top/sparevideo_top.sv
git commit -m "motion: thread STABILIZE_FRAMES parameter through wrapper (no logic yet)"
```

---

## Task 3: Implement the stabilize counter and `in_stabilize` flag in RTL

**Files:**
- Modify: `hw/ip/motion/rtl/axis_motion_detect.sv` — add counter, flag, and update the `bg_next` selector.

This task adds the logic but **does not change Python model yet** — verification will fail until Task 4. Don't run `make run-pipeline CFG=demo` until Task 4 lands.

- [ ] **Step 1: Read existing grace counter for pattern reference**

In `axis_motion_detect.sv`, the existing grace logic looks like:

```systemverilog
localparam int GRACE_CNT_W = $clog2(GRACE_FRAMES + 1);
logic [GRACE_CNT_W-1:0] grace_cnt;
logic                   in_grace;

assign in_grace = primed && (grace_cnt < (GRACE_CNT_W)'(GRACE_FRAMES));

always_ff @(posedge clk_i) begin
    if (!rst_n_i)
        grace_cnt <= '0;
    else if (beat_done_eof && in_grace)
        grace_cnt <= grace_cnt + 1'b1;
end
```

The stabilize counter mirrors this structure.

- [ ] **Step 2: Add the stabilize counter and flag**

Add (adjacent to the grace block):

```systemverilog
localparam int STAB_CNT_W = $clog2(STABILIZE_FRAMES + 1) > 0 ? $clog2(STABILIZE_FRAMES + 1) : 1;
logic [STAB_CNT_W-1:0] stabilize_cnt;
logic                  in_stabilize;

// in_stabilize is asserted only after grace has finished, until the
// stabilize counter saturates at STABILIZE_FRAMES.
assign in_stabilize = primed && !in_grace
                              && (stabilize_cnt < (STAB_CNT_W)'(STABILIZE_FRAMES));

always_ff @(posedge clk_i) begin
    if (!rst_n_i)
        stabilize_cnt <= '0;
    else if (beat_done_eof && in_stabilize)
        stabilize_cnt <= stabilize_cnt + 1'b1;
end
```

The `STAB_CNT_W` ternary handles `STABILIZE_FRAMES=0`: `$clog2(1)=0`, so the counter would be width 0; the ternary clamps to width 1 (which never gets used because `in_stabilize` is then always 0).

- [ ] **Step 3: Update `bg_next` selector**

Find the existing `always_comb` for `bg_next`:

```systemverilog
always_comb begin
    if (!primed)
        bg_next = y_smooth;
    else if (in_grace)
        bg_next = ema_update_grace;
    else if (!raw_motion)
        bg_next = ema_update;
    else
        bg_next = ema_update_slow;
end
```

Insert the stabilize branch:

```systemverilog
always_comb begin
    if (!primed)
        bg_next = y_smooth;          // frame-0 hard-init
    else if (in_grace)
        bg_next = ema_update_grace;  // grace window → aggressive rate
    else if (in_stabilize)
        bg_next = ema_update;        // stabilize window → fast rate, no slow latch
    else if (!raw_motion)
        bg_next = ema_update;        // post-stabilize non-motion → fast rate
    else
        bg_next = ema_update_slow;   // post-stabilize motion → slow rate
end
```

- [ ] **Step 4: Confirm the mask gating is unchanged**

The existing `assign m_axis_msk.tdata = mask_bit && !in_grace;` line stays as-is. Stabilize emits real masks.

- [ ] **Step 5: Lint**

```bash
make lint
```

Expected: clean.

- [ ] **Step 6: Smoke (existing CFG_DEFAULT, stabilize_frames=0)**

```bash
make run-pipeline SOURCE=synthetic:moving_box CTRL_FLOW=motion CFG=default FRAMES=4
```

Expected: pipeline completes; `verify` passes at `TOLERANCE=0`. With `stabilize_frames=0` the new branch never fires, so behavior is bit-identical to before.

- [ ] **Step 7: Commit**

```bash
git add hw/ip/motion/rtl/axis_motion_detect.sv
git commit -m "motion: implement in_stabilize counter + bg_next branch"
```

---

## Task 4: Mirror the stabilize regime in the Python reference model

**Files:**
- Modify: `py/models/motion.py` — add the same `in_stabilize` logic to the EMA loop.

The model must be bit-accurate against the RTL since `make verify` runs at `TOLERANCE=0`.

- [ ] **Step 1: Read existing grace logic in `motion.py`**

Locate the per-frame EMA loop. The existing logic has a grace counter that mirrors the RTL — find it and copy the pattern.

- [ ] **Step 2: Add stabilize counter and branch**

Mirror the SV logic in Python:

```python
# After the grace block, add:
in_stabilize = primed and not in_grace and stabilize_cnt < cfg["stabilize_frames"]

# In the bg_next branch ladder:
if not primed:
    bg_next = y_smooth
elif in_grace:
    bg_next = ema_update_grace
elif in_stabilize:
    bg_next = ema_update              # ← new branch
elif not raw_motion:
    bg_next = ema_update
else:
    bg_next = ema_update_slow

# At end of frame:
if primed and not in_grace and in_stabilize:
    stabilize_cnt += 1
```

(Adapt to whatever the actual variable names and structure are in `motion.py` — read the existing code first, don't blindly paste.)

- [ ] **Step 3: Run model unit tests**

```bash
source .venv/bin/activate
pytest py/tests/test_models.py -v
```

Expected: PASS. Existing tests use profiles where `stabilize_frames=0`, so no behavior change.

- [ ] **Step 4: Run a `CFG=demo` smoke pipeline**

This is the first end-to-end check that the model + RTL agree on the stabilize regime.

```bash
make run-pipeline SOURCE=synthetic:multi_speed_color CTRL_FLOW=motion CFG=demo FRAMES=8
```

Expected: completes; `verify` passes at `TOLERANCE=0`. With `CFG_DEMO.stabilize_frames=0` (still the value from Task 1) the branch isn't actually exercised yet — that happens in Task 6.

- [ ] **Step 5: Commit**

```bash
git add py/models/motion.py
git commit -m "motion: mirror in_stabilize regime in Python reference model"
```

---

## Task 5: Add cliff-bake-in regression test

**Files:**
- Create: a new test in `py/tests/test_models.py` (or extend the existing motion model tests).

This test makes the cliff scenario reproducible: an object present at the last grace frame, removed at the next frame. With `stabilize_frames=0` the test asserts a ghost mask appears (regression-pinning today's bad behavior). With `stabilize_frames=8` it asserts the ghost has decayed below THRESH within the stabilize window.

- [ ] **Step 1: Write the test**

```python
import numpy as np
from py.models.motion import run_motion_model
from py.profiles import DEMO


def _make_cliff_scenario(width, height, num_frames, grace_frames, fg_luma=200, bg_luma=50):
    """Pixel P has fg_luma during the last grace frame, bg_luma everywhere else.

    This is the minimal case that triggers cliff bake-in: the EMA averages bg ≈
    fg_luma at end of grace; at frame grace_frames+1 the pixel reverts to bg_luma,
    raw_motion fires, and (without stabilize) slow EMA latches on the contamination.
    """
    frames = np.full((num_frames, height, width, 3), bg_luma, dtype=np.uint8)
    last_grace_frame = grace_frames  # frame index 0..grace_frames-1 are grace; frame grace_frames is post-grace
    # Place a 4x4 fg patch in the centre during the last grace frame only.
    cy, cx = height // 2, width // 2
    frames[last_grace_frame - 1, cy:cy+4, cx:cx+4] = fg_luma
    return frames


def test_cliff_ghost_with_stabilize_zero(tmp_path):
    """Without stabilize, the cliff ghost persists past frame grace_frames+1."""
    cfg = dict(DEMO, stabilize_frames=0, grace_frames=8)
    frames = _make_cliff_scenario(64, 48, num_frames=20, grace_frames=cfg["grace_frames"])
    masks = run_motion_model(frames, cfg)
    cy, cx = 24, 32
    # At frame grace_frames+2 (well past the cliff), the centre patch should still be flagged
    assert masks[cfg["grace_frames"] + 2, cy, cx] == 1, \
        "expected cliff bake-in ghost without stabilize_frames"


def test_cliff_ghost_cleared_with_stabilize_eight(tmp_path):
    """With stabilize_frames=8, the cliff ghost decays within the stabilize window."""
    cfg = dict(DEMO, stabilize_frames=8, grace_frames=8)
    frames = _make_cliff_scenario(64, 48, num_frames=20, grace_frames=cfg["grace_frames"])
    masks = run_motion_model(frames, cfg)
    cy, cx = 24, 32
    # By frame grace_frames + stabilize_frames + 1, the ghost must be gone.
    assert masks[cfg["grace_frames"] + cfg["stabilize_frames"] + 1, cy, cx] == 0, \
        "expected cliff ghost cleared after stabilize_frames"
```

(Adjust the `run_motion_model` import path and signature to match the actual `py/models/motion.py` interface — read the existing entrypoint first.)

- [ ] **Step 2: Run the tests**

```bash
pytest py/tests/test_models.py -v -k cliff
```

Expected: both new tests PASS. The first asserts today's broken behavior is reproducible; the second asserts the new mechanism fixes it.

- [ ] **Step 3: Commit**

```bash
git add py/tests/test_models.py
git commit -m "motion: regression test for cliff bake-in with/without stabilize_frames"
```

---

## Task 6: Set `CFG_DEMO.stabilize_frames=8`

**Files:**
- Modify: `hw/top/sparevideo_pkg.sv` — flip `CFG_DEMO.stabilize_frames` from 0 to 8.
- Modify: `py/profiles.py` — set `DEMO`'s `stabilize_frames=8` override.

- [ ] **Step 1: Update the SV CFG**

```systemverilog
localparam cfg_t CFG_DEMO = '{
    ...
    grace_frames:      16,
    grace_alpha_shift: 1,
    stabilize_frames:  8,    // ← was 0
    ...
};
```

- [ ] **Step 2: Update the Python profile**

```python
DEMO: ProfileT = dict(
    DEFAULT, scaler_en=False, gamma_en=False,
    alpha_shift=2, alpha_shift_slow=8, grace_frames=16, stabilize_frames=8,
)
```

- [ ] **Step 3: Run parity test + lint**

```bash
pytest py/tests/test_profiles.py -v
make lint
```

Expected: parity passes; lint clean.

- [ ] **Step 4: Verify model and RTL agree on the demo**

```bash
make run-pipeline SOURCE=synthetic:multi_speed_color CTRL_FLOW=motion CFG=demo FRAMES=45
```

Expected: `verify` passes at `TOLERANCE=0` over all 45 frames. With `stabilize_frames=8` the new branch is exercised but the model and RTL stay in lockstep.

- [ ] **Step 5: Commit**

```bash
git add hw/top/sparevideo_pkg.sv py/profiles.py
git commit -m "motion: enable stabilize_frames=8 in demo profile"
```

---

## Task 7: Update the architecture spec

**Files:**
- Modify: `docs/specs/axis_motion_detect-arch.md` — document the new regime.

- [ ] **Step 1: Add a stabilize-window subsection**

Adjacent to the existing grace-window section, add an equally-sized subsection covering:

- Purpose — smooth the grace→selective-EMA transition; defeat fresh contamination at the cliff.
- Trigger condition (`primed && !in_grace && stabilize_cnt < STABILIZE_FRAMES`).
- Behavior (fast EMA regardless of `raw_motion`; mask output enabled).
- Counter mechanics (advances on `beat_done_eof`).
- Worked example: pixel with `Y[grace_frames-1] = 200`, `Y[grace_frames] = 50`, with `STABILIZE_FRAMES=8` and α=1/4 fast — show how `bg` decays from contaminated to clean within the window.

- [ ] **Step 2: Update the regime table**

Find the existing table that summarizes priming / grace / selective EMA. Add a row for stabilize.

- [ ] **Step 3: Add a "Why selective EMA isn't enough" rationale**

Short paragraph (~3-5 sentences) explaining the cliff issue and why a pure selective-EMA design without a stabilize window can't avoid it. Reference the design doc `docs/plans/2026-04-30-motion-stabilize-frames-design.md` for the deeper analysis.

- [ ] **Step 4: Commit**

```bash
git add docs/specs/axis_motion_detect-arch.md
git commit -m "docs: document stabilize_frames regime in axis_motion_detect arch spec"
```

---

## Task 8: Update CLAUDE.md and the project README

**Files:**
- Modify: `CLAUDE.md` — extend the motion-pipeline lessons section with the cliff/stabilize note.
- Modify: `README.md` — extend the motion-detection threshold subsection with a one-line mention of the new field.

- [ ] **Step 1: Add the lesson to CLAUDE.md**

In the `### Motion pipeline — lessons learned` section, add a new bullet:

> **Stabilize window prevents grace-cliff bake-in.** Selective EMA (slow rate when `raw_motion=1`) protects bg from absorbing stationary objects but creates a self-sustaining ghost when grace ends with fresh contamination. The `stabilize_frames` field of `cfg_t` (default 0; 8 in `CFG_DEMO`) enables an additional post-grace window where every pixel uses the fast EMA rate regardless of motion, letting the cliff residual decay below THRESH before slow EMA can latch on it. Mask output is enabled during stabilize so bboxes appear normally.

- [ ] **Step 2: Add the field mention to README.md**

In the existing "Motion detection threshold" subsection, append a line listing `stabilize_frames` alongside the other algorithm knobs.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: mention stabilize_frames in CLAUDE.md and README"
```

---

## Task 9: Final regression sweep + squash + PR

**Files:** none modified — verification + git operations only.

- [ ] **Step 1: Full Python tests**

```bash
make test-py
```

Expected: every test passes, including the new cliff regression tests.

- [ ] **Step 2: Per-IP unit tests**

```bash
make test-ip
```

Expected: every IP test passes.

- [ ] **Step 3: Default end-to-end (no stabilize)**

```bash
make run-pipeline SOURCE=synthetic:moving_box CTRL_FLOW=motion CFG=default FRAMES=8
```

Expected: pipeline completes; verify passes at `TOLERANCE=0`.

- [ ] **Step 4: Demo end-to-end (with stabilize)**

```bash
make run-pipeline SOURCE=synthetic:multi_speed_color CTRL_FLOW=motion CFG=demo FRAMES=45
```

Expected: `verify` passes at `TOLERANCE=0`. The stabilize branch is exercised and the Python model agrees pixel-perfectly with the RTL.

- [ ] **Step 5: Lint**

```bash
make lint
```

Expected: clean.

- [ ] **Step 6: Inspect commits**

```bash
git log --oneline origin/main..HEAD
```

Expected: 8 commits, all in scope. Move any unrelated commit to its own branch first.

- [ ] **Step 7: Squash**

```bash
git reset --soft origin/main
git commit -m "$(cat <<'EOF'
motion: add stabilize_frames to defeat grace-cliff bake-in

Adds a post-grace stabilize window to axis_motion_detect. While
in_stabilize, every pixel uses the fast EMA rate regardless of raw_motion,
so any cliff residual decays below THRESH within ~4-5 frames before slow
EMA can latch on it. Mask output is enabled (bboxes appear during the
window). When stabilize_frames=0 the branch never fires and the algorithm
collapses to the existing three-regime logic — all existing regression
vectors are bit-accurate.

- New cfg_t.stabilize_frames field (zero-default everywhere except CFG_DEMO=8).
- New STABILIZE_FRAMES module parameter on axis_motion_detect.
- New in_stabilize counter + bg_next branch.
- Python motion model mirrors the new branch exactly.
- Cliff-bake-in regression tests (with/without stabilize) in py/tests/test_models.py.
- Architecture spec and CLAUDE.md updated.
EOF
)"
```

- [ ] **Step 8: Push and PR**

```bash
git push -u origin feat/motion-stabilize-frames
gh pr create --title "motion: stabilize_frames regime to defeat grace-cliff bake-in" --body "..."
```

- [ ] **Step 9: Move design + plan to `docs/plans/old/`**

Per CLAUDE.md, after implementation the plan and design move:

```bash
mkdir -p docs/plans/old
git mv docs/plans/2026-04-30-motion-stabilize-frames-design.md docs/plans/old/
git mv docs/plans/2026-04-30-motion-stabilize-frames-plan.md   docs/plans/old/
git commit --amend --no-edit
git push --force-with-lease
```

---

## Self-review notes

- **Spec coverage** — every section of the design doc has at least one task: §4 algorithm → Tasks 1-3, §7.1-7.3 RTL → Tasks 1-3, §7.4 Python model → Task 4, §7.5 profiles → Tasks 1, 6, §7.6 tests → Task 5, §7.7 spec → Task 7.
- **No placeholders** — every task has concrete code or commands. Task 7 (arch spec) describes content rather than literal text because spec writing is content-shaped, not code-shaped.
- **Type consistency** — `stabilize_frames` (cfg_t int, Python int), `STABILIZE_FRAMES` (RTL parameter int), `in_stabilize` (RTL/Python flag), `stabilize_cnt` (RTL counter), all consistent across tasks.
- **Backward compat** — Task 1 sets `stabilize_frames=0` everywhere except where Task 6 explicitly enables it for `CFG_DEMO`. Existing regression vectors are bit-accurate.
