// Testbench for sparevideo_top (AXI4-Stream version)
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
//   +THRESH=<n>        Motion threshold (informational; MOTION_THRESH is a
//                      compile-time parameter — recompile to change it)
//   +sw_dry_run=1      Bypass RTL — direct file loopback (no clock)
//   +DUMP_VCD          Dump waveforms to VCD

`timescale 1ns / 1ps

module tb_sparevideo;

`ifdef VERILATOR
    import "DPI-C" function longint get_wall_ms();
`endif

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
    logic clk_pix;
    logic clk_dsp;
    logic rst_pix_n;
    logic rst_dsp_n;

    // AXI driver intermediaries — written by the initial block with blocking =.
    // Keeping these separate from s_axis_* ensures no NBA/blocking mix in the
    // same process, which causes INITIALDLY races in Verilator --timing mode.
    logic [23:0] drv_tdata  = '0;
    logic        drv_tvalid = 1'b0;
    logic        drv_tlast  = 1'b0;
    logic        drv_tuser  = 1'b0;

    // AXI-stream DUT inputs — driven ONLY by this always_ff (no initial-block
    // NBAs on these signals).  Registering on negedge means the DUT's posedge
    // always_ff sees a stable, settled value with no scheduling ambiguity.
    logic [23:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tready;
    logic        s_axis_tlast;
    logic        s_axis_tuser;

    always_ff @(negedge clk_pix) begin
        s_axis_tdata  <= drv_tdata;
        s_axis_tvalid <= drv_tvalid;
        s_axis_tlast  <= drv_tlast;
        s_axis_tuser  <= drv_tuser;
    end

    logic       vga_hsync;
    logic       vga_vsync;
    logic [7:0] vga_r;
    logic [7:0] vga_g;
    logic [7:0] vga_b;

    // The DUT's VGA controller is parameterised at instantiation; we
    // override here so the timing matches the small TB blanking values.
    sparevideo_top #(
        .H_ACTIVE      (320),
        .H_FRONT_PORCH (H_FRONT_PORCH),
        .H_SYNC_PULSE  (H_SYNC_PULSE),
        .H_BACK_PORCH  (H_BACK_PORCH),
        .V_ACTIVE      (240),
        .V_FRONT_PORCH (V_FRONT_PORCH),
        .V_SYNC_PULSE  (V_SYNC_PULSE),
        .V_BACK_PORCH  (V_BACK_PORCH)
    ) u_dut (
        .clk_pix_i       (clk_pix),
        .clk_dsp_i       (clk_dsp),
        .rst_pix_n_i     (rst_pix_n),
        .rst_dsp_n_i     (rst_dsp_n),
        .s_axis_tdata_i  (s_axis_tdata),
        .s_axis_tvalid_i (s_axis_tvalid),
        .s_axis_tready_o (s_axis_tready),
        .s_axis_tlast_i  (s_axis_tlast),
        .s_axis_tuser_i  (s_axis_tuser),
        .vga_hsync_o     (vga_hsync),
        .vga_vsync_o     (vga_vsync),
        .vga_r_o         (vga_r),
        .vga_g_o         (vga_g),
        .vga_b_o         (vga_b)
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
        integer pixel_ok;
        integer frame_pixels;
        integer sw_dry_run;
        longint t_frame_start_ms, t_frame_end_ms;

        // Parse plusargs
        if ($value$plusargs("WIDTH=%d",    cfg_width))   ;
        if ($value$plusargs("HEIGHT=%d",   cfg_height))  ;
        if ($value$plusargs("FRAMES=%d",   cfg_frames))  ;
        if ($value$plusargs("INFILE=%s",   cfg_infile))  ;
        if ($value$plusargs("OUTFILE=%s",  cfg_outfile)) ;
        if ($value$plusargs("MODE=%s",     cfg_mode))    ;
        sw_dry_run = 0;
        if ($value$plusargs("sw_dry_run=%d", sw_dry_run)) ;

        begin : log_thresh
            integer thresh_arg;
            thresh_arg = 16;
            if ($value$plusargs("THRESH=%d", thresh_arg))
                $display("TB note: +THRESH=%0d seen (informational; MOTION_THRESH is compile-time)",
                         thresh_arg);
        end

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

        // ---- Mode-specific setup ----
        if (sw_dry_run) begin
            $display("--- SW dry run (RTL bypassed) ---");
        end else begin
            $display("--- RTL simulation mode ---");
            // Reset (drv_* start at 0 from their declarations)
            rst_pix_n <= 0;
            rst_dsp_n <= 0;
            repeat (10) @(posedge clk_pix);
            rst_pix_n <= 1;
            rst_dsp_n <= 1;
            @(posedge clk_pix);
            // Enable VGA-side capture
            fd_out_rtl    = fd_out;
            rtl_capturing = 1;
        end

        // ---- Main frame loop ----
        for (frame_idx = 0; frame_idx < cfg_frames; frame_idx = frame_idx + 1) begin
            frame_pixels = 0;
`ifdef VERILATOR
            t_frame_start_ms = get_wall_ms();
