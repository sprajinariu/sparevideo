# `ram` Architecture

## 1. Purpose and Scope

`ram` is a generic behavioral dual-port byte-addressed RAM. It provides two independent 1R1W ports (A and B) sharing a single backing store. Port A is used by `axis_motion_detect` for the Y8 previous-frame buffer; port B is reserved for future host clients. The module is content-agnostic — it has no knowledge of frames, regions, or algorithms. It does **not** enforce access ordering between ports, synthesize to any specific FPGA primitive, or implement ECC.

---

## 2. Module Hierarchy

`ram` is a leaf module — no submodules.

---

## 3. Interface Specification

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DEPTH` | 76800 | Total number of bytes (default = 320×240) |
| `ADDR_W` | `$clog2(DEPTH)` | Address width (derived) |

### Ports

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `clk_i` | input | 1 | Clock (shared by both ports) |
| `a_rd_addr_i` | input | `ADDR_W` | Port A read address |
| `a_rd_data_o` | output | 8 | Port A read data (valid 1 cycle after address) |
| `a_wr_addr_i` | input | `ADDR_W` | Port A write address |
| `a_wr_data_i` | input | 8 | Port A write data |
| `a_wr_en_i` | input | 1 | Port A write enable |
| `b_rd_addr_i` | input | `ADDR_W` | Port B read address |
| `b_rd_data_o` | output | 8 | Port B read data (valid 1 cycle after address) |
| `b_wr_addr_i` | input | `ADDR_W` | Port B write address |
| `b_wr_data_i` | input | 8 | Port B write data |
| `b_wr_en_i` | input | 1 | Port B write enable |

---

## 4. Datapath Description

One `logic [7:0] mem [0:DEPTH-1]` backing store, zero-initialized in an `initial` block.

Two independent `always_ff @(posedge clk_i)` blocks, one per port. Each implements **read-first** semantics on the same port: if a port reads and writes the same address in the same cycle, it returns the **old** value. This is the discipline `axis_motion_detect` depends on (it reads `Y_prev` and writes `Y_cur` at the same address on the same cycle).

---

## 5. Inter-Port Collision Semantics

| Scenario | Port A | Port B | Result |
|----------|--------|--------|--------|
| Both read | read `addr_X` | read `addr_Y` | both defined |
| A reads, B writes, disjoint | read `addr_X` | write `addr_Y` | both defined |
| A reads, B writes, same address | read `addr_X` | write `addr_X` | A gets the **old** value |
| A writes, B reads, same address | write `addr_X` | read `addr_X` | B gets the **old** value |
| Both write same address same cycle | write `addr_X = V_A` | write `addr_X = V_B` | **non-deterministic** — last assignment wins in Verilog |

The last case is unsafe. It is prevented by the **host-responsibility rule** below.

### Host-responsibility rule

Any future port B client must obey **at least one** of:

1. **Read-only** — never drive `b_wr_en_i`. Always safe.
2. **Quiesced writes** — only assert `b_wr_en_i` while `axis_motion_detect`'s AXIS input `tvalid` has been low for more than one full frame period.
3. **Disjoint address ranges** — write only to addresses outside `axis_motion_detect`'s active region (`RGN_Y_PREV_BASE` … `RGN_Y_PREV_BASE + RGN_Y_PREV_SIZE − 1`).

Port B is currently tied off (`b_rd_addr_i='0`, `b_wr_en_i=1'b0`) at the top level.

---

## 6. Region Descriptor Model

Partitioning is handled externally by compile-time localparams in `sparevideo_top.sv`. Each client receives its `{RGN_BASE, RGN_SIZE}` as module parameters and computes physical addresses as `RGN_BASE + local_offset`. The RAM module itself has no knowledge of regions.

| Region | Owner | Base | Size |
|--------|-------|------|------|
| `Y_PREV` | `axis_motion_detect` | `0` | `H_ACTIVE × V_ACTIVE` |
| (reserved) | port B future client | — | — |

---

## 7. Timing

| Operation | Latency |
|-----------|---------|
| Read data valid after address | 1 cycle |
| Write takes effect | end of cycle (visible to reads on the next cycle) |
| Throughput per port | 1 read + 1 write per cycle (independent) |

Port A utilization by `axis_motion_detect`: ≤ 25% of `clk_dsp` cycles (bounded by the `clk_pix` pixel arrival rate via the input FIFO). Port B utilization: 0% (tied off).

---

## 8. Known Limitations

- **Simulation-only**: the behavioral model is not synthesizable as-is on FPGA. For synthesis, replace with a vendor true-dual-port BRAM primitive (e.g. Xilinx `xpm_memory_tdpram`). The interface already matches the typical BRAM port layout.
- **No ECC**: single-bit errors are not detected or corrected.
- **No inter-port arbitration**: concurrent writes to the same address from both ports produce non-deterministic results (host-responsibility rule applies).
- **No `ADDR_W` override needed**: `ADDR_W` is derived via `$clog2(DEPTH)`. The parameter is exposed for documentation clarity only; overriding it may cause mismatches.
