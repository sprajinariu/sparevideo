RTL_SRCS = ../../hw/top/sparevideo_pkg.sv \
           ../../hw/top/sparevideo_if.sv \
           ../../hw/top/ram.sv \
           ../../hw/ip/rgb2ycrcb/rtl/rgb2ycrcb.sv \
           ../../hw/ip/axis/rtl/axis_fork.sv \
           ../../hw/ip/axis/rtl/axis_async_fifo_ifc.sv \
           ../../hw/ip/hflip/rtl/axis_hflip.sv \
           ../../hw/ip/gamma/rtl/axis_gamma_cor.sv \
           ../../hw/ip/scaler/rtl/axis_scale2x.sv \
           ../../hw/ip/hud/rtl/axis_hud_font_pkg.sv \
           ../../hw/ip/hud/rtl/axis_hud.sv \
           ../../hw/ip/window/rtl/axis_window3x3.sv \
           ../../hw/ip/filters/rtl/axis_gauss3x3.sv \
           ../../hw/ip/filters/rtl/axis_morph3x3_erode.sv \
           ../../hw/ip/filters/rtl/axis_morph3x3_dilate.sv \
           ../../hw/ip/filters/rtl/axis_morph_clean.sv \
           ../../hw/ip/motion/rtl/motion_core.sv \
           ../../hw/ip/motion/rtl/axis_motion_detect.sv \
           ../../hw/ip/motion/rtl/motion_core_vibe.sv \
           ../../hw/ip/motion/rtl/axis_motion_detect_vibe.sv \
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
SIMULATOR ?= verilator
WIDTH     ?= 320
HEIGHT    ?= 240
FRAMES    ?= 4
MODE      ?= text
CTRL_FLOW ?= motion
CFG       ?= default
INFILE    ?= ../data/input.txt
OUTFILE   ?= ../data/output.txt

SIM_ARGS = +INFILE=$(INFILE) +OUTFILE=$(OUTFILE) \
           +WIDTH=$(WIDTH) +HEIGHT=$(HEIGHT) \
           +FRAMES=$(FRAMES) +MODE=$(MODE) \
           +CTRL_FLOW=$(CTRL_FLOW)

.PHONY: compile sim sim-waves sw-dry-run clean \
       test-ip test-ip-rgb2ycrcb test-ip-window test-ip-gauss3x3 \
       test-ip-motion-detect test-ip-motion-detect-gauss \
       test-ip-overlay-bbox test-ip-ccl \
       test-ip-morph3x3-erode test-ip-morph3x3-dilate \
       test-ip-morph-clean \
       test-ip-hflip test-ip-gamma-cor test-ip-scale2x \
       test-ip-vibe test-ip-vibe-k8 test-ip-vibe-k20 test-ip-vibe-external \
       test-ip-vibe-misconfig-external test-ip-vibe-misconfig-k

# ---------------------------------------------------------------------------
# Verilator
# ---------------------------------------------------------------------------
ifeq ($(SIMULATOR),verilator)

VLT_FLAGS = --binary -sv --timing \
            --top-module tb_sparevideo \
            --Mdir $(VOBJ_DIR) \
            --public-flat-rw \
            -GH_ACTIVE=$(WIDTH) -GV_ACTIVE=$(HEIGHT) -GCFG_NAME='"$(CFG)"' \
            -Wno-TIMESCALEMOD \
            -Wno-INITIALDLY \
            -Wno-SELRANGE \
            -Wno-WIDTHEXPAND \
            -Wno-WIDTHTRUNC \
            -Wno-WIDTHCONCAT \
            -Wno-CASEINCOMPLETE \
            --trace

# Extra preprocessor defines injected from dv/data/config.mk.
# VIBE_BG_INIT_EXTERNAL and VIBE_INIT_BANK_FILE are written by 'make prepare'
# when the active CFG has bg_model=ViBe and vibe_bg_init_external=1.
EXTRA_DEFINES :=
ifeq ($(VIBE_BG_INIT_EXTERNAL),1)
EXTRA_DEFINES += +define+VIBE_INIT_BANK_FILE=\"$(VIBE_INIT_BANK_FILE)\"
endif

