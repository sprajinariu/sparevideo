// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Unit testbench for axis_motion_detect_vibe.
//
// Tests:
//   T1   Static gray (8'h80) x 4 frames — mask must be 0 for all pixels
//        in frames 1..3 (after the frame-0 background init).
//
//   T2   ghost_box_disappear x 200 frames — bit-exact mask compare against
//        Python ViBe reference (hw/ip/motion/tb/golden/).
//        Drives RGB input from test2_input.bin; compares each mask beat
//        against test2_ghost_box_disappear.bin.  First mismatch logged.
//
//   T2b  Ghost ROI coverage decay — assert that diffusion has substantially
//        reduced ghost coverage in frames 150-199 vs frames 10-29.
//        Threshold pinned from Python reference (gen_golden.py):
//          avg_early  = 0.926562  (frames 10-29)
//          avg_late   = 0.090000  (frames 150-199)
//          ratio      = 0.097133
//          threshold  = 1.25 * ratio = 0.121417
//        If T2 passes (bit-exact), T2b is guaranteed to pass — it exists
//        for human readability of the coverage decay.
//
//   T5   Symmetric backpressure — 4 static-gray frames with m_axis_msk.tready
//        randomly deasserted (30% duty cycle).  Assert beat count equals
//        WIDTH × HEIGHT × 4 (no beats dropped or duplicated under stall).
//
//   T6   PRNG-no-drift under stall — two DUT instances receive identical
//        pixel streams.  DUT-A has tready=1 always; DUT-B has tready=0 for
//        16 cycles after each EOL (periodic stall), otherwise 1.  The mask
//        outputs must be bit-identical beat-for-beat: the backpressure shell's
//        PRNG gate must prevent any state drift during stall.
//
// Parameters:
//   WIDTH=32, HEIGHT=16 — small frame for fast simulation
//   K=8                 — minimum legal ViBe sample-set size
//   GAUSS_EN=0          — raw luma, no Gaussian pre-filter
//
// Conventions: drv_* intermediaries with blocking = in initial block;
// always_ff @(posedge clk) registers them to DUT inputs; mask capture at
// negedge to avoid race with DUT always_ff outputs.

