// Unit testbench for rgb2ycrcb.
//
// Drives corner-case, near-boundary, and spot-check RGB inputs through the
// 1-cycle pipeline and checks Y/Cb/Cr outputs.
//
// Checks:
//   Group A (original 6 corners): ±1 LSB tolerance to cover rounding.
//   Group B (near-boundary):      ±1 LSB tolerance — exercises small/large MACs.
//   Group C (exact-match):        0 tolerance — TB uses identical integer formula;
//                                 any systematic offset in RTL will be caught.
//
// Conventions:
//   - drv_* intermediaries driven with blocking = in initial block
//   - DUT inputs registered via always_ff @(negedge clk) to avoid INITIALDLY race
//   - $display + $fatal for pass/fail (no SVA — Verilator only)

`timescale 1ns / 1ps

module tb_rgb2ycrcb;

    localparam int CLK_PERIOD = 10; // 100 MHz

    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic rst_n;

    // Driver intermediaries (blocking = in initial)
    logic [7:0] drv_r = '0;
    logic [7:0] drv_g = '0;
    logic [7:0] drv_b = '0;

    // DUT inputs — driven on negedge to be stable at next posedge
    logic [7:0] dut_r, dut_g, dut_b;

    always_ff @(negedge clk) begin
        dut_r <= drv_r;
        dut_g <= drv_g;
        dut_b <= drv_b;
    end

    // DUT outputs
    logic [7:0] dut_y, dut_cb, dut_cr;

    rgb2ycrcb u_dut (
        .clk_i   (clk),
        .rst_n_i (rst_n),
        .r_i     (dut_r),
        .g_i     (dut_g),
        .b_i     (dut_b),
        .y_o     (dut_y),
        .cb_o    (dut_cb),
        .cr_o    (dut_cr)
    );

    integer num_errors = 0;

    // ---- Golden model ----
    // Matches RTL exactly: (coeff * channel) summed in 17-bit, top byte taken.
    function automatic logic [7:0] golden_y(input logic [7:0] r, g, b);
        return (17'(77*r) + 17'(150*g) + 17'(29*b)) >> 8;
    endfunction
    function automatic logic [7:0] golden_cb(input logic [7:0] r, g, b);
        logic [16:0] s;
        s = 17'(32768) - 17'(43*r) - 17'(85*g) + 17'(128*b);
        return s[15:8];
    endfunction
    function automatic logic [7:0] golden_cr(input logic [7:0] r, g, b);
        logic [16:0] s;
        s = 17'(32768) + 17'(128*r) - 17'(107*g) - 17'(21*b);
        return s[15:8];
    endfunction

    // ---- Check with tolerance ----
    task automatic check_tol(
        input string      name,
        input logic [7:0] exp_y,
        input logic [7:0] exp_cb,
        input logic [7:0] exp_cr,
        input integer     tol
    );
        integer dy, dcb, dcr;
        dy  = (dut_y  > exp_y)  ? int'(dut_y  - exp_y)  : int'(exp_y  - dut_y);
        dcb = (dut_cb > exp_cb) ? int'(dut_cb - exp_cb) : int'(exp_cb - dut_cb);
        dcr = (dut_cr > exp_cr) ? int'(dut_cr - exp_cr) : int'(exp_cr - dut_cr);
        if (dy > tol || dcb > tol || dcr > tol) begin
            $display("FAIL %s: Y=%0d(exp %0d) Cb=%0d(exp %0d) Cr=%0d(exp %0d)",
                     name, dut_y, exp_y, dut_cb, exp_cb, dut_cr, exp_cr);
            num_errors = num_errors + 1;
        end else begin
            $display("PASS %s: Y=%0d Cb=%0d Cr=%0d", name, dut_y, dut_cb, dut_cr);
        end
    endtask

    // ---- Drive and check one pixel ----
    // Sets drv_*, waits for pipeline (1 posedge register on negedge + 1 cycle DUT),
    // then checks output. Total wait = 2 posedges.
    task automatic drive_and_check(
        input string  name,
        input logic [7:0] r, g, b,
        input logic [7:0] exp_y, exp_cb, exp_cr,
        input integer tol
    );
        drv_r = r; drv_g = g; drv_b = b;
        repeat (2) @(posedge clk);
        check_tol(name, exp_y, exp_cb, exp_cr, tol);
    endtask

    // ---- Drive and check using golden model (exact) ----
    task automatic drive_and_check_golden(
        input string  name,
        input logic [7:0] r, g, b
    );
        drv_r = r; drv_g = g; drv_b = b;
        repeat (2) @(posedge clk);
        check_tol(name, golden_y(r,g,b), golden_cb(r,g,b), golden_cr(r,g,b), 0);
    endtask

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ================================================================
        // Group A — corner cases (original 6), ±1 LSB tolerance
        // ================================================================
        drive_and_check("black",  8'd0,   8'd0,   8'd0,   8'd0,   8'd128, 8'd128, 1);
        drive_and_check("white",  8'd255, 8'd255, 8'd255, 8'd255, 8'd128, 8'd128, 1);
        drive_and_check("gray",   8'd128, 8'd128, 8'd128, 8'd128, 8'd128, 8'd128, 1);
        drive_and_check("red",    8'd255, 8'd0,   8'd0,   8'd76,  8'd85,  8'd255, 1);
        drive_and_check("green",  8'd0,   8'd255, 8'd0,   8'd149, 8'd43,  8'd21,  1);
        drive_and_check("blue",   8'd0,   8'd0,   8'd255, 8'd28,  8'd255, 8'd107, 1);

        // ================================================================
        // Group B — near-boundary values, ±1 LSB tolerance
        // ================================================================
        // Near-black: small MAC sums, exercises low-end truncation
        drive_and_check("near_black",  8'd1,   8'd1,   8'd1,
                        golden_y(1,1,1), golden_cb(1,1,1), golden_cr(1,1,1), 1);
        // Near-white: large MAC sums
        drive_and_check("near_white",  8'd254, 8'd254, 8'd254,
                        golden_y(254,254,254), golden_cb(254,254,254), golden_cr(254,254,254), 1);
        // Purple: large Cb
        drive_and_check("purple",  8'd128, 8'd0,   8'd255,
                        golden_y(128,0,255), golden_cb(128,0,255), golden_cr(128,0,255), 1);
        // Orange: large Cr
        drive_and_check("orange",  8'd255, 8'd128, 8'd0,
                        golden_y(255,128,0), golden_cb(255,128,0), golden_cr(255,128,0), 1);

        // ================================================================
        // Group C — exact-match spot-checks (tolerance = 0)
        // TB and RTL use identical formula so any systematic bias is caught.
        // ================================================================
        drive_and_check_golden("exact_0",  8'd42,  8'd137, 8'd200);
        drive_and_check_golden("exact_1",  8'd200, 8'd50,  8'd80);
        drive_and_check_golden("exact_2",  8'd10,  8'd220, 8'd30);
        drive_and_check_golden("exact_3",  8'd180, 8'd180, 8'd10);
        drive_and_check_golden("exact_4",  8'd64,  8'd64,  8'd192);
        drive_and_check_golden("exact_5",  8'd0,   8'd128, 8'd255);
        drive_and_check_golden("exact_6",  8'd255, 8'd0,   8'd128);
        drive_and_check_golden("exact_7",  8'd100, 8'd100, 8'd100);

        // ================================================================
        // Summary
        // ================================================================
        if (num_errors > 0) begin
            $fatal(1, "tb_rgb2ycrcb FAILED with %0d errors", num_errors);
        end else begin
            $display("tb_rgb2ycrcb PASSED — all test vectors OK");
            $finish;
        end
    end

endmodule
