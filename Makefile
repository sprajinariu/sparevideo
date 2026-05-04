FUSESOC    := fusesoc
CORES_ROOT := --cores-root=. --cores-root=hw/ip/vga
VENV_PY    := $(CURDIR)/.venv/bin/python3
HARNESS    := $(VENV_PY) $(CURDIR)/py/harness.py
DATA_DIR   := dv/data

# Built-in defaults — lowest precedence.
SIMULATOR ?= verilator
SOURCE    ?= synthetic:moving_box
WIDTH     ?= 320
HEIGHT    ?= 240
FRAMES    ?= 16
MODE      ?= text
CTRL_FLOW ?= ccl_bbox
# Default tolerance: 0 (pixel-accurate model-based verification for all flows).
TOLERANCE ?= 0
# Algorithm tuning profile. See hw/top/sparevideo_pkg.sv for definitions
# and py/profiles.py for the Python mirror. To add a new profile, add
# entries in BOTH files (parity test catches drift).
CFG ?= default

# Load options saved by the last 'make prepare'.
# Overrides the ?= defaults above; command-line variables still win over this.
-include $(DATA_DIR)/config.mk

# Derived file paths — evaluated after config.mk is loaded so MODE is final.
ifeq ($(MODE),binary)
  PIPE_INFILE  = $(DATA_DIR)/input.bin
  PIPE_OUTFILE = $(DATA_DIR)/output.bin
else
  PIPE_INFILE  = $(DATA_DIR)/input.txt
  PIPE_OUTFILE = $(DATA_DIR)/output.txt
endif

SIM_VARS = SIMULATOR=$(SIMULATOR) \
           WIDTH=$(WIDTH) HEIGHT=$(HEIGHT) FRAMES=$(FRAMES) \
           MODE=$(MODE) CTRL_FLOW=$(CTRL_FLOW) CFG=$(CFG) \
           INFILE=$(CURDIR)/$(PIPE_INFILE) \
           OUTFILE=$(CURDIR)/$(PIPE_OUTFILE)

.PHONY: help lint run-pipeline prepare compile sim sw-dry-run verify render sim-waves \
        test-py test-ip test-ip-window test-ip-hflip test-ip-gamma-cor test-ip-scale2x setup clean \
        demo demo-synthetic demo-real demo-publish demo-prepare

