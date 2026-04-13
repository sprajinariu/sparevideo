// Generic dual-port byte-addressed RAM.
//
// True dual-port: two independent 1R1W ports (A and B) sharing one backing
// store. Read-first semantics per port — a port reading the same address it
// is writing on the same cycle sees the OLD value.
//
// Content-agnostic — partitioning is handled externally by region descriptors
// in sparesoc_top.sv.
//
// Behavioral model, simulation-only. For FPGA synthesis, swap in a vendor
// true-dual-port BRAM primitive (e.g. Xilinx xpm_memory_tdpram).

module ram #(
    parameter int DEPTH  = 76800,   // total bytes
    parameter int ADDR_W = $clog2(DEPTH)
) (
    input  logic            clk,

    // Port A
    input  logic [ADDR_W-1:0] a_rd_addr,
    output logic [7:0]        a_rd_data,
    input  logic [ADDR_W-1:0] a_wr_addr,
    input  logic [7:0]        a_wr_data,
    input  logic              a_wr_en,

    // Port B
    input  logic [ADDR_W-1:0] b_rd_addr,
    output logic [7:0]        b_rd_data,
    input  logic [ADDR_W-1:0] b_wr_addr,
    input  logic [7:0]        b_wr_data,
    input  logic              b_wr_en
);

    logic [7:0] mem [0:DEPTH-1];

    // Zero-initialize for simulation (first frame reads back 0).
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = 8'h00;
    end

    // Port A — read-first
    always_ff @(posedge clk) begin
        a_rd_data <= mem[a_rd_addr];
        if (a_wr_en)
            mem[a_wr_addr] <= a_wr_data;
    end

    // Port B — read-first
    always_ff @(posedge clk) begin
        b_rd_data <= mem[b_rd_addr];
        if (b_wr_en)
            mem[b_wr_addr] <= b_wr_data;
    end

endmodule
