SIM_TOP  = tb_vga_top
VIZ_TOP  = tb_vga_viz
RTL_SRCS = ../../hw/ip/vga/rtl/vga_controller.sv \
           ../../hw/ip/vga/rtl/pattern_gen.sv \
           ../../hw/top/vga_top.sv
TB_SRCS  = tb_vga_top.sv
VIZ_SRCS = tb_vga_viz.sv

# Pattern to visualize (0=color bars, 1=checkerboard, 2=solid red, 3=gradient)
PATTERN ?= 0
OUTFILE ?= frame.bin

.PHONY: sim sim-waves viz clean

sim: $(SIM_TOP).vvp
	vvp $<

sim-waves: $(SIM_TOP).vvp
	vvp $< +DUMP_VCD
	gtkwave $(SIM_TOP).vcd &

viz: $(VIZ_TOP).vvp
	vvp $< +PATTERN=$(PATTERN) +OUTFILE=$(OUTFILE)

$(SIM_TOP).vvp: $(RTL_SRCS) $(TB_SRCS)
	iverilog -g2012 -o $@ $^

$(VIZ_TOP).vvp: $(RTL_SRCS) $(VIZ_SRCS)
	iverilog -g2012 -o $@ $^

clean:
	rm -f *.vvp *.vcd *.bin