help:
	@echo "Usage: make <target> [OPTIONS]"
	@echo ""
	@echo "  run-pipeline   Run full pipeline (prepare → compile → sim → verify → render)"
	@echo "  lint           Run Verilator lint on all RTL"
	@echo "  setup          One-time setup (install deps)"
	@echo "  clean          Remove build artifacts"
	@echo ""
	@echo "  Pipeline steps (also runnable individually after 'make prepare'):"
	@echo "    prepare      Generate input frames — saves WIDTH/HEIGHT/FRAMES/MODE to dv/data/config.mk"
	@echo "    compile      Compile RTL + testbench (SIMULATOR)"
	@echo "    sim          Run RTL simulation"
	@echo "    verify       Check output matches input (passthrough)"
	@echo "    render       Save input vs output comparison PNG"
	@echo ""
	@echo "  Additional targets:"
	@echo "    sim-waves             RTL sim + open GTKWave"
	@echo "    sw-dry-run            Bypass RTL (file loopback, zero sim time)"
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
	@echo ""
	@echo "    test-py               Run Python unit tests"
	@echo "    test-ip               All per-block IP unit testbenches (Verilator)"
	@echo "    test-ip-rgb2ycrcb          rgb2ycrcb: 18 vectors, exact-match golden model"
	@echo "    test-ip-window             axis_window3x3: 3x3 sliding window + edge replication, shared primitive"
	@echo "    test-ip-gauss3x3           axis_gauss3x3: 6 tests, uniform/impulse/gradient/checker/stall/SOF"
	@echo "    test-ip-motion-detect      axis_motion_detect GAUSS_EN=0: 8-frame golden model, stall, fork desync"
	@echo "    test-ip-motion-detect-gauss axis_motion_detect GAUSS_EN=1: 8-frame Gaussian golden model, stall"
	@echo "    test-ip-overlay-bbox       axis_overlay_bbox: 8 tests, empty/full/single-pixel/backpressure"
	@echo "    test-ip-ccl                axis_ccl: 6 tests, single/hollow/disjoint/U-shape/overflow/back-to-back"
	@echo "    test-ip-morph-clean        axis_morph_clean: 7 tests, (open_en,close_en,CLOSE_KERNEL) ∈ {0,1}²×{3,5}, backpressure, multi-frame"
	@echo "    test-ip-hflip              axis_hflip: 5 tests, mirror correctness, asymmetric stall, enable_i passthrough"
	@echo "    test-ip-gamma-cor          axis_gamma_cor: 4 tests, sRGB endpoint/ramp/stall/passthrough"
	@echo "    test-ip-scale2x            axis_scale2x: 2x bilinear upscaler"
	@echo ""
	@echo "  Options (command-line always wins; 'make prepare' saves them for later steps):"
	@echo "    SIMULATOR=verilator              Simulator: verilator"
	@echo "    SOURCE=synthetic:moving_box      Input source (prepare only). See sources below."
	@echo "    WIDTH=320                        Frame width"
	@echo "    HEIGHT=240                       Frame height"
	@echo "    FRAMES=16                        Number of frames"
	@echo "    MODE=text|binary                 File format"
	@echo "    CTRL_FLOW=motion|passthrough|mask|ccl_bbox Control flow (default ccl_bbox)"
	@echo "    TOLERANCE=<n>                    Max diff pixels/frame for verify (default 0 = exact)"
	@echo "    CFG=default                      Algorithm profile (default|default_hflip|no_ema|no_morph|no_gauss|no_gamma_cor|no_scaler)"
	@echo ""
	@echo "  Sources (SOURCE=):"
	@echo "    synthetic:moving_box       Red box, diagonal top-left → bottom-right"
	@echo "    synthetic:dark_moving_box  Dark box on bright background"
	@echo "    synthetic:two_boxes        Red + cyan boxes, opposing directions"
	@echo "    synthetic:noisy_moving_box Red box on noisy background (EMA test)"
	@echo "    synthetic:lighting_ramp    Moving box on slowly brightening background"
	@echo "    synthetic:textured_static  Sinusoid-textured static bg + noise (negative test)"
	@echo "    synthetic:entering_object  Two soft-edged boxes entering from opposite edges"
	@echo "    synthetic:multi_speed      Three soft-edged boxes with distinct speeds and directions"
	@echo "    synthetic:stopping_object  Box stops after half the frames + box always moving"
	@echo "    synthetic:lit_moving_object Two soft-edged boxes under shifting L↔R lighting"
	@echo "    path/to/video.mp4          MP4/AVI file (via OpenCV)"
	@echo "    path/to/png_dir/           Directory of PNG frames"

# ---- Main pipeline flow ----

# run-pipeline runs verify *and then* render, even when verify reports a
# mismatch. Render is the most useful debugging artifact when something fails,
# so we still produce it; the overall exit status is the verify status.
run-pipeline: prepare compile sim
	@set +e; $(MAKE) --no-print-directory verify; status=$$?; \
	  $(MAKE) --no-print-directory render; \
	  if [ $$status -ne 0 ]; then \
	    echo "Pipeline finished with verify failures (render PNG written)."; \
	    exit $$status; \
	  fi; \
	  echo "Pipeline complete!"

# prepare writes dv/data/config.mk so that subsequent steps (sim, verify, render)
# automatically pick up the same WIDTH/HEIGHT/FRAMES/MODE without re-specifying them.
prepare:
	@echo ""
	@echo "==== [1/5] PREPARE (Python) ===="
	@mkdir -p $(DATA_DIR) renders
	@printf 'WIDTH=%s\nHEIGHT=%s\nFRAMES=%s\nMODE=%s\nCTRL_FLOW=%s\nCFG=%s\n' \
	  '$(WIDTH)' '$(HEIGHT)' '$(FRAMES)' '$(MODE)' '$(CTRL_FLOW)' '$(CFG)' \
	  > $(DATA_DIR)/config.mk
	cd py && $(HARNESS) prepare \
		--source "$(SOURCE)" --width $(WIDTH) --height $(HEIGHT) \
		--frames $(FRAMES) --mode $(MODE) --output $(CURDIR)/$(PIPE_INFILE)

compile:
	@echo ""
	@echo "==== [2/5] COMPILE (Verilator) ===="
	$(MAKE) -C dv/sim compile $(SIM_VARS)

sim: compile
	@echo ""
	@echo "==== [3/5] SIMULATE (Verilator) ===="
	$(MAKE) -C dv/sim sim $(SIM_VARS)

sim-waves:
	$(MAKE) -C dv/sim sim-waves $(SIM_VARS)

