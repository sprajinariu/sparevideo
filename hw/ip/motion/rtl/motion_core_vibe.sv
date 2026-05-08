// Copyright 2026 Sebastian Prajinariu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// motion_core_vibe.sv
// ViBe algorithm core. Substitutes for motion_core under cfg_t.bg_model=BG_MODEL_VIBE.
// AXIS-stream is handled by the wrapper (axis_motion_detect_vibe); this module
// works on a flow-controlled per-pixel beat (y_in_i + valid_i + sof_i + ready_o).
//
// See docs/specs/axis_motion_detect_vibe-arch.md and
// docs/plans/2026-05-06-vibe-phase-2-design.md.

module motion_core_vibe import sparevideo_pkg::*; #(
    parameter int          WIDTH                 = 320,
    parameter int          HEIGHT                = 240,
    parameter int          K                     = 8,            // {8, 20}
    parameter int          R                     = 20,
    parameter int          MIN_MATCH             = 2,
    parameter int          PHI_UPDATE            = 16,
    parameter int          PHI_DIFFUSE           = 16,
    parameter logic        VIBE_BG_INIT_EXTERNAL = 1'b0,
    parameter logic [31:0] PRNG_SEED             = 32'hDEADBEEF,
    parameter string       INIT_BANK_FILE        = ""
) (
    input  logic        clk_i,
    input  logic        rst_n_i,

    // Per-pixel input (post-Gauss luma)
    input  logic        valid_i,
    output logic        ready_o,
    input  logic        pipe_stall_i,     // output stage full and downstream not ready
    input  logic        sof_i,
    input  logic        eol_i,
    input  logic [7:0]  y_in_i,
    input  logic [15:0] frame_count_i,    // frame counter from wrapper (Task 14: init gating)

    // Per-pixel output mask
    output logic        valid_o,
    input  logic        ready_i,
    output logic        sof_o,
    output logic        eol_o,
    output logic        mask_o,

    // Drain-busy: tied to 1'b0 in the new W+1-delay FIFO design.
    // The defer-FIFO drains continuously in the active region, so the wrapper no
    // longer needs to gate s_axis_pix.tready on this signal.  Kept as a port for
    // wrapper compatibility.
    output logic        drain_busy_o
);

    // Elaboration-time guards
    initial begin
        if (K != 8 && K != 20)
            $error("motion_core_vibe: K must be 8 or 20, got %0d", K);
        if (VIBE_BG_INIT_EXTERNAL && INIT_BANK_FILE == "")
            $error("motion_core_vibe: VIBE_BG_INIT_EXTERNAL=1 requires non-empty INIT_BANK_FILE");
    end

    // -------------------------------------------------------------------------
    // Address geometry
    // -------------------------------------------------------------------------
    localparam int N_PIX  = WIDTH * HEIGHT;
    localparam int BANK_W = 8 * K;
    localparam int ADDR_W = $clog2(N_PIX);

    // -------------------------------------------------------------------------
    // Xorshift32 PRNG — pure combinational step function
    //
    // Init (frame 0): Python _init_scheme_c uses N parallel Xorshift32 streams
    //   (one per 32-bit word, ceil(K/4) streams total). Each stream is seeded
    //   from PRNG_SEED ^ INIT_MAGIC_<i>, advances ONCE per pixel. Bytes for
    //   slot k come from stream[k/4][8*(k%4)+:8].
    //   K=8  → 2 streams, K=20 → 5 streams.
    //
    // Runtime: a single, independent stream `prng_state` seeded at PRNG_SEED.
    //   Python's _init_scheme_c does NOT modify self.prng_state, so the runtime
    //   PRNG starts at PRNG_SEED on every reset and advances ONCE per accepted
    //   pixel beat (regardless of init/runtime phase) — _apply_update_coupled
    //   (coupled_rolls=True) advances it per pixel during all frames.
    // -------------------------------------------------------------------------
    localparam int N_INIT_STREAMS = (K + 3) / 4;  // ceil(K/4): 2 for K=8, 5 for K=20

    // Init-PRNG magic constants — XOR with PRNG_SEED to derive per-stream seeds.
    // Must match Python's models/ops/vibe.py INIT_SEED_MAGICS exactly.
    localparam logic [31:0] INIT_MAGIC_0 = 32'h00000000;
    localparam logic [31:0] INIT_MAGIC_1 = 32'h9E3779B9;
    localparam logic [31:0] INIT_MAGIC_2 = 32'hD1B54A32;
    localparam logic [31:0] INIT_MAGIC_3 = 32'hCAFEBABE;
    localparam logic [31:0] INIT_MAGIC_4 = 32'h12345678;

    function automatic logic [31:0] xorshift32(input logic [31:0] s);
        logic [31:0] s1, s2;
        s1 = s ^ (s << 13);
        s2 = s1 ^ (s1 >> 17);
        xorshift32 = s2 ^ (s2 << 5);
    endfunction

    function automatic logic [31:0] init_stream_seed(input int idx);
        case (idx)
            0:       init_stream_seed = PRNG_SEED ^ INIT_MAGIC_0;
            1:       init_stream_seed = PRNG_SEED ^ INIT_MAGIC_1;
            2:       init_stream_seed = PRNG_SEED ^ INIT_MAGIC_2;
            3:       init_stream_seed = PRNG_SEED ^ INIT_MAGIC_3;
            4:       init_stream_seed = PRNG_SEED ^ INIT_MAGIC_4;
            default: init_stream_seed = PRNG_SEED;
        endcase
    endfunction

    // init_phase: frame 0 self-init is active (gates init-stream advances)
    logic init_phase;
    assign init_phase = (frame_count_i == 16'd0) && !VIBE_BG_INIT_EXTERNAL;

    // -------------------------------------------------------------------------
    // N parallel init-PRNG state registers. Each advances once per accepted
    // pixel during init_phase only. Sized to max N=5; only first
    // N_INIT_STREAMS are used by the noise-lane decode (others are dead logic
    // for K=8, but kept to keep the generate-for unrolled at K-time).
    // -------------------------------------------------------------------------
    /* verilator lint_off UNUSED */
    logic [31:0] init_prng    [5];
    logic [31:0] init_prng_s1 [5];
    /* verilator lint_on UNUSED */

    genvar gi_init;
    generate
        for (gi_init = 0; gi_init < 5; gi_init++) begin : g_init_streams
            always_ff @(posedge clk_i or negedge rst_n_i) begin
                if (!rst_n_i) begin
                    init_prng[gi_init]    <= init_stream_seed(gi_init);
                    init_prng_s1[gi_init] <= '0;
                end else if (valid_i && ready_o && !pipe_stall_i) begin
                    if (init_phase)
                        init_prng[gi_init] <= xorshift32(init_prng[gi_init]);
                    // S1 shadow: capture the post-advance value at the S0→S1
                    // boundary so init noise lanes see the same value that
                    // init_prng[i] will hold next cycle, aligned with y_pipe.
                    init_prng_s1[gi_init] <= xorshift32(init_prng[gi_init]);
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Runtime PRNG — single stream, advances ONLY in runtime (frames 1+).
    // Python's _init_scheme_c does NOT modify self.prng_state, so frame 1's
    // first pixel sees prng_state == PRNG_SEED. The init_phase gate here mirrors
    // that: during frame 0, prng_state stays at PRNG_SEED.
    // -------------------------------------------------------------------------
    logic [31:0] prng_state;
    logic [31:0] prng_chain_s0;   // combinational xorshift32(prng_state)
    logic [31:0] prng_s1_word0;   // S1-registered runtime PRNG output

    assign prng_chain_s0 = xorshift32(prng_state);

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            prng_state    <= PRNG_SEED;
            prng_s1_word0 <= '0;
        end else if (valid_i && ready_o && !pipe_stall_i && !init_phase) begin
            // !pipe_stall_i guard: PRNG must NOT advance during a stalled cycle
            // — any drift breaks bit-exact SV-Python parity.
            // !init_phase guard: frame-0 init does not advance the runtime PRNG.
            prng_state    <= prng_chain_s0;
            prng_s1_word0 <= prng_chain_s0;
        end
    end

    // -------------------------------------------------------------------------
    // Per-pixel raster address counter
    // -------------------------------------------------------------------------
    logic [ADDR_W-1:0] pix_addr;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i)
            pix_addr <= '0;
        else if (valid_i && ready_o) begin
            if (sof_i)
                // SOF: pixel 0 is at address 0 (pre-posedge pix_addr=0).
                // Advance to 1 so pixel 1 reads address 1.
                pix_addr <= ADDR_W'(1);
            else if (pix_addr == ADDR_W'(N_PIX - 1))
                pix_addr <= '0;
            else
                pix_addr <= pix_addr + 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Sample bank BRAM — H*W words, each BANK_W bits, packed {slot[K-1],...,slot[0]}.
    // Port-A (read): samples on every rising edge at pix_addr.
    // Port-B (write): frame-0 self-init (Task 14); update+diffusion (Task 15).
    // -------------------------------------------------------------------------
    logic [BANK_W-1:0] sample_bank [N_PIX];

    // External-init path: preload sample_bank from a hex file at simulation start.
    // Runs before any clock edge; frame-0 self-init (init_phase) is already gated
    // off when VIBE_BG_INIT_EXTERNAL=1, so there is no collision.
    generate
        if (VIBE_BG_INIT_EXTERNAL) begin : g_external_init
            initial begin
                $readmemh(INIT_BANK_FILE, sample_bank);
            end
        end
    endgenerate

    logic [ADDR_W-1:0] mem_rd_addr;
    logic [ADDR_W-1:0] pix_addr_hold;  // stable copy of pix_addr during stall
    logic [BANK_W-1:0] mem_rd_data;

    // pix_addr_hold: captures pix_addr on every non-stalled accepted beat so
    // that mem_rd_addr stays stable while the pipeline is held (pipe_stall_i=1).
    // Without this, pix_addr wraps to 0 at end-of-frame even during a stall,
    // changing mem_rd_data under a pixel that hasn't been consumed yet.
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i)
            pix_addr_hold <= '0;
        else if (!pipe_stall_i && valid_i && ready_o)
            pix_addr_hold <= pix_addr;
    end

    assign mem_rd_addr = pipe_stall_i ? pix_addr_hold : pix_addr;

    always_ff @(posedge clk_i) begin
        mem_rd_data <= sample_bank[mem_rd_addr];
    end

    // -------------------------------------------------------------------------
    // Pipeline registers: S0 → S1 → S2
    // S0: pix_addr issued / valid_i accepted
    // S1: BRAM read returns (mem_rd_data) + comparators run combinationally
    // S2: mask captured from combinational result → outputs
    // -------------------------------------------------------------------------
    logic       valid_s1, valid_s2;
    logic       sof_s1,   sof_s2;
    logic       eol_s1,   eol_s2;
    logic [7:0] y_pipe;                      // y_in_i registered into S1
    logic       mask_s2;
    logic [ADDR_W-1:0]        pix_addr_s1;  // pix_addr registered at S1 (Port-B write address)
    logic [$clog2(WIDTH)-1:0] col_s1;       // column counter at S1 (for neighbor bounds check)
    logic       init_phase_s1;              // init_phase latched at S1
    logic       init_phase_s2;             // init_phase latched at S2 (matches mask pipeline depth)

    // col_s0: column counter tracking which pixel is at S0 (combinational from pix_addr)
    // We derive it from pix_addr % WIDTH. Since WIDTH is a power-of-2 in common cases,
    // but to be general we track it with a dedicated register.
    logic [$clog2(WIDTH)-1:0] col_s0;
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i)
            col_s0 <= '0;
        else if (valid_i && ready_o) begin
            if (sof_i)
                col_s0 <= $clog2(WIDTH)'(1);  // pixel 0 at addr 0; next is col 1
            else if (eol_i)
                col_s0 <= '0;
            else
                col_s0 <= col_s0 + 1'b1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            {valid_s1, valid_s2} <= '0;
            {sof_s1,   sof_s2}   <= '0;
            {eol_s1,   eol_s2}   <= '0;
            y_pipe                <= '0;
            mask_s2               <= '0;
            pix_addr_s1           <= '0;
            col_s1                <= '0;
            init_phase_s1         <= '0;
            init_phase_s2         <= '0;
        end else if (!pipe_stall_i) begin
            // S0 → S1: capture pixel, control sideband, address, column, and init flag.
            // Gated by !pipe_stall_i: when the output (S2) is stalled, S1 must hold
            // its data so it doesn't overwrite the pixel waiting at S2.
            valid_s1      <= valid_i && ready_o;
            y_pipe        <= y_in_i;
            sof_s1        <= sof_i;
            eol_s1        <= eol_i;
            pix_addr_s1   <= pix_addr;
            col_s1        <= col_s0;
            init_phase_s1 <= init_phase;
            // S1 → S2: forward control; capture mask from combinational result.
            // Also gated by !pipe_stall_i so S2 holds its output when stalled.
            valid_s2      <= valid_s1;
            sof_s2        <= sof_s1;
            eol_s2        <= eol_s1;
            mask_s2       <= mask_pre;
            init_phase_s2 <= init_phase_s1;
        end
    end

    // -------------------------------------------------------------------------
    // Init word — combinational at S1 from y_pipe and N parallel init-PRNG
    // streams (S1-registered).
    // Python ref _init_scheme_c (any K, N parallel streams = ceil(K/4)):
    //   states[w] = init_prng_s1[w]            (w = k // 4)
    //   byte      = (states[w] >> (8*(k%4))) & 0xFF
    //   noise     = (byte % 41) - 20           → [-20, +20]
    //   sample    = clamp(y + noise, 0, 255)
    // init_prng_s1[] hold the post-advance values for the current pixel,
    // captured at the S0→S1 boundary alongside y_pipe. Parametric: works for
    // any K ∈ {8, 20} (or any K ≤ 4*N_INIT_STREAMS).
    // -------------------------------------------------------------------------
    /* verilator lint_off UNUSED */
    logic [BANK_W-1:0] init_word;
    /* verilator lint_on UNUSED */

    genvar gi;
    generate
        for (gi = 0; gi < K; gi++) begin : g_init_lanes
            logic [7:0]        slot_byte;    // 8-bit lane from PRNG stream gi/4, byte gi%4
            logic signed [8:0] noise_val;    // (byte % 41) - 20, range [-20, +20]
            logic signed [9:0] sum_val;
            logic        [7:0] sample_clamp;

            // Select the correct init-PRNG stream and byte lane for slot gi.
            assign slot_byte    = init_prng_s1[gi / 4][8 * (gi % 4) +: 8];
            assign noise_val    = $signed(9'(slot_byte % 8'd41)) - 9'sd20;
            assign sum_val      = $signed({2'b00, y_pipe}) + 10'(noise_val);
            assign sample_clamp = (sum_val < 0)   ? 8'd0
                                : (sum_val > 255) ? 8'd255
                                : sum_val[7:0];
            // Pack into init_word: slot 0 in bits [7:0], slot K-1 in MSB.
            assign init_word[gi * 8 +: 8] = sample_clamp;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Runtime update + diffusion (coupled_rolls=True, matching Python default).
    //
    // Python _apply_update_coupled() — one PRNG advance per pixel:
    //   state = _next_prng()       → prng_s1_word0 in RTL
    //   fire  = (state & mask_phi) == 0,  mask_phi = (1<<log2_phi_self)-1
    //   slot_self = (state >> log2_phi_self) % K
    //   nbr_idx   = (state >> (log2_phi_self + log2_K)) & 0x7
    //   slot_nbr  = (state >> (log2_phi_self + log2_K + 3)) % K
    //
    // For K=8, phi_update=16: log2_phi_self=4, log2_K=3.
    //   fire      : prng_s1_word0[3:0] == 0
    //   slot_self : prng_s1_word0[6:4]   (3 bits; K=8=2^3 so % K = identity)
    //   nbr_idx   : prng_s1_word0[9:7]   (3 bits → 8 neighbors)
    //   slot_nbr  : prng_s1_word0[12:10] (3 bits; % K = identity for K=8)
    //
    // Both writes use y_pipe as the new sample value (same Python behaviour).
    // When update + diffusion fire on the same pixel (joint-fire), update wins
    // Port-B and diffusion is pushed to a 4-deep shift-register FIFO; deferred
    // diffusion drains opportunistically whenever no pixel-driven write is pending.
    // -------------------------------------------------------------------------

    // PRNG fire/slot/neighbor decode — all from prng_s1_word0 at S1.
    // Log2Phi = $clog2(PHI_UPDATE): 4 for PHI_UPDATE=16.
    // LogK    = $clog2(K):          3 for K=8, 5 for K=20.
    //
    // Python _apply_update_coupled bit-slice layout (coupled_rolls=True):
    //   fire      : state[Log2Phi-1:0] == 0
    //   slot_self : (state >> Log2Phi) % K          ← full shifted word, no mask
    //   nbr_idx   : (state >> (Log2Phi+LogK)) & 7   ← 3-bit field
    //   slot_nbr  : (state >> (Log2Phi+LogK+3)) % K ← full shifted word, no mask
    //
    // Key: Python does NOT mask to LogK bits before applying % K. For K=8
    // (power of 2) this is equivalent (% 8 = & 7), but for K=20 the upper bits
    // of the shifted word affect the modulo result. RTL must match Python exactly
    // by applying % K to the full (32 - shift_offset) bits, not just LogK bits.
    //
    // Implementation: shift prng_s1_word0 right by Log2Phi / (Log2Phi+LogK+3)
    // to get a 32-bit aligned value, then take % K using a 32-bit intermediate.
    localparam int Log2Phi = $clog2(PHI_UPDATE);
    localparam int LogK    = $clog2(K);

    logic                  update_fire;
    logic [31:0]           update_shifted;   // prng_s1_word0 >> Log2Phi (full 32-bit)
    logic [31:0]           diffuse_shifted;  // prng_s1_word0 >> (Log2Phi+LogK+3)
    logic [$clog2(K)-1:0] update_slot;
    logic [2:0]            nbr_idx;
    logic [$clog2(K)-1:0] diffuse_slot;

    // Fire when low Log2Phi bits of the runtime PRNG word are all zero (~1/16).
    assign update_fire    = (prng_s1_word0[Log2Phi-1:0] == '0)
                            && !mask_pre && !init_phase_s1 && valid_s1;

    // Full 32-bit shift (upper bits become 0) then % K — matches Python exactly.
    assign update_shifted  = prng_s1_word0 >> Log2Phi;
    assign diffuse_shifted = prng_s1_word0 >> (Log2Phi + LogK + 3);

    assign update_slot  = $clog2(K)'(update_shifted  % 32'(K));
    assign nbr_idx      = prng_s1_word0[Log2Phi + LogK +: 3];
    assign diffuse_slot = $clog2(K)'(diffuse_shifted % 32'(K));

    // -------------------------------------------------------------------------
    // Neighbor address computation + bounds check
    //
    // 8-neighbor index → (dr, dc) matching Python _NEIGHBOR_OFFSETS:
    //   0 NW(-1,-1)  1 N(-1,0)  2 NE(-1,+1)
    //   3  W( 0,-1)             4  E( 0,+1)
    //   5 SW(+1,-1)  6 S(+1,0)  7 SE(+1,+1)
    //
    // Raster address offset = dr*WIDTH + dc.
    // Bounds-check using pix_addr_s1 and col_s1:
    //   at_north : pix_addr_s1 <  WIDTH           (first row)
    //   at_south : pix_addr_s1 >= N_PIX - WIDTH    (last row)
    //   at_west  : col_s1 == 0
    //   at_east  : col_s1 == WIDTH-1
    // -------------------------------------------------------------------------
    logic at_north, at_south, at_west, at_east;
    assign at_north = (pix_addr_s1 <  ADDR_W'(WIDTH));
    assign at_south = (pix_addr_s1 >= ADDR_W'(N_PIX - WIDTH));
    assign at_west  = (col_s1 == '0);
    assign at_east  = (col_s1 == $clog2(WIDTH)'(WIDTH - 1));

    // out_of_bounds[nbr]: 1 when that neighbor direction is outside the frame.
    logic [7:0] nbr_oob;
    assign nbr_oob[0] = at_north | at_west;   // NW
    assign nbr_oob[1] = at_north;             // N
    assign nbr_oob[2] = at_north | at_east;   // NE
    assign nbr_oob[3] = at_west;              // W
    assign nbr_oob[4] = at_east;              // E
    assign nbr_oob[5] = at_south | at_west;   // SW
    assign nbr_oob[6] = at_south;             // S
    assign nbr_oob[7] = at_south | at_east;   // SE

    logic diffuse_in_bounds;
    assign diffuse_in_bounds = !nbr_oob[nbr_idx];

    // Neighbor raster-address offset (signed, WIDTH+1 bits to hold ±(WIDTH+1)).
    function automatic logic signed [ADDR_W:0] nbr_raster_offset(input logic [2:0] dir);
        unique case (dir)
            3'd0: nbr_raster_offset = -($signed(ADDR_W'(WIDTH)) + $signed(ADDR_W'(1)));  // NW
            3'd1: nbr_raster_offset = -$signed(ADDR_W'(WIDTH));                          // N
            3'd2: nbr_raster_offset = -($signed(ADDR_W'(WIDTH)) - $signed(ADDR_W'(1))); // NE
            3'd3: nbr_raster_offset = -$signed(ADDR_W'(1));                              // W
            3'd4: nbr_raster_offset =  $signed(ADDR_W'(1));                              // E
            3'd5: nbr_raster_offset =  $signed(ADDR_W'(WIDTH)) - $signed(ADDR_W'(1));   // SW
            3'd6: nbr_raster_offset =  $signed(ADDR_W'(WIDTH));                          // S
            3'd7: nbr_raster_offset =  $signed(ADDR_W'(WIDTH)) + $signed(ADDR_W'(1));   // SE
            default: nbr_raster_offset = '0;
        endcase
    endfunction

    logic [ADDR_W-1:0] diffuse_addr;
    assign diffuse_addr = ADDR_W'($signed({1'b0, pix_addr_s1}) + nbr_raster_offset(nbr_idx));

    // -------------------------------------------------------------------------
    // W+1-delay defer-FIFO: holds ONLY diffusion writes.
    //
    // Self-update writes go DIRECT to Port-B the same cycle the firing pixel is
    // at S1 (matching the existing pipeline alignment of update_fire/pix_addr_s1).
    //
    // Diffusion writes are pushed with a deadline measured in monotonic
    // accepted-pixel ticks (NOT cycles).  The FIFO drains continuously in the
    // active region whenever head.deadline <= pix_count_s2 AND Port-B is free
    // AND the pipeline is not stalled.  This guarantees the diffusion write
    // lands W+1 pixels after the firing pixel — late enough that the firing
    // pixel and its raster neighbours have already been read for masking, so
    // the bank state seen by comparators within the same row matches Python's
    // un-mutated frame snapshot.
    //
    // Sizing — see arch doc §5.5:
    //   avg occupancy ≈ (1/φ_diffuse) × (W+1) = 20 at default φ=16, W=320
    //   peak ≈ avg + 4·sqrt(avg) ≈ 39
    //   64 entries = ~60% margin over peak; fits LUTRAM
    // Sizing constraint: W ≤ 640, φ_diffuse ≥ 16.  Larger W or smaller φ
    // requires recomputing — overflow assertion below catches violations at
    // sim time.
    // -------------------------------------------------------------------------
    localparam int FifoDepth = 64;
    localparam int Log2Fifo  = $clog2(FifoDepth);
    localparam int PixCntW  = 32;

    // Pixel counter — increments only on accepted pixel beats.  Ignores AXIS
    // stalls.  Monotonic across frames (no per-frame reset).
    logic [PixCntW-1:0] pixel_count_q;
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i)
            pixel_count_q <= '0;
        else if (valid_i && ready_o && !pipe_stall_i)
            pixel_count_q <= pixel_count_q + PixCntW'(1);
    end

    // Pipeline-aligned copies of the count (S1, S2).  Use the SAME enable
    // conditions as pix_addr_s1 / pix_addr_s2 (see pipeline always_ff above).
    // S1: captured on accepted beat at the S0→S1 boundary.
    // S2: forwarded from S1 every non-stalled cycle.
    logic [PixCntW-1:0] pix_count_s1, pix_count_s2;
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            pix_count_s1 <= '0;
            pix_count_s2 <= '0;
        end else if (!pipe_stall_i) begin
            if (valid_i && ready_o)
                pix_count_s1 <= pixel_count_q;
            pix_count_s2 <= pix_count_s1;
        end
    end

    typedef struct packed {
        logic [PixCntW-1:0]  deadline;
        logic [ADDR_W-1:0]     addr;
        logic [$clog2(K)-1:0]  slot;
        logic [7:0]            data;
    } defer_entry_t;

    defer_entry_t        defer_fifo [FifoDepth];
    logic [Log2Fifo:0]  fifo_count;
    logic [Log2Fifo-1:0] fifo_head, fifo_tail;

    // Signals driven from the comb Port-B mux (declared before use).
    logic [BANK_W-1:0] mem_wr_data;
    logic [K-1:0]      mem_wr_be;
    logic              mem_wr_en;
    logic [ADDR_W-1:0] mem_wr_addr;

    // FIFO push/pop control signals (combinational).
    logic         fifo_push;
    logic         fifo_pop;
    defer_entry_t fifo_push_data;
    logic         self_update_fire;   // alias for update_fire path that hits Port-B directly
    logic         diffuse_fire;        // diffusion fire decision (push to FIFO)

    // -------------------------------------------------------------------------
    // Self-update / diffusion fire decisions (decided at S1, same as legacy).
    // self_update_fire reuses update_fire (gated on !pipe_stall_i in the mux).
    // diffuse_fire is the joint-fire diffusion push: update_fire && in_bounds.
    // -------------------------------------------------------------------------
    // mask/init/valid_s1 gating already in update_fire
    assign self_update_fire = update_fire;
    assign diffuse_fire     = update_fire && diffuse_in_bounds;

    // -------------------------------------------------------------------------
    // FIFO push: diffusion write deferred to land W+1 pixel-ticks later.
    //
    // Deadline = pix_count_s1 + W + 1.  Decision is at S1, where the firing
    // pixel has count == pix_count_s1.  pix_count_s2 lags pix_count_s1 by 1
    // cycle (and only advances on non-stalled accepted beats).  After W+1
    // accepted pixels have advanced past the firing pixel, pix_count_s2 will
    // equal pix_count_s1_at_push + W + 1, satisfying head.deadline <=
    // pix_count_s2 and unblocking the drain.
    // -------------------------------------------------------------------------
    assign fifo_push_data = '{
        deadline: pix_count_s1 + PixCntW'(WIDTH) + PixCntW'(1),
        addr:     diffuse_addr,
        slot:     diffuse_slot,
        data:     y_pipe
    };

    assign fifo_push = diffuse_fire && !init_phase_s1 && !pipe_stall_i;

    // -------------------------------------------------------------------------
    // FIFO drain: pop head when its deadline has been reached, Port-B is free
    // (no self-update firing this cycle), init isn't running, and the pipeline
    // isn't stalled.  Compare uses unsigned subtraction — pix_count_s2 and
    // deadline are both PixCntW=32 bits, so the wrap horizon is 2^32 pixels
    // (~3 hours at 100 MHz), far beyond any realistic sim/operation length.
    // -------------------------------------------------------------------------
    logic         head_ready;
    defer_entry_t head_entry;
    assign head_entry = defer_fifo[fifo_head];
    assign head_ready = (fifo_count != '0) && (head_entry.deadline <= pix_count_s2);

    assign fifo_pop = head_ready
                      && !self_update_fire
                      && !init_phase_s1
                      && !pipe_stall_i;

    // -------------------------------------------------------------------------
    // Port-B write mux — priority: init > self-update > FIFO drain.
    //
    // Frame-0 init writes all K slots directly (must land before frame 1).
    // Self-update writes a single slot at pix_addr_s1 (decided at S1).
    // Diffusion drains pop the head entry and broadcast head.data to all K
    //   bytes of mem_wr_data with byte-enable = 1 << head.slot — only the
    //   selected slot actually writes (see write always_ff below).
    //
    // Mutual exclusion: self-update and FIFO drain are arbitrated by fifo_pop's
    // !self_update_fire gate, so they never collide on Port-B.
    // -------------------------------------------------------------------------
    always_comb begin
        mem_wr_data = '0;
        mem_wr_be   = '0;
        mem_wr_en   = 1'b0;
        mem_wr_addr = '0;

        if (init_phase_s1 && valid_s1 && !pipe_stall_i) begin
            // Frame-0 init: write all K slots — must land before frame 1.
            mem_wr_addr = pix_addr_s1;
            mem_wr_data = init_word;
            mem_wr_be   = '1;
            mem_wr_en   = 1'b1;
        end else if (self_update_fire && !pipe_stall_i) begin
            // Runtime self-update — direct Port-B write at the firing pixel's
            // S1 address; matches legacy pipeline alignment exactly.
            mem_wr_addr = pix_addr_s1;
            mem_wr_data = BANK_W'(y_pipe) << (update_slot * 8);
            mem_wr_be   = K'(1'b1) << update_slot;
            mem_wr_en   = 1'b1;
        end else if (fifo_pop) begin
            // Diffusion drain: broadcast head.data to all K byte lanes; the
            // byte-enable picks the actual target slot.
            mem_wr_addr = head_entry.addr;
            mem_wr_data = {K{head_entry.data}};
            mem_wr_be   = K'(1'b1) << head_entry.slot;
            mem_wr_en   = 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // FIFO pointer/count update.  Two-bit head/tail wrap is a free truncation
    // because FifoDepth is a power of 2 (=64).
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            fifo_head  <= '0;
            fifo_tail  <= '0;
            fifo_count <= '0;
            for (int fi = 0; fi < FifoDepth; fi++)
                defer_fifo[fi] = '0;  // blocking = required by Verilator for array loop init
        end else begin
            // Push side
            if (fifo_push) begin
                defer_fifo[fifo_tail] <= fifo_push_data;
                fifo_tail             <= fifo_tail + Log2Fifo'(1);
            end
            // Pop side
            if (fifo_pop)
                fifo_head <= fifo_head + Log2Fifo'(1);
            // Count: net change of {push, pop}
            unique case ({fifo_push, fifo_pop})
                2'b10:   fifo_count <= fifo_count + {{Log2Fifo{1'b0}}, 1'b1};
                2'b01:   fifo_count <= fifo_count - {{Log2Fifo{1'b0}}, 1'b1};
                default: fifo_count <= fifo_count;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Overflow detection.  CLAUDE.md prohibits SVA, so use a procedural $error
    // — fires only at sim time when the FIFO would overflow.  Triggers if
    // pushing while close to full; the (-2) margin accounts for the extra
    // cycle between detection and the actual push registering.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_n_i && fifo_push && (fifo_count > (Log2Fifo+1)'(FifoDepth-2)))
            $error("motion_core_vibe: defer FIFO overflow (count=%0d, FifoDepth=%0d). %s",
                   fifo_count, FifoDepth,
                   "Increase FifoDepth or reduce phi_diffuse (see arch doc 5.5).");
    end

    // -------------------------------------------------------------------------
    // Sample-bank Port-B write.  Per-byte-enable lane gating preserves slots
    // that aren't part of the current write.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (mem_wr_en) begin
            for (int j = 0; j < K; j++) begin
                if (mem_wr_be[j])
                    sample_bank[mem_wr_addr][j*8 +: 8] <= mem_wr_data[j*8 +: 8];
            end
        end
    end

    // -------------------------------------------------------------------------
    // S1: K parallel L1-distance comparators (combinational on mem_rd_data + y_pipe)
    // -------------------------------------------------------------------------
    logic [K-1:0]            match_vec;
    logic [7:0]              slot_byte [K];
    logic [$clog2(K+1)-1:0]  match_count;
    logic                    mask_pre;

    genvar i;
    generate
        for (i = 0; i < K; i++) begin : g_compare
            logic signed [9:0] diff;
            logic        [8:0] absdiff;

            assign slot_byte[i] = mem_rd_data[i*8 +: 8];
            assign diff         = $signed({2'b00, y_pipe}) - $signed({2'b00, slot_byte[i]});
            // Take the absolute value of the 10-bit signed difference.
            // diff[8:0] is the 9-bit magnitude of the 10-bit 2s-complement result;
            // negating an unsigned 9-bit value gives the correct modular inverse.
            // Do NOT use logic'(-diff[8:0]) — logic' casts to 1 bit.
            assign absdiff      = (diff[9]) ? (-diff[8:0]) : diff[8:0];
            assign match_vec[i] = (absdiff <= 9'(R));
        end
    endgenerate

    assign match_count = $countones(match_vec);
    assign mask_pre    = (match_count < $bits(match_count)'(MIN_MATCH));

    // -------------------------------------------------------------------------
    // Outputs — mask forced 0 during frame 0 (init_phase_s2)
    // -------------------------------------------------------------------------
    assign ready_o      = ready_i;
    // drain_busy_o: tied to 0 — the W+1-delay defer-FIFO drains continuously
    // during the active region, so the wrapper does not need to gate tready.
    assign drain_busy_o = 1'b0;
    assign valid_o = valid_s2;
    assign sof_o   = sof_s2;
    assign eol_o   = eol_s2;
    assign mask_o  = init_phase_s2 ? 1'b0 : mask_s2;

endmodule