`else
            t_frame_start_ms = 0;
`endif

            for (row_idx = 0; row_idx < cfg_height; row_idx = row_idx + 1) begin
                for (col_idx = 0; col_idx < cfg_width; col_idx = col_idx + 1) begin

                    // ---- Read next pixel from file ----
                    pixel_ok = 1;
                    if (cfg_mode == "text") begin
                        scan_count = $fscanf(fd_in, "%x", scan_pixel);
                        if (scan_count != 1) begin
                            $display("ERROR: Read failed at frame %0d row %0d col %0d",
                                     frame_idx, row_idx, col_idx);
                            error_count = error_count + 1;
                            scan_pixel  = 0;
                            pixel_ok    = 0;
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
                            pixel_ok = 0;
                        end
                    end

                    // ---- Per-pixel action ----
                    if (sw_dry_run) begin
                        // Loopback: write pixel straight to output file
                        if (pixel_ok) begin
                            if (cfg_mode == "text") begin
                                if (col_idx > 0) $fwrite(fd_out, " ");
                                $fwrite(fd_out, "%06X", scan_pixel[23:0]);
                            end else begin
                                $fwrite(fd_out, "%c%c%c",
                                        scan_r[7:0], scan_g[7:0], scan_b[7:0]);
                            end
                            frame_pixels = frame_pixels + 1;
                        end
                    end else begin
                        // RTL: drive pixel into the DUT via AXI4-Stream
                        if (cfg_mode == "text")
                            drv_tdata = scan_pixel[23:0];
                        else
                            drv_tdata = {scan_r[7:0], scan_g[7:0], scan_b[7:0]};
                        drv_tvalid = 1;
                        drv_tuser  = (row_idx == 0) && (col_idx == 0);
                        drv_tlast  = (col_idx == cfg_width - 1);

                        // Hold until accepted (backpressure)
                        @(posedge clk_pix);
                        while (!s_axis_tready) @(posedge clk_pix);

                        drv_tvalid = 0;
                        drv_tuser  = 0;
                        drv_tlast  = 0;
                    end

                end // col
                if (sw_dry_run && cfg_mode == "text") $fwrite(fd_out, "\n");

                // Horizontal blanking gap after each active row (RTL only).
                // Matches the H_BLANK period the VGA controller inserts, so the
                // input rate equals the output rate and the output FIFO never overflows.
                if (!sw_dry_run) begin
                    drv_tvalid = 0;
                    repeat (H_BLANK) @(posedge clk_pix);
                end
            end // row

            // Vertical blanking gap after each frame (RTL only).
            // V_BLANK full lines (each H_ACTIVE + H_BLANK cycles wide).
            if (!sw_dry_run) begin
                begin : v_blank_gap
                    integer vb;
                    drv_tvalid = 0;
                    for (vb = 0; vb < V_BLANK * (cfg_width + H_BLANK); vb = vb + 1)
                        @(posedge clk_pix);
                end
            end

`ifdef VERILATOR
            t_frame_end_ms = get_wall_ms();
            if (sw_dry_run)
                $display("Frame %0d: %0d pixels OK (wall-clock %.3f s)",
                         frame_idx, frame_pixels,
                         (t_frame_end_ms - t_frame_start_ms) / 1000.0);
            else
                $display("Frame %0d: input complete (wall-clock %.3f s)",
                         frame_idx,
                         (t_frame_end_ms - t_frame_start_ms) / 1000.0);
`else
            if (sw_dry_run)
                $display("Frame %0d: %0d pixels OK (wall-clock N/A on Icarus)",
                         frame_idx, frame_pixels);
            else
                $display("Frame %0d: input complete (wall-clock N/A on Icarus)",
                         frame_idx);
`endif
        end // frame

        // ---- Mode-specific teardown ----
        if (sw_dry_run) begin
            $fclose(fd_in);
            $fclose(fd_out);
        end else begin
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
        end

        if (error_count == 0) $display("PASS");
        else                  $display("FAIL: %0d errors", error_count);
        $finish;
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
    wire dut_active = u_dut.u_vga.pixel_ready_o & u_dut.vga_started;
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
