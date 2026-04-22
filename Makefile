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
FRAMES    ?= 4
MODE      ?= text
CTRL_FLOW ?= motion
# Default tolerance: 0 (pixel-accurate model-based verification for all flows).
TOLERANCE ?= 0
# EMA background adaptation rate: alpha = 1 / (1 << ALPHA_SHIFT).
ALPHA_SHIFT ?= 3
# EMA background adaptation rate on motion pixels: alpha = 1 / (1 << ALPHA_SHIFT_SLOW).
ALPHA_SHIFT_SLOW ?= 6
# Aggressive-EMA grace window after priming (frames). Default 8. Set to 0 to disable.
GRACE_FRAMES ?= 8
# EMA rate during the grace window: alpha = 1 / (1 << GRACE_ALPHA_SHIFT).
# Default 1 → α=1/2, chosen so delta halves per frame and converges below THRESH
# within ~4-5 frames regardless of d₀.
GRACE_ALPHA_SHIFT ?= 1
# Gaussian pre-filter: 1=enabled, 0=disabled.
GAUSS_EN ?= 1

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
           MODE=$(MODE) CTRL_FLOW=$(CTRL_FLOW) \
           ALPHA_SHIFT=$(ALPHA_SHIFT) ALPHA_SHIFT_SLOW=$(ALPHA_SHIFT_SLOW) GRACE_FRAMES=$(GRACE_FRAMES) GRACE_ALPHA_SHIFT=$(GRACE_ALPHA_SHIFT) GAUSS_EN=$(GAUSS_EN) \
           INFILE=$(CURDIR)/$(PIPE_INFILE) \
           OUTFILE=$(CURDIR)/$(PIPE_OUTFILE)

.PHONY: help lint run-pipeline prepare compile sim sw-dry-run verify render sim-waves \
        test-py test-ip setup clean

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
	@echo "    test-py               Run Python unit tests"
	@echo "    test-ip               All per-block IP unit testbenches (Verilator)"
	@echo "    test-ip-rgb2ycrcb          rgb2ycrcb: 18 vectors, exact-match golden model"
	@echo "    test-ip-gauss3x3           axis_gauss3x3: 6 tests, uniform/impulse/gradient/checker/stall/SOF"
	@echo "    test-ip-motion-detect      axis_motion_detect GAUSS_EN=0: 8-frame golden model, stall, fork desync"
	@echo "    test-ip-motion-detect-gauss axis_motion_detect GAUSS_EN=1: 8-frame Gaussian golden model, stall"
	@echo "    test-ip-overlay-bbox       axis_overlay_bbox: 8 tests, empty/full/single-pixel/backpressure"
	@echo "    test-ip-ccl                axis_ccl: 6 tests, single/hollow/disjoint/U-shape/overflow/back-to-back"
	@echo ""
	@echo "  Options (command-line always wins; 'make prepare' saves them for later steps):"
	@echo "    SIMULATOR=verilator              Simulator: verilator (default) or icarus"
	@echo "    SOURCE=synthetic:moving_box      Input source (prepare only). See sources below."
	@echo "    WIDTH=320                        Frame width"
	@echo "    HEIGHT=240                       Frame height"
	@echo "    FRAMES=4                         Number of frames"
	@echo "    MODE=text|binary                 File format"
	@echo "    CTRL_FLOW=motion|passthrough|mask|ccl_bbox Control flow (default motion)"
	@echo "    TOLERANCE=<n>                    Max diff pixels/frame for verify (default 0 = exact)"
	@echo "    ALPHA_SHIFT=3                    EMA adaptation (non-motion pixel): alpha=1/(1<<N) (default 3)"
	@echo "    ALPHA_SHIFT_SLOW=6               EMA adaptation (motion pixel): alpha=1/(1<<N) (default 6)"
	@echo "    GRACE_FRAMES=8                   Aggressive-EMA grace window after priming (default 8)"
	@echo "    GRACE_ALPHA_SHIFT=1              EMA shift during grace: alpha=1/(1<<N) (default 1, α=1/2)"
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

