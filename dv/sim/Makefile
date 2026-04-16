RTL_SRCS = ../../hw/top/sparevideo_pkg.sv \
           ../../hw/top/ram.sv \
           ../../hw/ip/rgb2ycrcb/rtl/rgb2ycrcb.sv \
           ../../hw/ip/motion/rtl/axis_motion_detect.sv \
           ../../hw/ip/motion/rtl/axis_bbox_reduce.sv \
           ../../hw/ip/motion/rtl/axis_overlay_bbox.sv \
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
ALPHA_SHIFT ?= 3
INFILE      ?= ../data/input.txt
OUTFILE     ?= ../data/output.txt

SIM_ARGS = +INFILE=$(INFILE) +OUTFILE=$(OUTFILE) \
           +WIDTH=$(WIDTH) +HEIGHT=$(HEIGHT) \
           +FRAMES=$(FRAMES) +MODE=$(MODE) \
           +CTRL_FLOW=$(CTRL_FLOW)

.PHONY: compile sim sim-waves sw-dry-run clean \
       test-ip test-ip-rgb2ycrcb test-ip-motion-detect test-ip-bbox-reduce test-ip-overlay-bbox

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
            -GH_ACTIVE=$(WIDTH) -GV_ACTIVE=$(HEIGHT) -GALPHA_SHIFT=$(ALPHA_SHIFT) \
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
	@echo "$(WIDTH) $(HEIGHT) $(ALPHA_SHIFT)" | cmp -s - $@ || echo "$(WIDTH) $(HEIGHT) $(ALPHA_SHIFT)" > $@
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
IP_MOTION_RTL    = ../../hw/ip/rgb2ycrcb/rtl/rgb2ycrcb.sv \
                   ../../hw/top/ram.sv \
                   ../../hw/ip/motion/rtl/axis_motion_detect.sv \
                   ../../hw/ip/motion/rtl/axis_bbox_reduce.sv \
                   ../../hw/ip/motion/rtl/axis_overlay_bbox.sv

# Common Verilator flags for block TBs (suppress harmless TB warnings)
VLT_TB_FLAGS = --binary -sv --timing \
               -Wno-TIMESCALEMOD -Wno-INITIALDLY -Wno-WIDTHEXPAND \
               -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-WIDTHCONCAT \
               -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN

test-ip: test-ip-rgb2ycrcb test-ip-motion-detect test-ip-bbox-reduce test-ip-overlay-bbox
	@echo "All block testbenches passed."

# --- rgb2ycrcb ---
test-ip-rgb2ycrcb:
	verilator $(VLT_TB_FLAGS) --top-module tb_rgb2ycrcb --Mdir obj_tb_rgb2ycrcb \
	  $(IP_RGB2YCRCB_RTL) ../../hw/ip/rgb2ycrcb/tb/tb_rgb2ycrcb.sv
	obj_tb_rgb2ycrcb/Vtb_rgb2ycrcb

# --- axis_motion_detect ---
test-ip-motion-detect:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_motion_detect --Mdir obj_tb_axis_motion_detect \
	  $(IP_RGB2YCRCB_RTL) ../../hw/top/ram.sv ../../hw/ip/motion/rtl/axis_motion_detect.sv \
	  ../../hw/ip/motion/tb/tb_axis_motion_detect.sv
	obj_tb_axis_motion_detect/Vtb_axis_motion_detect

# --- axis_bbox_reduce ---
test-ip-bbox-reduce:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_bbox_reduce --Mdir obj_tb_axis_bbox_reduce \
	  ../../hw/ip/motion/rtl/axis_bbox_reduce.sv ../../hw/ip/motion/tb/tb_axis_bbox_reduce.sv
	obj_tb_axis_bbox_reduce/Vtb_axis_bbox_reduce

# --- axis_overlay_bbox ---
test-ip-overlay-bbox:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_overlay_bbox --Mdir obj_tb_axis_overlay_bbox \
	  ../../hw/ip/motion/rtl/axis_overlay_bbox.sv ../../hw/ip/motion/tb/tb_axis_overlay_bbox.sv
	obj_tb_axis_overlay_bbox/Vtb_axis_overlay_bbox

# ---------------------------------------------------------------------------

clean:
	rm -f *.vvp *.vcd *.bin *.vpi
	rm -rf $(VOBJ_DIR) obj_tb_rgb2ycrcb obj_tb_axis_motion_detect \
	       obj_tb_axis_bbox_reduce obj_tb_axis_overlay_bbox
