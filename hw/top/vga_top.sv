// VGA Top-Level
// Wires pattern generator into VGA controller.

module vga_top (
    input  logic        clk,            // 25 MHz pixel clock
    input  logic        rst_n,
    input  logic [1:0]  pattern_sel,
    output logic        vga_hsync,
    output logic        vga_vsync,
    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b
);

    // Internal signals
    logic [23:0] pixel_data;
    logic        pixel_valid;
    logic        pixel_ready;
    logic        frame_start;
    logic        line_start;

    pattern_gen u_pattern_gen (
        .clk         (clk),
        .rst_n       (rst_n),
        .pattern_sel (pattern_sel),
        .frame_start (frame_start),
        .line_start  (line_start),
        .pixel_data  (pixel_data),
        .pixel_valid (pixel_valid),
        .pixel_ready (pixel_ready)
    );

    vga_controller u_vga_controller (
        .clk         (clk),
        .rst_n       (rst_n),
        .pixel_data  (pixel_data),
        .pixel_valid (pixel_valid),
        .pixel_ready (pixel_ready),
        .frame_start (frame_start),
        .line_start  (line_start),
        .vga_hsync   (vga_hsync),
        .vga_vsync   (vga_vsync),
        .vga_r       (vga_r),
        .vga_g       (vga_g),
        .vga_b       (vga_b)
    );

endmodule