run-pipeline: prepare compile sim verify render
	@echo "Pipeline complete!"

# prepare writes dv/data/config.mk so that subsequent steps (sim, verify, render)
# automatically pick up the same WIDTH/HEIGHT/FRAMES/MODE without re-specifying them.
prepare:
	@echo ""
	@echo "==== [1/5] PREPARE (Python) ===="
	@mkdir -p $(DATA_DIR)/renders
	@printf 'SOURCE = %s\nWIDTH = %s\nHEIGHT = %s\nFRAMES = %s\nMODE = %s\nCTRL_FLOW = %s\nALPHA_SHIFT = %s\nALPHA_SHIFT_SLOW = %s\nGRACE_FRAMES = %s\nGRACE_ALPHA_SHIFT = %s\nGAUSS_EN = %s\n' \
		'$(SOURCE)' '$(WIDTH)' '$(HEIGHT)' '$(FRAMES)' '$(MODE)' '$(CTRL_FLOW)' '$(ALPHA_SHIFT)' '$(ALPHA_SHIFT_SLOW)' '$(GRACE_FRAMES)' '$(GRACE_ALPHA_SHIFT)' '$(GAUSS_EN)' > $(DATA_DIR)/config.mk
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
		--alpha-shift $(ALPHA_SHIFT) --alpha-shift-slow $(ALPHA_SHIFT_SLOW) --grace-frames $(GRACE_FRAMES) --grace-alpha-shift $(GRACE_ALPHA_SHIFT) --gauss-en $(GAUSS_EN)

RENDER_SOURCE_SAFE = $(subst _,-,$(subst :,-,$(SOURCE)))
RENDER_OUT = $(CURDIR)/$(DATA_DIR)/renders/$(RENDER_SOURCE_SAFE)__width=$(WIDTH)__height=$(HEIGHT)__frames=$(FRAMES)__ctrl-flow=$(CTRL_FLOW)__alpha-shift=$(ALPHA_SHIFT)__alpha-shift-slow=$(ALPHA_SHIFT_SLOW)__grace-frames=$(GRACE_FRAMES)__grace-alpha-shift=$(GRACE_ALPHA_SHIFT)__gauss-en=$(GAUSS_EN).png

render:
	@echo ""
	@echo "==== [5/5] RENDER (Python) ===="
	@mkdir -p $(DATA_DIR)/renders
	cd py && $(HARNESS) render \
		--input $(CURDIR)/$(PIPE_INFILE) --output $(CURDIR)/$(PIPE_OUTFILE) \
		--mode $(MODE) --ctrl-flow $(CTRL_FLOW) --alpha-shift $(ALPHA_SHIFT) \
		--alpha-shift-slow $(ALPHA_SHIFT_SLOW) --grace-frames $(GRACE_FRAMES) --grace-alpha-shift $(GRACE_ALPHA_SHIFT) --gauss-en $(GAUSS_EN) --render-output $(RENDER_OUT)

# ---- Other targets ----

lint:
	$(FUSESOC) $(CORES_ROOT) run --target=lint sparevideo:video:sparevideo_top

test-py:
	$(VENV_PY) $(CURDIR)/py/tests/test_frame_io.py
	$(VENV_PY) $(CURDIR)/py/tests/test_models.py

test-ip:
	$(MAKE) -C dv/sim test-ip SIMULATOR=$(SIMULATOR)

setup:
	sudo apt install -y iverilog verilator
	python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt

clean:
	rm -rf build
	$(MAKE) -C dv/sim clean
	rm -f $(DATA_DIR)/*.txt $(DATA_DIR)/*.dat $(DATA_DIR)/*.bin $(DATA_DIR)/config.mk
	rm -rf $(DATA_DIR)/renders
