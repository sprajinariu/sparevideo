# Multi-source real demos + EXP=1 backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand the README demo to a curated set of real-video clips (starting at 3 — `intersection`, `birdseye`, `people` — matching the three raws already staged in `media/source_raw/`), add a fast Python-model "experimental" backend triggered by `EXP=1`, and standardize new-clip prep behind a `make demo-prepare` target.

**Architecture:** Makefile gets a `REAL_SOURCES` list and a `demo-real-%` pattern rule. A new top-level `EXP` variable dispatches `DEMO_BACKEND={rtl,model}`, `DEMO_FRAMES={45,150}`, and `DEMO_DRAFT_DIR={demo-draft,demo-draft-exp}` so `EXP=1` runs land in a dir `demo-publish` won't read (un-publishable by construction). The model backend invokes a new `harness.py model` subcommand that wraps the existing bit-accurate `run_model()` and writes binary output frames in the same format the RTL produces — downstream WebP composer is backend-agnostic. Stabilized 320×240 clip masters live at 10 s (150 frames); the publish path consumes the first 45 frames (3 s) so README WebPs stay github-renderable.

**Tech Stack:** GNU Make, Python 3 + venv (numpy, OpenCV, Pillow), Verilator (untouched), existing `py/harness.py` / `py/models/` / `py/demo/stabilize.py`.

**Reference spec:** [docs/plans/2026-05-04-demo-real-sources-design.md](2026-05-04-demo-real-sources-design.md)

**Branch:** `feat/demo-real-sources` (already created from `origin/main`; design spec already committed).

**Files this plan touches:**

| File | Action | Purpose |
|------|--------|---------|
| `.gitignore` | Modify | Add `media/source_raw/` and `media/demo-draft-exp/` |
| `py/harness.py` | Modify | Add `model` subcommand |
| `py/tests/test_harness_model.py` | Create | Unit test for the new subcommand |
| `Makefile` | Modify | `REAL_SOURCES`, `demo-real-%`, `EXP=1` dispatch, `demo-prepare`, help |
| `media/source/pexels-pedestrians-320x240.mp4` | Delete | Replaced by `intersection-320x240.mp4` |
| `media/source/intersection-320x240.mp4` | Create | Re-stabilized at 10 s from `media/source_raw/intersection.mp4` |
| `media/source/birdseye-320x240.mp4` | Create | New, 10 s, stabilized from `media/source_raw/birdseye.mp4` |
| `media/source/people-320x240.mp4` | Create | New, 10 s, stabilized from `media/source_raw/people.mp4` |
| `media/source/README.md` | Modify | Document new naming + all three clips, point at `make demo-prepare` |
| `media/demo/synthetic.webp` | Modify | Regenerated (45 frames, no other change) |
| `media/demo/intersection.webp` | Create | Replaces `real.webp` |
| `media/demo/birdseye.webp` | Create | New triptych |
| `media/demo/people.webp` | Create | New triptych |
| `media/demo/real.webp` | Delete | Renamed to `intersection.webp` |
| `README.md` | Modify | Rename real→intersection demo section, add two new clip sections, mention `EXP=1` and `make demo-prepare` |

---

## Task 1: Update `.gitignore`

**Files:**
- Modify: `.gitignore` (top of file, in the existing demo block)

- [ ] **Step 1.1: Add the two new ignored dirs to `.gitignore`**

Edit the existing demo block (currently lines 18–20):

```
# Demo working dir — outputs of `make demo[-synthetic|-real]` land here.
# `make demo-publish` promotes them to media/demo/ for the README.
media/demo-draft/
```

Replace with:

```
# Demo working dirs.
# `make demo[-…]`        writes RTL-backend WebPs here (publishable).
# `make demo[-…] EXP=1`  writes Python-model-backend WebPs to demo-draft-exp/
#                        (NOT publishable — demo-publish never reads from here).
media/demo-draft/
media/demo-draft-exp/

# Raw downloaded MP4s. Stage here before running `make demo-prepare`.
# Stabilized 320x240 masters land in media/source/ (committed); raws are local-only.
media/source_raw/
```

- [ ] **Step 1.2: Verify `git status` no longer lists the staged raw dir**

Run: `git status --short`
Expected: no `media/source_raw/` line. The directory still exists on disk; it's just ignored.

- [ ] **Step 1.3: Commit**

```bash
git add .gitignore
git commit -m "chore(demo): gitignore source_raw/ and demo-draft-exp/"
```

---

## Task 2: Add `harness.py model` subcommand (TDD)

The model subcommand reads input frames, runs `run_model(ctrl_flow, frames, **cfg)`, and writes the result as a binary frame file in the same format `make sim` produces — letting the demo recipe substitute model output for RTL output transparently.

**Files:**
- Create: `py/tests/test_harness_model.py`
- Modify: `py/harness.py` (add `cmd_model`, argparse subparser, dispatch)

- [ ] **Step 2.1: Write the failing test**

Create `py/tests/test_harness_model.py`:

```python
"""Unit tests for the `harness.py model` subcommand.

Covers the plumbing only: reads input.bin, calls run_model, writes output.bin
in the same binary format `make sim` produces. The model itself is exercised
in test_models.py.
"""

import argparse
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np

from frames.frame_io import read_frames, write_frames
from models import run_model
from profiles import resolve as resolve_cfg
from harness import cmd_model


def _make_test_frames(width=8, height=4, num_frames=3):
    rng = np.random.RandomState(42)
    return [rng.randint(0, 256, (height, width, 3), dtype=np.uint8)
            for _ in range(num_frames)]


def test_model_passthrough_binary():
    """cmd_model output equals run_model('passthrough') output, frame-for-frame."""
    frames = _make_test_frames()
    h, w, _ = frames[0].shape
    n = len(frames)

    with tempfile.TemporaryDirectory() as td:
        in_path  = Path(td) / "input.bin"
        out_path = Path(td) / "output.bin"
        write_frames(in_path, frames, mode="binary")

        args = argparse.Namespace(
            input=str(in_path), output=str(out_path),
            ctrl_flow="passthrough", cfg="default",
            width=w, height=h, frames=n, mode="binary",
        )
        cmd_model(args)

        got = read_frames(out_path, mode="binary")
        cfg = resolve_cfg("default")
        expected = run_model("passthrough", frames, **cfg)

        assert len(got) == len(expected), \
            f"frame count mismatch: got {len(got)} expected {len(expected)}"
        for i, (a, e) in enumerate(zip(got, expected)):
            np.testing.assert_array_equal(
                a, e, err_msg=f"frame {i} differs from run_model output")


def test_model_motion_demo_profile():
    """cmd_model with cfg=demo and ctrl_flow=motion matches run_model() exactly.

    Frame size 64x32 — wide enough for the post-scaler HUD bitmap (8x8 glyphs)
    not to clip; HUD is enabled in the demo profile.
    """
    rng = np.random.RandomState(7)
    frames = [rng.randint(0, 256, (32, 64, 3), dtype=np.uint8) for _ in range(4)]

    with tempfile.TemporaryDirectory() as td:
        in_path  = Path(td) / "input.bin"
        out_path = Path(td) / "output.bin"
        write_frames(in_path, frames, mode="binary")

        args = argparse.Namespace(
            input=str(in_path), output=str(out_path),
            ctrl_flow="motion", cfg="demo",
            width=64, height=32, frames=4, mode="binary",
        )
        cmd_model(args)

        got = read_frames(out_path, mode="binary")
        cfg = resolve_cfg("demo")
        expected = run_model("motion", frames, **cfg)

        assert len(got) == len(expected) == 4
        for i, (a, e) in enumerate(zip(got, expected)):
            np.testing.assert_array_equal(
                a, e, err_msg=f"frame {i} differs from run_model output")


if __name__ == "__main__":
    test_model_passthrough_binary()
    test_model_motion_demo_profile()
    print("All tests passed!")
```

