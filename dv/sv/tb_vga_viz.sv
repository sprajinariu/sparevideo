// VGA frame dump testbench
// Runs the RTL and writes raw pixel data to a binary file.
// No timing checks — purely for visualization.
//
// Plusargs:
//   +PATTERN=<0-3>   Pattern select (default 0)
//   +OUTFILE=<path>  Output file (default "frame.bin")
//   +FRAMES=<n>      Number of frames to dump (default 1)
//
// Output format: raw bytes, 3 bytes per pixel (R, G, B), row-major,
// 640 x 480 pixels per frame. Total = 921600 bytes per frame.

`timescale 1ns / 1ps

module tb_vga_viz;

    localparam H_ACTIVE      = 640;
    localparam H_FRONT_PORCH = 16;
    localparam H_SYNC_PULSE  = 96;
    localparam H_BACK_PORCH  = 48;
    localparam H_TOTAL       = H_ACTIVE + H_FRONT_PORCH + H_SYNC_PULSE + H_BACK_PORCH;
    localparam V_ACTIVE      = 480;
    localparam V_FRONT_PORCH = 10;
    localparam V_SYNC_PULSE  = 2;
    localparam V_BACK_PORCH  = 33;
    localparam V_TOTAL       = V_ACTIVE + V_FRONT_PORCH + V_SYNC_PULSE + V_BACK_PORCH;

    localparam CLK_PERIOD = 40;

    logic        clk;
    logic        rst_n;
    logic [1:0]  pattern_sel;
    logic        vga_hsync, vga_vsync;
    logic [7:0]  vga_r, vga_g, vga_b;

    vga_top u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .pattern_sel (pattern_sel),
        .vga_hsync   (vga_hsync),
        .vga_vsync   (vga_vsync),
        .vga_r       (vga_r),
        .vga_g       (vga_g),
        .vga_b       (vga_b)
    );

    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // Internal counters — shadow the RTL to know when we're in active area
    integer h_count, v_count;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            h_count <= 0;
            v_count <= 0;
        end else begin
            if (h_count == H_TOTAL - 1) begin
                h_count <= 0;
                if (v_count == V_TOTAL - 1)
                    v_count <= 0;
                else
                    v_count <= v_count + 1;
            end else begin
                h_count <= h_count + 1;
            end
        end
    end

    wire active = (h_count < H_ACTIVE) && (v_count < V_ACTIVE);

    // Main sequence
    integer fd;
    integer pattern_arg, frames_arg;
    integer frame_num;
    string  outfile;

    initial begin
        // Parse plusargs
        if (!$value$plusargs("PATTERN=%d", pattern_arg))
            pattern_arg = 0;
        if (!$value$plusargs("FRAMES=%d", frames_arg))
            frames_arg = 1;
        if (!$value$plusargs("OUTFILE=%s", outfile))
            outfile = "frame.bin";

        $display("VGA Viz: pattern=%0d, frames=%0d, outfile=%s",
                 pattern_arg, frames_arg, outfile);

        // Reset
        rst_n = 0;
        pattern_sel = pattern_arg[1:0];
        repeat (20) @(posedge clk);
        rst_n = 1;

        // Wait for first full frame to stabilize
        @(negedge vga_vsync);
        @(posedge vga_vsync);
        $display("Sync acquired, starting capture");

        // Open output file
        fd = $fopen(outfile, "wb");
        if (fd == 0) begin
            $display("ERROR: Cannot open %s", outfile);
            $finish;
        end

        for (frame_num = 0; frame_num < frames_arg; frame_num = frame_num + 1) begin
            // Wait for back porch to end (reach active area)
            // We're after vsync posedge. Wait V_BACK_PORCH lines.
            repeat (V_BACK_PORCH) @(negedge vga_hsync);
            @(posedge vga_hsync);
            repeat (H_BACK_PORCH) @(posedge clk);

            // Now at h_count=0, v_count=0. Capture the full active frame.
            // The VGA output is registered (1 clock delay), so we need to
            // sample starting at h_count=1 to get pixel 0's data.
            @(posedge clk); // advance to h_count=1

            begin
                integer line, px;
                for (line = 0; line < V_ACTIVE; line = line + 1) begin
                    for (px = 0; px < H_ACTIVE; px = px + 1) begin
                        $fwrite(fd, "%c%c%c", vga_r, vga_g, vga_b);
                        if (px < H_ACTIVE - 1)
                            @(posedge clk);
                    end
                    // Skip blanking to next active line
                    if (line < V_ACTIVE - 1) begin
                        // Remaining in this line: FP + sync + BP = 160 clocks
                        // Plus 1 clock for the register delay at start of next line
                        repeat (H_FRONT_PORCH + H_SYNC_PULSE + H_BACK_PORCH + 1) @(posedge clk);
                    end
                end
            end

            $display("Frame %0d captured", frame_num);

            // If more frames, wait for next frame
            if (frame_num < frames_arg - 1) begin
                @(negedge vga_vsync);
                @(posedge vga_vsync);
            end
        end

        $fclose(fd);
        $display("Done — %0d frame(s) written to %s", frames_arg, outfile);
        $finish;
    end

    // Timeout
    initial begin
        #(CLK_PERIOD * H_TOTAL * V_TOTAL * (10 + 10));
        $display("ERROR: Simulation timeout");
        $finish;
    end

endmodule
