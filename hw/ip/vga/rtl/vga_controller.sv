// VGA Controller with streaming pixel input
// Generates VGA sync signals and accepts pixel data via ready/valid handshake.
// Timing parameters default to 640x480 @ 60Hz (25 MHz pixel clock).
// Reference: Project F display_timings.sv (MIT, github.com/projf/projf-explore)

module vga_controller #(
    // Horizontal timing (pixel clocks)
    parameter H_ACTIVE      = 640,
    parameter H_FRONT_PORCH = 16,
    parameter H_SYNC_PULSE  = 96,
    parameter H_BACK_PORCH  = 48,
    // Vertical timing (lines)
    parameter V_ACTIVE      = 480,
    parameter V_FRONT_PORCH = 10,
    parameter V_SYNC_PULSE  = 2,
    parameter V_BACK_PORCH  = 33
)(
    input  logic        clk,            // pixel clock
    input  logic        rst_n,          // active-low synchronous reset

    // Streaming pixel input
    input  logic [23:0] pixel_data,     // {R[7:0], G[7:0], B[7:0]}
    input  logic        pixel_valid,    // upstream has pixel data
    output logic        pixel_ready,    // controller accepting pixels (active area)

    // Synchronization outputs to upstream
    output logic        frame_start,    // pulse at first active pixel of frame
    output logic        line_start,     // pulse at first active pixel of each line

    // VGA output
    output logic        vga_hsync,      // horizontal sync (active-low)
    output logic        vga_vsync,      // vertical sync (active-low)
    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b
);

    // Derived timing constants
    localparam H_TOTAL = H_ACTIVE + H_FRONT_PORCH + H_SYNC_PULSE + H_BACK_PORCH;
    localparam V_TOTAL = V_ACTIVE + V_FRONT_PORCH + V_SYNC_PULSE + V_BACK_PORCH;

    // Sync pulse start positions
    localparam H_SYNC_START = H_ACTIVE + H_FRONT_PORCH;
    localparam H_SYNC_END   = H_SYNC_START + H_SYNC_PULSE;
    localparam V_SYNC_START = V_ACTIVE + V_FRONT_PORCH;
    localparam V_SYNC_END   = V_SYNC_START + V_SYNC_PULSE;

    // Counters
    logic [$clog2(H_TOTAL)-1:0] h_count;
    logic [$clog2(V_TOTAL)-1:0] v_count;

    // Active region flag
    logic active;

    // Horizontal counter
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            h_count <= '0;
        end else if (h_count == H_TOTAL - 1) begin
            h_count <= '0;
        end else begin
            h_count <= h_count + 1'b1;
        end
    end

    // Vertical counter
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            v_count <= '0;
        end else if (h_count == H_TOTAL - 1) begin
            if (v_count == V_TOTAL - 1)
                v_count <= '0;
            else
                v_count <= v_count + 1'b1;
        end
    end

    // Active display area
    always_comb begin
        active = (h_count < H_ACTIVE) && (v_count < V_ACTIVE);
    end

    // Pixel ready — accept data during active area
    assign pixel_ready = active;

    // Sync signals (active-low)
    assign vga_hsync = !((h_count >= H_SYNC_START) && (h_count < H_SYNC_END));
    assign vga_vsync = !((v_count >= V_SYNC_START) && (v_count < V_SYNC_END));

    // Synchronization pulses to upstream
    assign frame_start = (h_count == 0) && (v_count == 0);
    assign line_start  = (h_count == 0) && (v_count < V_ACTIVE);

    // VGA RGB output — register pixel data during active area
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            vga_r <= 8'h00;
            vga_g <= 8'h00;
            vga_b <= 8'h00;
        end else if (active && pixel_valid) begin
            vga_r <= pixel_data[23:16];
            vga_g <= pixel_data[15:8];
            vga_b <= pixel_data[7:0];
        end else begin
            vga_r <= 8'h00;
            vga_g <= 8'h00;
            vga_b <= 8'h00;
        end
    end

endmodule