- [ ] **Step 2.2: Run the test and verify it fails**

Run: `.venv/bin/python3 py/tests/test_harness_model.py`
Expected: `ImportError: cannot import name 'cmd_model' from 'harness'` (or similar — the function does not exist yet).

- [ ] **Step 2.3: Add `cmd_model` and the `model` subparser to `py/harness.py`**

In `py/harness.py`, add a new function `cmd_model` immediately after `cmd_render` (line 161 area):

```python
def cmd_model(args):
    """Run the bit-accurate Python reference model and write its output as
    a frame file. Used by `make demo … EXP=1` so demo iterations on new
    clips can skip the slow Verilator compile+sim step.

    The model is the same one `cmd_verify` uses; we just plumb its output
    to a file in the format `make sim` produces.
    """
    width, height, num_frames = _resolve_dims(args)

    if args.mode == "text":
        input_frames = read_frames(args.input, mode="text",
                                   width=width, height=height,
                                   num_frames=num_frames)
    else:
        input_frames = read_frames(args.input, mode="binary")

    cfg = resolve_cfg(args.cfg)
    output_frames = run_model(args.ctrl_flow, input_frames, **cfg)

    write_frames(args.output, output_frames, mode=args.mode)
    print(f"Wrote {len(output_frames)} model frames to {args.output} "
          f"(ctrl_flow={args.ctrl_flow}, cfg={args.cfg})")
```

In `main()`, add a subparser block (after the existing `# render` block, around line 217):

```python
    # model
    p_mod = sub.add_parser("model", parents=[common],
                           help="Run reference model, write output frame file")
    p_mod.add_argument("--input",  default="dv/data/input.bin",
                       help="Input file (text or binary)")
    p_mod.add_argument("--output", default="dv/data/output.bin",
                       help="Output file (text or binary)")
    p_mod.add_argument("--ctrl-flow", default="passthrough",
                       choices=["passthrough", "motion", "mask", "ccl_bbox"],
                       help="Control flow model to run")
    p_mod.add_argument("--cfg", default="default",
                       choices=list(PROFILES.keys()),
                       help="Algorithm profile name (see py/profiles.py)")
```

In the dispatch chain at the bottom of `main()`, add:

```python
    elif args.command == "model":
        cmd_model(args)
```

- [ ] **Step 2.4: Run the test and verify it passes**

Run: `.venv/bin/python3 py/tests/test_harness_model.py`
Expected: `All tests passed!`

- [ ] **Step 2.5: Wire the test into `make test-py` so it runs in CI flow**

Edit `Makefile`, the `test-py` target (around line 256). Replace:

```make
test-py:
	$(VENV_PY) $(CURDIR)/py/tests/test_frame_io.py
	$(VENV_PY) $(CURDIR)/py/tests/test_models.py
```

with:

```make
test-py:
	$(VENV_PY) $(CURDIR)/py/tests/test_frame_io.py
	$(VENV_PY) $(CURDIR)/py/tests/test_models.py
	$(VENV_PY) $(CURDIR)/py/tests/test_harness_model.py
```

- [ ] **Step 2.6: Run the full Python test suite**

Run: `make test-py`
Expected: all three test files print `All tests passed!` (or equivalent), exit 0.

- [ ] **Step 2.7: Smoke-test the subcommand from the CLI**

Run:
```bash
mkdir -p /tmp/sv-smoke
cd py && .venv/bin/python3 ../py/harness.py prepare \
    --source synthetic:moving_box --width 32 --height 24 --frames 3 \
    --mode binary --output /tmp/sv-smoke/in.bin
cd py && .venv/bin/python3 ../py/harness.py model \
    --input /tmp/sv-smoke/in.bin --output /tmp/sv-smoke/out.bin \
    --mode binary --ctrl-flow passthrough --cfg default
ls -l /tmp/sv-smoke/out.bin
rm -rf /tmp/sv-smoke
```

Expected: `out.bin` exists and is `12 + 32*24*3*3 = 6924` bytes (header + 3 RGB frames).

(If your venv path differs, use `.venv/bin/python3` from the repo root; the existing `make` targets use `$(VENV_PY)`.)

- [ ] **Step 2.8: Commit**

```bash
git add py/harness.py py/tests/test_harness_model.py Makefile
git commit -m "feat(harness): add 'model' subcommand for fast demo backend"
```

---

## Task 3: Add `make demo-prepare` target

A thin Makefile wrapper over `python -m demo.stabilize`, with required `SRC` / `NAME` and sensible defaults. This is what new-clip workflows will call going forward.

**Files:**
- Modify: `Makefile` (new target in the demo block, around line 224)

- [ ] **Step 3.1: Add the target**

In `Makefile`, after the `demo-publish` recipe (around the line `# ---- Other targets ----`, ~line 251), insert:

```make
# Stabilize a raw downloaded MP4 into a 320x240 demo master.
#   Required: SRC=path/to/raw.mp4 NAME=<short-name>
#   Optional: START=<sec> DURATION=<sec> (defaults: 0, 10)
#             WIDTH/HEIGHT/FPS inherit DEMO_WIDTH/DEMO_HEIGHT/DEMO_FPS
# Output: media/source/$(NAME)-$(WIDTH)x$(HEIGHT).mp4
DEMO_PREP_START    ?= 0
DEMO_PREP_DURATION ?= 10
demo-prepare:
	@if [ -z "$(SRC)" ] || [ -z "$(NAME)" ]; then \
	    echo "usage: make demo-prepare SRC=<raw.mp4> NAME=<short-name> \\"; \
	    echo "                         [START=<s>] [DURATION=<s>]"; \
	    echo ""; \
	    echo "  SRC      Path to raw download (e.g. media/source_raw/foo.mp4)"; \
	    echo "  NAME     Short scenario name (e.g. intersection, birdseye)"; \
	    echo "  START    Trim start seconds into source (default $(DEMO_PREP_START))"; \
	    echo "  DURATION Trim duration in seconds   (default $(DEMO_PREP_DURATION))"; \
	    exit 2; \
	fi
	@mkdir -p $(CURDIR)/media/source
	cd $(CURDIR) && PYTHONPATH=py $(VENV_PY) -m demo.stabilize \
	    --src $(SRC) \
	    --dst $(CURDIR)/media/source/$(NAME)-$(DEMO_WIDTH)x$(DEMO_HEIGHT).mp4 \
	    --start $(DEMO_PREP_START) --duration $(DEMO_PREP_DURATION) \
	    --width $(DEMO_WIDTH) --height $(DEMO_HEIGHT) --fps $(DEMO_FPS)
	@echo "Wrote media/source/$(NAME)-$(DEMO_WIDTH)x$(DEMO_HEIGHT).mp4"
	@echo "  Record this invocation in media/source/README.md, then commit"
	@echo "  the new MP4 alongside the README update."
```

