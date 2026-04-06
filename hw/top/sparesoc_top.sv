// Sparesoc Top-Level
// Video passthrough pipeline: accepts RGB + sync input, outputs with 1-clock delay.
// No processing — just a registered pipeline stage for now.

module sparesoc_top (
    input  logic        clk,
    input  logic        rst_n,

    // Video input
    input  logic [23:0] vid_i_data,     // {R[7:0], G[7:0], B[7:0]}
    input  logic        vid_i_valid,
    input  logic        vid_i_hsync,
    input  logic        vid_i_vsync,

    // Video output
    output logic [23:0] vid_o_data,
    output logic        vid_o_valid,
    output logic        vid_o_hsync,
    output logic        vid_o_vsync
);

    // Single pipeline register stage
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            vid_o_data  <= '0;
            vid_o_valid <= 1'b0;
            vid_o_hsync <= 1'b1;    // inactive (active-low)
            vid_o_vsync <= 1'b1;
        end else begin
            vid_o_data  <= vid_i_data;
            vid_o_valid <= vid_i_valid;
            vid_o_hsync <= vid_i_hsync;
            vid_o_vsync <= vid_i_vsync;
        end
    end

endmodule
