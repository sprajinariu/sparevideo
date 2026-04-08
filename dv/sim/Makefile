RTL_SRCS = ../../hw/top/sparesoc_top.sv \
           ../../hw/ip/vga/rtl/vga_controller.sv \
           ../../third_party/verilog-axis/rtl/axis_register.v \
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
INFILE    ?= ../data/input.txt
OUTFILE   ?= ../data/output.txt

SIM_ARGS = +INFILE=$(INFILE) +OUTFILE=$(OUTFILE) \
           +WIDTH=$(WIDTH) +HEIGHT=$(HEIGHT) \
           +FRAMES=$(FRAMES) +MODE=$(MODE)

.PHONY: compile sim sim-waves sw-dry-run clean

# ---------------------------------------------------------------------------
# Icarus Verilog
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
            -Wno-TIMESCALEMOD \
            -Wno-INITIALDLY \
            -Wno-SELRANGE \
            -Wno-WIDTHEXPAND \
            -Wno-WIDTHTRUNC \
            -Wno-WIDTHCONCAT \
            -Wno-CASEINCOMPLETE \
            --trace

compile: $(VOBJ_DIR)/Vtb_sparevideo

$(VOBJ_DIR)/Vtb_sparevideo: $(RTL_SRCS) $(TB_SRC) $(DPI_SRC)
	verilator $(VLT_FLAGS) $(RTL_SRCS) $(TB_SRC) $(DPI_SRC)

sim: compile
	$(VOBJ_DIR)/Vtb_sparevideo $(SIM_ARGS)

sim-waves: compile
	$(VOBJ_DIR)/Vtb_sparevideo $(SIM_ARGS) +DUMP_VCD
	gtkwave tb_sparevideo.vcd &

sw-dry-run: compile
	$(VOBJ_DIR)/Vtb_sparevideo $(SIM_ARGS) +sw_dry_run=1

else
$(error Unknown SIMULATOR='$(SIMULATOR)'. Use SIMULATOR=icarus or SIMULATOR=verilator)
endif

# ---------------------------------------------------------------------------

clean:
	rm -f *.vvp *.vcd *.bin *.vpi
	rm -rf $(VOBJ_DIR)
