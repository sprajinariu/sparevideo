// Testbench for sparesoc_top
//
// Main usage: read video input file, generate VGA-like timing, feed pixels
// to the RTL design, capture output, write to output file.
//
// Plusargs:
//   +INFILE=<path>     Input frame file (default "input.dat")
//   +OUTFILE=<path>    Output frame file (default "output.dat")
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
    localparam H_FRONT_PORCH = 4;
    localparam H_SYNC_PULSE  = 8;
    localparam H_BACK_PORCH  = 4;
    localparam H_BLANK       = H_FRONT_PORCH + H_SYNC_PULSE + H_BACK_PORCH;
    localparam V_FRONT_PORCH = 2;
    localparam V_SYNC_PULSE  = 2;
    localparam V_BACK_PORCH  = 2;
    localparam V_BLANK       = V_FRONT_PORCH + V_SYNC_PULSE + V_BACK_PORCH;
    localparam CLK_PERIOD    = 40; // 40ns = 25 MHz

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
    // DUT signals + clock
    // ---------------------------------------------------------------
    logic        clk;
    logic        rst_n;
    logic [23:0] vid_i_data;
    logic        vid_i_valid;
    logic        vid_i_hsync;
    logic        vid_i_vsync;
    logic [23:0] vid_o_data;
    logic        vid_o_valid;
    logic        vid_o_hsync;
    logic        vid_o_vsync;

    sparesoc_top u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .vid_i_data  (vid_i_data),
        .vid_i_valid (vid_i_valid),
        .vid_i_hsync (vid_i_hsync),
        .vid_i_vsync (vid_i_vsync),
        .vid_o_data  (vid_o_data),
        .vid_o_valid (vid_o_valid),
        .vid_o_hsync (vid_o_hsync),
        .vid_o_vsync (vid_o_vsync)
    );

    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

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
        if (cfg_mode == "text") begin
            fd_in = $fopen(cfg_infile, "r");
        end else begin
            fd_in = $fopen(cfg_infile, "rb");
        end
        if (fd_in == 0) begin
            $display("ERROR: Cannot open input file: %s", cfg_infile);
            $finish;
        end
        // Skip binary header
        if (cfg_mode != "text") begin
            begin
                integer hdr_byte, i;
                for (i = 0; i < 12; i = i + 1) begin
                    hdr_byte = $fgetc(fd_in);
                    if (hdr_byte == -1) begin
                        $display("ERROR: Input file too short (header)");
                        $finish;
                    end
                end
            end
        end

        // ---- Open output file ----
        if (cfg_mode == "text") begin
            fd_out = $fopen(cfg_outfile, "w");
        end else begin
            fd_out = $fopen(cfg_outfile, "wb");
        end
        if (fd_out == 0) begin
            $display("ERROR: Cannot open output file: %s", cfg_outfile);
            $finish;
        end
        // Write binary header
        if (cfg_mode != "text") begin
            $fwrite(fd_out, "%c%c%c%c",
                cfg_width[7:0], cfg_width[15:8],
                cfg_width[23:16], cfg_width[31:24]);
            $fwrite(fd_out, "%c%c%c%c",
                cfg_height[7:0], cfg_height[15:8],
                cfg_height[23:16], cfg_height[31:24]);
            $fwrite(fd_out, "%c%c%c%c",
                cfg_frames[7:0], cfg_frames[15:8],
                cfg_frames[23:16], cfg_frames[31:24]);
        end

        // ---- Dispatch to dry run or RTL sim ----
        if ($test$plusargs("sw_dry_run")) begin
            // ===============================================================
            // SW DRY RUN: file loopback, no RTL, no sim time
            // ===============================================================
            $display("--- SW dry run (RTL bypassed) ---");

            for (frame_idx = 0; frame_idx < cfg_frames; frame_idx = frame_idx + 1) begin
                integer frame_pixels;
                frame_pixels = 0;
                t_frame_start = $realtime;

                for (row_idx = 0; row_idx < cfg_height; row_idx = row_idx + 1) begin
                    for (col_idx = 0; col_idx < cfg_width; col_idx = col_idx + 1) begin
                        if (cfg_mode == "text") begin
                            scan_count = $fscanf(fd_in, "%x",
                                                 scan_pixel);
                            if (scan_count != 1) begin
                                $display("ERROR: Read failed at frame %0d row %0d col %0d",
                                         frame_idx, row_idx, col_idx);
                                error_count = error_count + 1;
                            end else begin
                                if (col_idx > 0)
                                    $fwrite(fd_out, " ");
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
                    if (cfg_mode == "text")
                        $fwrite(fd_out, "\n");
                end

                t_frame_end = $realtime;
                $display("Frame %0d: %0d pixels OK (wall-clock %.3f s)",
                         frame_idx, frame_pixels,
                         (t_frame_end - t_frame_start) / 1.0e9);
            end

            $fclose(fd_in);
            $fclose(fd_out);

            if (error_count == 0)
                $display("PASS");
            else
                $display("FAIL: %0d errors", error_count);

            $finish;

        end else begin
            // ===============================================================
            // RTL SIMULATION: generate timing, feed DUT, capture output
            // ===============================================================
            // TB drives signals at posedge clk using non-blocking assignments
            // (NBA). The DUT's always_ff also triggers at posedge, but NBA
            // scheduling ensures TB drives land in the NBA region after the
            // DUT has sampled its inputs in the Active region.
            $display("--- RTL simulation mode ---");

            // Reset
            @(posedge clk);
            rst_n       <= 0;
            vid_i_data  <= '0;
            vid_i_valid <= 0;
            vid_i_hsync <= 1;  // inactive (active-low)
            vid_i_vsync <= 1;
            repeat (10) @(posedge clk);
            rst_n <= 1;
            @(posedge clk);

            // Enable output capture (always block writes to fd_out_rtl)
            fd_out_rtl = fd_out;
            rtl_capturing = 1;

            for (frame_idx = 0; frame_idx < cfg_frames; frame_idx = frame_idx + 1) begin
                t_frame_start = $realtime;

                // --- Vsync pulse ---
                vid_i_vsync <= 0;
                repeat (V_SYNC_PULSE * (cfg_width + H_BLANK)) @(posedge clk);
                vid_i_vsync <= 1;

                // --- V back porch ---
                repeat (V_BACK_PORCH * (cfg_width + H_BLANK)) @(posedge clk);

                // --- Active lines ---
                for (row_idx = 0; row_idx < cfg_height; row_idx = row_idx + 1) begin
                    // Hsync pulse
                    vid_i_hsync <= 0;
                    repeat (H_SYNC_PULSE) @(posedge clk);
                    vid_i_hsync <= 1;

                    // H back porch
                    repeat (H_BACK_PORCH) @(posedge clk);

                    // Active pixels — read from file and drive to DUT
                    for (col_idx = 0; col_idx < cfg_width; col_idx = col_idx + 1) begin
                        if (cfg_mode == "text") begin
                            scan_count = $fscanf(fd_in, "%x",
                                                 scan_pixel);
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

                        if (cfg_mode == "text") begin
                            vid_i_data  <= scan_pixel[23:0];
                        end else begin
                            vid_i_data  <= {scan_r[7:0], scan_g[7:0], scan_b[7:0]};
                        end
                        vid_i_valid <= 1;
                        @(posedge clk);
                    end

                    vid_i_valid <= 0;
                    vid_i_data  <= '0;

                    // H front porch
                    repeat (H_FRONT_PORCH) @(posedge clk);
                end

                // --- V front porch ---
                repeat (V_FRONT_PORCH * (cfg_width + H_BLANK)) @(posedge clk);

                t_frame_end = $realtime;
                $display("Frame %0d: input complete (wall-clock %.3f s)",
                         frame_idx,
                         (t_frame_end - t_frame_start) / 1.0e9);
            end

            // Flush: wait extra clocks for pipeline drain
            repeat (10) @(posedge clk);
            rtl_capturing = 0;

            $fclose(fd_in);
            $fclose(fd_out_rtl);

            // Check output pixel count
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

            if (error_count == 0)
                $display("PASS");
            else
                $display("FAIL: %0d errors", error_count);

            $finish;
        end
    end

    // ---------------------------------------------------------------
    // RTL output capture (runs concurrently via always block)
    // ---------------------------------------------------------------
    integer fd_out_rtl;
    integer rtl_out_total = 0;
    integer rtl_out_col   = 0;
    integer rtl_capturing = 0;

    always @(negedge clk) begin
        if (rtl_capturing && vid_o_valid) begin
            if (cfg_mode == "text") begin
                if (rtl_out_col > 0)
                    $fwrite(fd_out_rtl, " ");
                $fwrite(fd_out_rtl, "%06X",
                        vid_o_data[23:0]);
                rtl_out_col = rtl_out_col + 1;
                if (rtl_out_col == cfg_width) begin
                    $fwrite(fd_out_rtl, "\n");
                    rtl_out_col = 0;
                end
            end else begin
                $fwrite(fd_out_rtl, "%c%c%c",
                        vid_o_data[23:16], vid_o_data[15:8], vid_o_data[7:0]);
            end
            rtl_out_total = rtl_out_total + 1;
        end
    end

    // ---------------------------------------------------------------
    // Watchdog: timeout after (frames + 2) frame durations
    // ---------------------------------------------------------------
    initial begin
        #1;
        begin
            integer timeout_clocks;
            timeout_clocks = (cfg_width + H_BLANK) * (cfg_height + V_BLANK)
                           * (cfg_frames + 2);
            #(CLK_PERIOD * timeout_clocks);
            $display("ERROR: Watchdog timeout after %0d clocks", timeout_clocks);
            $finish;
        end
    end

endmodule
