# Project Structure Cleanup — Design

**Date:** 2026-04-21
**Scope:** Pure reorganization. No RTL, no algorithm changes.

## Problems

1. **`dv/data/renders/` is buried.** The PNG comparison grids are the main human-visible artifact of the pipeline, but they live three levels deep alongside sim scratch files (`input.bin`, `output.txt`). `dv/data/` conflates "simulator I/O" with "pipeline deliverables".
2. **`hw/ip/motion/rtl/` mixes scopes.** Four modules live there:
   - `axis_motion_detect.sv` + `motion_core.sv` — motion-specific (EMA background, threshold)
   - `axis_ccl.sv` — streaming connected-components labeling (general vision primitive)
   - `axis_overlay_bbox.sv` — draws rectangles on a video stream (generic graphics primitive)

   CCL and the bbox overlay are reusable outside motion detection. Keeping them under `motion/` misrepresents their scope and makes the IP filelist dishonest.

## Design

### 1. Move renders to repo root

**File moves:**
- `dv/data/renders/` → `renders/`

**Edits:**
- `Makefile` — lines 109, 141, 146, 173: replace `$(DATA_DIR)/renders` with `renders` (repo-root relative).
- `py/harness.py` — any render path construction switches to `renders/`.
- `.gitignore` — replace `dv/data/renders/` with `renders/`.
- `CLAUDE.md`, `README.md` — update wherever the renders path is documented.

### 2. Split motion IP into peer IPs

The peer-IP convention is already established (`hw/ip/gauss3x3/`, `hw/ip/rgb2ycrcb/`, `hw/ip/vga/`, `hw/ip/axis/`). CCL and overlay become siblings.

**File moves:**
- `hw/ip/motion/rtl/axis_ccl.sv` → `hw/ip/ccl/rtl/axis_ccl.sv`
- `hw/ip/motion/tb/tb_axis_ccl.sv` → `hw/ip/ccl/tb/tb_axis_ccl.sv`
- `hw/ip/motion/rtl/axis_overlay_bbox.sv` → `hw/ip/overlay/rtl/axis_overlay_bbox.sv`
- `hw/ip/motion/tb/tb_axis_overlay_bbox.sv` → `hw/ip/overlay/tb/tb_axis_overlay_bbox.sv`

`hw/ip/motion/` retains `axis_motion_detect.sv`, `motion_core.sv`, and `tb_axis_motion_detect.sv`.

**New core files (written fresh, not copied):**
- `hw/ip/ccl/ccl.core` — `name: sparevideo:ip:ccl`, filelist: `rtl/axis_ccl.sv`
- `hw/ip/overlay/overlay.core` — `name: sparevideo:ip:overlay`, filelist: `rtl/axis_overlay_bbox.sv`

**Edits:**
- `hw/ip/motion/motion.core` — drop `axis_ccl.sv` / `axis_overlay_bbox.sv` from the filelist; update description to "EMA background model + threshold mask".
- `sparevideo_top.core` — add `sparevideo:ip:ccl` and `sparevideo:ip:overlay` to the depend list.
- `dv/sim/Makefile` — fix hardcoded source paths at lines 8, 9, 165, 172 to point at the new `ccl/` and `overlay/` locations.
- `CLAUDE.md`, `README.md` — update the Project Structure section to reflect the peer IPs.

Module names are **not** changed (`axis_ccl`, `axis_overlay_bbox` stay as-is). Only directories move. This keeps the diff minimal and avoids touching every `include`/instantiation site.

### 3. Verification

After the moves, run the full matrix to confirm nothing silently broke:
- `make lint`
- `make test-ip` (all per-block TBs still find their sources)
- `make run-pipeline` across all four `CTRL_FLOW` values (passthrough, motion, mask, ccl_bbox)
- Confirm `renders/` populates at the repo root, not under `dv/data/`

## Out of scope

- No RTL changes.
- No module renames (e.g. `axis_overlay_bbox` → `axis_bbox_overlay`).
- Old plan docs under `docs/plans/old/` are not updated — they are historical records of work as executed at the time.
- No change to testbench code itself; only its path when referenced from `dv/sim/Makefile`.
