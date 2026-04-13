FUSESOC    := fusesoc
CORES_ROOT := --cores-root=. --cores-root=hw/ip/vga
VENV_PY    := $(CURDIR)/.venv/bin/python3
HARNESS    := $(VENV_PY) $(CURDIR)/py/harness.py
DATA_DIR   := dv/data

# Built-in defaults — lowest precedence.
SIMULATOR ?= verilator
SOURCE    ?= synthetic:color_bars
WIDTH     ?= 320
HEIGHT    ?= 240
FRAMES    ?= 4
MODE      ?= text
# Default tolerance: accommodate the frame-0 bounding-box border that the
# motion-detect pipeline overlays on every run (border pixel count ≈ 2*(W+H)).
# Override with TOLERANCE=0 for exact-match checks or a higher value for
# motion-heavy sources (e.g. TOLERANCE=10000 for synthetic:moving_box).
TOLERANCE ?= $(shell echo "$$((2*($(WIDTH)+$(HEIGHT))))")

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
           MODE=$(MODE) \
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
	@echo "    sim-waves    RTL sim + open GTKWave"
	@echo "    sw-dry-run   Bypass RTL (file loopback, zero sim time)"
	@echo "    test-py      Run Python unit tests"
	@echo ""
	@echo "  Options (command-line always wins; 'make prepare' saves them for later steps):"
	@echo "    SIMULATOR=verilator        Simulator: verilator (default) or icarus"
	@echo "    SOURCE=synthetic:color_bars  Input source (prepare only)"
	@echo "    WIDTH=320                  Frame width"
	@echo "    HEIGHT=240                 Frame height"
	@echo "    FRAMES=4                   Number of frames"
	@echo "    MODE=text|binary           File format"
	@echo "    TOLERANCE=<n>              Max diff pixels/frame for verify (default 2*(W+H))"

# ---- Main pipeline flow ----

run-pipeline: prepare compile sim verify render
	@echo "Pipeline complete!"

# prepare writes dv/data/config.mk so that subsequent steps (sim, verify, render)
# automatically pick up the same WIDTH/HEIGHT/FRAMES/MODE without re-specifying them.
prepare:
	@mkdir -p $(DATA_DIR)/renders
	@printf 'SOURCE = %s\nWIDTH = %s\nHEIGHT = %s\nFRAMES = %s\nMODE = %s\n' \
		'$(SOURCE)' '$(WIDTH)' '$(HEIGHT)' '$(FRAMES)' '$(MODE)' > $(DATA_DIR)/config.mk
	cd py && $(HARNESS) prepare \
		--source "$(SOURCE)" --width $(WIDTH) --height $(HEIGHT) \
		--frames $(FRAMES) --mode $(MODE) --output $(CURDIR)/$(PIPE_INFILE)

compile:
	$(MAKE) -C dv/sim compile $(SIM_VARS)

sim: compile
	$(MAKE) -C dv/sim sim $(SIM_VARS)

sim-waves:
	$(MAKE) -C dv/sim sim-waves $(SIM_VARS)

sw-dry-run:
	$(MAKE) -C dv/sim sw-dry-run $(SIM_VARS)

verify:
	cd py && $(HARNESS) verify \
		--input $(CURDIR)/$(PIPE_INFILE) --output $(CURDIR)/$(PIPE_OUTFILE) \
		--mode $(MODE) --tolerance $(TOLERANCE)

render:
	@mkdir -p $(DATA_DIR)/renders
	cd py && $(HARNESS) render \
		--input $(CURDIR)/$(PIPE_INFILE) --output $(CURDIR)/$(PIPE_OUTFILE) \
		--mode $(MODE) \
		--render-output $(CURDIR)/$(DATA_DIR)/renders/comparison.png

# ---- Other targets ----

lint:
	$(FUSESOC) $(CORES_ROOT) run --target=lint sparevideo:video:sparevideo_top

test-py:
	$(VENV_PY) $(CURDIR)/py/tests/test_frame_io.py

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
