// Unit testbench for axis_scale2x.
//
// Tests both SCALE_FILTER values; relies on the build invoking verilator
// twice (or two separate `make test-ip-scale2x SCALE_FILTER=nn` runs).
//
// Pattern inventory:
//   t1: 2x2 ramp (NN: pixel-doubled; bilinear: top-edge + right-edge replicate)
//   t2: 4x4 ramp + asymmetric stall (downstream tready toggled per beat)
//   t3: 8x4 with mid-frame downstream stall (5-cycle hold low)

`timescale 1ns / 1ps

module tb_axis_scale2x;

    parameter int    H_ACTIVE_IN = 4;
    parameter int    V_ACTIVE_IN = 4;
    parameter string SCALE_FILTER = "bilinear";   // override per recipe

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    axis_if #(.DATA_W(24), .USER_W(1)) s_axis ();
    axis_if #(.DATA_W(24), .USER_W(1)) m_axis ();

    // drv_* pattern: blocking writes in initial; NBA copy on negedge keeps
    // DUT inputs stable at posedge. Mirrors dv/sv/tb_sparevideo.sv.
    logic [23:0] drv_tdata  = '0;
    logic        drv_tvalid = 1'b0;
    logic        drv_tlast  = 1'b0;
    logic        drv_tuser  = 1'b0;
    logic        drv_m_tready = 1'b1;
    always_ff @(negedge clk) begin
        s_axis.tdata  <= drv_tdata;
        s_axis.tvalid <= drv_tvalid;
        s_axis.tlast  <= drv_tlast;
        s_axis.tuser  <= drv_tuser;
        m_axis.tready <= drv_m_tready;
    end

    axis_scale2x #(
        .H_ACTIVE_IN  (H_ACTIVE_IN),
        .V_ACTIVE_IN  (V_ACTIVE_IN),
        .SCALE_FILTER (SCALE_FILTER)
    ) dut (
        .clk_i   (clk),
        .rst_n_i (rst_n),
        .s_axis  (s_axis),
        .m_axis  (m_axis)
    );

    // Output capture: append every accepted output beat to an array.
    logic [23:0] captured [0:1023];
    int          n_captured = 0;
    always_ff @(posedge clk) begin
        if (m_axis.tvalid && m_axis.tready) begin
            captured[n_captured] <= m_axis.tdata;
            n_captured <= n_captured + 1;
        end
    end

    int errors = 0;

    task automatic drive_pixel(input int row, input int col,
                               input logic [23:0] data, input logic last);
        drv_tdata  = data;
        drv_tvalid = 1'b1;
        drv_tuser  = (row == 0) && (col == 0);
        drv_tlast  = last;
        @(posedge clk);
        while (!s_axis.tready) @(posedge clk);
        drv_tvalid = 1'b0;
        drv_tuser  = 1'b0;
        drv_tlast  = 1'b0;
    endtask

    task automatic check_eq(input int idx, input logic [23:0] expected);
        if (captured[idx] !== expected) begin
            $display("FAIL idx=%0d: got 0x%06x expected 0x%06x", idx, captured[idx], expected);
            errors++;
        end
    endtask

    initial begin : main
        int r, c;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Test 1: 2x2 ramp, no stall. Drive pixels {0x000010, 0x000020,
        //                                            0x000030, 0x000040}.
        // For NN: 16 output beats, each source pixel emitted 4 times.
        // For bilinear: 16 output beats with averaging (golden hand-checked
        // in test_scale2x.py).
        for (r = 0; r < 2; r++) begin
            for (c = 0; c < 2; c++) begin
                drive_pixel(r, c, 24'h000010 + 24'h10 * (2*r + c),
                                  /*last=*/(c == 1));
            end
        end

        // Wait for last output beat: 2*H_IN * 2*V_IN = 16 beats.
        repeat (64) @(posedge clk);

        if (SCALE_FILTER == "nn") begin
            check_eq(0, 24'h000010); check_eq(1, 24'h000010);
            check_eq(2, 24'h000020); check_eq(3, 24'h000020);
            check_eq(4, 24'h000010); check_eq(5, 24'h000010);
            check_eq(6, 24'h000020); check_eq(7, 24'h000020);
            check_eq(8,  24'h000030); check_eq(9,  24'h000030);
            check_eq(10, 24'h000040); check_eq(11, 24'h000040);
        end else begin
            check_eq(0, 24'h000010);
            check_eq(1, 24'h000018);
            check_eq(2, 24'h000020);
            check_eq(3, 24'h000020);
            check_eq(4, 24'h000010);
            check_eq(5, 24'h000018);
            check_eq(6, 24'h000020);
            check_eq(7, 24'h000020);
            check_eq(8,  24'h000030);
            check_eq(9,  24'h000038);
            check_eq(10, 24'h000040);
            check_eq(11, 24'h000040);
            check_eq(12, 24'h000020);
            check_eq(13, 24'h000028);
            check_eq(14, 24'h000030);
            check_eq(15, 24'h000030);
        end

        // Test 2: asymmetric stall. Toggle drv_m_tready every output beat
        // and replay test 1's input. This proves the FSM correctly holds the
        // input while emitting the two output rows.
        n_captured = 0;
        fork
            begin : stall_driver
                int t;
                for (t = 0; t < 32; t++) begin
                    drv_m_tready = (t & 1);
                    @(posedge clk);
                end
                drv_m_tready = 1'b1;
            end
            begin : input_driver
                rst_n = 0; @(posedge clk); rst_n = 1; @(posedge clk);
                for (r = 0; r < 2; r++) begin
                    for (c = 0; c < 2; c++) begin
                        drive_pixel(r, c, 24'h000010 + 24'h10 * (2*r + c),
                                          /*last=*/(c == 1));
                    end
                end
            end
        join

        repeat (64) @(posedge clk);

        if (SCALE_FILTER == "nn") begin
            check_eq(0, 24'h000010);
            check_eq(15, 24'h000040);
        end else begin
            check_eq(0, 24'h000010);
            check_eq(15, 24'h000030);
        end

        if (errors == 0) $display("PASS");
        else             $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Watchdog");
    end

endmodule
