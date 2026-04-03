// Self-checking testbench for vga_top
// Verifies VGA timing and color bar pixel values.
// Icarus Verilog 12 compatible (no SVA, no break, no disable fork).

`timescale 1ns / 1ps

module tb_vga_top;

    // VGA timing parameters (must match RTL defaults)
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

    localparam CLK_PERIOD = 40; // 40ns = 25 MHz

    // DUT signals
    logic        clk;
    logic        rst_n;
    logic [1:0]  pattern_sel;
    logic        vga_hsync;
    logic        vga_vsync;
    logic [7:0]  vga_r, vga_g, vga_b;

    // Test tracking
    integer error_count = 0;
    integer test_count  = 0;
    integer measured;

    // DUT
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

    // Clock generation
    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // Waveform dump
    initial begin
        if ($test$plusargs("DUMP_VCD")) begin
            $dumpfile("tb_vga_top.vcd");
            $dumpvars(0, tb_vga_top);
        end
    end

    // Helper task: check a value and report
    task automatic check(input string name, input integer got, input integer expected);
        test_count = test_count + 1;
        if (got !== expected) begin
            $display("FAIL: %s = %0d, expected %0d", name, got, expected);
            error_count = error_count + 1;
        end else begin
            $display("PASS: %s = %0d", name, got);
        end
    endtask

    // Helper task: check RGB pixel
    task automatic check_rgb(input string name,
                             input [7:0] got_r, got_g, got_b,
                             input [7:0] exp_r, exp_g, exp_b);
        test_count = test_count + 1;
        if (got_r !== exp_r || got_g !== exp_g || got_b !== exp_b) begin
            $display("FAIL: %s: R=%02h G=%02h B=%02h, expected %02h %02h %02h",
                     name, got_r, got_g, got_b, exp_r, exp_g, exp_b);
            error_count = error_count + 1;
        end else begin
            $display("PASS: %s = %02h %02h %02h", name, got_r, got_g, got_b);
        end
    endtask

    // ---------------------------------------------------------------
    // Main test sequence
    // ---------------------------------------------------------------
    initial begin
        $display("=== VGA Top Testbench ===");

        // Reset
        rst_n = 0;
        pattern_sel = 2'd0;  // color bars
        repeat (20) @(posedge clk);
        rst_n = 1;
        $display("Reset released");

        // Let the design run for a bit to stabilize
        // Wait for two vsync falling edges to align to a known frame boundary
        @(negedge vga_vsync);
        @(negedge vga_vsync);
        $display("Frame boundary aligned, starting measurements");

        // ---- Test 1: Hsync period (negedge to negedge) ----
        @(negedge vga_hsync);
        measured = 0;
        @(posedge clk);
        while (vga_hsync) begin  // wait through high portion
            @(posedge clk);
            measured = measured + 1;
        end
        while (!vga_hsync) begin // wait through low portion (pulse)
            @(posedge clk);
            measured = measured + 1;
        end
        // Now hsync just went high again; wait for next negedge
        while (vga_hsync) begin
            @(posedge clk);
            measured = measured + 1;
        end
        // We've gone negedge -> (high) -> (low) -> (high) -> negedge
        // But we started after negedge aligned to posedge clk,
        // so first partial high was already counted. This is getting tricky.
        // Simpler approach: just count full clocks between two negedges.

        // Let me redo this cleanly
        // (the above ran but let's do it right with a second measurement)
        @(negedge vga_hsync);  // first negedge
        measured = 0;
        @(negedge vga_hsync);  // second negedge — measure time between
        // Use $time to measure instead
        $display("(Hsync period measured via edge-to-edge below)");

        // ---- Redo timing via $time ----
        begin
            integer t0_h, t1_h, t0_v, t1_v;

            // Hsync period
            @(negedge vga_hsync);
            t0_h = $time;
            @(negedge vga_hsync);
            t1_h = $time;
            check("Hsync period (clocks)", (t1_h - t0_h) / CLK_PERIOD, H_TOTAL);

            // Hsync pulse width
            @(negedge vga_hsync);
            t0_h = $time;
            @(posedge vga_hsync);
            t1_h = $time;
            check("Hsync pulse width (clocks)", (t1_h - t0_h) / CLK_PERIOD, H_SYNC_PULSE);

            // Lines per frame: vsync negedge to vsync negedge, count hsync negedges
            @(negedge vga_vsync);
            measured = 0;
            t0_v = $time;
            @(negedge vga_vsync);
            t1_v = $time;
            check("Frame period (clocks)", (t1_v - t0_v) / CLK_PERIOD, H_TOTAL * V_TOTAL);

            // Vsync pulse width
            @(negedge vga_vsync);
            t0_v = $time;
            @(posedge vga_vsync);
            t1_v = $time;
            check("Vsync pulse width (clocks)", (t1_v - t0_v) / CLK_PERIOD, H_TOTAL * V_SYNC_PULSE);
        end

        // ---- Color bar pixel checks ----
        // Strategy: wait for frame start (vsync negedge -> posedge -> back porch -> active)
        // then navigate to specific pixel positions.
        @(negedge vga_vsync);
        @(posedge vga_vsync);
        // After vsync posedge, we have V_BACK_PORCH lines of blanking
        repeat (V_BACK_PORCH) @(negedge vga_hsync);
        // Now at line 0. After this hsync negedge, we're at H_SYNC_START.
        // hsync goes high at H_SYNC_END, then H_BACK_PORCH clocks to reach h_count=0.
        @(posedge vga_hsync);
        repeat (H_BACK_PORCH) @(posedge clk);

        // Now at h_count=0, v_count=0 (first active pixel)
        // VGA output is registered (1 clock latency from pixel_data to vga_r/g/b)
        // So vga_r/g/b shows the pixel from 1 clock ago.
        // At h_count=0: pixel_data has x=0 data, vga output has it at h_count=1.
        // To see pixel x=40, wait 40+1 clocks.
        repeat (41) @(posedge clk);

        check_rgb("Color bar col 0 (white, x~40)", vga_r, vga_g, vga_b, 8'hFF, 8'hFF, 8'hFF);

        // Advance to x=120 (middle of yellow bar): 80 more clocks
        repeat (80) @(posedge clk);
        check_rgb("Color bar col 1 (yellow, x~120)", vga_r, vga_g, vga_b, 8'hFF, 8'hFF, 8'h00);

        // Advance to x=520 (middle of blue bar): 400 more clocks
        repeat (400) @(posedge clk);
        check_rgb("Color bar col 6 (blue, x~520)", vga_r, vga_g, vga_b, 8'h00, 8'h00, 8'hFF);

        // ---- Summary ----
        $display("");
        $display("=== Results: %0d tests, %0d errors ===", test_count, error_count);
        if (error_count == 0)
            $display("*** PASS ***");
        else
            $display("*** FAIL ***");

        $finish;
    end

    // Timeout watchdog
    initial begin
        #(CLK_PERIOD * H_TOTAL * V_TOTAL * 10);
        $display("ERROR: Simulation timeout");
        $finish;
    end

endmodule