# Recompile when WIDTH/HEIGHT/CFG/VIBE_BG_INIT_EXTERNAL change.
CONFIG_STAMP = $(VOBJ_DIR)/.config_stamp
$(CONFIG_STAMP): FORCE
	@mkdir -p $(VOBJ_DIR)
	@echo "$(WIDTH) $(HEIGHT) $(CFG) $(VIBE_BG_INIT_EXTERNAL)" | cmp -s - $@ || \
	  echo "$(WIDTH) $(HEIGHT) $(CFG) $(VIBE_BG_INIT_EXTERNAL)" > $@
FORCE:

compile: $(VOBJ_DIR)/Vtb_sparevideo

$(VOBJ_DIR)/Vtb_sparevideo: $(RTL_SRCS) $(TB_SRC) $(DPI_SRC) $(CONFIG_STAMP)
	verilator $(VLT_FLAGS) $(EXTRA_DEFINES) $(RTL_SRCS) $(TB_SRC) $(DPI_SRC)

sim: compile
	$(VOBJ_DIR)/Vtb_sparevideo $(SIM_ARGS)

sim-waves: compile
	$(VOBJ_DIR)/Vtb_sparevideo $(SIM_ARGS) +DUMP_VCD
	gtkwave tb_sparevideo.vcd &

sw-dry-run: compile
	$(VOBJ_DIR)/Vtb_sparevideo $(SIM_ARGS) +sw_dry_run=1

else
$(error Unknown SIMULATOR='$(SIMULATOR)'. Use SIMULATOR=verilator (the only supported simulator))
endif

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Per-block unit testbenches (test-ip)
# ---------------------------------------------------------------------------
IP_RGB2YCRCB_RTL    = ../../hw/ip/rgb2ycrcb/rtl/rgb2ycrcb.sv
IP_WINDOW3X3_RTL    = ../../hw/ip/window/rtl/axis_window3x3.sv
IP_GAUSS3X3_RTL     = ../../hw/ip/filters/rtl/axis_gauss3x3.sv
IP_MORPH3X3_ERODE_RTL  = ../../hw/ip/filters/rtl/axis_morph3x3_erode.sv
IP_MORPH3X3_DILATE_RTL = ../../hw/ip/filters/rtl/axis_morph3x3_dilate.sv
IP_MORPH_CLEAN_RTL     = ../../hw/ip/filters/rtl/axis_morph_clean.sv
IP_HFLIP_RTL        = ../../hw/ip/hflip/rtl/axis_hflip.sv
IP_GAMMA_COR_RTL    = ../../hw/ip/gamma/rtl/axis_gamma_cor.sv
IP_SCALE2X_RTL      = ../../hw/ip/scaler/rtl/axis_scale2x.sv

# Common Verilator flags for block TBs (suppress harmless TB warnings)
VLT_TB_FLAGS = --binary -sv --timing \
               -Wno-TIMESCALEMOD -Wno-INITIALDLY -Wno-WIDTHEXPAND \
               -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-WIDTHCONCAT \
               -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN

test-ip: test-ip-rgb2ycrcb test-ip-window test-ip-gauss3x3 test-ip-motion-detect test-ip-motion-detect-gauss test-ip-overlay-bbox test-ip-ccl test-ip-morph3x3-erode test-ip-morph3x3-dilate test-ip-morph-clean test-ip-hflip test-ip-gamma-cor test-ip-scale2x test-ip-vibe
	@echo "All block testbenches passed."

# test-ip-vibe runs K=8, K=20, external-init, and misconfig variants.
test-ip-vibe: test-ip-vibe-k8 test-ip-vibe-k20 test-ip-vibe-external \
              test-ip-vibe-misconfig-external test-ip-vibe-misconfig-k

# --- rgb2ycrcb ---
test-ip-rgb2ycrcb:
	verilator $(VLT_TB_FLAGS) --top-module tb_rgb2ycrcb --Mdir obj_tb_rgb2ycrcb \
	  $(IP_RGB2YCRCB_RTL) ../../hw/ip/rgb2ycrcb/tb/tb_rgb2ycrcb.sv
	obj_tb_rgb2ycrcb/Vtb_rgb2ycrcb

# Sources shared by both motion detect TB targets
IP_MOTION_DETECT_SRCS = ../../hw/top/sparevideo_pkg.sv \
	  ../../hw/top/sparevideo_if.sv \
	  $(IP_RGB2YCRCB_RTL) ../../hw/top/ram.sv \
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

