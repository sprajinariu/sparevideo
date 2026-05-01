// Testbench for sparevideo_top (AXI4-Stream version)
//
// Drives an AXI4-Stream input on clk_pix_in, runs processing on clk_dsp,
// and captures VGA RGB output on clk_pix_out.
//
// Plusargs:
//   +INFILE=<path>     Input frame file (default "input.txt")
//   +OUTFILE=<path>    Output frame file (default "output.txt")
//   +WIDTH=<n>         Frame width (default 320)
//   +HEIGHT=<n>        Frame height (default 240)
//   +FRAMES=<n>        Number of frames (default 4)
//   +MODE=text|binary  File format (default "text")
//   +CTRL_FLOW=<name>  passthrough|motion|mask|ccl_bbox
//   +sw_dry_run=1      Bypass RTL — direct file loopback (no clock)
//   +DUMP_VCD          Dump waveforms to VCD
//
// Compile-time -G overrides:
//   -GCFG_NAME='"<name>"' Algorithm profile (default|default_hflip|no_ema|no_morph|no_gauss|no_gamma_cor|no_scaler|demo|no_hud)
//   -GH_ACTIVE / -GV_ACTIVE Resolution overrides

`timescale 1ns / 1ps

module tb_sparevideo #(
    parameter int    H_ACTIVE     = 320,
    parameter int    V_ACTIVE     = 240,
    parameter string CFG_NAME     = "default"
);

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
    localparam int V_FRONT_PORCH = 5;
    localparam int V_SYNC_PULSE  = 6;
    localparam int V_BACK_PORCH  = 5;
    localparam int V_BLANK       = V_FRONT_PORCH + V_SYNC_PULSE + V_BACK_PORCH;

    // ---------------------------------------------------------------
    // Algorithm profile resolution (must come before any localparam
    // that depends on CFG.scaler_en). Add new entries here AND in
    // sparevideo_pkg.sv AND in py/profiles.py.
    // ---------------------------------------------------------------
    localparam sparevideo_pkg::cfg_t CFG =
        (CFG_NAME == "default_hflip") ? sparevideo_pkg::CFG_DEFAULT_HFLIP :
        (CFG_NAME == "no_ema")        ? sparevideo_pkg::CFG_NO_EMA        :
        (CFG_NAME == "no_morph")      ? sparevideo_pkg::CFG_NO_MORPH      :
        (CFG_NAME == "no_gauss")      ? sparevideo_pkg::CFG_NO_GAUSS      :
        (CFG_NAME == "no_gamma_cor")  ? sparevideo_pkg::CFG_NO_GAMMA_COR  :
        (CFG_NAME == "no_scaler")     ? sparevideo_pkg::CFG_NO_SCALER     :
        (CFG_NAME == "demo")          ? sparevideo_pkg::CFG_DEMO          :
        (CFG_NAME == "no_hud")        ? sparevideo_pkg::CFG_NO_HUD        :
                                        sparevideo_pkg::CFG_DEFAULT;

    localparam int H_ACTIVE_OUT = CFG.scaler_en ? 2 * H_ACTIVE : H_ACTIVE;
    localparam int V_ACTIVE_OUT = CFG.scaler_en ? 2 * V_ACTIVE : V_ACTIVE;

    // 25 MHz output pixel clock (40ns), 100 MHz DSP clock (10ns).
    // When CFG.scaler_en=1, the input pixel clock runs at 1/4 of the output
    // pixel clock so the long-term input pixel rate matches the
    // VGA-side consumption rate (one input pixel produces a 2x2 output
    // tile, i.e. 4 output pixels).
    localparam int CLK_PIX_OUT_PERIOD = 40;                                     // 25 MHz
    localparam int CLK_PIX_IN_PERIOD  = CFG.scaler_en ? 4 * CLK_PIX_OUT_PERIOD  // 6.25 MHz when scaler enabled
                                                      :     CLK_PIX_OUT_PERIOD; // 25 MHz when scaler bypassed
    localparam int CLK_DSP_PERIOD     = 10;                                     // 100 MHz, unchanged

    // ---------------------------------------------------------------
    // Configuration (from plusargs)
    // ---------------------------------------------------------------
    integer cfg_width   = 320;
    integer cfg_height  = 240;
    integer cfg_frames  = 4;
    integer cfg_out_width  = 320;
    integer cfg_out_height = 240;
    string  cfg_infile  = "input.txt";
    string  cfg_outfile = "output.txt";
    string  cfg_mode    = "text";

    // Control flow (driven by plusarg, quasi-static)
    logic [1:0] ctrl_flow = sparevideo_pkg::CTRL_MOTION_DETECT;

    // ---------------------------------------------------------------
    // Clocks, resets, DUT signals
    // ---------------------------------------------------------------
    logic clk_pix_in;
    logic clk_pix_out;
    logic clk_dsp;
    logic rst_pix_in_n;
    logic rst_pix_out_n;
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
    axis_if #(.DATA_W(24), .USER_W(1)) s_axis ();

    always_ff @(negedge clk_pix_in) begin
        s_axis.tdata  <= drv_tdata;
        s_axis.tvalid <= drv_tvalid;
        s_axis.tlast  <= drv_tlast;
        s_axis.tuser  <= drv_tuser;
    end

    logic       vga_hsync;
    logic       vga_vsync;
    logic [7:0] vga_r;
    logic [7:0] vga_g;
    logic [7:0] vga_b;

    initial begin
        if (CFG_NAME != "default"       &&
            CFG_NAME != "default_hflip" &&
            CFG_NAME != "no_ema"        &&
            CFG_NAME != "no_morph"      &&
            CFG_NAME != "no_gauss"      &&
            CFG_NAME != "no_gamma_cor"  &&
            CFG_NAME != "no_scaler"     &&
            CFG_NAME != "demo"          &&
            CFG_NAME != "no_hud")
            $warning("Unknown CFG_NAME '%s'; falling back to CFG_DEFAULT",
                     CFG_NAME);
    end

    // The DUT's VGA controller is parameterised at instantiation; we
    // override here so the timing matches the small TB blanking values.
    sparevideo_top #(
        .H_ACTIVE      (H_ACTIVE),
        .H_FRONT_PORCH (H_FRONT_PORCH),
        .H_SYNC_PULSE  (H_SYNC_PULSE),
        .H_BACK_PORCH  (H_BACK_PORCH),
        .V_ACTIVE      (V_ACTIVE),
        .V_FRONT_PORCH (V_FRONT_PORCH),
        .V_SYNC_PULSE  (V_SYNC_PULSE),
        .V_BACK_PORCH  (V_BACK_PORCH),
        .CFG           (CFG)
    ) u_dut (
        .clk_pix_in_i    (clk_pix_in),
        .clk_pix_out_i   (clk_pix_out),
        .clk_dsp_i       (clk_dsp),
        .rst_pix_in_n_i  (rst_pix_in_n),
        .rst_pix_out_n_i (rst_pix_out_n),
        .rst_dsp_n_i     (rst_dsp_n),
        .s_axis      (s_axis),
        .ctrl_flow_i (ctrl_flow),
        .vga_hsync_o (vga_hsync),
        .vga_vsync_o (vga_vsync),
        .vga_r_o     (vga_r),
        .vga_g_o     (vga_g),
        .vga_b_o     (vga_b)
    );

    initial clk_pix_in  = 0;
    always #(CLK_PIX_IN_PERIOD/2)  clk_pix_in  = ~clk_pix_in;
    initial clk_pix_out = 0;
    always #(CLK_PIX_OUT_PERIOD/2) clk_pix_out = ~clk_pix_out;
    initial clk_dsp     = 0;
    always #(CLK_DSP_PERIOD/2)     clk_dsp     = ~clk_dsp;

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

        begin : parse_ctrl_flow
            string ctrl_flow_str;
            ctrl_flow_str = "";
            if ($value$plusargs("CTRL_FLOW=%s", ctrl_flow_str)) begin
                if (ctrl_flow_str == "passthrough")
                    ctrl_flow = sparevideo_pkg::CTRL_PASSTHROUGH;
                else if (ctrl_flow_str == "motion")
                    ctrl_flow = sparevideo_pkg::CTRL_MOTION_DETECT;
                else if (ctrl_flow_str == "mask")
                    ctrl_flow = sparevideo_pkg::CTRL_MASK_DISPLAY;
                else if (ctrl_flow_str == "ccl_bbox")
                    ctrl_flow = sparevideo_pkg::CTRL_CCL_BBOX;
                else
                    $warning("Unknown CTRL_FLOW '%s', using default (motion)", ctrl_flow_str);
            end
        end

        cfg_out_width  = CFG.scaler_en ? (2 * cfg_width)  : cfg_width;
        cfg_out_height = CFG.scaler_en ? (2 * cfg_height) : cfg_height;

        $display("TB sparevideo: %0dx%0d in -> %0dx%0d out, %0d frames, mode=%s",
                 cfg_width, cfg_height, cfg_out_width, cfg_out_height,
                 cfg_frames, cfg_mode);
        $display("  ctrl_flow: %s",
            (ctrl_flow == sparevideo_pkg::CTRL_PASSTHROUGH)   ? "passthrough" :
            (ctrl_flow == sparevideo_pkg::CTRL_MOTION_DETECT) ? "motion"      :
            (ctrl_flow == sparevideo_pkg::CTRL_MASK_DISPLAY)  ? "mask"        :
            (ctrl_flow == sparevideo_pkg::CTRL_CCL_BBOX)      ? "ccl_bbox"    : "unknown");
        $display("  CFG=%s thresh=%0d a=%0d a_slow=%0d grace=%0d ga=%0d",
                 CFG_NAME, CFG.motion_thresh, CFG.alpha_shift, CFG.alpha_shift_slow,
                 CFG.grace_frames, CFG.grace_alpha_shift);
        $display("  gauss=%0b morph=%0b hflip=%0b gamma=%0b bbox=0x%06x",
                 CFG.gauss_en, CFG.morph_en, CFG.hflip_en, CFG.gamma_en, CFG.bbox_color);
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
            integer hdr_w, hdr_h;
            hdr_w = CFG.scaler_en ? (2 * cfg_width)  : cfg_width;
            hdr_h = CFG.scaler_en ? (2 * cfg_height) : cfg_height;
            $fwrite(fd_out, "%c%c%c%c",
                hdr_w[7:0],  hdr_w[15:8],
                hdr_w[23:16], hdr_w[31:24]);
            $fwrite(fd_out, "%c%c%c%c",
                hdr_h[7:0], hdr_h[15:8],
                hdr_h[23:16], hdr_h[31:24]);
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
            rst_pix_in_n  <= 0;
            rst_pix_out_n <= 0;
            rst_dsp_n     <= 0;
            repeat (10) @(posedge clk_pix_out);
            rst_pix_in_n  <= 1;
            rst_pix_out_n <= 1;
            rst_dsp_n     <= 1;
            @(posedge clk_pix_out);
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
                        @(posedge clk_pix_in);
                        while (!s_axis.tready) @(posedge clk_pix_in);

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
                    repeat (H_BLANK) @(posedge clk_pix_in);
                end
            end // row

            // Vertical blanking gap after each frame (RTL only).
            // V_BLANK full lines (each H_ACTIVE + H_BLANK cycles wide).
            if (!sw_dry_run) begin
                begin : v_blank_gap
                    integer vb;
                    drv_tvalid = 0;
                    for (vb = 0; vb < V_BLANK * (cfg_width + H_BLANK); vb = vb + 1)
                        @(posedge clk_pix_in);
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
                $display("Frame %0d: %0d pixels OK",
                         frame_idx, frame_pixels);
            else
                $display("Frame %0d: input complete",
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
                expected_pixels = cfg_out_width * cfg_out_height * cfg_frames;
                while (rtl_out_total < expected_pixels) @(posedge clk_pix_out);
            end
            repeat (10) @(posedge clk_pix_out);
            rtl_capturing = 0;

            $fclose(fd_in);
            $fclose(fd_out_rtl);

            begin
                integer expected_pixels;
                expected_pixels = cfg_out_width * cfg_out_height * cfg_frames;
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

        if (error_count == 0) begin
            $display("PASS");
            $finish;
        end else begin
            $display("FAIL: %0d errors", error_count);
            $fatal(1, "Simulation failed with %0d errors", error_count);
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
    // sampled at posedge K when (active && pixel_valid) was true.
    // So vga_r is one cycle behind the handshake. We delay the
    // capture qualifier by one clock so it lines up with the
    // registered RGB. Both ready AND valid must be true — ready alone
    // would capture cycles where the VGA is in the active region but
    // the FIFO hasn't delivered a pixel yet.
    wire dut_active = u_dut.u_vga.pixel_ready_o
                    & u_dut.pix_out_tvalid
                    & u_dut.vga_started;
    logic dut_active_d;
    always_ff @(posedge clk_pix_out) begin
        if (!rst_pix_out_n) dut_active_d <= 1'b0;
        else                dut_active_d <= dut_active;
    end

    always @(negedge clk_pix_out) begin
        if (rtl_capturing && dut_active_d) begin
            if (cfg_mode == "text") begin
                if (rtl_out_col > 0) $fwrite(fd_out_rtl, " ");
                $fwrite(fd_out_rtl, "%02X%02X%02X", vga_r, vga_g, vga_b);
                rtl_out_col = rtl_out_col + 1;
                if (rtl_out_col == cfg_out_width) begin
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
            timeout_clocks = (cfg_out_width + H_BLANK) * (cfg_out_height + V_BLANK)
                           * (cfg_frames + 4);
            #(CLK_PIX_IN_PERIOD * timeout_clocks);
            $display("ERROR: Watchdog timeout after %0d clocks", timeout_clocks);
            $finish;
        end
    end

endmodule