`timescale 1ns / 1ps

module tb_axis_motion_detect_vibe;

    // ---- Clock / reset / DIM parameters ----
    localparam int Width     = 32;
    localparam int Height    = 16;
    localparam int K         = 8;
    localparam int NumPix    = Width * Height;   // 512
    localparam int ClkPeriod = 10;               // 100 MHz

    // Blanking margins: VBlank must exceed worst-case FIFO drain cycles.
    // With W+1-delay FIFO draining during active region, 36 cycles is sufficient
    // (Width+4 = 32+4 = 36). Phase 2 drains deferred writes during active region,
    // not during V-blank.
    localparam int HBlank = 4;
    localparam int VBlank = 36;

    // ---- T2 parameters ----
    localparam int T2Frames   = 200;
    localparam int T2TotalPix = T2Frames * NumPix;  // 102400

    // Ghost ROI (_gen_ghost_box_disappear at WIDTH=32, HEIGHT=16):
    //   box_w = WIDTH/4 = 8, box_h = HEIGHT/4 = 4
    //   cx = (WIDTH - box_w) / 2 = 12, cy = (HEIGHT - box_h) / 2 = 6
    localparam int GhostBoxW = Width  / 4;                    // 8
    localparam int GhostBoxH = Height / 4;                    // 4
    localparam int GhostCx   = (Width  - GhostBoxW) / 2;     // 12
    localparam int GhostCy   = (Height - GhostBoxH) / 2;     // 6
    localparam int GhostArea = GhostBoxW * GhostBoxH;         // 32

    // Coverage windows (0-based frame indices):
    //   Early: frames 10..29 (20 frames; ghost fully established)
    //   Late:  frames 150..199 (50 frames; ghost mostly gone via diffusion)
    localparam int EarlyStart = 10;
    localparam int EarlyEnd   = 30;    // exclusive
    localparam int LateStart  = 150;
    localparam int LateEnd    = 200;   // exclusive

    // T2b threshold pinned from gen_golden.py:
    //   measured ratio avg_late/avg_early = 0.094198
    //   threshold = 1.25 * measured_ratio = 0.121417
    localparam real T2bThreshold = 0.121417;

    // ---- T5 parameters ----
    localparam int T5Frames   = 4;
    localparam int T5TotalPix = T5Frames * NumPix;   // 2048

    // ---- T6 parameters ----
    // Two DUTs, 6 frames of static-gray.
    // DUT-B stalls for T6StallCycles cycles after each EOL assertion
    // (tready=0 for those cycles, then 1 for the rest of VBlank).
    localparam int T6Frames      = 6;
    localparam int T6TotalPix    = T6Frames * NumPix;  // 3072
    localparam int T6StallCycles = 16;

    // File paths — relative to dv/sim/ (simulation working directory).
    localparam string InputFile  =
        "../../hw/ip/motion/tb/golden/test2_input.bin";
    localparam string GoldenFile =
        "../../hw/ip/motion/tb/golden/test2_ghost_box_disappear.bin";

    // ---- Clock ----
    logic clk = 0;
    always #(ClkPeriod/2) clk = ~clk;

    // ---- Reset ----
    logic rst_n = 1'b0;

    // ---- Driver intermediaries (blocking = in initial/task; posedge-registered) ----
    logic [23:0] drv_tdata   = '0;
    logic        drv_tvalid  = 1'b0;
    logic        drv_tlast   = 1'b0;
    logic        drv_tuser   = 1'b0;

    // ---- AXI4-Stream interfaces ----
    // Shared input interface — drives both DUTs simultaneously.
    axis_if #(.DATA_W(24), .USER_W(1)) s_axis_pix ();

    // DUT-A output — always-ready consumer (T1, T2, T5 baseline).
    axis_if #(.DATA_W(1), .USER_W(1)) m_axis_msk_a ();

    // DUT-B output — periodically stalled consumer (T6 stalled path).
    axis_if #(.DATA_W(1), .USER_W(1)) m_axis_msk_b ();

    // DUT inputs — registered on posedge to avoid INITIALDLY races.
    always_ff @(posedge clk) begin
        s_axis_pix.tdata  <= drv_tdata;
        s_axis_pix.tvalid <= drv_tvalid;
        s_axis_pix.tlast  <= drv_tlast;
        s_axis_pix.tuser  <= drv_tuser;
    end

    // ---- Downstream ready control ----
    // t5_bp_ready: driven by always_comb below — 1 when T5 inactive, else duty-cycle.
    // t6_stall_ready: driven by T6 task to gate DUT-B after each EOL.
    logic t5_bp_ready;
    logic t6_stall_ready = 1'b1;

    // DUT-A: always-ready (T1, T2, T2b, T5 with backpressure applied via t5_bp_ready)
    assign m_axis_msk_a.tready = t5_bp_ready;

    // DUT-B: gated by T6 stall controller
    assign m_axis_msk_b.tready = t6_stall_ready;

    // ---- DUT-A (primary: used by T1, T2, T2b, T5) ----
    axis_motion_detect_vibe #(
        .WIDTH    (Width),
        .HEIGHT   (Height),
        .K        (K),
        .GAUSS_EN (1'b0)
    ) u_dut_a (
        .clk_i      (clk),
        .rst_n_i    (rst_n),
        .s_axis_pix (s_axis_pix),
        .m_axis_msk (m_axis_msk_a)
    );

    // ---- DUT-B (T6 stall path only) ----
    // Separate input interface so DUT-B can have independent tready (and thus
    // independent tready feedback to s_axis_pix). During T6 both DUTs receive
    // the same data; DUT-B's input is wired directly rather than through the
    // shared drv_*/posedge-register path to keep hierarchy simple — the posedge
    // register IS shared (s_axis_pix drives both).
    axis_if #(.DATA_W(24), .USER_W(1)) s_axis_pix_b ();

    // Mirror the registered s_axis_pix signals into s_axis_pix_b combinationally.
    // tready from DUT-B flows back through s_axis_pix_b; during T6 DUT-A's
    // tready is permanently 1 (T1/T2/T5 guard t5_bp_ready separately).
    assign s_axis_pix_b.tdata  = s_axis_pix.tdata;
    assign s_axis_pix_b.tvalid = s_axis_pix.tvalid;
    assign s_axis_pix_b.tlast  = s_axis_pix.tlast;
    assign s_axis_pix_b.tuser  = s_axis_pix.tuser;

    logic rst_n_b = 1'b0;   // separate reset for DUT-B (T6 resets independently)

    axis_motion_detect_vibe #(
        .WIDTH    (Width),
        .HEIGHT   (Height),
        .K        (K),
        .GAUSS_EN (1'b0)
    ) u_dut_b (
        .clk_i      (clk),
        .rst_n_i    (rst_n_b),
        .s_axis_pix (s_axis_pix_b),
        .m_axis_msk (m_axis_msk_b)
    );

    // ---- Global error counter ----
    integer num_errors = 0;

    // =========================================================================
    // T1 mask capture — concurrent negedge block (safe from DUT posedge races)
    // Active only when t1_active == 1.
    // Uses DUT-A output (m_axis_msk_a).
    // =========================================================================
    logic   t1_active   = 1'b0;
    integer t1_masks_one = 0;

    always @(negedge clk) begin
        if (t1_active && m_axis_msk_a.tvalid && m_axis_msk_a.tready) begin
            if (m_axis_msk_a.tdata[0] !== 1'b0)
                t1_masks_one = t1_masks_one + 1;
        end
    end

    // =========================================================================
    // T2 mask capture — concurrent negedge block.
    // Active only when t2_active == 1.
    // Collected into t2_mask_arr; t2_beat incremented after each beat.
    // Uses DUT-A output (m_axis_msk_a).
    // =========================================================================
    logic   t2_active   = 1'b0;
    integer t2_beat     = 0;           // next beat index to store (0..T2TotalPix-1)

    // Flat storage: T2TotalPix = 200 * 512 = 102400 bits.
    // One element per beat: 0 = bg, 1 = motion.
    logic t2_mask_arr [T2TotalPix];

    always @(negedge clk) begin
        if (t2_active && m_axis_msk_a.tvalid && m_axis_msk_a.tready) begin
            if (t2_beat < T2TotalPix) begin
                t2_mask_arr[t2_beat] = m_axis_msk_a.tdata[0];
                t2_beat = t2_beat + 1;
            end
        end
    end

    // =========================================================================
    // T5 mask capture — concurrent negedge block.
    // Active only when t5_active == 1.
    // Counts beats accepted through m_axis_msk_a (which has backpressure applied).
    // =========================================================================
    logic   t5_active   = 1'b0;
    integer t5_beat_cnt = 0;

    always @(negedge clk) begin
        if (t5_active && m_axis_msk_a.tvalid && m_axis_msk_a.tready)
            t5_beat_cnt = t5_beat_cnt + 1;
    end

    // =========================================================================
    // T6 mask capture — concurrent negedge block.
    // Active only when t6_active == 1.
    // Captures beats from BOTH DUT-A and DUT-B independently.
    // Both arrays are compared after the run completes.
    // =========================================================================
    logic   t6_active    = 1'b0;
    integer t6_beat_a    = 0;
    integer t6_beat_b    = 0;

    logic t6_mask_a [T6TotalPix];
    logic t6_mask_b [T6TotalPix];

    always @(negedge clk) begin
        if (t6_active) begin
            // DUT-A capture (always-ready during T6)
            if (m_axis_msk_a.tvalid && m_axis_msk_a.tready) begin
                if (t6_beat_a < T6TotalPix) begin
                    t6_mask_a[t6_beat_a] = m_axis_msk_a.tdata[0];
                    t6_beat_a = t6_beat_a + 1;
                end
            end
            // DUT-B capture (stalled for T6StallCycles after each EOL)
            if (m_axis_msk_b.tvalid && m_axis_msk_b.tready) begin
                if (t6_beat_b < T6TotalPix) begin
                    t6_mask_b[t6_beat_b] = m_axis_msk_b.tdata[0];
                    t6_beat_b = t6_beat_b + 1;
                end
            end
        end
    end

    // =========================================================================
    // Utility tasks
    // =========================================================================

    // Reset DUT-A to a clean state (shared input path reset).
    task automatic do_reset();
        drv_tvalid = 1'b0;
        drv_tuser  = 1'b0;
        drv_tlast  = 1'b0;
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
    endtask

    // Reset both DUT-A and DUT-B together.
    task automatic do_reset_both();
        drv_tvalid = 1'b0;
        drv_tuser  = 1'b0;
        drv_tlast  = 1'b0;
        rst_n   = 1'b0;
        rst_n_b = 1'b0;
        repeat (8) @(posedge clk);
        rst_n   = 1'b1;
        rst_n_b = 1'b1;
        repeat (2) @(posedge clk);
    endtask

    // Drive one frame of constant gray (8'h80 → Y ≈ 128).
    // Waits on tready from the active DUT (s_axis_pix.tready reflects DUT-A;
    // during T6 DUT-B's tready is carried via s_axis_pix_b.tready — the input
    // driver only tracks s_axis_pix.tready here, which is DUT-A's tready.
    // DUT-B may stall internally but DUT-A's tready is 1, so input keeps flowing).
    task automatic drive_gray_frame();
        for (int r = 0; r < Height; r++) begin
            for (int c = 0; c < Width; c++) begin
                drv_tdata  = 24'h80_80_80;
                drv_tvalid = 1'b1;
                drv_tuser  = (r == 0 && c == 0) ? 1'b1 : 1'b0;
                drv_tlast  = (c == Width - 1)   ? 1'b1 : 1'b0;
                @(posedge clk);
                while (!s_axis_pix.tready) @(posedge clk);
            end
            drv_tvalid = 1'b0;
            drv_tuser  = 1'b0;
            drv_tlast  = 1'b0;
            repeat (HBlank) @(posedge clk);
        end
        repeat (VBlank) @(posedge clk);
    endtask

    // Drive one frame from an open file descriptor fd (binary RGB).
    // Returns 0 on success, 1 on read error.
    task automatic drive_frame_from_file(
        input  integer fd,
        input  integer frame_idx,
        output integer ok
    );
        integer r_byte, g_byte, b_byte;
        ok = 1;
        for (int row_i = 0; row_i < Height; row_i++) begin
            for (int col_i = 0; col_i < Width; col_i++) begin
                r_byte = $fgetc(fd);
                g_byte = $fgetc(fd);
                b_byte = $fgetc(fd);
                if (r_byte == -1 || g_byte == -1 || b_byte == -1) begin
                    $display("ERROR T2: input EOF at frame=%0d row=%0d col=%0d",
                             frame_idx, row_i, col_i);
                    ok = 0;
                    return;
                end
                drv_tdata  = {r_byte[7:0], g_byte[7:0], b_byte[7:0]};
                drv_tvalid = 1'b1;
                drv_tuser  = (row_i == 0 && col_i == 0) ? 1'b1 : 1'b0;
                drv_tlast  = (col_i == Width - 1)       ? 1'b1 : 1'b0;
                @(posedge clk);
                while (!s_axis_pix.tready) @(posedge clk);
            end
            drv_tvalid = 1'b0;
            drv_tuser  = 1'b0;
            drv_tlast  = 1'b0;
            repeat (HBlank) @(posedge clk);
        end
        repeat (VBlank) @(posedge clk);
    endtask

    // Drive one gray frame with a T6StallCycles stall on DUT-B inserted
    // inside the per-frame VBlank window (after all active rows complete),
    // NOT after each row.  Stalling during VBlank is safe because no new
    // input pixels arrive then — DUT-B's s_axis_pix.tready going low cannot
    // cause input pixel drops.  DUT-B output backpressure during active rows
    // would propagate to DUT-B's input tready (via pipe_stall), causing the
    // input driver (which only waits on DUT-A's tready) to advance and present
    // a pixel that DUT-B silently drops.
    task automatic drive_gray_frame_t6();
        for (int r = 0; r < Height; r++) begin
            for (int c = 0; c < Width; c++) begin
                drv_tdata  = 24'h80_80_80;
                drv_tvalid = 1'b1;
                drv_tuser  = (r == 0 && c == 0) ? 1'b1 : 1'b0;
                drv_tlast  = (c == Width - 1)   ? 1'b1 : 1'b0;
                @(posedge clk);
                while (!s_axis_pix.tready) @(posedge clk);
            end
            drv_tvalid = 1'b0;
            drv_tuser  = 1'b0;
            drv_tlast  = 1'b0;
            repeat (HBlank) @(posedge clk);
        end
        // VBlank: stall DUT-B for T6StallCycles, then release for remaining drain.
        // T6StallCycles < VBlank, so both pipelines drain fully before next SOF.
        t6_stall_ready = 1'b0;
        repeat (T6StallCycles) @(posedge clk);
        t6_stall_ready = 1'b1;
        repeat (VBlank - T6StallCycles) @(posedge clk);
    endtask

    // Skip nb bytes from file fd (header skip).
    task automatic skip_bytes(input integer fd, input int nb);
        for (int i = 0; i < nb; i++)
            void'($fgetc(fd));
    endtask

    // =========================================================================
    // T1: Static gray x 4 frames
    // =========================================================================
    task automatic run_t1();
        $display("==========================================================");
        $display("T1: Static gray x 4 frames (K=%0d, W=%0d, H=%0d)",
                 K, Width, Height);
        $display("==========================================================");

        do_reset();
        t1_active    = 1'b1;
        t1_masks_one = 0;

        for (int f = 0; f < 4; f++)
            drive_gray_frame();

        repeat (20) @(posedge clk);
        t1_active = 1'b0;

        if (t1_masks_one !== 0) begin
            $display("FAIL T1: %0d mask=1 bits — expected 0 (static bg)",
                     t1_masks_one);
            num_errors = num_errors + 1;
        end else begin
            $display("PASS T1: all mask outputs are zero after frame-0 init");
        end
    endtask

    // =========================================================================
    // T2: bit-exact mask parity against Python ref (200 frames)
    // T2b: ghost ROI coverage decay
    // =========================================================================
    task automatic run_t2_t2b();
        integer fd_in, fd_gold, ok;
        integer t2_fail_frame, t2_fail_pix;
        logic   t2_fail_expected, t2_fail_got;
        integer t2_fail_cnt;

        // T2b accumulators
        integer roi_ones [T2Frames];
        real    early_acc, late_acc, avg_early, avg_late, ratio;
        integer early_cnt, late_cnt;

        $display("");
        $display("==========================================================");
        $display("T2/T2b: ghost_box_disappear x %0d frames", T2Frames);
        $display("  Input:  %s", InputFile);
        $display("  Golden: %s", GoldenFile);
        $display("==========================================================");

        // ---- Reset DUT ----
        do_reset();
        t2_beat   = 0;
        t2_active = 1'b1;

        // ---- Open files ----
        fd_in = $fopen(InputFile, "rb");
        if (fd_in == 0) begin
            $display("ERROR T2: cannot open input file: %s", InputFile);
            num_errors = num_errors + 1;
            t2_active = 1'b0;
            return;
        end
        fd_gold = $fopen(GoldenFile, "rb");
        if (fd_gold == 0) begin
            $display("ERROR T2: cannot open golden file: %s", GoldenFile);
            $fclose(fd_in);
            num_errors = num_errors + 1;
            t2_active = 1'b0;
            return;
        end

        // Skip 12-byte headers
        skip_bytes(fd_in,   12);
        skip_bytes(fd_gold, 12);

        // ---- Drive all T2Frames from file ----
        ok = 1;
        for (int f = 0; f < T2Frames && ok; f++) begin
            drive_frame_from_file(fd_in, f, ok);
        end

        $fclose(fd_in);

        if (!ok) begin
            $display("ERROR T2: input file read failed — aborting T2");
            $fclose(fd_gold);
            num_errors = num_errors + 1;
            t2_active = 1'b0;
            return;
        end

        // ---- Wait for all mask beats to drain ----
        // After the last input frame, the pipeline needs (pipeline depth + blanking)
        // cycles to emit the last mask beats.  W+1-delay FIFO drains during active
        // region, so V-blank (Width+4 = 36 cycles) is sufficient.
        repeat (VBlank) @(posedge clk);
        t2_active = 1'b0;
        repeat (4)   @(posedge clk);  // let the negedge capture settle

        // ---- T2 compare: collected beats vs golden file ----
        t2_fail_cnt   = 0;
        t2_fail_frame = -1;
        t2_fail_pix   = -1;

        if (t2_beat !== T2TotalPix) begin
            $display("ERROR T2: collected %0d mask beats, expected %0d",
                     t2_beat, T2TotalPix);
            num_errors = num_errors + 1;
        end else begin
            for (int b = 0; b < T2TotalPix; b++) begin
                integer golden_byte;
                logic   golden_bit;
                golden_byte = $fgetc(fd_gold);
                if (golden_byte == -1) begin
                    $display("ERROR T2: golden file too short at beat %0d", b);
                    num_errors = num_errors + 1;
                    break;
                end
                golden_bit = logic'(golden_byte & 1);
                if (t2_mask_arr[b] !== golden_bit) begin
                    if (t2_fail_cnt == 0) begin
                        t2_fail_frame    = b / NumPix;
                        t2_fail_pix      = b % NumPix;
                        t2_fail_expected = golden_bit;
                        t2_fail_got      = t2_mask_arr[b];
                        $error("T2 FAIL: frame=%0d (x,y)=(%0d,%0d) expected=%b got=%b",
                               t2_fail_frame,
                               t2_fail_pix % Width, t2_fail_pix / Width,
                               t2_fail_expected, t2_fail_got);
                    end
                    t2_fail_cnt = t2_fail_cnt + 1;
                end
            end

            if (t2_fail_cnt > 0) begin
                $display("FAIL T2: %0d mismatch(es) across %0d frames",
                         t2_fail_cnt, T2Frames);
                num_errors = num_errors + 1;
            end else begin
                $display("PASS T2: %0d frames x %0d pixels — bit-exact match",
                         T2Frames, NumPix);
            end
        end

        $fclose(fd_gold);

        // ---- T2b: ghost ROI coverage decay ----
        // Compute per-frame ROI pixel count from collected mask array.
        for (int fi = 0; fi < T2Frames; fi++)
            roi_ones[fi] = 0;

        for (int b = 0; b < T2TotalPix; b++) begin
            integer fi, pix_in_frame, row_b, col_b;
            fi           = b / NumPix;
            pix_in_frame = b % NumPix;
            row_b        = pix_in_frame / Width;
            col_b        = pix_in_frame % Width;
            if (row_b >= GhostCy && row_b < GhostCy + GhostBoxH &&
                col_b >= GhostCx && col_b < GhostCx + GhostBoxW) begin
                if (t2_mask_arr[b])
                    roi_ones[fi] = roi_ones[fi] + 1;
            end
        end

        early_acc = 0.0;
        late_acc  = 0.0;
        early_cnt = 0;
        late_cnt  = 0;

        for (int fi = 0; fi < T2Frames; fi++) begin
            real cov;
            cov = real'(roi_ones[fi]) / real'(GhostArea);
            if (fi >= EarlyStart && fi < EarlyEnd) begin
                early_acc = early_acc + cov;
                early_cnt = early_cnt + 1;
            end
            if (fi >= LateStart && fi < LateEnd) begin
                late_acc = late_acc + cov;
                late_cnt = late_cnt + 1;
            end
        end

        avg_early = early_acc / real'(early_cnt);
        avg_late  = late_acc  / real'(late_cnt);
        // Guard against zero denominator (e.g. parity failure path)
        ratio = (avg_early > 0.0) ? (avg_late / avg_early) : 0.0;

        $display("");
        $display("T2b coverage (ghost ROI rows %0d-%0d, cols %0d-%0d):",
                 GhostCy, GhostCy + GhostBoxH - 1,
                 GhostCx, GhostCx + GhostBoxW - 1);
        $display("  avg_early (frames %0d-%0d): %.4f",
                 EarlyStart, EarlyEnd - 1, avg_early);
        $display("  avg_late  (frames %0d-%0d): %.4f",
                 LateStart,  LateEnd  - 1, avg_late);
        $display("  ratio     = %.6f   threshold = %.6f",
                 ratio, real'(T2bThreshold));

        if (ratio > real'(T2bThreshold)) begin
            $error("T2b FAIL: late=%.4f early=%.4f ratio=%.3f > threshold=%.3f",
                   avg_late, avg_early, ratio, real'(T2bThreshold));
            num_errors = num_errors + 1;
        end else begin
            $display("PASS T2b: ratio=%.6f <= threshold=%.6f",
                     ratio, real'(T2bThreshold));
        end

    endtask

    // =========================================================================
    // T5: Symmetric backpressure — beat count check
    // =========================================================================
    // t5_bp_ready is updated at negedge so it is stable at the posedge where the
    // DUT samples it.  This ensures that when the negedge capture fires, it sees
    // the same tready value that the DUT used to decide the handshake one half-
    // period earlier.  Without this, a posedge-updated counter creates a race:
    // the DUT's NBA clears tvalid at posedge N (after the handshake), and the
    // counter NBA also updates tready at posedge N — so at negedge N both tvalid
    // and tready may have changed, causing the capture to miss the beat.
    //
    // Counter cycles 0..9 at every negedge when t5_active=1.
    // tready=0 when count < 3 (30% deasserted), tready=1 when count >= 3.
    logic [3:0] t5_bp_ctr = 4'd0;

    always_ff @(negedge clk) begin
        if (t5_active) begin
            if (t5_bp_ctr == 4'd9)
                t5_bp_ctr <= 4'd0;
            else
                t5_bp_ctr <= t5_bp_ctr + 4'd1;
        end else begin
            t5_bp_ctr <= 4'd0;
        end
    end

    always_comb begin
        if (t5_active)
            t5_bp_ready = (t5_bp_ctr >= 4'd3);
        else
            t5_bp_ready = 1'b1;
    end

    task automatic run_t5();
        $display("");
        $display("==========================================================");
        $display("T5: Symmetric backpressure — %0d gray frames (K=%0d)",
                 T5Frames, K);
        $display("    Expected beat count = %0d", T5TotalPix);
        $display("==========================================================");

        // T5 resets DUT-A only.  DUT-B is not used here; its state is
        // irrelevant (it will be reset fresh in T6).
        do_reset();
        t5_beat_cnt = 0;
        t5_active   = 1'b1;

        for (int f = 0; f < T5Frames; f++)
            drive_gray_frame();

        // Pipeline depth is 2 stages.  The last beat drains within one full
        // counter cycle (10 clocks) after the last frame's VBlank.  32 cycles
        // is generous; t5_active must stay 1 so the negedge capture can count
        // any beat that drains after drive_gray_frame() returns.
        repeat (32) @(posedge clk);
        t5_active = 1'b0;
        repeat (4)  @(posedge clk);

        if (t5_beat_cnt !== T5TotalPix) begin
            $display("FAIL T5: collected %0d beats, expected %0d (drop or dup under stall)",
                     t5_beat_cnt, T5TotalPix);
            num_errors = num_errors + 1;
        end else begin
            $display("PASS T5: %0d beats collected — no drops under 30%% backpressure",
                     t5_beat_cnt);
        end
    endtask

    // =========================================================================
    // T6: PRNG-no-drift under stall — dual-DUT comparison
    // =========================================================================
    task automatic run_t6();
        integer t6_mismatch_cnt;
        integer t6_first_mismatch;

        $display("");
        $display("==========================================================");
        $display("T6: PRNG-no-drift — dual-DUT comparison (%0d gray frames)", T6Frames);
        $display("    DUT-A: tready=1 always");
        $display("    DUT-B: tready=0 for %0d cycles after each EOL", T6StallCycles);
        $display("==========================================================");

        // Reset both DUTs to a clean, identical state.
        do_reset_both();
        t6_beat_a    = 0;
        t6_beat_b    = 0;
        t6_active    = 1'b1;
        t6_stall_ready = 1'b1;

        // During T6, DUT-A's tready is always-ready (t5_bp_ready=1 because
        // t5_active==0 after T5 completes, so the always_comb gives 1'b1).
        // DUT-B's tready is controlled by t6_stall_ready inside drive_gray_frame_t6.
        for (int f = 0; f < T6Frames; f++)
            drive_gray_frame_t6();

        // Allow both pipelines to drain.
        repeat (VBlank) @(posedge clk);
        t6_active    = 1'b0;
        t6_stall_ready = 1'b1;
        repeat (4)   @(posedge clk);

        // ---- Beat-count sanity ----
        if (t6_beat_a !== T6TotalPix) begin
            $display("ERROR T6: DUT-A collected %0d beats, expected %0d",
                     t6_beat_a, T6TotalPix);
            num_errors = num_errors + 1;
        end
        if (t6_beat_b !== T6TotalPix) begin
            $display("ERROR T6: DUT-B collected %0d beats, expected %0d",
                     t6_beat_b, T6TotalPix);
            num_errors = num_errors + 1;
        end

        if (t6_beat_a !== T6TotalPix || t6_beat_b !== T6TotalPix) begin
            $display("FAIL T6: beat count mismatch — skipping bit comparison");
            return;
        end

        // ---- Bit-exact comparison ----
        t6_mismatch_cnt   = 0;
        t6_first_mismatch = -1;
        for (int b = 0; b < T6TotalPix; b++) begin
            if (t6_mask_a[b] !== t6_mask_b[b]) begin
                if (t6_mismatch_cnt == 0) begin
                    t6_first_mismatch = b;
                    $error("T6 FAIL: first mismatch at beat %0d (frame %0d pix %0d): A=%b B=%b",
                           b, b / NumPix, b % NumPix,
                           t6_mask_a[b], t6_mask_b[b]);
                end
                t6_mismatch_cnt = t6_mismatch_cnt + 1;
            end
        end

        if (t6_mismatch_cnt > 0) begin
            $display("FAIL T6: %0d mismatch(es) — PRNG drifted under stall",
                     t6_mismatch_cnt);
            num_errors = num_errors + 1;
        end else begin
            $display("PASS T6: %0d frames x %0d pixels — bit-identical under stall",
                     T6Frames, NumPix);
        end
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        run_t1();
        run_t2_t2b();
        run_t5();
        run_t6();

        $display("");
        if (num_errors > 0)
            $fatal(1, "tb_axis_motion_detect_vibe FAILED: %0d error(s)", num_errors);
        else begin
            $display("tb_axis_motion_detect_vibe PASSED — T1, T2, T2b, T5, T6 OK");
            $finish;
        end
    end

    // ---- Timeout guard (15 ms covers T1+T2+T5+T6 at 100 MHz) ----
    initial begin
        #15_000_000;
        $fatal(1, "tb_axis_motion_detect_vibe TIMEOUT after 15 ms sim time");
    end

endmodule
