RTL_SRCS = ../../hw/top/sparevideo_pkg.sv \
           ../../hw/top/ram.sv \
           ../../hw/ip/rgb2ycrcb/rtl/rgb2ycrcb.sv \
           ../../hw/ip/axis/rtl/axis_fork.sv \
           ../../hw/ip/window/rtl/axis_window3x3.sv \
           ../../hw/ip/filters/rtl/axis_gauss3x3.sv \
           ../../hw/ip/motion/rtl/motion_core.sv \
           ../../hw/ip/motion/rtl/axis_motion_detect.sv \
           ../../hw/ip/ccl/rtl/axis_ccl.sv \
           ../../hw/ip/overlay/rtl/axis_overlay_bbox.sv \
           ../../hw/top/sparevideo_top.sv \
           ../../hw/ip/vga/rtl/vga_controller.sv \
           ../../third_party/verilog-axis/rtl/axis_async_fifo.v
TB_SRC   = ../sv/tb_sparevideo.sv
DPI_SRC  = ../sv/tb_utils.c

# Verilator output directory
VOBJ_DIR = obj_dir

# Simulation defaults
SIMULATOR   ?= verilator
WIDTH       ?= 320
HEIGHT      ?= 240
FRAMES      ?= 4
MODE        ?= text
CTRL_FLOW   ?= motion
ALPHA_SHIFT       ?= 3
ALPHA_SHIFT_SLOW  ?= 6
GRACE_FRAMES      ?= 8
GRACE_ALPHA_SHIFT ?= 1
GAUSS_EN          ?= 1
INFILE      ?= ../data/input.txt
OUTFILE     ?= ../data/output.txt

SIM_ARGS = +INFILE=$(INFILE) +OUTFILE=$(OUTFILE) \
           +WIDTH=$(WIDTH) +HEIGHT=$(HEIGHT) \
           +FRAMES=$(FRAMES) +MODE=$(MODE) \
           +CTRL_FLOW=$(CTRL_FLOW)

.PHONY: compile sim sim-waves sw-dry-run clean \
       test-ip test-ip-rgb2ycrcb test-ip-window test-ip-gauss3x3 \
       test-ip-motion-detect test-ip-motion-detect-gauss \
       test-ip-overlay-bbox test-ip-ccl

# ---------------------------------------------------------------------------
# Icarus Verilog — NOT MAINTAINED. Kept for reference only; will likely fail.
# Icarus has been removed from CI and required checks. Use SIMULATOR=verilator.
# ---------------------------------------------------------------------------
ifeq ($(SIMULATOR),icarus)

DPI_LIB = tb_utils.vpi

compile: tb_sparevideo.vvp $(DPI_LIB)

sim: compile
	vvp -m./$(DPI_LIB) tb_sparevideo.vvp $(SIM_ARGS)

sim-waves: compile
	vvp -m./$(DPI_LIB) tb_sparevideo.vvp $(SIM_ARGS) +DUMP_VCD
	gtkwave tb_sparevideo.vcd &

sw-dry-run: compile
	vvp -m./$(DPI_LIB) tb_sparevideo.vvp $(SIM_ARGS) +sw_dry_run=1

tb_sparevideo.vvp: $(RTL_SRCS) $(TB_SRC)
	iverilog -g2012 -o $@ $^

$(DPI_LIB): $(DPI_SRC)
	gcc -shared -fPIC -o $@ $<

# ---------------------------------------------------------------------------
# Verilator
# ---------------------------------------------------------------------------
else ifeq ($(SIMULATOR),verilator)

VLT_FLAGS = --binary -sv --timing \
            --top-module tb_sparevideo \
            --Mdir $(VOBJ_DIR) \
            --public-flat-rw \
            -GH_ACTIVE=$(WIDTH) -GV_ACTIVE=$(HEIGHT) -GALPHA_SHIFT=$(ALPHA_SHIFT) -GALPHA_SHIFT_SLOW=$(ALPHA_SHIFT_SLOW) -GGRACE_FRAMES=$(GRACE_FRAMES) -GGRACE_ALPHA_SHIFT=$(GRACE_ALPHA_SHIFT) -GGAUSS_EN=$(GAUSS_EN) \
            -Wno-TIMESCALEMOD \
            -Wno-INITIALDLY \
            -Wno-SELRANGE \
            -Wno-WIDTHEXPAND \
            -Wno-WIDTHTRUNC \
            -Wno-WIDTHCONCAT \
            -Wno-CASEINCOMPLETE \
            --trace

# Recompile when WIDTH/HEIGHT change (they affect -G parameters).
CONFIG_STAMP = $(VOBJ_DIR)/.config_stamp
$(CONFIG_STAMP): FORCE
	@mkdir -p $(VOBJ_DIR)
	@echo "$(WIDTH) $(HEIGHT) $(ALPHA_SHIFT) $(ALPHA_SHIFT_SLOW) $(GRACE_FRAMES) $(GRACE_ALPHA_SHIFT) $(GAUSS_EN)" | cmp -s - $@ || echo "$(WIDTH) $(HEIGHT) $(ALPHA_SHIFT) $(ALPHA_SHIFT_SLOW) $(GRACE_FRAMES) $(GRACE_ALPHA_SHIFT) $(GAUSS_EN)" > $@
FORCE:

compile: $(VOBJ_DIR)/Vtb_sparevideo

$(VOBJ_DIR)/Vtb_sparevideo: $(RTL_SRCS) $(TB_SRC) $(DPI_SRC) $(CONFIG_STAMP)
	verilator $(VLT_FLAGS) $(RTL_SRCS) $(TB_SRC) $(DPI_SRC)