sw-dry-run: prepare compile
	$(MAKE) -C dv/sim sw-dry-run $(SIM_VARS)

verify:
	@echo ""
	@echo "==== [4/5] VERIFY (Python) ===="
	cd py && $(HARNESS) verify \
		--input $(CURDIR)/$(PIPE_INFILE) --output $(CURDIR)/$(PIPE_OUTFILE) \
		--mode $(MODE) --ctrl-flow $(CTRL_FLOW) --tolerance $(TOLERANCE) \
		--cfg $(CFG)

RENDER_SOURCE_SAFE = $(subst _,-,$(subst :,-,$(SOURCE)))
RENDER_OUT = $(CURDIR)/renders/$(RENDER_SOURCE_SAFE)__width=$(WIDTH)__height=$(HEIGHT)__frames=$(FRAMES)__ctrl-flow=$(CTRL_FLOW)__cfg=$(CFG).png

render:
	@echo ""
	@echo "==== [5/5] RENDER (Python) ===="
	@mkdir -p renders
	cd py && $(HARNESS) render \
		--input $(CURDIR)/$(PIPE_INFILE) --output $(CURDIR)/$(PIPE_OUTFILE) \
		--mode $(MODE) --ctrl-flow $(CTRL_FLOW) --cfg $(CFG) \
		--render-output $(RENDER_OUT)

# ---- README demo (animated WebP triptychs) ----
# Two-stage workflow:
#   1. `make demo[-synthetic|-real]` writes WebPs to $(DEMO_DRAFT_DIR) (gitignored).
#      Iterate freely without dirtying the tree.
#   2. `make demo-publish` promotes them to $(DEMO_PUBLISH_DIR) — the path
#      referenced by the README.

# RTL-backend (publishable) demo length: 3 s @ 15 fps.
DEMO_PUBLISH_FRAMES ?= 45
# Model-backend (EXP=1) demo length: full 10 s master @ 15 fps.
DEMO_EXP_FRAMES     ?= 150

# Per-clip EXP frame count overrides. If unset, the clip uses DEMO_EXP_FRAMES.
# Set when a clip's stabilized master is shorter than DEMO_EXP_FRAMES (because
# only a portion of the raw was usable — typically a scene cut or motion artifact).
DEMO_EXP_FRAMES_people ?= 75   # raw has a scene cut at ~5 s; only first 5 s usable

# Resolve EXP frame count for a given clip name, falling back to the global default.
# Usage: $(call demo_exp_frames,<clip-name>)
demo_exp_frames = $(or $(DEMO_EXP_FRAMES_$(1)),$(DEMO_EXP_FRAMES))

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

# Curated set of real-video demo clips. Each <name> here corresponds to a
# committed master at media/source/<name>-$(DEMO_WIDTH)x$(DEMO_HEIGHT).mp4
# (produced via `make demo-prepare`). Adding a clip is a one-line edit here
# plus a stabilize run.
REAL_SOURCES ?= intersection birdseye people

demo: demo-synthetic demo-real

demo-synthetic:
	$(MAKE) prepare SOURCE=synthetic:multi_speed_color \
	    WIDTH=$(DEMO_WIDTH) HEIGHT=$(DEMO_HEIGHT) FRAMES=$(DEMO_FRAMES) MODE=binary CFG=demo
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

# Per-target frame count: in EXP=1 mode, falls back to clip-specific override
# via demo_exp_frames; otherwise uses DEMO_FRAMES (which the EXP/publish
# dispatch above already resolved).
ifeq ($(EXP),1)
demo-real-%: DEMO_REAL_FRAMES = $(call demo_exp_frames,$*)
else
demo-real-%: DEMO_REAL_FRAMES = $(DEMO_FRAMES)
endif

demo-real-%:
	$(MAKE) prepare SOURCE=$(CURDIR)/media/source/$*-$(DEMO_WIDTH)x$(DEMO_HEIGHT).mp4 \
	    WIDTH=$(DEMO_WIDTH) HEIGHT=$(DEMO_HEIGHT) FRAMES=$(DEMO_REAL_FRAMES) MODE=binary CFG=demo
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
	@mkdir -p $(DEMO_DRAFT_DIR)
	cd $(CURDIR) && PYTHONPATH=py $(VENV_PY) -m demo \
	    --input  dv/data/input.bin \
	    --ccl    dv/data/output_ccl_bbox.bin \
	    --motion dv/data/output_motion.bin \
	    --out    $(DEMO_DRAFT_DIR)/$*.webp \
	    --width $(DEMO_WIDTH) --height $(DEMO_HEIGHT) --frames $(DEMO_REAL_FRAMES) \
	    --fps   $(DEMO_FPS)
	@echo "Draft WebP written to $(DEMO_DRAFT_DIR)/$*.webp — run 'make demo-publish' to promote."

