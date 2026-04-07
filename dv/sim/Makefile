RTL_SRCS = ../../hw/top/sparesoc_top.sv
TB_SRC   = ../sv/tb_sparevideo.sv

# Simulation defaults
WIDTH   ?= 320
HEIGHT  ?= 240
FRAMES  ?= 4
MODE    ?= text
INFILE  ?= ../data/input.txt
OUTFILE ?= ../data/output.txt

.PHONY: compile sim sim-waves sw-dry-run clean

compile: tb_sparevideo.vvp

sim: tb_sparevideo.vvp
	vvp $< +INFILE=$(INFILE) +OUTFILE=$(OUTFILE) \
		+WIDTH=$(WIDTH) +HEIGHT=$(HEIGHT) \
		+FRAMES=$(FRAMES) +MODE=$(MODE)

sim-waves: tb_sparevideo.vvp
	vvp $< +INFILE=$(INFILE) +OUTFILE=$(OUTFILE) \
		+WIDTH=$(WIDTH) +HEIGHT=$(HEIGHT) \
		+FRAMES=$(FRAMES) +MODE=$(MODE) +DUMP_VCD
	gtkwave tb_sparevideo.vcd &

sw-dry-run: tb_sparevideo.vvp
	vvp $< +INFILE=$(INFILE) +OUTFILE=$(OUTFILE) \
		+WIDTH=$(WIDTH) +HEIGHT=$(HEIGHT) \
		+FRAMES=$(FRAMES) +MODE=$(MODE) +sw_dry_run

tb_sparevideo.vvp: $(RTL_SRCS) $(TB_SRC)
	iverilog -g2012 -o $@ $^

clean:
	rm -f *.vvp *.vcd *.bin