# --- axis_morph3x3_erode ---
test-ip-morph3x3-erode:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_morph3x3_erode --Mdir obj_tb_axis_morph3x3_erode \
	  ../../hw/top/sparevideo_pkg.sv ../../hw/top/sparevideo_if.sv \
	  $(IP_WINDOW3X3_RTL) $(IP_MORPH3X3_ERODE_RTL) ../../hw/ip/filters/tb/tb_axis_morph3x3_erode.sv
	obj_tb_axis_morph3x3_erode/Vtb_axis_morph3x3_erode

# --- axis_morph3x3_dilate ---
test-ip-morph3x3-dilate:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_morph3x3_dilate --Mdir obj_tb_axis_morph3x3_dilate \
	  ../../hw/top/sparevideo_pkg.sv ../../hw/top/sparevideo_if.sv \
	  $(IP_WINDOW3X3_RTL) $(IP_MORPH3X3_DILATE_RTL) ../../hw/ip/filters/tb/tb_axis_morph3x3_dilate.sv
	obj_tb_axis_morph3x3_dilate/Vtb_axis_morph3x3_dilate

# --- axis_morph_clean ---
test-ip-morph-clean:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_morph_clean --Mdir obj_tb_axis_morph_clean \
	  ../../hw/top/sparevideo_pkg.sv ../../hw/top/sparevideo_if.sv \
	  $(IP_WINDOW3X3_RTL) $(IP_MORPH3X3_ERODE_RTL) $(IP_MORPH3X3_DILATE_RTL) \
	  $(IP_MORPH_CLEAN_RTL) ../../hw/ip/filters/tb/tb_axis_morph_clean.sv
	obj_tb_axis_morph_clean/Vtb_axis_morph_clean

# --- axis_hflip ---
test-ip-hflip:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_hflip --Mdir obj_tb_axis_hflip \
	  ../../hw/top/sparevideo_pkg.sv ../../hw/top/sparevideo_if.sv \
	  $(IP_HFLIP_RTL) ../../hw/ip/hflip/tb/tb_axis_hflip.sv
	obj_tb_axis_hflip/Vtb_axis_hflip

# --- axis_gamma_cor ---
test-ip-gamma-cor:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_gamma_cor --Mdir obj_tb_axis_gamma_cor \
	  ../../hw/top/sparevideo_pkg.sv ../../hw/top/sparevideo_if.sv \
	  $(IP_GAMMA_COR_RTL) ../../hw/ip/gamma/tb/tb_axis_gamma_cor.sv
	obj_tb_axis_gamma_cor/Vtb_axis_gamma_cor

# --- axis_scale2x ---
test-ip-scale2x:
	verilator $(VLT_TB_FLAGS) \
	  --top-module tb_axis_scale2x --Mdir obj_tb_axis_scale2x \
	  ../../hw/top/sparevideo_pkg.sv ../../hw/top/sparevideo_if.sv \
	  $(IP_SCALE2X_RTL) ../../hw/ip/scaler/tb/tb_axis_scale2x.sv
	obj_tb_axis_scale2x/Vtb_axis_scale2x

# --- axis_overlay_bbox ---
test-ip-overlay-bbox:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_overlay_bbox --Mdir obj_tb_axis_overlay_bbox \
	  ../../hw/top/sparevideo_pkg.sv ../../hw/top/sparevideo_if.sv \
	  ../../hw/ip/overlay/rtl/axis_overlay_bbox.sv ../../hw/ip/overlay/tb/tb_axis_overlay_bbox.sv
	obj_tb_axis_overlay_bbox/Vtb_axis_overlay_bbox

# --- axis_ccl ---
test-ip-ccl:
	verilator $(VLT_TB_FLAGS) --top-module tb_axis_ccl --Mdir obj_tb_axis_ccl \
	  ../../hw/top/sparevideo_pkg.sv ../../hw/top/sparevideo_if.sv \
	  ../../hw/ip/ccl/rtl/axis_ccl.sv ../../hw/ip/ccl/tb/tb_axis_ccl.sv
	obj_tb_axis_ccl/Vtb_axis_ccl

# Sources for axis_motion_detect_vibe TBs (GAUSS_EN=0: no window/gauss needed).
# TB file is not included here; each K-specific target appends its own TB.
IP_MOTION_DETECT_VIBE_SRCS = ../../hw/top/sparevideo_pkg.sv \
	  ../../hw/top/sparevideo_if.sv \
	  ../../hw/ip/rgb2ycrcb/rtl/rgb2ycrcb.sv \
	  ../../hw/ip/motion/rtl/motion_core_vibe.sv \
	  ../../hw/ip/motion/rtl/axis_motion_detect_vibe.sv

