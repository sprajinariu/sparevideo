// RGB888 to YCrCb color-space converter (Rec.601-ish, 8-bit fixed-point).
//
// 1-stage pipeline: compute MAC sums combinationally, extract top byte (>>8
// is just wiring), register the byte result.
// No saturation logic needed — coefficients chosen so all intermediates are
// non-negative and fit within [0, 65535] after the +32768 offset for Cb/Cr.
//
// Inspired by freecores/video_systems/rgb2ycrcb.v (Richard Herveille, BSD),
// adapted to 8-bit coefficients with retuned offsets.

module rgb2ycrcb (
    input  logic       clk_i,
    input  logic       rst_n_i,

    input  logic [7:0] r_i,
    input  logic [7:0] g_i,
    input  logic [7:0] b_i,

    output logic [7:0] y_o,
    output logic [7:0] cb_o,
    output logic [7:0] cr_o
);

    // Combinational MAC sums — >>8 is just wiring, no logic needed.
    logic [16:0] y_sum_c;
    logic [16:0] cb_sum_c;
    logic [16:0] cr_sum_c;

    assign y_sum_c  = 17'(77 * r_i) + 17'(150 * g_i) + 17'(29 * b_i);
    assign cb_sum_c = 17'(32768) - 17'(43 * r_i) - 17'(85 * g_i) + 17'(128 * b_i);
    assign cr_sum_c = 17'(32768) + 17'(128 * r_i) - 17'(107 * g_i) - 17'(21 * b_i);

    // Register the top byte — 1-cycle latency.
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            y_o  <= '0;
            cb_o <= '0;
            cr_o <= '0;
        end else begin
            y_o  <= y_sum_c[15:8];
            cb_o <= cb_sum_c[15:8];
            cr_o <= cr_sum_c[15:8];
        end
    end

endmodule