Also add `demo-prepare` to the `.PHONY` line (line 41):

```make
.PHONY: help lint run-pipeline prepare compile sim sw-dry-run verify render sim-waves \
        test-py test-ip test-ip-window test-ip-hflip test-ip-gamma-cor test-ip-scale2x setup clean \
        demo demo-synthetic demo-real demo-publish demo-prepare
```

- [ ] **Step 3.2: Test missing-args path**

Run: `make demo-prepare`
Expected:
- Exit code 2
- Output starts with `usage: make demo-prepare SRC=<raw.mp4> NAME=<short-name>`

Run: `make demo-prepare SRC=foo.mp4`
Expected: same usage banner, exit 2.

- [ ] **Step 3.3: Sanity-check the recipe expands correctly**

Run: `make -n demo-prepare SRC=media/source_raw/intersection.mp4 NAME=test`
Expected: dry-run output contains `python -m demo.stabilize`, `--src media/source_raw/intersection.mp4`, `--dst <repo>/media/source/test-320x240.mp4`, `--start 0 --duration 10`.

(Don't actually run the full prep here — that's part of Task 5.)

- [ ] **Step 3.4: Commit**

```bash
git add Makefile
git commit -m "feat(make): add demo-prepare target wrapping demo.stabilize"
```

---

## Task 4a: Refactor demo block — `REAL_SOURCES` + pattern rule

Replace the hardcoded `demo-real:` recipe with a list-driven pattern rule. **No EXP=1 logic yet** — that's Task 4b. After this task `make demo-real` still works exactly as today, just driven by the list.

**Files:**
- Modify: `Makefile` (the demo block, lines 171–223)

- [ ] **Step 4a.1: Replace the demo block**

Delete the existing `demo:` / `demo-synthetic:` / `demo-real:` block (lines 185–223 — start at `demo: demo-synthetic demo-real` and end at the line `@echo "Draft WebP written ... /real.webp ..."` for the `demo-real` recipe).

Insert in its place:

```make
# Curated set of real-video demo clips. Each <name> here corresponds to a
# committed master at media/source/<name>-$(DEMO_WIDTH)x$(DEMO_HEIGHT).mp4
# (produced via `make demo-prepare`). Adding a clip is a one-line edit here
# plus a stabilize run.
REAL_SOURCES ?= intersection birdseye people

demo: demo-synthetic demo-real

demo-synthetic:
	$(MAKE) prepare SOURCE=synthetic:multi_speed_color \
	    WIDTH=$(DEMO_WIDTH) HEIGHT=$(DEMO_HEIGHT) FRAMES=$(DEMO_FRAMES) MODE=binary CFG=demo
	$(MAKE) compile CTRL_FLOW=ccl_bbox CFG=demo
	$(MAKE) sim     CTRL_FLOW=ccl_bbox CFG=demo
	cp $(CURDIR)/dv/data/output.bin $(CURDIR)/dv/data/output_ccl_bbox.bin
	$(MAKE) compile CTRL_FLOW=motion CFG=demo
	$(MAKE) sim     CTRL_FLOW=motion CFG=demo
	cp $(CURDIR)/dv/data/output.bin $(CURDIR)/dv/data/output_motion.bin
	@mkdir -p $(DEMO_DRAFT_DIR)
	cd $(CURDIR) && PYTHONPATH=py $(VENV_PY) -m demo \
	    --input  dv/data/input.bin \
	    --ccl    dv/data/output_ccl_bbox.bin \
	    --motion dv/data/output_motion.bin \
	    --out    $(DEMO_DRAFT_DIR)/synthetic.webp \
	    --width $(DEMO_WIDTH) --height $(DEMO_HEIGHT) --frames $(DEMO_FRAMES) \
	    --fps   $(DEMO_FPS)
	@echo "Draft WebP written to $(DEMO_DRAFT_DIR)/synthetic.webp — run 'make demo-publish' to promote."

demo-real: $(REAL_SOURCES:%=demo-real-%)

demo-real-%:
	$(MAKE) prepare SOURCE=$(CURDIR)/media/source/$*-$(DEMO_WIDTH)x$(DEMO_HEIGHT).mp4 \
	    WIDTH=$(DEMO_WIDTH) HEIGHT=$(DEMO_HEIGHT) FRAMES=$(DEMO_FRAMES) MODE=binary CFG=demo
	$(MAKE) compile CTRL_FLOW=ccl_bbox CFG=demo
	$(MAKE) sim     CTRL_FLOW=ccl_bbox CFG=demo
	cp $(CURDIR)/dv/data/output.bin $(CURDIR)/dv/data/output_ccl_bbox.bin
	$(MAKE) compile CTRL_FLOW=motion CFG=demo
	$(MAKE) sim     CTRL_FLOW=motion CFG=demo
	cp $(CURDIR)/dv/data/output.bin $(CURDIR)/dv/data/output_motion.bin
	@mkdir -p $(DEMO_DRAFT_DIR)
	cd $(CURDIR) && PYTHONPATH=py $(VENV_PY) -m demo \
	    --input  dv/data/input.bin \
	    --ccl    dv/data/output_ccl_bbox.bin \
	    --motion dv/data/output_motion.bin \
	    --out    $(DEMO_DRAFT_DIR)/$*.webp \
	    --width $(DEMO_WIDTH) --height $(DEMO_HEIGHT) --frames $(DEMO_FRAMES) \
	    --fps   $(DEMO_FPS)
	@echo "Draft WebP written to $(DEMO_DRAFT_DIR)/$*.webp — run 'make demo-publish' to promote."
```

- [ ] **Step 4a.2: Update `demo-publish` to handle the list of real names**

The existing `demo-publish` recipe (lines 228–249) hardcodes `for name in synthetic real`. Replace that loop driver:

Find the line:

```make
	@for name in synthetic real; do \
```

Replace with:

```make
	@for name in synthetic $(REAL_SOURCES); do \
```

Also update the help-text fallback message in the same recipe — find:

```make
	    echo "Nothing published. Run 'make demo' or 'make demo-synthetic'/'make demo-real' first."; \
```

Replace with:

```make
	    echo "Nothing published. Run 'make demo' or 'make demo-synthetic'/'make demo-real-<name>' first."; \
```

- [ ] **Step 4a.3: Verify pattern-rule expansion**

Run: `make -n demo-real`
Expected: prints three `$(MAKE) demo-real-intersection`, `$(MAKE) demo-real-birdseye`, and `$(MAKE) demo-real-people` invocations (or whichever names are in `REAL_SOURCES`).

Run: `make -n demo-real-intersection`
Expected: dry-run prints recipe with `SOURCE=…/media/source/intersection-320x240.mp4` and `--out …/media/demo-draft/intersection.webp`.

