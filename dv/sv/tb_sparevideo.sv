// Testbench for sparesoc_top (AXI4-Stream version)
//
// Drives an AXI4-Stream input on clk_pix, runs processing on clk_dsp,
// and captures VGA RGB output on clk_pix.
//
// Plusargs:
//   +INFILE=<path>     Input frame file (default "input.txt")
//   +OUTFILE=<path>    Output frame file (default "output.txt")
//   +WIDTH=<n>         Frame width (default 320)
//   +HEIGHT=<n>        Frame height (default 240)
//   +FRAMES=<n>        Number of frames (default 4)
//   +MODE=text|binary  File format (default "text")
//   +sw_dry_run        Bypass RTL — direct file loopback (no clock)
//   +DUMP_VCD          Dump waveforms to VCD

`timescale 1ns / 1ps

module tb_sparevideo;

    // ---------------------------------------------------------------
    // Blanking parameters (small values to keep sim fast)
    // ---------------------------------------------------------------
    localparam int H_FRONT_PORCH = 4;
    localparam int H_SYNC_PULSE  = 8;
    localparam int H_BACK_PORCH  = 4;
    localparam int H_BLANK       = H_FRONT_PORCH + H_SYNC_PULSE + H_BACK_PORCH;
    localparam int V_FRONT_PORCH = 2;
    localparam int V_SYNC_PULSE  = 2;
    localparam int V_BACK_PORCH  = 2;
    localparam int V_BLANK       = V_FRONT_PORCH + V_SYNC_PULSE + V_BACK_PORCH;

    // 25 MHz pixel clock (40ns), 100 MHz DSP clock (10ns)
    localparam int CLK_PIX_PERIOD = 40;
    localparam int CLK_DSP_PERIOD = 10;

    // ---------------------------------------------------------------
    // Configuration (from plusargs)
    // ---------------------------------------------------------------
    integer cfg_width   = 320;
    integer cfg_height  = 240;
    integer cfg_frames  = 4;
    string  cfg_infile  = "input.txt";
    string  cfg_outfile = "output.txt";
    string  cfg_mode    = "text";

    // ---------------------------------------------------------------
    // Clocks, resets, DUT signals
    // ---------------------------------------------------------------
    logic        clk_pix;
    logic        clk_dsp;
    logic        rst_pix_n;
    logic        rst_dsp_n;

    logic [23:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tready;
    logic        s_axis_tlast;
    logic        s_axis_tuser;

    logic        vga_hsync;
    logic        vga_vsync;
    logic [7:0]  vga_r;
    logic [7:0]  vga_g;
    logic [7:0]  vga_b;

    // The DUT's VGA controller is parameterised at instantiation; we
    // override here so the timing matches the small TB blanking values.
    sparesoc_top #(
        .H_ACTIVE      (320),  // overridden via cfg_width below — see note
        .H_FRONT_PORCH (H_FRONT_PORCH),
        .H_SYNC_PULSE  (H_SYNC_PULSE),
        .H_BACK_PORCH  (H_BACK_PORCH),
        .V_ACTIVE      (240),
        .V_FRONT_PORCH (V_FRONT_PORCH),
        .V_SYNC_PULSE  (V_SYNC_PULSE),
        .V_BACK_PORCH  (V_BACK_PORCH)
    ) u_dut (
        .clk_pix       (clk_pix),
        .clk_dsp       (clk_dsp),
        .rst_pix_n     (rst_pix_n),
        .rst_dsp_n     (rst_dsp_n),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tlast  (s_axis_tlast),
        .s_axis_tuser  (s_axis_tuser),
        .vga_hsync     (vga_hsync),
        .vga_vsync     (vga_vsync),
        .vga_r         (vga_r),
        .vga_g         (vga_g),
        .vga_b         (vga_b)
    );

    initial clk_pix = 0;
    always #(CLK_PIX_PERIOD/2) clk_pix = ~clk_pix;
    initial clk_dsp = 0;
    always #(CLK_DSP_PERIOD/2) clk_dsp = ~clk_dsp;

    // Waveform dump
    initial begin
        if ($test$plusargs("DUMP_VCD")) begin
            $dumpfile("tb_sparevideo.vcd");
            $dumpvars(0, tb_sparevideo);
        end
    end

    // ---------------------------------------------------------------
    // Shared state
    // ---------------------------------------------------------------
    integer error_count = 0;
    integer fd_in, fd_out;

    // ---------------------------------------------------------------
    // Main test sequence
    // ---------------------------------------------------------------
    initial begin
        integer frame_idx, row_idx, col_idx;
        integer scan_r, scan_g, scan_b;
        integer scan_count;
        integer scan_pixel;
        realtime t_frame_start, t_frame_end;

        // Parse plusargs
        if ($value$plusargs("WIDTH=%d", cfg_width)) ;
        if ($value$plusargs("HEIGHT=%d", cfg_height)) ;
        if ($value$plusargs("FRAMES=%d", cfg_frames)) ;
        if ($value$plusargs("INFILE=%s", cfg_infile)) ;
        if ($value$plusargs("OUTFILE=%s", cfg_outfile)) ;
        if ($value$plusargs("MODE=%s", cfg_mode)) ;

        $display("TB sparevideo: %0dx%0d, %0d frames, mode=%s",
                 cfg_width, cfg_height, cfg_frames, cfg_mode);
        $display("  input:  %s", cfg_infile);
        $display("  output: %s", cfg_outfile);

        // ---- Open input file ----
        if (cfg_mode == "text") fd_in = $fopen(cfg_infile, "r");
        else                    fd_in = $fopen(cfg_infile, "rb");
        if (fd_in == 0) begin
            $display("ERROR: Cannot open input file: %s", cfg_infile);
            $finish;
        end
        if (cfg_mode != "text") begin
            integer hdr_byte, i;
            for (i = 0; i < 12; i = i + 1) begin
                hdr_byte = $fgetc(fd_in);
                if (hdr_byte == -1) begin
                    $display("ERROR: Input file too short (header)");
                    $finish;
                end
            end
        end

        // ---- Open output file ----
        if (cfg_mode == "text") fd_out = $fopen(cfg_outfile, "w");
        else                    fd_out = $fopen(cfg_outfile, "wb");
        if (fd_out == 0) begin
            $display("ERROR: Cannot open output file: %s", cfg_outfile);
            $finish;
        end
        if (cfg_mode != "text") begin
            $fwrite(fd_out, "%c%c%c%c",
                cfg_width[7:0],  cfg_width[15:8],
                cfg_width[23:16], cfg_width[31:24]);
            $fwrite(fd_out, "%c%c%c%c",
                cfg_height[7:0], cfg_height[15:8],
                cfg_height[23:16], cfg_height[31:24]);
            $fwrite(fd_out, "%c%c%c%c",
                cfg_frames[7:0], cfg_frames[15:8],
                cfg_frames[23:16], cfg_frames[31:24]);
        end

        // ---- Dispatch ----
        if ($test$plusargs("sw_dry_run")) begin
            // ===============================================================
            // SW DRY RUN: file loopback, no RTL
            // ===============================================================
            $display("--- SW dry run (RTL bypassed) ---");

            for (frame_idx = 0; frame_idx < cfg_frames; frame_idx = frame_idx + 1) begin
                integer frame_pixels;
                frame_pixels = 0;
                t_frame_start = $realtime;

                for (row_idx = 0; row_idx < cfg_height; row_idx = row_idx + 1) begin
                    for (col_idx = 0; col_idx < cfg_width; col_idx = col_idx + 1) begin
                        if (cfg_mode == "text") begin
                            scan_count = $fscanf(fd_in, "%x", scan_pixel);
                            if (scan_count != 1) begin
                                $display("ERROR: Read failed at frame %0d row %0d col %0d",
                                         frame_idx, row_idx, col_idx);
                                error_count = error_count + 1;
                            end else begin
                                if (col_idx > 0) $fwrite(fd_out, " ");
                                $fwrite(fd_out, "%06X", scan_pixel[23:0]);
                                frame_pixels = frame_pixels + 1;
                            end
                        end else begin
                            scan_r = $fgetc(fd_in);
                            scan_g = $fgetc(fd_in);
                            scan_b = $fgetc(fd_in);
                            if (scan_r == -1 || scan_g == -1 || scan_b == -1) begin
                                $display("ERROR: EOF at frame %0d row %0d col %0d",
                                         frame_idx, row_idx, col_idx);
                                error_count = error_count + 1;
                            end else begin
                                $fwrite(fd_out, "%c%c%c",
                                        scan_r[7:0], scan_g[7:0], scan_b[7:0]);
                                frame_pixels = frame_pixels + 1;
                            end
                        end
                    end
                    if (cfg_mode == "text") $fwrite(fd_out, "\n");
                end

                t_frame_end = $realtime;
                $display("Frame %0d: %0d pixels OK (wall-clock %.3f s)",
                         frame_idx, frame_pixels,
                         (t_frame_end - t_frame_start) / 1.0e9);
            end

            $fclose(fd_in);
            $fclose(fd_out);
            if (error_count == 0) $display("PASS");
            else                  $display("FAIL: %0d errors", error_count);
            $finish;

        end else begin
            // ===============================================================
            // RTL SIMULATION: drive AXI4-Stream, capture VGA RGB
            // ===============================================================
            $display("--- RTL simulation mode ---");

            // Reset
            rst_pix_n     <= 0;
            rst_dsp_n     <= 0;
            s_axis_tdata  <= '0;
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
            s_axis_tuser  <= 0;
            repeat (10) @(posedge clk_pix);
            rst_pix_n <= 1;
            rst_dsp_n <= 1;
            @(posedge clk_pix);

            // Enable VGA-side capture
            fd_out_rtl    = fd_out;
            rtl_capturing = 1;

            for (frame_idx = 0; frame_idx < cfg_frames; frame_idx = frame_idx + 1) begin
                t_frame_start = $realtime;

                for (row_idx = 0; row_idx < cfg_height; row_idx = row_idx + 1) begin
                    for (col_idx = 0; col_idx < cfg_width; col_idx = col_idx + 1) begin
                        if (cfg_mode == "text") begin
                            scan_count = $fscanf(fd_in, "%x", scan_pixel);
                            if (scan_count != 1) begin
                                $display("ERROR: Read failed at frame %0d row %0d col %0d",
                                         frame_idx, row_idx, col_idx);
                                error_count = error_count + 1;
                                scan_pixel = 0;
                            end
                        end else begin
                            scan_r = $fgetc(fd_in);
                            scan_g = $fgetc(fd_in);
                            scan_b = $fgetc(fd_in);
                            if (scan_r == -1 || scan_g == -1 || scan_b == -1) begin
                                $display("ERROR: EOF at frame %0d row %0d col %0d",
                                         frame_idx, row_idx, col_idx);
                                error_count = error_count + 1;
                                scan_r = 0; scan_g = 0; scan_b = 0;
                            end
                        end

                        if (cfg_mode == "text")
                            s_axis_tdata <= scan_pixel[23:0];
                        else
                            s_axis_tdata <= {scan_r[7:0], scan_g[7:0], scan_b[7:0]};
                        s_axis_tvalid <= 1;
                        s_axis_tuser  <= (row_idx == 0) && (col_idx == 0);
                        s_axis_tlast  <= (col_idx == cfg_width - 1);

                        // Hold until accepted (backpressure)
                        @(posedge clk_pix);
                        while (!s_axis_tready) @(posedge clk_pix);

                        s_axis_tvalid <= 0;
                        s_axis_tuser  <= 0;
                        s_axis_tlast  <= 0;
                    end
                end

                t_frame_end = $realtime;
                $display("Frame %0d: input complete (wall-clock %.3f s)",
                         frame_idx,
                         (t_frame_end - t_frame_start) / 1.0e9);
            end

            // Wait until VGA has emitted all expected pixels (or watchdog kills us)
            begin
                integer expected_pixels;
                expected_pixels = cfg_width * cfg_height * cfg_frames;
                while (rtl_out_total < expected_pixels) @(posedge clk_pix);
            end
            repeat (10) @(posedge clk_pix);
            rtl_capturing = 0;

            $fclose(fd_in);
            $fclose(fd_out_rtl);

            begin
                integer expected_pixels;
                expected_pixels = cfg_width * cfg_height * cfg_frames;
                $display("");
                $display("=== RTL Sim Summary ===");
                $display("Frames: %0d, Output pixels: %0d (expected %0d)",
                         cfg_frames, rtl_out_total, expected_pixels);
                if (rtl_out_total != expected_pixels) begin
                    $display("FAIL: pixel count mismatch");
                    error_count = error_count + 1;
                end
            end

            if (error_count == 0) $display("PASS");
            else                  $display("FAIL: %0d errors", error_count);
            $finish;
        end
    end

    // ---------------------------------------------------------------
    // VGA output capture: track h/v counters in lockstep with the
    // controller and write a pixel during the active region every
    // pixel clock. The vga_controller registers RGB on posedge, so
    // we sample at posedge of the *next* clock — i.e. we let the
    // pixel propagate then sample at negedge.
    // ---------------------------------------------------------------
    integer fd_out_rtl;
    integer rtl_out_total = 0;
    integer rtl_out_col   = 0;
    integer rtl_capturing = 0;

    // The vga_controller latches RGB at posedge K+1 from pixel_data
    // sampled at posedge K when active_K was true. So vga_r is one
    // cycle behind `pixel_ready`. We delay our capture qualifier by
    // one clock so it lines up with the registered RGB.
    wire dut_active = u_dut.u_vga.pixel_ready & u_dut.vga_started;
    logic dut_active_d;
    always_ff @(posedge clk_pix) begin
        if (!rst_pix_n) dut_active_d <= 1'b0;
        else            dut_active_d <= dut_active;
    end

    always @(negedge clk_pix) begin
        if (rtl_capturing && dut_active_d) begin
            if (cfg_mode == "text") begin
                if (rtl_out_col > 0) $fwrite(fd_out_rtl, " ");
                $fwrite(fd_out_rtl, "%02X%02X%02X", vga_r, vga_g, vga_b);
                rtl_out_col = rtl_out_col + 1;
                if (rtl_out_col == cfg_width) begin
                    $fwrite(fd_out_rtl, "\n");
                    rtl_out_col = 0;
                end
            end else begin
                $fwrite(fd_out_rtl, "%c%c%c", vga_r, vga_g, vga_b);
            end
            rtl_out_total = rtl_out_total + 1;
        end
    end

    // ---------------------------------------------------------------
    // Watchdog
    // ---------------------------------------------------------------
    initial begin
        #1;
        begin
            integer timeout_clocks;
            timeout_clocks = (cfg_width + H_BLANK) * (cfg_height + V_BLANK)
                           * (cfg_frames + 4);
            #(CLK_PIX_PERIOD * timeout_clocks);
            $display("ERROR: Watchdog timeout after %0d clocks", timeout_clocks);
            $finish;
        end
    end

endmodule