sim: compile
	$(VOBJ_DIR)/Vtb_sparevideo $(SIM_ARGS)

sim-waves: compile
	$(VOBJ_DIR)/Vtb_sparevideo $(SIM_ARGS) +DUMP_VCD
	gtkwave tb_sparevideo.vcd &

sw-dry-run: compile
	$(VOBJ_DIR)/Vtb_sparevideo $(SIM_ARGS) +sw_dry_run=1

else
$(error Unknown SIMULATOR='$(SIMULATOR)'. Use SIMULATOR=verilator (default) or SIMULATOR=icarus (not maintained))
endif

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Per-block unit testbenches (test-ip)
# ---------------------------------------------------------------------------
IP_RGB2YCRCB_RTL = ../../hw/ip/rgb2ycrcb/rtl/rgb2ycrcb.sv
IP_WINDOW3X3_RTL = ../../hw/ip/window/rtl/axis_window3x3.sv
IP_GAUSS3X3_RTL  = ../../hw/ip/filters/rtl/axis_gauss3x3.sv

# Common Verilator flags for block TBs (suppress harmless TB warnings)
VLT_TB_FLAGS = --binary -sv --timing \
               -Wno-TIMESCALEMOD -Wno-INITIALDLY -Wno-WIDTHEXPAND \
               -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-WIDTHCONCAT \
               -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN

test-ip: test-ip-rgb2ycrcb test-ip-window test-ip-gauss3x3 test-ip-motion-detect test-ip-motion-detect-gauss test-ip-overlay-bbox test-ip-ccl
	@echo "All block testbenches passed."

# --- rgb2ycrcb ---
test-ip-rgb2ycrcb:
	verilator $(VLT_TB_FLAGS) --top-module tb_rgb2ycrcb --Mdir obj_tb_rgb2ycrcb \
	  $(IP_RGB2YCRCB_RTL) ../../hw/ip/rgb2ycrcb/tb/tb_rgb2ycrcb.sv
	obj_tb_rgb2ycrcb/Vtb_rgb2ycrcb

# Sources shared by both motion detect TB targets
IP_MOTION_DETECT_SRCS = $(IP_RGB2YCRCB_RTL) ../../hw/top/ram.sv \
	  ../../hw/ip/motion/rtl/motion_core.sv \
	  ../../hw/ip/motion/rtl/axis_motion_detect.sv \
	  ../../hw/ip/motion/tb/tb_axis_motion_detect.sv

# --- axis_motion_detect (GAUSS_EN=0) ---
test-ip-motion-detect:
	verilator $(VLT_TB_FLAGS) -GGAUSS_EN=0 \
	  --top-module tb_axis_motion_detect --Mdir obj_tb_axis_motion_detect \
	  $(IP_MOTION_DETECT_SRCS)
	obj_tb_axis_motion_detect/Vtb_axis_motion_detect

# --- axis_motion_detect (GAUSS_EN=1) ---
test-ip-motion-detect-gauss:
	verilator $(VLT_TB_FLAGS) -GGAUSS_EN=1 \
	  --top-module tb_axis_motion_detect --Mdir obj_tb_axis_motion_detect_gauss \
	  $(IP_WINDOW3X3_RTL) $(IP_GAUSS3X3_RTL) $(IP_MOTION_DETECT_SRCS)
	obj_tb_axis_motion_detect_gauss/Vtb_axis_motion_detect

# --- axis_window3x3 ---
test-ip-window:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_window3x3 --Mdir obj_tb_axis_window3x3 \
	  $(IP_WINDOW3X3_RTL) ../../hw/ip/window/tb/tb_axis_window3x3.sv
	obj_tb_axis_window3x3/Vtb_axis_window3x3

# --- gauss3x3 ---
test-ip-gauss3x3:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_gauss3x3 --Mdir obj_tb_axis_gauss3x3 \
	  $(IP_WINDOW3X3_RTL) $(IP_GAUSS3X3_RTL) ../../hw/ip/filters/tb/tb_axis_gauss3x3.sv
	obj_tb_axis_gauss3x3/Vtb_axis_gauss3x3

# --- axis_overlay_bbox ---
test-ip-overlay-bbox:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_overlay_bbox --Mdir obj_tb_axis_overlay_bbox \
	  ../../hw/top/sparevideo_pkg.sv \
	  ../../hw/ip/overlay/rtl/axis_overlay_bbox.sv ../../hw/ip/overlay/tb/tb_axis_overlay_bbox.sv
	obj_tb_axis_overlay_bbox/Vtb_axis_overlay_bbox

# --- axis_ccl ---
test-ip-ccl:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_ccl --Mdir obj_tb_axis_ccl \
	  ../../hw/top/sparevideo_pkg.sv \
	  ../../hw/ip/ccl/rtl/axis_ccl.sv ../../hw/ip/ccl/tb/tb_axis_ccl.sv
	obj_tb_axis_ccl/Vtb_axis_ccl

# ---------------------------------------------------------------------------

clean:
	rm -f *.vvp *.vcd *.bin *.vpi
	rm -rf $(VOBJ_DIR) obj_tb_rgb2ycrcb obj_tb_axis_window3x3 obj_tb_axis_gauss3x3 \
	       obj_tb_axis_motion_detect obj_tb_axis_motion_detect_gauss \
	       obj_tb_axis_overlay_bbox obj_tb_axis_ccl
