// Unit testbench for rgb2ycrcb.
//
// Drives 6 corner-case RGB inputs through the 2-cycle pipeline and checks
// Y/Cb/Cr outputs against hand-computed reference values with +/-1 LSB
// tolerance (to cover any rounding differences).
//
// Conventions:
//   - drv_* intermediaries with blocking = in initial block
//   - DUT inputs registered via always_ff @(negedge clk) to avoid INITIALDLY race
//   - $display + $fatal for pass/fail (no SVA — Icarus 12 compat)
//   - $finish on success, $fatal on mismatch

`timescale 1ns / 1ps

module tb_rgb2ycrcb;

    localparam int CLK_PERIOD = 10; // 100 MHz

    // Clock and reset
    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic rst_n;

    // Driver intermediaries (blocking = in initial)
    logic [7:0] drv_r = '0;
    logic [7:0] drv_g = '0;
    logic [7:0] drv_b = '0;

    // DUT inputs — driven on negedge
    logic [7:0] dut_r, dut_g, dut_b;

    always_ff @(negedge clk) begin
        dut_r <= drv_r;
        dut_g <= drv_g;
        dut_b <= drv_b;
    end

    // DUT outputs
    logic [7:0] dut_y, dut_cb, dut_cr;

    rgb2ycrcb u_dut (
        .clk   (clk),
        .rst_n (rst_n),
        .r     (dut_r),
        .g     (dut_g),
        .b     (dut_b),
        .y     (dut_y),
        .cb    (dut_cb),
        .cr    (dut_cr)
    );

    integer num_errors = 0;

    task automatic check_output(
        input string      name,
        input logic [7:0] exp_y,
        input logic [7:0] exp_cb,
        input logic [7:0] exp_cr
    );
        integer diff_y, diff_cb, diff_cr;

        diff_y  = (dut_y  > exp_y)  ? (dut_y  - exp_y)  : (exp_y  - dut_y);
        diff_cb = (dut_cb > exp_cb) ? (dut_cb - exp_cb) : (exp_cb - dut_cb);
        diff_cr = (dut_cr > exp_cr) ? (dut_cr - exp_cr) : (exp_cr - dut_cr);

        if (diff_y > 1 || diff_cb > 1 || diff_cr > 1) begin
            $display("FAIL %s: Y=%0d(exp %0d) Cb=%0d(exp %0d) Cr=%0d(exp %0d)",
                     name, dut_y, exp_y, dut_cb, exp_cb, dut_cr, exp_cr);
            num_errors = num_errors + 1;
        end else begin
            $display("PASS %s: Y=%0d Cb=%0d Cr=%0d", name, dut_y, dut_cb, dut_cr);
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- Test 0: Black (0,0,0) -> Y=0, Cb=128, Cr=128 ----
        drv_r = 0; drv_g = 0; drv_b = 0;
        // Wait 1-cycle pipeline + 1 negedge register = 2 posedges for output
        repeat (2) @(posedge clk);
        check_output("black", 8'd0, 8'd128, 8'd128);

        // ---- Test 1: White (255,255,255) -> Y=255, Cb=128, Cr=128 ----
        drv_r = 255; drv_g = 255; drv_b = 255;
        repeat (2) @(posedge clk);
        check_output("white", 8'd255, 8'd128, 8'd128);

        // ---- Test 2: Gray (128,128,128) -> Y=128, Cb=128, Cr=128 ----
        drv_r = 128; drv_g = 128; drv_b = 128;
        repeat (2) @(posedge clk);
        check_output("gray", 8'd128, 8'd128, 8'd128);

        // ---- Test 3: Red (255,0,0) -> Y=76, Cb=85, Cr=255 ----
        drv_r = 255; drv_g = 0; drv_b = 0;
        repeat (2) @(posedge clk);
        check_output("red", 8'd76, 8'd85, 8'd255);

        // ---- Test 4: Green (0,255,0) -> Y=149, Cb=43, Cr=21 ----
        drv_r = 0; drv_g = 255; drv_b = 0;
        repeat (2) @(posedge clk);
        check_output("green", 8'd149, 8'd43, 8'd21);

        // ---- Test 5: Blue (0,0,255) -> Y=28, Cb=255, Cr=107 ----
        drv_r = 0; drv_g = 0; drv_b = 255;
        repeat (2) @(posedge clk);
        check_output("blue", 8'd28, 8'd255, 8'd107);

        // Summary
        if (num_errors > 0) begin
            $fatal(1, "tb_rgb2ycrcb FAILED with %0d errors", num_errors);
        end else begin
            $display("tb_rgb2ycrcb PASSED — all 6 test vectors OK");
            $finish;
        end
    end

endmodule
