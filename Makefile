FUSESOC    := fusesoc
CORES_ROOT := --cores-root=. --cores-root=hw/ip/vga
VENV_PY    := $(CURDIR)/.venv/bin/python3
VIZ_SCRIPT := dv/cocotb/viz.py
VIZ_OUT    := dv/cocotb/output

.PHONY: help lint sim-sv sim-sv-waves sim viz setup clean

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  lint          Run Verilator lint on all RTL"
	@echo "  sim-sv        Run SV testbench (iverilog)"
	@echo "  sim-sv-waves  Run SV testbench + open GTKWave"
	@echo "  sim           Run cocotb tests — timing + pixel checks"
	@echo "  viz           Simulate all 4 patterns and save PNGs (fast, RTL-based)"
	@echo "  viz PATTERN=N Simulate a single pattern (0-3) and save PNG"
	@echo "  setup         One-time setup (install deps)"
	@echo "  clean         Remove build artifacts"

lint:
	$(FUSESOC) $(CORES_ROOT) run --target=lint opensoc:video:vga_top

sim-sv:
	$(MAKE) -C dv/sv sim

sim-sv-waves:
	$(MAKE) -C dv/sv sim-waves

sim:
	PATH=$(CURDIR)/.venv/bin:$$PATH $(MAKE) -C dv/cocotb

# Visualization: simulate RTL at native speed, dump raw pixels, convert to PNG.
# With PATTERN=N: single pattern. Without: all 4 patterns.
ifdef PATTERN
viz:
	@mkdir -p $(VIZ_OUT)
	$(MAKE) -C dv/sv viz PATTERN=$(PATTERN) OUTFILE=$(CURDIR)/$(VIZ_OUT)/pattern_$(PATTERN).bin
	$(VENV_PY) $(VIZ_SCRIPT) $(VIZ_OUT)/pattern_$(PATTERN).bin $(VIZ_OUT)/pattern_$(PATTERN).png
else
viz:
	@mkdir -p $(VIZ_OUT)
	@echo "--- Pattern 0: color_bars ---"
	@$(MAKE) --no-print-directory -C dv/sv viz PATTERN=0 OUTFILE=$(CURDIR)/$(VIZ_OUT)/color_bars.bin
	@$(VENV_PY) $(VIZ_SCRIPT) $(VIZ_OUT)/color_bars.bin $(VIZ_OUT)/color_bars.png
	@echo "--- Pattern 1: checkerboard ---"
	@$(MAKE) --no-print-directory -C dv/sv viz PATTERN=1 OUTFILE=$(CURDIR)/$(VIZ_OUT)/checkerboard.bin
	@$(VENV_PY) $(VIZ_SCRIPT) $(VIZ_OUT)/checkerboard.bin $(VIZ_OUT)/checkerboard.png
	@echo "--- Pattern 2: solid_red ---"
	@$(MAKE) --no-print-directory -C dv/sv viz PATTERN=2 OUTFILE=$(CURDIR)/$(VIZ_OUT)/solid_red.bin
	@$(VENV_PY) $(VIZ_SCRIPT) $(VIZ_OUT)/solid_red.bin $(VIZ_OUT)/solid_red.png
	@echo "--- Pattern 3: gradient ---"
	@$(MAKE) --no-print-directory -C dv/sv viz PATTERN=3 OUTFILE=$(CURDIR)/$(VIZ_OUT)/gradient.bin
	@$(VENV_PY) $(VIZ_SCRIPT) $(VIZ_OUT)/gradient.bin $(VIZ_OUT)/gradient.png
	@echo "All patterns saved to $(VIZ_OUT)/"
endif

setup:
	sudo apt install -y iverilog
	python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt

clean:
	rm -rf build
	$(MAKE) -C dv/sv clean
	$(MAKE) -C dv/cocotb clean
	rm -rf $(VIZ_OUT)
