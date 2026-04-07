FUSESOC    := fusesoc
CORES_ROOT := --cores-root=. --cores-root=hw/ip/vga
VENV_PY    := $(CURDIR)/.venv/bin/python3
HARNESS    := $(VENV_PY) $(CURDIR)/py/harness.py
DATA_DIR   := dv/data

# Simulation configuration
SOURCE     ?= synthetic:color_bars
WIDTH      ?= 320
HEIGHT     ?= 240
FRAMES     ?= 4
MODE       ?= text

# Derived file paths
ifeq ($(MODE),binary)
  PIPE_INFILE  = $(DATA_DIR)/input.bin
  PIPE_OUTFILE = $(DATA_DIR)/output.bin
else
  PIPE_INFILE  = $(DATA_DIR)/input.txt
  PIPE_OUTFILE = $(DATA_DIR)/output.txt
endif

.PHONY: help lint run-pipeline prepare compile sim sw-dry-run verify render sim-waves test-py setup clean

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  run-pipeline   Run full pipeline (see below)"
	@echo "  lint           Run Verilator lint on all RTL"
	@echo "  setup          One-time setup (install deps)"
	@echo "  clean          Remove build artifacts"
	@echo ""
	@echo "  run-pipeline runs these steps in order:"
	@echo "    1. prepare   Generate input frames from SOURCE"
	@echo "    2. sim       Run RTL simulation (feed input → DUT → capture output)"
	@echo "    3. verify    Check output matches input (passthrough)"
	@echo "    4. render    Save input vs output comparison PNG"
	@echo ""
	@echo "  Each step can also be run individually, e.g. to re-run sim after"
	@echo "  an RTL change without re-preparing input."
	@echo ""
	@echo "  Additional targets:"
	@echo "    compile      Compile RTL + testbench only (no simulation)"
	@echo "    sw-dry-run  Bypass RTL (file loopback, zero sim time)"
	@echo "    sim-waves    RTL simulation + open GTKWave"
	@echo "    test-py      Run Python unit tests"
	@echo ""
	@echo "  Options:"
	@echo "    SOURCE=synthetic:color_bars  Input source (synthetic:<pattern>, path/to/video.mp4)"
	@echo "    WIDTH=320                    Frame width"
	@echo "    HEIGHT=240                   Frame height"
	@echo "    FRAMES=4                     Number of frames"
	@echo "    MODE=text|binary             File format (default: text)"

# ---- Main pipeline flow ----

run-pipeline: prepare compile sim verify render
	@echo "Pipeline complete!"

prepare:
	@mkdir -p $(DATA_DIR)/renders
	cd py && $(HARNESS) prepare \
		--source "$(SOURCE)" --width $(WIDTH) --height $(HEIGHT) \
		--frames $(FRAMES) --mode $(MODE) --output $(CURDIR)/$(PIPE_INFILE)

sim: compile
	$(MAKE) -C dv/sim sim \
		WIDTH=$(WIDTH) HEIGHT=$(HEIGHT) FRAMES=$(FRAMES) \
		MODE=$(MODE) \
		INFILE=$(CURDIR)/$(PIPE_INFILE) \
		OUTFILE=$(CURDIR)/$(PIPE_OUTFILE)

verify:
	cd py && $(HARNESS) verify \
		--input $(CURDIR)/$(PIPE_INFILE) --output $(CURDIR)/$(PIPE_OUTFILE) \
		--mode $(MODE)

render:
	@mkdir -p $(DATA_DIR)/renders
	cd py && $(HARNESS) render \
		--input $(CURDIR)/$(PIPE_INFILE) --output $(CURDIR)/$(PIPE_OUTFILE) \
		--mode $(MODE) \
		--render-output $(CURDIR)/$(DATA_DIR)/renders/comparison.png

compile:
	$(MAKE) -C dv/sim compile

# ---- Additional targets ----

lint:
	$(FUSESOC) $(CORES_ROOT) run --target=lint opensoc:video:sparesoc_top

test-py:
	$(VENV_PY) $(CURDIR)/py/tests/test_frame_io.py

sw-dry-run:
	$(MAKE) -C dv/sim sw-dry-run \
		WIDTH=$(WIDTH) HEIGHT=$(HEIGHT) FRAMES=$(FRAMES) \
		MODE=$(MODE) \
		INFILE=$(CURDIR)/$(PIPE_INFILE) \
		OUTFILE=$(CURDIR)/$(PIPE_OUTFILE)

sim-waves:
	$(MAKE) -C dv/sim sim-waves \
		WIDTH=$(WIDTH) HEIGHT=$(HEIGHT) FRAMES=$(FRAMES) \
		MODE=$(MODE) \
		INFILE=$(CURDIR)/$(PIPE_INFILE) \
		OUTFILE=$(CURDIR)/$(PIPE_OUTFILE)

setup:
	sudo apt install -y iverilog
	python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt

clean:
	rm -rf build
	$(MAKE) -C dv/sim clean
	rm -f $(DATA_DIR)/*.txt $(DATA_DIR)/*.dat $(DATA_DIR)/*.bin
	rm -rf $(DATA_DIR)/renders