# Promote draft WebPs to the README-referenced media/demo/ dir.
# WHICH=both|synthetic|<real-name> selects which panels to publish; default both.
WHICH ?= both
demo-publish:
	@mkdir -p $(DEMO_PUBLISH_DIR)
	@published=0; \
	for name in synthetic $(REAL_SOURCES); do \
	    case "$(WHICH)" in \
	        both|$$name) ;; \
	        *) continue ;; \
	    esac; \
	    # src is intentionally hardcoded — never reads from demo-draft-exp/, so EXP=1 runs cannot be published. \
	    src=$(CURDIR)/media/demo-draft/$$name.webp; \
	    dst=$(DEMO_PUBLISH_DIR)/$$name.webp; \
	    if [ ! -f "$$src" ]; then \
	        if [ "$$name" = "synthetic" ]; then \
	            echo "skip $$name: $$src not found (run 'make demo-synthetic' first)"; \
	        else \
	            echo "skip $$name: $$src not found (run 'make demo-real-$$name' first)"; \
	        fi; \
	        continue; \
	    fi; \
	    cp "$$src" "$$dst"; \
	    echo "published $$src -> $$dst"; \
	    published=$$((published+1)); \
	done; \
	if [ $$published -eq 0 ]; then \
	    echo "Nothing published. Run 'make demo' or 'make demo-synthetic'/'make demo-real-<name>' first."; \
	    exit 1; \
	fi

# Stabilize a raw downloaded MP4 into a 320x240 demo master.
#   Required: SRC=path/to/raw.mp4 NAME=<short-name>
#   Optional: START=<sec> DURATION=<sec> (defaults: 0, 10)
#             WIDTH/HEIGHT/FPS inherit DEMO_WIDTH/DEMO_HEIGHT/DEMO_FPS
# Output: media/source/$(NAME)-$(DEMO_WIDTH)x$(DEMO_HEIGHT).mp4
DEMO_PREP_START    ?= 0
DEMO_PREP_DURATION ?= 10
demo-prepare:
	@if [ -z "$(SRC)" ] || [ "$(origin NAME)" != "command line" ]; then \
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
	    --src "$(SRC)" \
	    --dst "$(CURDIR)/media/source/$(NAME)-$(DEMO_WIDTH)x$(DEMO_HEIGHT).mp4" \
	    --start $(DEMO_PREP_START) --duration $(DEMO_PREP_DURATION) \
	    --width $(DEMO_WIDTH) --height $(DEMO_HEIGHT) --fps $(DEMO_FPS)
	@echo "Wrote media/source/$(NAME)-$(DEMO_WIDTH)x$(DEMO_HEIGHT).mp4"
	@echo "  Record this invocation in media/source/README.md, then commit"
	@echo "  the new MP4 alongside the README update."

# ---- Other targets ----

lint:
	$(FUSESOC) $(CORES_ROOT) run --target=lint sparevideo:video:sparevideo_top

test-py:
	$(VENV_PY) $(CURDIR)/py/tests/test_frame_io.py
	$(VENV_PY) $(CURDIR)/py/tests/test_models.py
	$(VENV_PY) $(CURDIR)/py/tests/test_harness_model.py

test-ip:
	$(MAKE) -C dv/sim test-ip SIMULATOR=$(SIMULATOR)

test-ip-window:
	$(MAKE) -C dv/sim test-ip-window SIMULATOR=$(SIMULATOR)

test-ip-hflip:
	$(MAKE) -C dv/sim test-ip-hflip SIMULATOR=$(SIMULATOR)

test-ip-gamma-cor:
	$(MAKE) -C dv/sim test-ip-gamma-cor SIMULATOR=$(SIMULATOR)

test-ip-scale2x:
	$(MAKE) -C dv/sim test-ip-scale2x SIMULATOR=$(SIMULATOR)

setup:
	sudo apt install -y verilator
	python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt

clean:
	rm -rf build
	$(MAKE) -C dv/sim clean
	rm -f $(DATA_DIR)/*.txt $(DATA_DIR)/*.dat $(DATA_DIR)/*.bin $(DATA_DIR)/config.mk
	rm -rf renders
