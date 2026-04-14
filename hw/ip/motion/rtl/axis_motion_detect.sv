// AXI4-Stream motion detector.
//
// Computes a 1-bit motion mask by comparing the current frame's luma (Y8)
// against the previous frame stored in an external shared RAM (port A).
// Passes the RGB video stream through unchanged with matched latency.
//
// Pipeline timing (1-cycle total latency):
//   Cycle C  : pixel N accepted → MAC sums computed combinationally in rgb2ycrcb,
//              mem_rd_addr issued combinationally
//   Cycle C+1: y_cur registered (rgb2ycrcb output), mem_rd_data arrives from RAM
//              → compare & emit
//
// The Y8 frame buffer is external — this module exposes a 1R1W memory port
// and connects to the shared `ram` port A at the top level.

module axis_motion_detect #(
    parameter int H_ACTIVE = 320,
    parameter int V_ACTIVE = 240,
    parameter int THRESH   = 16,
    parameter int RGN_BASE = 0,
    parameter int RGN_SIZE = H_ACTIVE * V_ACTIVE
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    // AXI4-Stream input (RGB888)
    input  logic [23:0] s_axis_tdata_i,
    input  logic        s_axis_tvalid_i,
    output logic        s_axis_tready_o,
    input  logic        s_axis_tlast_i,
    input  logic        s_axis_tuser_i,

    // AXI4-Stream output — video passthrough (RGB888)
    output logic [23:0] m_axis_vid_tdata_o,
    output logic        m_axis_vid_tvalid_o,
    input  logic        m_axis_vid_tready_i,
    output logic        m_axis_vid_tlast_o,
    output logic        m_axis_vid_tuser_o,

    // AXI4-Stream output — mask (1 bit)
    output logic        m_axis_msk_tdata_o,
    output logic        m_axis_msk_tvalid_o,
    input  logic        m_axis_msk_tready_i,
    output logic        m_axis_msk_tlast_o,
    output logic        m_axis_msk_tuser_o,

    // Memory port (to shared RAM port A)
    output logic [$clog2(RGN_BASE + RGN_SIZE)-1:0] mem_rd_addr_o,
    input  logic [7:0]                              mem_rd_data_i,
    output logic [$clog2(RGN_BASE + RGN_SIZE)-1:0] mem_wr_addr_o,
    output logic [7:0]                              mem_wr_data_o,
    output logic                                    mem_wr_en_o
);

    // ---- Backpressure ----
    logic both_ready;
    assign both_ready      = m_axis_vid_tready_i && m_axis_msk_tready_i;
    assign s_axis_tready_o = both_ready;

    // Pipeline stall: output has valid data but downstream isn't ready.
    // When stalled the pipeline registers must not advance, otherwise the
    // pixel currently at the output would be silently overwritten (dropped).
    logic pipe_stall;
    assign pipe_stall = tvalid_pipe[PIPE_STAGES-1] && !both_ready;

    // ---- Pixel address counter ----
    // pix_addr_reg holds the address of the NEXT expected pixel.
    // pix_addr is combinational: reset to 0 on SOF, otherwise use pix_addr_reg.
    logic [$clog2(H_ACTIVE * V_ACTIVE)-1:0] pix_addr_reg;
    logic [$clog2(H_ACTIVE * V_ACTIVE)-1:0] pix_addr;

    assign pix_addr = s_axis_tuser_i ? '0 : pix_addr_reg;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            pix_addr_reg <= '0;
        end else if (s_axis_tvalid_i && s_axis_tready_o) begin
            if (pix_addr == ($bits(pix_addr))'(H_ACTIVE * V_ACTIVE - 1))
                pix_addr_reg <= '0;
            else
                pix_addr_reg <= pix_addr + 1;
        end
    end

    // ---- RGB → Y conversion (2-cycle pipeline) ----
    logic [7:0] y_cur;
    logic [7:0] cr_unused;
    logic [7:0] cb_unused;

    // During a stall the upstream source may immediately present the next pixel
    // on s_axis_tdata_i (AXI permits this after tready goes low).  rgb2ycrcb is a
    // registered 1-cycle stage, so if its input changes mid-stall, y_cur will
    // reflect the wrong (next) pixel one cycle later.  Fix: while stalled, feed
    // the pixel already captured in tdata_pipe (which is held by !pipe_stall) so
    // y_cur stays stable for the duration of the stall.
    logic [7:0] in_r, in_g, in_b;
    always_comb begin
        if (pipe_stall) begin
            in_r = tdata_pipe[PIPE_STAGES-1][23:16];
            in_g = tdata_pipe[PIPE_STAGES-1][15:8];
            in_b = tdata_pipe[PIPE_STAGES-1][7:0];
        end else begin
            in_r = s_axis_tdata_i[23:16];
            in_g = s_axis_tdata_i[15:8];
            in_b = s_axis_tdata_i[7:0];
        end
    end

    rgb2ycrcb u_rgb2y (
        .clk_i   (clk_i),
        .rst_n_i (rst_n_i),
        .r_i     (in_r),
        .g_i     (in_g),
        .b_i     (in_b),
        .y_o     (y_cur),
        .cb_o    (cb_unused),
        .cr_o    (cr_unused)
    );

    // ---- Memory read: issue combinationally at cycle C, data arrives at C+1 ----
    // With 1-cycle rgb2ycrcb, y_cur and mem_rd_data are both available at C+1.
    //
    // During a pipeline stall, pix_addr_reg may advance (e.g. wrapping after
    // the last pixel of a frame is accepted), which would change mem_rd_addr_o
    // and corrupt mem_rd_data_i for the pixel held at the pipeline output.
    // Fix: register the last non-stall address and re-issue it every stall
    // cycle so mem_rd_data_i stays stable and correct.
    logic [$clog2(H_ACTIVE * V_ACTIVE)-1:0] pix_addr_hold;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i)
            pix_addr_hold <= '0;
        else if (!pipe_stall)
            pix_addr_hold <= pix_addr;
    end

    assign mem_rd_addr_o = ($bits(mem_rd_addr_o))'(RGN_BASE) +
                           (pipe_stall ? pix_addr_hold : pix_addr);

    // ---- Sideband pipeline (1 stage to match rgb2ycrcb latency) ----
    localparam int PIPE_STAGES = 1;

    logic [23:0] tdata_pipe  [PIPE_STAGES];
    logic        tvalid_pipe [PIPE_STAGES];
    logic        tlast_pipe  [PIPE_STAGES];
    logic        tuser_pipe  [PIPE_STAGES];
    logic [$clog2(H_ACTIVE * V_ACTIVE)-1:0] idx_pipe [PIPE_STAGES];

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            for (int i = 0; i < PIPE_STAGES; i++) begin
                tdata_pipe[i]  <= '0;
                tvalid_pipe[i] <= 1'b0;
                tlast_pipe[i]  <= 1'b0;
                tuser_pipe[i]  <= 1'b0;
                idx_pipe[i]    <= '0;
            end
        end else if (!pipe_stall) begin
            // Only advance when not stalled: prevents dropping the pixel
            // currently at the output when the downstream isn't ready.
            tdata_pipe[0]  <= s_axis_tdata_i;
            tvalid_pipe[0] <= s_axis_tvalid_i && s_axis_tready_o;
            tlast_pipe[0]  <= s_axis_tlast_i;
            tuser_pipe[0]  <= s_axis_tuser_i;
            idx_pipe[0]    <= pix_addr;
            for (int i = 1; i < PIPE_STAGES; i++) begin
                tdata_pipe[i]  <= tdata_pipe[i-1];
                tvalid_pipe[i] <= tvalid_pipe[i-1];
                tlast_pipe[i]  <= tlast_pipe[i-1];
                tuser_pipe[i]  <= tuser_pipe[i-1];
                idx_pipe[i]    <= idx_pipe[i-1];
            end
        end
    end

    // ---- Motion comparison (at pipeline output, cycle C+1) ----
    // y_cur     = Y of the pipeline output pixel (stable: rgb2ycrcb input is
    //             held to tdata_pipe during stall — see MUX above)
    // mem_rd_data_i = Y_prev from RAM (stable: pix_addr_hold keeps address fixed)
    // Both are stable during stall → mask_bit can remain combinational.
    logic [7:0] diff;
    logic       mask_bit;

    assign diff     = (y_cur > mem_rd_data_i) ? (y_cur - mem_rd_data_i)
                                               : (mem_rd_data_i - y_cur);
    assign mask_bit = (diff > THRESH[7:0]);

    // ---- Memory write-back: store current Y for next frame ----
    // Gate on both_ready so the write fires exactly once per pixel,
    // on the cycle the downstream actually consumes it.
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            mem_wr_en_o   <= 1'b0;
            mem_wr_addr_o <= '0;
            mem_wr_data_o <= '0;
        end else begin
            mem_wr_en_o   <= tvalid_pipe[PIPE_STAGES-1] && both_ready;
            mem_wr_addr_o <= ($bits(mem_wr_addr_o))'(RGN_BASE) + idx_pipe[PIPE_STAGES-1];
            mem_wr_data_o <= y_cur;
        end
    end

    // ---- Output: video passthrough ----
    assign m_axis_vid_tdata_o  = tdata_pipe[PIPE_STAGES-1];
    assign m_axis_vid_tvalid_o = tvalid_pipe[PIPE_STAGES-1];
    assign m_axis_vid_tlast_o  = tlast_pipe[PIPE_STAGES-1];
    assign m_axis_vid_tuser_o  = tuser_pipe[PIPE_STAGES-1];

    // ---- Output: mask ----
    assign m_axis_msk_tdata_o  = mask_bit;
    assign m_axis_msk_tvalid_o = tvalid_pipe[PIPE_STAGES-1];
    assign m_axis_msk_tlast_o  = tlast_pipe[PIPE_STAGES-1];
    assign m_axis_msk_tuser_o  = tuser_pipe[PIPE_STAGES-1];

endmodule