# --- axis_motion_detect_vibe K=8: T1 (static gray), T2/T2b (bit-exact + decay) ---
test-ip-vibe-k8:
	verilator $(VLT_TB_FLAGS) \
	  --top-module tb_axis_motion_detect_vibe --Mdir obj_tb_axis_motion_detect_vibe \
	  $(IP_MOTION_DETECT_VIBE_SRCS) \
	  ../../hw/ip/motion/tb/tb_axis_motion_detect_vibe.sv
	obj_tb_axis_motion_detect_vibe/Vtb_axis_motion_detect_vibe

# --- axis_motion_detect_vibe K=20: T3/T3b (bit-exact + decay) ---
test-ip-vibe-k20:
	verilator $(VLT_TB_FLAGS) \
	  --top-module tb_axis_motion_detect_vibe_k20 --Mdir obj_tb_axis_motion_detect_vibe_k20 \
	  $(IP_MOTION_DETECT_VIBE_SRCS) \
	  ../../hw/ip/motion/tb/tb_axis_motion_detect_vibe_k20.sv
	obj_tb_axis_motion_detect_vibe_k20/Vtb_axis_motion_detect_vibe_k20

# --- axis_motion_detect_vibe external-init: T4 (frame-0 ghost suppression) ---
test-ip-vibe-external:
	verilator $(VLT_TB_FLAGS) \
	  --top-module tb_axis_motion_detect_vibe_external --Mdir obj_tb_axis_motion_detect_vibe_external \
	  $(IP_MOTION_DETECT_VIBE_SRCS) \
	  ../../hw/ip/motion/tb/tb_axis_motion_detect_vibe_external.sv
	obj_tb_axis_motion_detect_vibe_external/Vtb_axis_motion_detect_vibe_external

# --- axis_motion_detect_vibe misconfig: T7 (VIBE_BG_INIT_EXTERNAL=1, empty INIT_BANK_FILE) ---
# Verilator must fail at elaboration — target passes when verilator exits non-zero.
test-ip-vibe-misconfig-external:
	! verilator $(VLT_TB_FLAGS) \
	  --top-module tb_axis_motion_detect_vibe_external --Mdir obj_tb_axis_motion_detect_vibe_misconfig_ext \
	  -GVIBE_BG_INIT_EXTERNAL=1 -GINIT_BANK_FILE='""' \
	  $(IP_MOTION_DETECT_VIBE_SRCS) \
	  ../../hw/ip/motion/tb/tb_axis_motion_detect_vibe_external.sv
	@echo "PASS T7: verilator correctly rejected VIBE_BG_INIT_EXTERNAL=1 with empty INIT_BANK_FILE"

# --- axis_motion_detect_vibe misconfig: T8 (illegal K=7) ---
# Verilator must fail at elaboration — target passes when verilator exits non-zero.
test-ip-vibe-misconfig-k:
	! verilator $(VLT_TB_FLAGS) \
	  --top-module tb_axis_motion_detect_vibe --Mdir obj_tb_axis_motion_detect_vibe_misconfig_k \
	  -GK=7 \
	  $(IP_MOTION_DETECT_VIBE_SRCS) \
	  ../../hw/ip/motion/tb/tb_axis_motion_detect_vibe.sv
	@echo "PASS T8: verilator correctly rejected illegal K=7"

# ---------------------------------------------------------------------------

clean:
	rm -f *.vvp *.vcd *.bin *.vpi
	rm -rf $(VOBJ_DIR) obj_tb_rgb2ycrcb obj_tb_axis_window3x3 obj_tb_axis_gauss3x3 \
	       obj_tb_axis_motion_detect obj_tb_axis_motion_detect_gauss \
	       obj_tb_axis_overlay_bbox obj_tb_axis_ccl \
	       obj_tb_axis_morph3x3_erode obj_tb_axis_morph3x3_dilate \
	       obj_tb_axis_morph_clean \
	       obj_tb_axis_hflip obj_tb_axis_gamma_cor obj_tb_axis_scale2x \
	       obj_tb_axis_motion_detect_vibe obj_tb_axis_motion_detect_vibe_k20 \
	       obj_tb_axis_motion_detect_vibe_external
