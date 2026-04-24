// AXI4-Stream connected-component labeler (CCL).
//
// Consumes a 1-bit mask stream; assigns 8-connected-component labels using
// streaming union-find with path compression; at EOF runs a 4-phase
// resolution FSM (compress / fold / filter+select / reset) during vblank;
// exports up to N_OUT distinct bboxes via a double-buffered sideband.
//
// Output sideband: packed arrays of N_OUT {min_x, max_x, min_y, max_y, valid}.
// A 1-cycle `bbox_swap_o` pulse indicates the front buffer has been updated;
// `bbox_empty_o` is asserted when no slot is valid (i.e. `bbox_valid_o == '0`).
//
// See docs/specs/axis_ccl-arch.md for the algorithm, EOF FSM phases,
// cycle budget, and memory layout.

module axis_ccl #(
    parameter int H_ACTIVE             = 320,
    parameter int V_ACTIVE             = 240,
    parameter int N_LABELS_INT         = sparevideo_pkg::CCL_N_LABELS_INT,
    parameter int N_OUT                = sparevideo_pkg::CCL_N_OUT,
    parameter int MIN_COMPONENT_PIXELS = sparevideo_pkg::CCL_MIN_COMPONENT_PIXELS,
    parameter int MAX_CHAIN_DEPTH      = sparevideo_pkg::CCL_MAX_CHAIN_DEPTH,
    parameter int PRIME_FRAMES         = sparevideo_pkg::CCL_PRIME_FRAMES
) (
    input  logic clk_i,
    input  logic rst_n_i,

    // AXI4-Stream input — mask (1 bit)
    input  logic s_axis_tdata_i,
    input  logic s_axis_tvalid_i,
    output logic s_axis_tready_o,
    input  logic s_axis_tlast_i,
    input  logic s_axis_tuser_i,

    // Sideband output — packed arrays, one slot per output bbox.
    output logic [N_OUT-1:0]                       bbox_valid_o,   // per-slot valid
    output logic [N_OUT-1:0][$clog2(H_ACTIVE)-1:0] bbox_min_x_o,
    output logic [N_OUT-1:0][$clog2(H_ACTIVE)-1:0] bbox_max_x_o,
    output logic [N_OUT-1:0][$clog2(V_ACTIVE)-1:0] bbox_min_y_o,
    output logic [N_OUT-1:0][$clog2(V_ACTIVE)-1:0] bbox_max_y_o,
    output logic                                   bbox_swap_o,    // 1-cycle strobe on new frame
    output logic                                   bbox_empty_o    // no valid slots
);

    // Backpressure during the EOF resolution FSM — see the tready assign
    // below the `phase_t` declaration.

    // ---- Parameter widths ----
    localparam int LABEL_W   = $clog2(N_LABELS_INT);
    localparam int COL_W     = $clog2(H_ACTIVE);
    localparam int ROW_W     = $clog2(V_ACTIVE);
    // Count widths: per-component max count = H_ACTIVE*V_ACTIVE (sanity ceiling).
    localparam int COUNT_W   = $clog2(H_ACTIVE * V_ACTIVE + 1);
    // Index width for N_OUT-element packed arrays (3 bits for N_OUT=8).
    localparam int SLOT_IDX_W = $clog2(N_OUT);

    // ---- Column / row scan counters ----
    logic [COL_W-1:0] col;
    logic [ROW_W-1:0] row;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            col <= '0;
            row <= '0;
        end else if (s_axis_tvalid_i && s_axis_tready_o) begin
            if (s_axis_tuser_i) begin
                col <= COL_W'(1);
                row <= '0;
            end else if (s_axis_tlast_i) begin
                col <= '0;
                row <= row + 1;
            end else begin
                col <= col + 1;
            end
        end
    end

    // ---- Label line buffer (prev-row labels) : H_ACTIVE × LABEL_W ----
    logic [LABEL_W-1:0] line_buf [0:H_ACTIVE-1];

    // ---- Equivalence table : N_LABELS_INT × LABEL_W ----
    logic [LABEL_W-1:0] equiv [0:N_LABELS_INT-1];

    // ---- Accumulator bank : N_LABELS_INT × {min_x, max_x, min_y, max_y, count} ----
    logic [COL_W-1:0]   acc_min_x [0:N_LABELS_INT-1];
    logic [COL_W-1:0]   acc_max_x [0:N_LABELS_INT-1];
    logic [ROW_W-1:0]   acc_min_y [0:N_LABELS_INT-1];
    logic [ROW_W-1:0]   acc_max_y [0:N_LABELS_INT-1];
    logic [COUNT_W-1:0] acc_count [0:N_LABELS_INT-1];

    // ---- Next-free label counter ----
    logic [LABEL_W:0] next_free;  // LABEL_W+1 bits — saturates at N_LABELS_INT; never wraps.

    // ---- Output double-buffer (N_OUT slots, front = visible, back = being written) ----
    // Front buffer registers — visible on bbox_*_o ports.
    logic [N_OUT-1:0]                       front_valid;
    logic [N_OUT-1:0][COL_W-1:0]            front_min_x;
    logic [N_OUT-1:0][COL_W-1:0]            front_max_x;
    logic [N_OUT-1:0][ROW_W-1:0]            front_min_y;
    logic [N_OUT-1:0][ROW_W-1:0]            front_max_y;

    // Back buffer — written by EOF FSM phase C.
    logic [N_OUT-1:0]                       back_valid;
    logic [N_OUT-1:0][COL_W-1:0]            back_min_x;
    logic [N_OUT-1:0][COL_W-1:0]            back_max_x;
    logic [N_OUT-1:0][ROW_W-1:0]            back_min_y;
    logic [N_OUT-1:0][ROW_W-1:0]            back_max_y;

    assign bbox_valid_o = front_valid;
    assign bbox_min_x_o = front_min_x;
    assign bbox_max_x_o = front_max_x;
    assign bbox_min_y_o = front_min_y;
    assign bbox_max_y_o = front_max_y;
    assign bbox_empty_o = (front_valid == '0);

    // ----------------------------------------------------------------
    // Per-pixel labelling pipeline
    // ----------------------------------------------------------------
    //
    // Stage 0 (acceptance): issue line-buffer read at col+1 (one column
    //                       ahead) so NE is available next cycle.
    // Stage 1 (window valid): {NW, N, NE, W} present. Decide, write line
    //                         buffer at col, merge-write equiv if needed,
    //                         RMW accumulator.

    // Line-buffer read address — one column ahead of the scan position so
    // the registered read result exposes N and can be shifted into NE.
    logic [COL_W-1:0] line_rd_addr;
    assign line_rd_addr = (col == COL_W'(H_ACTIVE - 1)) ? '0 : (col + COL_W'(1));

    logic [LABEL_W-1:0] line_rd_data_r;
    always_ff @(posedge clk_i) begin
        line_rd_data_r <= line_buf[line_rd_addr];
    end

    // Previous-row neighbour labels at stage 1 col_d1=C (after registering the
    // line-buffer read). line_rd_data_r already equals line_buf[C+1] in the
    // current cycle (stage-0 reads col+1 one cycle ahead), so it is used
    // directly as NE. Two further register stages yield N (= line_buf[C]) and
    // NW (= line_buf[C-1]).
    logic [LABEL_W-1:0] shift_nw, shift_n;

    // Stage-1-valid: delayed acceptance, aligned with the window.
    logic accept_d1;
    logic tdata_d1, tuser_d1, tlast_d1;
    logic [COL_W-1:0] col_d1;
    logic [ROW_W-1:0] row_d1;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            accept_d1 <= 1'b0;
            tdata_d1  <= 1'b0;
            tuser_d1  <= 1'b0;
            tlast_d1  <= 1'b0;
            col_d1    <= '0;
            row_d1    <= '0;
        end else begin
            accept_d1 <= s_axis_tvalid_i && s_axis_tready_o;
            tdata_d1  <= s_axis_tdata_i;
            tuser_d1  <= s_axis_tuser_i;
            tlast_d1  <= s_axis_tlast_i;
            // On SOF, the counters still hold post-tlast values from the
            // previous frame (col=0, row=V_ACTIVE). The logical position of
            // the tuser pixel is (0, 0) — force col_d1/row_d1 to match so
            // accumulator updates use the correct coordinate.
            col_d1    <= s_axis_tuser_i ? '0 : col;
            row_d1    <= s_axis_tuser_i ? '0 : row;
        end
    end

    // On each accepted pixel, advance the 2-deep previous-row label chain:
    //   shift_n  <= line_rd_data_r  (which equals line_buf[col_d1+1] next cycle,
    //               becoming N = line_buf[col_d1] at the cycle after that)
    //   shift_nw <= shift_n         (becoming NW = line_buf[col_d1-1])
    // Off-image neighbours (row 0, col 0, last col) are masked downstream via
    // nb_* edge logic; the shift chain itself carries raw line_buf values.
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            shift_nw <= '0;
            shift_n  <= '0;
        end else if (accept_d1) begin
            shift_nw <= shift_n;
            shift_n  <= line_rd_data_r;
        end
    end

    // W register — label assigned to the immediately previous column in this row.
    logic [LABEL_W-1:0] w_label;

    // Effective neighbours with edge masking.
    logic [LABEL_W-1:0] nb_nw, nb_n, nb_ne, nb_w;
    logic at_col0, at_last_col, at_row0;
    assign at_col0     = (col_d1 == '0);
    assign at_last_col = (col_d1 == COL_W'(H_ACTIVE - 1));
    assign at_row0     = (row_d1 == '0);
    assign nb_nw = (at_col0 || at_row0)     ? '0 : shift_nw;
    assign nb_n  = (at_row0)                ? '0 : shift_n;
    assign nb_ne = (at_last_col || at_row0) ? '0 : line_rd_data_r;
    assign nb_w  = (at_col0)                ? '0 : w_label;

    // ---- Label decision (combinational) ----
    //
    // 8-connected raster CCL invariant: among {NW, N, NE, W}, at most two
    // distinct non-zero labels can appear. See docs/specs/axis_ccl-arch.md.
    //
    // We resolve as: min-of-distinct-nonzero wins; on two-distinct, schedule
    // an equivalence write equiv[max] <= min.

    logic any_above;  // any of {NW, N, NE} non-zero
    logic [LABEL_W-1:0] first_above, min_above;
    always_comb begin
        // Collapse {NW, N, NE} to its single-label contribution using min-of-nonzero.
        any_above   = (nb_nw != '0) || (nb_n != '0) || (nb_ne != '0);
        first_above = (nb_n  != '0) ? nb_n  :
                      (nb_nw != '0) ? nb_nw :
                      (nb_ne != '0) ? nb_ne : LABEL_W'(0);
        min_above = first_above;
        if (nb_n  != '0 && nb_n  < min_above) min_above = nb_n;
        if (nb_nw != '0 && nb_nw < min_above) min_above = nb_nw;
        if (nb_ne != '0 && nb_ne < min_above) min_above = nb_ne;
    end

    logic        any_nonzero;
    logic [LABEL_W-1:0] pick_label;
    logic        need_merge;
    logic [LABEL_W-1:0] merge_hi, merge_lo;
    always_comb begin
        any_nonzero = any_above || (nb_w != '0);
        need_merge  = 1'b0;
        merge_hi    = '0;
        merge_lo    = '0;
        pick_label  = '0;

        if (!any_nonzero) begin
            // next_free overflows check: next_free is LABEL_W+1 bits, saturates at N_LABELS_INT.
            pick_label = (next_free < (LABEL_W+1)'(N_LABELS_INT)) ? next_free[LABEL_W-1:0] : LABEL_W'(0);
        end else if (!any_above) begin
            pick_label = nb_w;
        end else if (nb_w == '0) begin
            pick_label = min_above;
        end else begin
            // Both W and {above} contribute.
            if (nb_w == min_above) begin
                pick_label = nb_w;  // same label, no merge
            end else begin
                pick_label = (nb_w < min_above) ? nb_w : min_above;
                need_merge = 1'b1;
                merge_hi   = (nb_w > min_above) ? nb_w : min_above;
                merge_lo   = (nb_w < min_above) ? nb_w : min_above;
            end
        end
    end

    // ---- Writes ----
    // Only applied when we're in the stage-1 window with accept_d1 and mask==1.
    logic write_fg;
    assign write_fg = accept_d1 && tdata_d1;

    // W register update.
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            w_label <= '0;
        end else if (accept_d1) begin
            if (tuser_d1) begin
                w_label <= '0;  // SOF: start-of-frame, no left neighbour.
            end else if (tlast_d1) begin
                w_label <= '0;  // end-of-line: reset W for the next row.
            end else begin
                w_label <= write_fg ? pick_label : LABEL_W'(0);
            end
        end
    end

    // Line buffer write at col_d1 with label for this pixel (0 for background).
    always_ff @(posedge clk_i) begin
        if (accept_d1)
            line_buf[col_d1] <= write_fg ? pick_label : LABEL_W'(0);
    end

    // ----------------------------------------------------------------
    // EOF detection
    // ----------------------------------------------------------------
    // End-of-frame pulse: tlast on last row, delayed by 1 cycle (to let the
    // last pixel's accumulator write commit before Phase A reads start).
    logic is_eof, is_eof_r;
    assign is_eof = accept_d1 && tlast_d1 && (row_d1 == ROW_W'(V_ACTIVE - 1));
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) is_eof_r <= 1'b0;
        else          is_eof_r <= is_eof;
    end

    // ----------------------------------------------------------------
    // EOF resolution FSM
    //   PHASE_IDLE    — waiting for is_eof_r
    //   PHASE_A       — path compression: for each label, chase equiv chain.
    //   PHASE_A_CHASE — inner chase loop, bounded by MAX_CHAIN_DEPTH.
    //   PHASE_B       — accumulator fold: for each non-root, merge into root.
    //   PHASE_C       — top-N selection: per slot, scan acc[] for the max-count
    //                   survivor that passes the min-size filter.
    //   PHASE_D       — reset for next frame: clear equiv[] to identity, acc[]
    //                   to sentinel, next_free to 1; then PHASE_SWAP.
    //   PHASE_SWAP    — copy back -> front, pulse bbox_swap_o, return to IDLE.
    // ----------------------------------------------------------------
    typedef enum logic [2:0] {
        PHASE_IDLE,
        PHASE_A,
        PHASE_A_CHASE,
        PHASE_B,
        PHASE_C,
        PHASE_D,
        PHASE_SWAP
    } phase_t;
    phase_t phase;

    // Deassert tready while the EOF resolution FSM is active. The per-pixel
    // writes to equiv[], acc_*[], and next_free below are gated on
    // PHASE_IDLE, so accepting beats while phase != PHASE_IDLE would
    // silently drop the label updates while still advancing line_buf,
    // w_label, and col/row — corrupting the labeling state when streaming
    // resumes. Instead we stall the upstream for the duration of the FSM
    // (~1,300 cycles worst case); the fork + motion_detect propagate the
    // stall and the input async FIFO absorbs it during vblank. The
    // `assert_no_accept_during_eof_fsm` SVA is a regression trip-wire.
    assign s_axis_tready_o = (phase == PHASE_IDLE);

    // Walker for labels 1..N_LABELS_INT-1 (fits in LABEL_W bits).
    logic [LABEL_W-1:0] lbl_idx;
    logic [$clog2(MAX_CHAIN_DEPTH+1)-1:0] chase_cnt;
    logic [LABEL_W-1:0] chase_root;

    // Phase C: top-N walker.
    // out_slot indexes [0..N_OUT-1]; FSM transitions to PHASE_D at
    // out_slot == N_OUT-1 BEFORE incrementing, so SLOT_IDX_W bits suffice.
    logic [SLOT_IDX_W-1:0] out_slot;
    logic [LABEL_W-1:0]         scan_idx;
    logic [COUNT_W-1:0]         scan_best_count;
    logic [LABEL_W-1:0]         scan_best_lbl;

    // Priming counter — saturates at PRIME_FRAMES. Until it reaches PRIME_FRAMES,
    // PHASE_SWAP leaves the front buffer empty so the EMA background has time
    // to converge (first few frames' masks are noise on y_ref=0).
    localparam int PRIME_CNT_W = (PRIME_FRAMES <= 1) ? 1 : $clog2(PRIME_FRAMES + 1);
    logic [PRIME_CNT_W-1:0] prime_cnt;

    // Fold-phase 1R1W two-cycle dance.
    logic fold_wr_pending;
    logic [LABEL_W-1:0] fold_src_lbl;
    logic [LABEL_W-1:0] fold_dst_lbl;
    logic [COL_W-1:0]   fold_src_min_x;
    logic [COL_W-1:0]   fold_src_max_x;
    logic [ROW_W-1:0]   fold_src_min_y;
    logic [ROW_W-1:0]   fold_src_max_y;
    logic [COUNT_W-1:0] fold_src_count;

    // ----------------------------------------------------------------
    // Consolidated always_ff: owns equiv[], acc_*[], next_free,
    // front_*, back_*, bbox_swap_o, and all FSM state.
    // Per-pixel runtime writes are gated by (phase == PHASE_IDLE).
    // ----------------------------------------------------------------
    integer ri;
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            // ---- FSM-owned state ----
            phase            <= PHASE_IDLE;
            lbl_idx          <= '0;
            chase_cnt        <= '0;
            chase_root       <= '0;
            out_slot         <= '0;
            scan_idx         <= '0;
            scan_best_count  <= '0;
            scan_best_lbl    <= '0;
            fold_wr_pending  <= 1'b0;
            bbox_swap_o      <= 1'b0;
            prime_cnt        <= '0;
            // ---- Front / back buffer init ----
            front_valid      <= '0;
            front_min_x      <= '0;
            front_max_x      <= '0;
            front_min_y      <= '0;
            front_max_y      <= '0;
            back_valid       <= '0;
            back_min_x       <= '0;
            back_max_x       <= '0;
            back_min_y       <= '0;
            back_max_y       <= '0;
            // ---- Memory init ----
            next_free        <= (LABEL_W+1)'(1);
            for (ri = 0; ri < N_LABELS_INT; ri = ri + 1) begin
                equiv[ri]     <= LABEL_W'(ri);
                acc_min_x[ri] <= COL_W'(H_ACTIVE - 1);
                acc_max_x[ri] <= '0;
                acc_min_y[ri] <= ROW_W'(V_ACTIVE - 1);
                acc_max_y[ri] <= '0;
                acc_count[ri] <= '0;
            end
        end else begin
            bbox_swap_o <= 1'b0;

            // ---- Per-pixel writes (gated to PHASE_IDLE streaming phase) ----
            if (phase == PHASE_IDLE) begin
                // next_free increment
                if (write_fg && !any_nonzero && (next_free < (LABEL_W+1)'(N_LABELS_INT))) begin
                    next_free <= next_free + (LABEL_W+1)'(1);
                end
                // equiv merge write
                if (write_fg && need_merge) begin
                    equiv[merge_hi] <= merge_lo;
                end
                // accumulator RMW on pick_label
                if (write_fg) begin
                    if (col_d1 < acc_min_x[pick_label]) acc_min_x[pick_label] <= col_d1;
                    if (col_d1 > acc_max_x[pick_label]) acc_max_x[pick_label] <= col_d1;
                    if (row_d1 < acc_min_y[pick_label]) acc_min_y[pick_label] <= row_d1;
                    if (row_d1 > acc_max_y[pick_label]) acc_max_y[pick_label] <= row_d1;
                    acc_count[pick_label] <= acc_count[pick_label] + COUNT_W'(1);
                end
            end

            // ---- FSM phases ----
            case (phase)
            PHASE_IDLE: begin
                if (is_eof_r) begin
                    lbl_idx <= LABEL_W'(1);
                    phase   <= PHASE_A;
                end
            end

            PHASE_A: begin
                chase_root <= lbl_idx;
                chase_cnt  <= '0;
                phase      <= PHASE_A_CHASE;
            end

            PHASE_A_CHASE: begin
                if (equiv[chase_root] == chase_root || chase_cnt == MAX_CHAIN_DEPTH[$bits(chase_cnt)-1:0]) begin
                    equiv[lbl_idx] <= chase_root;
                    if (lbl_idx == LABEL_W'(N_LABELS_INT - 1)) begin
                        lbl_idx <= LABEL_W'(1);
                        phase   <= PHASE_B;
                    end else begin
                        lbl_idx <= lbl_idx + LABEL_W'(1);
                        phase   <= PHASE_A;
                    end
                end else begin
                    chase_root <= equiv[chase_root];
                    chase_cnt  <= chase_cnt + 1'b1;
                end
            end

            PHASE_B: begin
                if (fold_wr_pending) begin
                    if (fold_src_min_x < acc_min_x[fold_dst_lbl]) acc_min_x[fold_dst_lbl] <= fold_src_min_x;
                    if (fold_src_max_x > acc_max_x[fold_dst_lbl]) acc_max_x[fold_dst_lbl] <= fold_src_max_x;
                    if (fold_src_min_y < acc_min_y[fold_dst_lbl]) acc_min_y[fold_dst_lbl] <= fold_src_min_y;
                    if (fold_src_max_y > acc_max_y[fold_dst_lbl]) acc_max_y[fold_dst_lbl] <= fold_src_max_y;
                    acc_count[fold_dst_lbl] <= acc_count[fold_dst_lbl] + fold_src_count;
                    acc_count[fold_src_lbl] <= '0;
                    fold_wr_pending <= 1'b0;
                    if (lbl_idx == LABEL_W'(N_LABELS_INT - 1)) begin
                        lbl_idx   <= '0;
                        out_slot  <= '0;
                        phase     <= PHASE_C;
                    end else begin
                        lbl_idx <= lbl_idx + LABEL_W'(1);
                    end
                end else begin
                    if (equiv[lbl_idx] != lbl_idx && acc_count[lbl_idx] != '0) begin
                        fold_src_lbl    <= lbl_idx;
                        fold_dst_lbl    <= equiv[lbl_idx];
                        fold_src_min_x  <= acc_min_x[lbl_idx];
                        fold_src_max_x  <= acc_max_x[lbl_idx];
                        fold_src_min_y  <= acc_min_y[lbl_idx];
                        fold_src_max_y  <= acc_max_y[lbl_idx];
                        fold_src_count  <= acc_count[lbl_idx];
                        fold_wr_pending <= 1'b1;
                    end else begin
                        if (lbl_idx == LABEL_W'(N_LABELS_INT - 1)) begin
                            lbl_idx   <= '0;
                            out_slot  <= '0;
                            phase     <= PHASE_C;
                        end else begin
                            lbl_idx <= lbl_idx + LABEL_W'(1);
                        end
                    end
                end
            end

            PHASE_C: begin
                // Evaluate the current scan_idx candidate on EVERY cycle
                // (including the terminal one), so label N_LABELS_INT-1 is
                // not skipped. Use a block-local variable for the effective
                // best values — needed on the terminal cycle where NBA-next
                // won't help (there is no next cycle in this path).
                begin : phase_c_eval
                    logic                cand_valid;
                    logic [COUNT_W-1:0]  eff_best_count;
                    logic [LABEL_W-1:0]  eff_best_lbl;

                    cand_valid = (acc_count[scan_idx] >= COUNT_W'(MIN_COMPONENT_PIXELS)) &&
                                 (acc_count[scan_idx] > scan_best_count);
                    eff_best_count = cand_valid ? acc_count[scan_idx] : scan_best_count;
                    eff_best_lbl   = cand_valid ? scan_idx           : scan_best_lbl;

                    // Propagate running best for the next cycle.
                    scan_best_count <= eff_best_count;
                    scan_best_lbl   <= eff_best_lbl;

                    if (scan_idx == LABEL_W'(N_LABELS_INT - 1)) begin
                        // Terminal cycle for this slot: commit using the
                        // current-cycle-effective best values.
                        if (eff_best_count >= COUNT_W'(MIN_COMPONENT_PIXELS)) begin
                            back_valid[out_slot] <= 1'b1;
                            back_min_x[out_slot] <= acc_min_x[eff_best_lbl];
                            back_max_x[out_slot] <= acc_max_x[eff_best_lbl];
                            back_min_y[out_slot] <= acc_min_y[eff_best_lbl];
                            back_max_y[out_slot] <= acc_max_y[eff_best_lbl];
                            acc_count[eff_best_lbl] <= '0;  // mark consumed
                        end else begin
                            back_valid[out_slot] <= 1'b0;
                        end
                        // Re-init walker for next slot.
                        scan_best_count <= '0;
                        scan_best_lbl   <= '0;
                        scan_idx        <= '0;
                        if (out_slot == SLOT_IDX_W'(N_OUT - 1)) begin
                            lbl_idx <= '0;
                            phase   <= PHASE_D;
                        end else begin
                            out_slot <= out_slot + SLOT_IDX_W'(1);
                        end
                    end else begin
                        scan_idx <= scan_idx + LABEL_W'(1);
                    end
                end
            end

            PHASE_D: begin
                equiv[lbl_idx]     <= lbl_idx;
                acc_min_x[lbl_idx] <= COL_W'(H_ACTIVE - 1);
                acc_max_x[lbl_idx] <= '0;
                acc_min_y[lbl_idx] <= ROW_W'(V_ACTIVE - 1);
                acc_max_y[lbl_idx] <= '0;
                acc_count[lbl_idx] <= '0;
                if (lbl_idx == LABEL_W'(N_LABELS_INT - 1)) begin
                    next_free <= (LABEL_W+1)'(1);
                    phase     <= PHASE_SWAP;
                end else begin
                    lbl_idx <= lbl_idx + LABEL_W'(1);
                end
            end

            PHASE_SWAP: begin
                // During priming, skip the swap so the front buffer stays
                // empty and no bboxes overlay while the EMA converges.
                /* verilator lint_off UNSIGNED */
                if (prime_cnt >= PRIME_CNT_W'(PRIME_FRAMES)) begin
                /* verilator lint_on UNSIGNED */
                    front_valid <= back_valid;
                    front_min_x <= back_min_x;
                    front_max_x <= back_max_x;
                    front_min_y <= back_min_y;
                    front_max_y <= back_max_y;
                end else begin
                    prime_cnt <= prime_cnt + PRIME_CNT_W'(1);
                end
                back_valid  <= '0;
                bbox_swap_o <= 1'b1;
                phase       <= PHASE_IDLE;
            end

            default: phase <= PHASE_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------
    // SVA checker (Verilator only)
    // -----------------------------------------------------------------
`ifdef VERILATOR
    // No input beat may be accepted while the EOF resolution FSM is active.
    // The tready deassert above enforces this structurally; this assertion
    // is a trip-wire that will fire if the tready gate is ever removed or
    // if a downstream change lets a beat slip through during PHASE_A..SWAP.
    assert_no_accept_during_eof_fsm: assert property (
        @(posedge clk_i) disable iff (!rst_n_i)
            !(s_axis_tvalid_i && s_axis_tready_o && (phase != PHASE_IDLE))
    ) else $error("axis_ccl: input beat accepted during EOF FSM (phase=%0d) — V_BLANK insufficient or tready gate missing",
                  phase);
`endif

endmodule
