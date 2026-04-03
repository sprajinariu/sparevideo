SIM ?= icarus
TOPLEVEL_LANG ?= verilog

VERILOG_SOURCES = $(PWD)/../../hw/ip/vga/rtl/vga_controller.sv \
                  $(PWD)/../../hw/ip/vga/rtl/pattern_gen.sv \
                  $(PWD)/../../hw/top/vga_top.sv

TOPLEVEL = vga_top

# Default to full test suite; override with COCOTB_TEST_MODULES=test_viz for fast mode
COCOTB_TEST_MODULES ?= test_vga

COMPILE_ARGS = -g2012

# cocotb-config must be on PATH when this Makefile is invoked.
# The root Makefile prepends .venv/bin to PATH before calling us.
include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: clean-output
clean-output:
	rm -rf output
