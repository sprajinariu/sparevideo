// Test Pattern Generator
// Streams pixel data to a VGA controller via ready/valid handshake.
// Supports 4 patterns: color bars, checkerboard, solid red, gradient.

module pattern_gen (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [1:0]  pattern_sel,    // 0=color bars, 1=checkerboard, 2=solid, 3=gradient

    // Synchronization inputs from VGA controller
    input  logic        frame_start,
    input  logic        line_start,

    // Streaming pixel output
    output logic [23:0] pixel_data,     // {R[7:0], G[7:0], B[7:0]}
    output logic        pixel_valid,
    input  logic        pixel_ready
);

    // Internal position counters
    logic [9:0] pixel_x;
    logic [9:0] pixel_y;

    // Position tracking
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pixel_x <= '0;
            pixel_y <= '0;
        end else begin
            if (frame_start) begin
                pixel_x <= '0;
                pixel_y <= '0;
            end else if (line_start) begin
                pixel_x <= '0;
                pixel_y <= pixel_y + 1'b1;
            end else if (pixel_valid && pixel_ready) begin
                pixel_x <= pixel_x + 1'b1;
            end
        end
    end

    // Always ready to provide pixels (combinational patterns)
    assign pixel_valid = 1'b1;

    // Color bar column index (640px / 8 = 80px per column)
    logic [2:0] col_idx;

    always_comb begin
        if      (pixel_x < 80)  col_idx = 3'd0;
        else if (pixel_x < 160) col_idx = 3'd1;
        else if (pixel_x < 240) col_idx = 3'd2;
        else if (pixel_x < 320) col_idx = 3'd3;
        else if (pixel_x < 400) col_idx = 3'd4;
        else if (pixel_x < 480) col_idx = 3'd5;
        else if (pixel_x < 560) col_idx = 3'd6;
        else                    col_idx = 3'd7;
    end

    // Color bars lookup
    logic [23:0] color_bars_data;

    always_comb begin
        case (col_idx)
            3'd0:    color_bars_data = 24'hFFFFFF; // White
            3'd1:    color_bars_data = 24'hFFFF00; // Yellow
            3'd2:    color_bars_data = 24'h00FFFF; // Cyan
            3'd3:    color_bars_data = 24'h00FF00; // Green
            3'd4:    color_bars_data = 24'hFF00FF; // Magenta
            3'd5:    color_bars_data = 24'hFF0000; // Red
            3'd6:    color_bars_data = 24'h0000FF; // Blue
            3'd7:    color_bars_data = 24'h000000; // Black
            default: color_bars_data = 24'h000000;
        endcase
    end

    // Pre-compute pattern bits (avoids Icarus part-select warning in always_comb)
    logic [7:0] grad_r;
    logic [7:0] grad_g;
    logic       checker_bit;
    assign grad_r      = pixel_x[9:2];
    assign grad_g      = pixel_y[8:1];
    assign checker_bit = pixel_x[3] ^ pixel_y[3];

    // Pattern mux
    always_comb begin
        case (pattern_sel)
            2'd0:    pixel_data = color_bars_data;
            2'd1:    pixel_data = checker_bit ? 24'hFFFFFF : 24'h000000;
            2'd2:    pixel_data = 24'hFF0000;
            2'd3:    pixel_data = {grad_r, grad_g, 8'h00};
            default: pixel_data = 24'h000000;
        endcase
    end

endmodule
