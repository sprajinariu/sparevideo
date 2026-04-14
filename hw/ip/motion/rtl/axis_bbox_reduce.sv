// AXI4-Stream bounding-box reducer.
//
// Consumes a 1-bit mask stream and tracks {min_x, max_x, min_y, max_y}
// over all pixels where mask==1 within each frame. At EOF (last pixel of
// the frame), the accumulated bbox is latched into output registers and
// the scratch counters are reset for the next frame.
//
// Output is a sideband interface (not AXIS) — 4 registered coordinates
// plus bbox_valid (1-cycle strobe on latch) and bbox_empty (no motion
// pixels in the completed frame).
//
// Implementation notes:
//
//   Col counter after SOF: the SOF pixel is at image col=0 and is processed
//   with col_current = 0 (left by the prior tlast or reset). To ensure the
//   NEXT pixel (image col=1) also sees col_current=1, the SOF branch sets
//   col <= 1 rather than 0. Every subsequent row starts correctly because
//   the tlast branch still sets col <= 0 for the first pixel of the next row.
//
//   SOF + mask=1 initialisation: when the SOF pixel itself has mask=1 it is
//   always at (col=0, row=0). The scratch block is split into a SOF branch
//   (which initialises sc directly from the pixel data) and a non-SOF branch
//   (which applies comparisons against the running min/max). This avoids the
//   race where both branches would fire in the same cycle and the SOF reset
//   value '1 would incorrectly dominate the comparison.
//
//   EOF latch delay: the last pixel of the frame updates the scratch in the
//   same cycle that is_eof is asserted. Register is_eof and use it 1 cycle
//   later. Back-to-back frames are safe since this is pipelined

module axis_bbox_reduce #(
    parameter int H_ACTIVE = 320,
    parameter int V_ACTIVE = 240
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    // AXI4-Stream input — mask (1 bit)
    input  logic        s_axis_tdata_i,
    input  logic        s_axis_tvalid_i,
    output logic        s_axis_tready_o,
    input  logic        s_axis_tlast_i,
    input  logic        s_axis_tuser_i,

    // Sideband output — latched bbox
    output logic [$clog2(H_ACTIVE)-1:0] bbox_min_x_o,
    output logic [$clog2(H_ACTIVE)-1:0] bbox_max_x_o,
    output logic [$clog2(V_ACTIVE)-1:0] bbox_min_y_o,
    output logic [$clog2(V_ACTIVE)-1:0] bbox_max_y_o,
    output logic                        bbox_valid_o,
    output logic                        bbox_empty_o
);

    // Always ready — pure sink, no backpressure.
    assign s_axis_tready_o = 1'b1;

    // ---- Column/row counters ----
    logic [$clog2(H_ACTIVE)-1:0] col;
    logic [$clog2(V_ACTIVE)-1:0] row;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            col <= '0;
            row <= '0;
        end else if (s_axis_tvalid_i && s_axis_tready_o) begin
            if (s_axis_tuser_i) begin
                // SOF: reset row, and advance col to 1 so that the pixel
                // immediately after SOF (image col=1) sees col_current=1.
                // The SOF pixel itself already has col_current=0 from the
                // prior tlast or hardware reset.
                col <= ($bits(col))'(1);
                row <= '0;
            end else if (s_axis_tlast_i) begin
                col <= '0;
                row <= row + 1;
            end else begin
                col <= col + 1;
            end
        end
    end

    // ---- Scratch accumulators ----
    logic [$clog2(H_ACTIVE)-1:0] sc_min_x, sc_max_x;
    logic [$clog2(V_ACTIVE)-1:0] sc_min_y, sc_max_y;
    logic                        sc_any;  // at least one mask=1 seen

    // EOF detection: last pixel of frame = tlast on the last row.
    logic is_eof;
    assign is_eof = s_axis_tvalid_i && s_axis_tready_o && s_axis_tlast_i
                    && (row == ($bits(row))'(V_ACTIVE - 1));

    // Registered EOF — latch output one cycle after EOF so that the EOF
    // pixel's scratch update (NBA) has already committed before we read sc_*.
    logic is_eof_r;
    always_ff @(posedge clk_i) begin
        if (!rst_n_i)
            is_eof_r <= 1'b0;
        else
            is_eof_r <= is_eof;
    end

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            sc_min_x <= '1;
            sc_max_x <= '0;
            sc_min_y <= '1;
            sc_max_y <= '0;
            sc_any   <= 1'b0;
        end else if (s_axis_tvalid_i && s_axis_tready_o) begin
            if (s_axis_tuser_i) begin
                // SOF: initialise scratch.
                // If the SOF pixel itself has mask=1 it is always at (0,0);
                // set sc directly rather than racing the comparison below.
                if (s_axis_tdata_i) begin
                    sc_min_x <= '0;
                    sc_max_x <= '0;
                    sc_min_y <= '0;
                    sc_max_y <= '0;
                    sc_any   <= 1'b1;
                end else begin
                    sc_min_x <= '1;
                    sc_max_x <= '0;
                    sc_min_y <= '1;
                    sc_max_y <= '0;
                    sc_any   <= 1'b0;
                end
            end else if (s_axis_tdata_i) begin
                // Non-SOF mask pixel — update running min/max.
                sc_any <= 1'b1;
                if (col < sc_min_x) sc_min_x <= col;
                if (col > sc_max_x) sc_max_x <= col;
                if (row < sc_min_y) sc_min_y <= row;
                if (row > sc_max_y) sc_max_y <= row;
            end
        end
    end

    // ---- Latch output one cycle after EOF ----
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            bbox_min_x_o <= '0;
            bbox_max_x_o <= '0;
            bbox_min_y_o <= '0;
            bbox_max_y_o <= '0;
            bbox_valid_o <= 1'b0;
            bbox_empty_o <= 1'b1;
        end else begin
            bbox_valid_o <= 1'b0;  // default: strobe off

            if (is_eof_r) begin
                bbox_valid_o <= 1'b1;
                bbox_empty_o <= ~sc_any;
                if (sc_any) begin
                    bbox_min_x_o <= sc_min_x;
                    bbox_max_x_o <= sc_max_x;
                    bbox_min_y_o <= sc_min_y;
                    bbox_max_y_o <= sc_max_y;
                end else begin
                    bbox_min_x_o <= '0;
                    bbox_max_x_o <= '0;
                    bbox_min_y_o <= '0;
                    bbox_max_y_o <= '0;
                end
            end
        end
    end

endmodule