(Note: the actual sources don't exist yet — that's fine, dry-run doesn't read them. Real execution waits for Tasks 5 + 6.)

- [ ] **Step 4a.4: Commit**

```bash
git add Makefile
git commit -m "refactor(make): drive demo-real from REAL_SOURCES pattern rule"
```

---

## Task 4b: Add `EXP=1` dispatch — model backend + alt draft dir

Replace `compile`+`sim` with `harness.py model` invocations when `EXP=1`, route output to `media/demo-draft-exp/`, and use `DEMO_EXP_FRAMES` instead of `DEMO_PUBLISH_FRAMES`.

**Files:**
- Modify: `Makefile` (demo block — DEMO_FRAMES variable rename, EXP dispatch, recipes)

- [ ] **Step 4b.1: Add the EXP variable + derived dispatch above the demo block**

Find the line `DEMO_FRAMES      ?= 45` (in the `# ---- README demo …` section) and replace the entire variables block (currently 6 lines starting at `DEMO_FRAMES`):

```make
DEMO_FRAMES      ?= 45
DEMO_WIDTH       ?= 320
DEMO_HEIGHT      ?= 240
DEMO_FPS         ?= 15
DEMO_DRAFT_DIR   ?= $(CURDIR)/media/demo-draft
DEMO_PUBLISH_DIR ?= $(CURDIR)/media/demo
```

with:

```make
DEMO_PUBLISH_FRAMES ?= 45      # 3 s @ 15 fps — README WebPs (default)
DEMO_EXP_FRAMES     ?= 150     # 10 s @ 15 fps — full master, EXP=1 runs
DEMO_WIDTH          ?= 320
DEMO_HEIGHT         ?= 240
DEMO_FPS            ?= 15
DEMO_PUBLISH_DIR    ?= $(CURDIR)/media/demo

# EXP=1 runs the bit-accurate Python reference model in place of the RTL
# simulator (much faster) and routes output to a separate draft dir that
# demo-publish never reads — so EXP runs are physically un-publishable.
EXP ?= 0
ifeq ($(EXP),1)
DEMO_BACKEND   := model
DEMO_FRAMES    ?= $(DEMO_EXP_FRAMES)
DEMO_DRAFT_DIR ?= $(CURDIR)/media/demo-draft-exp
else
DEMO_BACKEND   := rtl
DEMO_FRAMES    ?= $(DEMO_PUBLISH_FRAMES)
DEMO_DRAFT_DIR ?= $(CURDIR)/media/demo-draft
endif
```

(`?=` lets command-line `DEMO_FRAMES=…` still override either branch — preserves the existing knob.)

- [ ] **Step 4b.2: Add the model-backend branch to `demo-synthetic`**

In the `demo-synthetic:` recipe, replace the four lines that start with `$(MAKE) compile` … `$(MAKE) sim … cp …` (the ccl_bbox + motion sim block) with this `ifeq`-gated block:

Find:

```make
	$(MAKE) compile CTRL_FLOW=ccl_bbox CFG=demo
	$(MAKE) sim     CTRL_FLOW=ccl_bbox CFG=demo
	cp $(CURDIR)/dv/data/output.bin $(CURDIR)/dv/data/output_ccl_bbox.bin
	$(MAKE) compile CTRL_FLOW=motion CFG=demo
	$(MAKE) sim     CTRL_FLOW=motion CFG=demo
	cp $(CURDIR)/dv/data/output.bin $(CURDIR)/dv/data/output_motion.bin
```

Replace with:

```make
ifeq ($(DEMO_BACKEND),rtl)
	$(MAKE) compile CTRL_FLOW=ccl_bbox CFG=demo
	$(MAKE) sim     CTRL_FLOW=ccl_bbox CFG=demo
	cp $(CURDIR)/dv/data/output.bin $(CURDIR)/dv/data/output_ccl_bbox.bin
	$(MAKE) compile CTRL_FLOW=motion CFG=demo
	$(MAKE) sim     CTRL_FLOW=motion CFG=demo
	cp $(CURDIR)/dv/data/output.bin $(CURDIR)/dv/data/output_motion.bin
else
	cd py && $(HARNESS) model --input $(CURDIR)/dv/data/input.bin \
	    --output $(CURDIR)/dv/data/output_ccl_bbox.bin \
	    --mode binary --ctrl-flow ccl_bbox --cfg demo
	cd py && $(HARNESS) model --input $(CURDIR)/dv/data/input.bin \
	    --output $(CURDIR)/dv/data/output_motion.bin \
	    --mode binary --ctrl-flow motion --cfg demo
endif
```

- [ ] **Step 4b.3: Make the same replacement in `demo-real-%`**

Identical block, identical replacement.

- [ ] **Step 4b.4: Verify the EXP path expands correctly (no execution yet)**

Run: `make -n demo-real-intersection`
Expected: contains `compile CTRL_FLOW=ccl_bbox`, `sim`, no `harness.py model`. Frames should be 45.

Run: `make -n demo-real-intersection EXP=1`
Expected:
- contains `harness.py model --input`, `--ctrl-flow ccl_bbox`, `--ctrl-flow motion`
- does **not** contain `verilator` / `compile CTRL_FLOW=` / `$(MAKE) sim`
- `--out` path includes `media/demo-draft-exp/intersection.webp`
- `--frames 150` and `FRAMES=150` appear

You can grep:
```bash
make -n demo-real-intersection EXP=1 | grep -E '(harness.py model|demo-draft-exp|--frames 150)'
make -n demo-real-intersection EXP=1 | grep -E '(verilator|CTRL_FLOW=ccl_bbox CFG=demo$)' || echo "OK — no RTL refs"
```

- [ ] **Step 4b.5: Verify EXP=1 routes through `demo-publish` correctly**

Run: `make -n demo-publish EXP=1`
Expected: the recipe still references `media/demo-draft-exp/` as the source dir but `media/demo/` as the destination. **Important security check:** demo-publish should refuse to copy from `demo-draft-exp/` into `demo/`. Update the publish recipe to enforce this.

Find the existing `demo-publish:` recipe and change the source path inside the `for` loop. Locate:

```make
	    src=$(DEMO_DRAFT_DIR)/$$name.webp; \
```

Replace with a hardcoded reference to the publishable draft dir (so `EXP=1` cannot accidentally redirect publish):

```make
	    src=$(CURDIR)/media/demo-draft/$$name.webp; \
```

This makes `demo-publish` always read from `media/demo-draft/`, regardless of `EXP`. EXP draft contents are physically unreachable through publish.

Re-verify: `make -n demo-publish EXP=1` shows `src=…/media/demo-draft/synthetic.webp`, NOT `…/media/demo-draft-exp/…`.

- [ ] **Step 4b.6: Commit**

```bash
git add Makefile
git commit -m "feat(make): EXP=1 dispatches Python model backend, isolated draft dir"
```

---

## Task 4c: Update `make help` output

**Files:**
- Modify: `Makefile` (the `help:` recipe, lines 45–107)

- [ ] **Step 4c.1: Update the demo-relevant lines in help**

In the `help:` recipe, find the four demo lines (around lines 63–67):

```make
	@echo "    demo                  Build both demo WebPs into media/demo-draft/ (gitignored)"
	@echo "    demo-synthetic        Build media/demo-draft/synthetic.webp from synthetic:multi_speed_color"
	@echo "    demo-real             Build media/demo-draft/real.webp from media/source/pexels-pedestrians-320x240.mp4"
	@echo "                          (real-clip prep: see media/source/README.md and py/demo/stabilize.py)"
	@echo "    demo-publish          Promote media/demo-draft/*.webp to media/demo/ (README-referenced)"
	@echo "                          Override: WHICH=both|synthetic|real (default both)"
```

Replace with:

```make
	@echo "    demo                  Build all demo WebPs into media/demo-draft/ (gitignored)"
	@echo "    demo-synthetic        Build the synthetic-source WebP (multi_speed_color)"
	@echo "    demo-real             Build all real-source WebPs (each name in REAL_SOURCES)"
	@echo "    demo-real-<name>      Build one real WebP (e.g. demo-real-intersection)"
	@echo "    demo-publish          Promote media/demo-draft/*.webp to media/demo/"
	@echo "                          Override: WHICH=both|<name> (default both)"
	@echo "    demo-prepare          Stabilize a raw download into a 320x240 demo master."
	@echo "                          Required: SRC=raw.mp4 NAME=<short>; opt START/DURATION."
	@echo ""
	@echo "  Demo knobs:"
	@echo "    EXP=1                 Use Python reference model (fast). Output → media/demo-draft-exp/."
	@echo "                          EXP runs are NOT publishable (demo-publish reads media/demo-draft/ only)."
	@echo "    DEMO_PUBLISH_FRAMES=45    Frame count for default (RTL) demo runs"
	@echo "    DEMO_EXP_FRAMES=150       Frame count for EXP=1 (model) runs"
	@echo "    REAL_SOURCES='a b'    Curated real clips (default: intersection birdseye people)"
```

- [ ] **Step 4c.2: Verify**

Run: `make help | grep -A1 'demo-real'`
Expected: shows the new aggregator + pattern-rule lines.

Run: `make help | grep EXP=1`
Expected: prints the EXP=1 knob line.

- [ ] **Step 4c.3: Commit**

```bash
git add Makefile
git commit -m "docs(make): help text for REAL_SOURCES, demo-real-%, demo-prepare, EXP=1"
```

---

## Task 5: Stabilize the `intersection` clip at 10 s

The current committed master is 3 s. Re-run the stabilizer at 10 s into the new filename.

**Files:**
- Delete: `media/source/pexels-pedestrians-320x240.mp4`
- Create: `media/source/intersection-320x240.mp4`

- [ ] **Step 5.1: Verify the raw download is in `media/source_raw/`**

Run: `ls media/source_raw/intersection.mp4`
Expected: file exists. (If the user's raw is named differently — e.g. `4791734-…` — substitute the path everywhere below.)

- [ ] **Step 5.2: Run the stabilizer via the new target**

Run:
```bash
make demo-prepare SRC=media/source_raw/intersection.mp4 NAME=intersection \
                  START=0 DURATION=10
```

Expected:
- prints `Wrote stabilized clip to <repo>/media/source/intersection-320x240.mp4`
- `media/source/intersection-320x240.mp4` exists

(If `ffprobe` is installed it can confirm the encoded metadata, but OpenCV's
mp4v writer can be off-by-one in `nb_frames`. The authoritative check is
reading back with cv2 — see step 5.3.)

- [ ] **Step 5.3: Verify frame count by reading**

Run:
```bash
.venv/bin/python3 -c "
import cv2
cap = cv2.VideoCapture('media/source/intersection-320x240.mp4')
n = 0
while True:
    ok, _ = cap.read()
    if not ok: break
    n += 1
print(f'frames={n}')
"
```
Expected: `frames=150`.

- [ ] **Step 5.4: `git rm` the old clip**

Run:
```bash
git rm media/source/pexels-pedestrians-320x240.mp4
```

- [ ] **Step 5.5: Stage the new clip**

Run:
```bash
git add media/source/intersection-320x240.mp4
git status --short
```
Expected: shows `D media/source/pexels-pedestrians-320x240.mp4` and `A media/source/intersection-320x240.mp4`. Size should be ~700 KB–1 MB (10 s mp4v).

- [ ] **Step 5.6: Commit**

```bash
git commit -m "feat(demo): rename pedestrians→intersection, restabilize at 10s"
```

---

## Task 6: Stabilize the two additional real sources (`birdseye`, `people`)

Stabilize both remaining raws into 10 s / 320×240 / 15 fps masters. Same flow as Task 5 — repeat once per source. The default `REAL_SOURCES` list (`intersection birdseye people`) expects names matching the raw filenames; if you decide a different short name better describes the scene (e.g. `highway` for a highway clip), rename here AND update `REAL_SOURCES` in `Makefile` to match before proceeding.

**Files:**
- Create: `media/source/birdseye-320x240.mp4`
- Create: `media/source/people-320x240.mp4`

- [ ] **Step 6.1: Inspect both raws**

Run:
```bash
for f in media/source_raw/birdseye.mp4 media/source_raw/people.mp4; do
  echo "== $f =="
  .venv/bin/python3 -c "
import cv2, sys
cap = cv2.VideoCapture('$f')
fps = cap.get(cv2.CAP_PROP_FPS)
w   = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
h   = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
n   = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
dur = n / fps if fps else float('nan')
print(f'  {w}x{h} @ {fps:.2f} fps, {n} frames, {dur:.1f} s total')
"
done
```
Expected: prints dimensions, framerate, total duration for each raw.

For each clip, decide:
- A scenario name (default = the raw filename root: `birdseye`, `people`)
- A `START` value for the most interesting 10 s window

If you pick names other than the defaults, update `REAL_SOURCES` in `Makefile` accordingly and commit that change before proceeding to step 6.2.

- [ ] **Step 6.2: Preview each window before committing to a stabilize**

For each clip, run a quick preview with a tentative `START`:

```bash
# birdseye
.venv/bin/python3 -m demo.stabilize \
    --src media/source_raw/birdseye.mp4 --dst /tmp/preview-birdseye.mp4 \
    --start 0 --duration 10 --width 320 --height 240 --fps 15
explorer.exe "$(wslpath -w /tmp/preview-birdseye.mp4)" 2>/dev/null || \
  echo "Preview at /tmp/preview-birdseye.mp4"

# people
.venv/bin/python3 -m demo.stabilize \
    --src media/source_raw/people.mp4 --dst /tmp/preview-people.mp4 \
    --start 0 --duration 10 --width 320 --height 240 --fps 15
explorer.exe "$(wslpath -w /tmp/preview-people.mp4)" 2>/dev/null || \
  echo "Preview at /tmp/preview-people.mp4"
```

Inspect each: does the 10 s window contain useful motion (objects in motion, fixed camera, no abrupt cuts)? If not, rerun with a different `--start`. Note the final `START` for each.

- [ ] **Step 6.3: Stabilize `birdseye` into `media/source/`**

Run (substituting the chosen `START`):

```bash
make demo-prepare SRC=media/source_raw/birdseye.mp4 NAME=birdseye \
                  START=<chosen> DURATION=10
```

Verify frame count:

```bash
.venv/bin/python3 -c "
import cv2
cap = cv2.VideoCapture('media/source/birdseye-320x240.mp4')
n = 0
while True:
    ok, _ = cap.read()
    if not ok: break
    n += 1
print(f'frames={n}')
"
```
Expected: `frames=150`.

- [ ] **Step 6.4: Stabilize `people` into `media/source/`**

```bash
make demo-prepare SRC=media/source_raw/people.mp4 NAME=people \
                  START=<chosen> DURATION=10
```

Verify:

```bash
.venv/bin/python3 -c "
import cv2
cap = cv2.VideoCapture('media/source/people-320x240.mp4')
n = 0
while True:
    ok, _ = cap.read()
    if not ok: break
    n += 1
print(f'frames={n}')
"
```
Expected: `frames=150`.

- [ ] **Step 6.5: Stage + commit both**

```bash
git add media/source/birdseye-320x240.mp4 media/source/people-320x240.mp4
git commit -m "feat(demo): add birdseye and people real-source clips (10s stabilized)"
```

(If you renamed either source, substitute the chosen names in the file paths and commit message, and verify the corresponding `Makefile` `REAL_SOURCES` update was already committed.)

---

## Task 7: Update `media/source/README.md`

Replace the per-clip prep recipe with a recipe table and a pointer to `make demo-prepare`.

**Files:**
- Modify: `media/source/README.md`

- [ ] **Step 7.1: Replace the file contents**

Overwrite `media/source/README.md` with:

```markdown
# Source clips

Stabilized 320×240 / 15 fps / 10 s masters consumed by `make demo-real-<name>`.
Pre-trimmed and stabilized so the existing OpenCV loader can ingest them
directly — the motion-detection RTL assumes a fixed camera, and raw clips
almost always have sub-pixel tripod sway / autofocus jitter that would
otherwise produce global motion masks.

Raw downloads are kept locally in `media/source_raw/` (gitignored). They are
re-derivable from the source URLs below.

## Naming convention

`<scenario>-<W>x<H>.mp4`. Scenario is a short name (`intersection`, `birdseye`,
`people`, …) that also forms the published WebP filename in `media/demo/<scenario>.webp`.
The list of currently-built clips is `REAL_SOURCES` in the root `Makefile`.

## Adding or replacing a clip

1. Drop the raw download into `media/source_raw/`.
2. Pick a 10-second window with interesting motion. Iterate by running
   `python -m demo.stabilize` directly with different `--start` values into
   `/tmp/preview.mp4`.
3. Once happy, run:
   ```bash
   make demo-prepare SRC=media/source_raw/<raw>.mp4 NAME=<scenario> \
                     START=<sec> DURATION=10
   ```
   Output: `media/source/<scenario>-320x240.mp4`.
4. If the scenario is new, append it to `REAL_SOURCES` in the root `Makefile`.
5. Record the prep command in this README under "Clips" below.
6. Regenerate WebPs: `make demo-real-<scenario>` then `make demo-publish`.
7. Commit the new master MP4, the README update, the regenerated WebP, and
   any `Makefile` change in one logical commit.

## Clips

### `intersection-320x240.mp4`

- **Description:** Intersection fixed camera (cars + pedestrians).
- **Source:** https://www.pexels.com/video/traffic-flow-in-an-intersection-4791734/
- **License:** Pexels License — free for commercial and non-commercial use,
  modification and redistribution permitted, no attribution required.
  See https://www.pexels.com/license/.
- **Prep command:**
  ```bash
  make demo-prepare SRC=media/source_raw/intersection.mp4 NAME=intersection \
                    START=0 DURATION=10
  ```

### `birdseye-320x240.mp4`

- **Description:** [TODO at execution time: 1-line scene description.]
- **Source:** [TODO: source URL of the raw download.]
- **License:** [TODO: e.g. "Pexels License (see above)" — fill in once URL is recorded.]
- **Prep command:**
  ```bash
  make demo-prepare SRC=media/source_raw/birdseye.mp4 NAME=birdseye \
                    START=<chosen> DURATION=10
  ```

### `people-320x240.mp4`

- **Description:** [TODO at execution time: 1-line scene description.]
- **Source:** [TODO: source URL of the raw download.]
- **License:** [TODO: e.g. "Pexels License (see above)".]
- **Prep command:**
  ```bash
  make demo-prepare SRC=media/source_raw/people.mp4 NAME=people \
                    START=<chosen> DURATION=10
  ```

(If different short names were chosen for either clip, replace `birdseye` /
`people` above with the chosen name and update `REAL_SOURCES` in the root
`Makefile` to match.)
```

- [ ] **Step 7.2: Fill in the per-clip TODOs**

Edit `media/source/README.md`'s `### birdseye-320x240.mp4` and `### people-320x240.mp4` sections: replace each `[TODO …]` marker with the actual description, source URL, license, and `START` value used in Task 6. Do not commit until all three TODOs per clip are filled in for both clips.

- [ ] **Step 7.3: Commit**

```bash
git add media/source/README.md
git commit -m "docs(source): document new naming + intersection/birdseye/people clips"
```

---

## Task 8: Regenerate WebPs (RTL backend)

This is the slow step — runs Verilator twice per source. Expect ~15–25 min total wall-clock for 1 synthetic + 3 real clips × 2 ctrl-flows.

**Files:**
- Modify: `media/demo/synthetic.webp` (regenerated)
- Create: `media/demo/intersection.webp` (replaces `real.webp`)
- Create: `media/demo/birdseye.webp`
- Create: `media/demo/people.webp`
- Delete: `media/demo/real.webp`

- [ ] **Step 8.1: Confirm a clean working tree (commit-wise)**

Run: `git status --short`
Expected: no staged or modified files (everything from prior tasks is committed). Untracked files in `media/source_raw/` and `media/demo-draft/` are fine — both gitignored.

- [ ] **Step 8.2: Run the full demo build**

Run: `make demo`
Expected: synthetic + 3 real sources each run `prepare` → `compile` → `sim ccl_bbox` → `compile` → `sim motion` → composes WebP. Final draft files:
- `media/demo-draft/synthetic.webp`
- `media/demo-draft/intersection.webp`
- `media/demo-draft/birdseye.webp`
- `media/demo-draft/people.webp`

If a sim fails on a particular clip, the most likely cause is the clip having too-large global motion that the stabilizer didn't fully suppress (CCL overflow / spurious mask everywhere). Mitigation: re-run the relevant Task 6 step with a different `--start` value, then rerun just the failing target via `make demo-real-<name>`.

- [ ] **Step 8.3: Sanity-preview each draft WebP**

Run (one per panel; WSL-specific):
```bash
for name in synthetic intersection birdseye people; do
  explorer.exe "$(wslpath -w media/demo-draft/$name.webp)"
done
```
Expected: each opens in your default image viewer; each is a 3-panel triptych (Input | CCL BBOX | MOTION) animating at ~15 fps, 3 s long.

- [ ] **Step 8.4: Promote to `media/demo/`**

Run: `make demo-publish`
Expected: prints four `published … -> …` lines (one per clip) and `media/demo/` now contains:
- `synthetic.webp`
- `intersection.webp`
- `birdseye.webp`
- `people.webp`

- [ ] **Step 8.5: Remove the obsolete `real.webp`**

Run:
```bash
git rm media/demo/real.webp
```

- [ ] **Step 8.6: Stage + commit the new WebPs**

```bash
git add media/demo/synthetic.webp media/demo/intersection.webp \
        media/demo/birdseye.webp media/demo/people.webp
git status --short
```
Expected: shows four modified/added WebPs and one deleted (`real.webp`).

```bash
git commit -m "demo: regenerated WebPs (synthetic + intersection + birdseye + people)"
```

---

## Task 9: Update root `README.md`

**Files:**
- Modify: `README.md` (Demo section + Regenerating-the-demo section)

- [ ] **Step 9.1: Update the Demo section (lines 5–19)**

Find lines 5–19, currently:

```markdown
## Demo

End-to-end animated triptychs: **Input | CCL BBOX | MOTION**, each panel 320×240, ~3 s @ 15 fps, regenerable from `make demo`.

### Synthetic input (`multi_speed_color`)

![Synthetic demo](media/demo/synthetic.webp)

Three colored objects with distinct speeds and trajectories on a tinted textured background. Used as the canonical regression-style demo: deterministic, fully regenerable, frame 0 is bg-only by construction so EMA priming starts clean.

### Real video (Pexels intersection)

![Real demo](media/demo/real.webp)

Top-down view of an intersection (cars + pedestrians). 3 s window from a Pexels-licensed clip, pre-stabilized to remove tripod sway (the motion-detect RTL assumes a fixed camera). The first ~1 s of output frames contain no bboxes — `grace_frames=16` blanks the mask while the EMA background converges past frame-0 contamination. Source clip and prep command: [`media/source/README.md`](media/source/README.md).
```

Replace with:

```markdown
## Demo

End-to-end animated triptychs: **Input | CCL BBOX | MOTION**, each panel 320×240, ~3 s @ 15 fps, regenerable from `make demo`.

### Synthetic input (`multi_speed_color`)

![Synthetic demo](media/demo/synthetic.webp)

Three colored objects with distinct speeds and trajectories on a tinted textured background. Used as the canonical regression-style demo: deterministic, fully regenerable, frame 0 is bg-only by construction so EMA priming starts clean.

### Real video — intersection (Pexels)

![Intersection demo](media/demo/intersection.webp)

Top-down view of an intersection (cars + pedestrians). 3 s window from a Pexels-licensed clip, pre-stabilized to remove tripod sway (the motion-detect RTL assumes a fixed camera).

### Real video — birdseye

![Birdseye demo](media/demo/birdseye.webp)

[TODO at execution time: 1-line scene description matching what's actually in the birdseye clip.]

### Real video — people

![People demo](media/demo/people.webp)

[TODO at execution time: 1-line scene description matching what's actually in the people clip.]

Source clips and prep commands: [`media/source/README.md`](media/source/README.md).
```

- [ ] **Step 9.2: Fill in the per-clip-section TODOs**

Replace each `[TODO at execution time …]` placeholder in the birdseye and people sections with a real one-sentence scene description matching the actual clip content.

- [ ] **Step 9.3: Update the "Regenerating the demo" section (lines 181–199)**

Find and replace the section starting `### Regenerating the demo` and ending after `… see [media/source/README.md](media/source/README.md).`. Replace its body with:

```markdown
### Regenerating the demo

Two-stage workflow: build to a gitignored draft dir, preview, then publish to the README-referenced dir when happy.

```bash
make demo                                                          # build all WebPs into media/demo-draft/
make demo-synthetic                                                # just media/demo-draft/synthetic.webp
make demo-real                                                     # all real WebPs (every name in REAL_SOURCES)
make demo-real-intersection                                        # one real WebP
explorer.exe "$(wslpath -w media/demo-draft/intersection.webp)"    # preview the draft (WSL)
make demo-publish                                                  # promote media/demo-draft/*.webp → media/demo/
make demo-publish WHICH=synthetic                                  # promote one panel only (WHICH=<name>)
grip README.md                                                     # preview README at github.com fidelity
```

`media/demo-draft/` is gitignored — iterate freely. `media/demo/` is what the README points at; commit the published WebPs alongside the RTL change that produced them.

**Iterating on a new real clip without RTL sim.** Pass `EXP=1` to use the bit-accurate Python reference model in place of Verilator. Output lands in `media/demo-draft-exp/` (gitignored), which `demo-publish` never reads — so EXP runs are physically un-publishable.

```bash
make demo-real-birdseye EXP=1                                      # ~15 sec; output → media/demo-draft-exp/birdseye.webp
explorer.exe "$(wslpath -w media/demo-draft-exp/birdseye.webp)"
```

EXP runs default to 10 s (`DEMO_EXP_FRAMES=150`) so you can see the full master; default RTL runs use 3 s (`DEMO_PUBLISH_FRAMES=45`) for a github-friendly README WebP.

Knobs: `DEMO_PUBLISH_FRAMES=45 DEMO_EXP_FRAMES=150 DEMO_WIDTH=320 DEMO_HEIGHT=240 DEMO_FPS=15`. Each build target runs `prepare → compile → sim` twice (once for `ccl_bbox`, once for `motion`) under `CFG=demo`, then assembles the triptych via `python -m demo`. With `EXP=1` the `compile`+`sim` pair is replaced by `python harness.py model`.

**Adding a new real clip.** Stage a raw download under `media/source_raw/` (gitignored), then:

```bash
make demo-prepare SRC=media/source_raw/foo.mp4 NAME=foo START=0 DURATION=10
# adds media/source/foo-320x240.mp4
# add 'foo' to REAL_SOURCES in the Makefile
make demo-real-foo EXP=1                                           # quick preview
make demo-real-foo                                                 # final RTL build
make demo-publish WHICH=foo
```

See [`media/source/README.md`](media/source/README.md) for license notes and per-clip prep commands.

`grip` is an optional dev tool (`pip install grip`) that renders local markdown using GitHub's API — useful for confirming the README looks right before pushing.
```

- [ ] **Step 9.4: Render-check the README**

Run: `grip README.md` (if installed, opens a localhost preview) or just visually scan with `less README.md`. Confirm:
- The Demo section shows four panels (synthetic, intersection, birdseye, people) in order.
- All `media/demo/*.webp` paths in the markdown match files that actually exist in `media/demo/`.
- No remaining references to `real.webp` or `pexels-pedestrians-320x240.mp4`.

```bash
grep -nE 'real\.webp|pexels-pedestrians' README.md
```
Expected: no matches.

- [ ] **Step 9.5: Commit**

```bash
git add README.md
git commit -m "docs(readme): four demo panels (synthetic + 3 real), document EXP=1 and demo-prepare"
```

---

## Task 10: End-to-end integration check

Verify the full feature works as a connected whole.

- [ ] **Step 10.1: Clean workspace**

Run: `make clean`
Expected: removes `dv/data/*`, `renders/`, etc. Working tree should still have `media/source/`, `media/demo/`, all source code.

- [ ] **Step 10.2: Run `make demo EXP=1` end-to-end FIRST (fast)**

Run: `make demo EXP=1`
Expected: produces all four draft WebPs in `media/demo-draft-exp/`. Wall-clock ~30–90 sec total — the model is much faster than RTL. Each EXP WebP is 10 s.

If anything looks wrong (clip framing, motion content, etc.) at this stage, fix it before paying the RTL cost in step 10.3. Iterate by re-running individual `make demo-real-<name> EXP=1` invocations.

- [ ] **Step 10.3: Run `make demo` (RTL) end-to-end (slow)**

Run: `make demo`
Expected: produces all four draft WebPs in `media/demo-draft/` (3 s each). Wall-clock ~15–25 min.

- [ ] **Step 10.4: Confirm `demo-publish` ignores EXP runs**

Run: `make demo-publish`
Expected: copies `media/demo-draft/*.webp` (the RTL outputs) into `media/demo/`. The EXP outputs in `media/demo-draft-exp/` remain there — never copied.

Verify: `ls media/demo/*.webp` should still show the 4 RTL-built panels (3 s each), not the EXP versions.

- [ ] **Step 10.5: Confirm `make help` is current**

Run: `make help`
Expected: lists `demo-real-<name>`, `demo-prepare`, `EXP=1` knob, `DEMO_PUBLISH_FRAMES`, `DEMO_EXP_FRAMES`, `REAL_SOURCES`.

- [ ] **Step 10.6: Run all unit tests**

Run: `make test-py`
Expected: all three test files print `All tests passed!`.

Run: `make test-ip` (if you have time — this is the per-IP testbench suite, ~5–10 min)
Expected: all per-block tests pass. The RTL hasn't changed, so this is a regression check only — should be unchanged from `main`.

- [ ] **Step 10.7: Final `git status`**

Run: `git status`
Expected: clean working tree. All commits recorded:

Run: `git log --oneline origin/main..HEAD`
Expected: roughly the following sequence of commits (more if you split tasks):
```
… docs(readme): four demo panels (synthetic + 3 real), document EXP=1 and demo-prepare
… demo: regenerated WebPs (synthetic + intersection + birdseye + people)
… docs(source): document new naming + intersection/birdseye/people clips
… feat(demo): add birdseye and people real-source clips (10s stabilized)
… feat(demo): rename pedestrians→intersection, restabilize at 10s
… docs(make): help text for REAL_SOURCES, demo-real-%, demo-prepare, EXP=1
… feat(make): EXP=1 dispatches Python model backend, isolated draft dir
… refactor(make): drive demo-real from REAL_SOURCES pattern rule
… feat(make): add demo-prepare target wrapping demo.stabilize
… feat(harness): add 'model' subcommand for fast demo backend
… chore(demo): gitignore source_raw/ and demo-draft-exp/
… docs(plans): design for multi-source real demos + EXP=1 backend
```

---

## Task 11: Squash + open PR

Per `CLAUDE.md`: "Squash at plan completion. Once a plan is fully implemented and its tests pass, squash all of the plan's commits into a single commit before opening the PR."

- [ ] **Step 11.1: Confirm no foreign commits slipped in**

Run: `git log --oneline origin/main..HEAD`
Expected: every commit listed should be plan-scoped (per the table in Step 10.7). If anything unrelated slipped in, move it to its own branch + PR before squashing.

- [ ] **Step 11.2: Squash to a single commit**

Run:
```bash
git reset --soft origin/main
git commit -m "$(cat <<'EOF'
feat(demo): multi-source real demos + EXP=1 model backend

- REAL_SOURCES list-driven Makefile with `demo-real-%` pattern rule
  (currently intersection + birdseye + people; 1-line edit to add more).
- EXP=1 swaps RTL for the bit-accurate Python reference model,
  routes output to media/demo-draft-exp/ (un-publishable by
  construction). Default RTL run produces 3s WebPs for the README;
  EXP run produces 10s for full-master previewing.
- New `make demo-prepare` wraps py/demo/stabilize.py. Raw downloads
  live in media/source_raw/ (gitignored); stabilized 10s 320x240
  masters live committed in media/source/.
- New `harness.py model` subcommand wraps run_model() and writes
  binary frame files matching the format `make sim` produces.
- Renamed the Pexels intersection clip
  (pexels-pedestrians-320x240.mp4 → intersection-320x240.mp4) and
  re-stabilized at 10s. Added two new clips (birdseye, people).
- Regenerated all four demo WebPs (1 synthetic + 3 real).
- Updated README.md and media/source/README.md.
EOF
)"
```

- [ ] **Step 11.3: Push and open the PR**

Run:
```bash
git push -u origin feat/demo-real-sources
gh pr create --title "feat(demo): multi-source real demos + EXP=1 model backend" --body "$(cat <<'EOF'
## Summary
- Adds an `EXP=1` flag to `make demo*` that uses the Python reference model instead of Verilator (~30s vs ~20min) and isolates output to `media/demo-draft-exp/` so it's un-publishable by construction.
- Replaces hardcoded `make demo-real` with a `REAL_SOURCES`-driven pattern rule. Adding a new clip is now a one-line Makefile edit + a `make demo-prepare` run.
- Adds `make demo-prepare` wrapping `py/demo/stabilize.py` for new-clip prep.
- Standardizes on 10s stabilized masters; publish path uses the first 3s for github-renderable WebPs.
- Renames the existing Pexels intersection clip and adds two new real clips (birdseye, people) for a 4-panel demo.

Design spec: [docs/plans/2026-05-04-demo-real-sources-design.md](docs/plans/2026-05-04-demo-real-sources-design.md)

## Test plan
- [ ] `make test-py` (includes new `test_harness_model.py`)
- [ ] `make demo` regenerates all WebPs (RTL backend)
- [ ] `make demo EXP=1` regenerates all preview WebPs (model backend) into `media/demo-draft-exp/`
- [ ] `make demo-publish` only copies RTL outputs (never EXP)
- [ ] `make demo-prepare` errors with a usage banner if `SRC` or `NAME` is missing
- [ ] README renders correctly (three demo panels)
EOF
)"
```

Expected: PR opened, returns the URL.

---

## Self-Review Notes

The plan has been self-reviewed against the spec. Key checks:

**Spec coverage:**
- §"Directory layout" → Tasks 1, 5, 6
- §"Make interface" REAL_SOURCES + targets → Tasks 4a, 4c
- §"Make interface" `demo-prepare` → Task 3
- §"Backend dispatch" → Tasks 2, 4b
- §"Length policy" → Task 4b (DEMO_PUBLISH_FRAMES / DEMO_EXP_FRAMES)
- §"Stabilization model" → no work (already adequate per spec)
- §"Rollout / migration" steps 1–9 → Tasks 1, 5, 6, 2, 4a/4b, 7, 9, 8 (in implementation order, not migration order)

**One spec-vs-plan deviation:** Step 4b.5 hardens `demo-publish` by hardcoding its source dir to `media/demo-draft/` — going slightly beyond the spec's "directory isolation" guarantee. Without this, a user could (in theory) `make demo-publish EXP=1` and override `DEMO_DRAFT_DIR` to publish EXP runs. With the hardcode, EXP runs are truly un-publishable. Good defensive code; matches the spec's intent.

**Type / name consistency:**
- `cmd_model` defined in Task 2, used in Task 2 only — consistent.
- `REAL_SOURCES` defined in Task 4a, used in Tasks 4a, 4b, 4c, 9 — consistent.
- `EXP`, `DEMO_BACKEND`, `DEMO_FRAMES`, `DEMO_DRAFT_DIR`, `DEMO_PUBLISH_FRAMES`, `DEMO_EXP_FRAMES` — all defined in Task 4b, used downstream consistently.
- `intersection-320x240.mp4` filename — used in 5, 6, 7, 8, 9 consistently.

**Open at execution time (intentional, not a placeholder):**
- Per-clip `START` value for `birdseye` and `people` — Task 6 steps 6.1 + 6.2 (chosen interactively after previewing each window).
- Scenario name for `birdseye` and `people` — defaults match the raw filenames (`birdseye`, `people`). User may rename, in which case Task 6.1 also requires updating `REAL_SOURCES` in `Makefile`.
- One-line scene descriptions + source URLs + license notes for `birdseye` and `people` in `README.md` and `media/source/README.md` — Tasks 7.2 and 9.2 (filled in once each clip is chosen).

These are explicit fill-in steps with clear instructions, not placeholder hand-waving.
