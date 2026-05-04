"""Streaming connected-component labeling (CCL) reference model.

Implements the SAME algorithm as the RTL `axis_ccl` module:
  - 8-connected 4-neighbour (NW, N, NE, W) streaming labeler
  - Union-find with path compression, single write per pixel
  - EOF resolution: path compression, accumulator fold, min-size filter,
    top-N-by-count selection.

Public API:
  run_ccl(masks, n_out=8, n_labels_int=64, min_component_pixels=16,
          max_chain_depth=8) -> list[list[Optional[Bbox]]]

  Bbox = (min_x, max_x, min_y, max_y, count)  # tuple of ints

Notes:
  - Label 0 is reserved as background and overflow catch-all.
  - When more than `n_labels_int - 1` components exist, extra pixels pool
    into label 0's accumulator. Label 0 may emit a spurious catch-all bbox;
    this is the documented overflow behaviour.
"""

from typing import List, Optional, Tuple

import numpy as np

Bbox = Tuple[int, int, int, int, int]  # (min_x, max_x, min_y, max_y, count)


def _find(equiv: List[int], lbl: int, max_depth: int) -> int:
    """Chase equiv pointers up to max_depth steps; return the root found."""
    cur = lbl
    for _ in range(max_depth):
        parent = equiv[cur]
        if parent == cur:
            return cur
        cur = parent
    return cur  # bounded: may not be a true root on adversarial inputs


def _compress(equiv: List[int], lbl: int, max_depth: int) -> None:
    """Two-pass path compression: chase to a (bounded) root, then point lbl at it."""
    root = _find(equiv, lbl, max_depth)
    equiv[lbl] = root


def _run_single_frame(
    mask: np.ndarray,
    n_out: int,
    n_labels_int: int,
    min_component_pixels: int,
    max_chain_depth: int,
) -> List[Optional[Bbox]]:
    h, w = mask.shape

    # Per-frame state (matches RTL reset-at-entry semantics).
    equiv = list(range(n_labels_int))          # equiv[L] = L at start (identity)
    # Accumulator: (min_x, max_x, min_y, max_y, count) per label; label 0 is reserved.
    acc = [[w, -1, h, -1, 0] for _ in range(n_labels_int)]
    line_prev = np.zeros(w, dtype=np.int32)    # labels assigned in the previous row
    next_free = 1

    # ---- Per-pixel streaming pass ----
    for r in range(h):
        line_cur = np.zeros(w, dtype=np.int32)
        w_label = 0  # label of the left neighbour in the current row (starts at 0 per row)
        for c in range(w):
            if not mask[r, c]:
                line_cur[c] = 0
                w_label = 0
                continue

            # Gather 8-connected neighbours NW, N, NE, W (0 if off-image or row 0).
            nw = line_prev[c - 1] if (r > 0 and c > 0) else 0
            n  = line_prev[c]     if (r > 0)           else 0
            ne = line_prev[c + 1] if (r > 0 and c < w - 1) else 0
            wn = w_label

            # Distinct non-zero labels among the 4 neighbours (invariant: |distinct| <= 2).
            distinct = []
            for v in (nw, n, ne, wn):
                if v != 0 and v not in distinct:
                    distinct.append(v)

            if len(distinct) == 0:
                # New component; allocate from next_free. Overflow pools into label 0.
                if next_free < n_labels_int:
                    assigned = next_free
                    next_free += 1
                else:
                    assigned = 0  # overflow -> catch-all
            elif len(distinct) == 1:
                assigned = distinct[0]
            else:
                # len == 2: merge. Assign min; record equivalence max -> min.
                # Per-spec single write: equiv[hi] = lo (unconditional, no root
                # chase). This matches the RTL's 1W equiv port budget exactly.
                # Phase A at EOF performs the root compression.
                lo = min(distinct)
                hi = max(distinct)
                assigned = lo
                equiv[hi] = lo

            # Commit label into the scan state and the accumulator.
            line_cur[c] = assigned
            w_label = assigned
            a = acc[assigned]
            if c < a[0]: a[0] = c
            if c > a[1]: a[1] = c
            if r < a[2]: a[2] = r
            if r > a[3]: a[3] = r
            a[4] += 1

        line_prev = line_cur

    # ---- Phase A: path compression for every label ----
    for lbl in range(1, n_labels_int):
        _compress(equiv, lbl, max_chain_depth)

    # ---- Phase B: accumulator fold (non-root -> its root) ----
    for lbl in range(1, n_labels_int):
        root = equiv[lbl]
        if root == lbl:
            continue  # already a root, nothing to fold
        src = acc[lbl]
        dst = acc[root]
        if src[4] == 0:
            continue
        if src[0] < dst[0]: dst[0] = src[0]
        if src[1] > dst[1]: dst[1] = src[1]
        if src[2] < dst[2]: dst[2] = src[2]
        if src[3] > dst[3]: dst[3] = src[3]
        dst[4] += src[4]
        src[4] = 0  # mark consumed

    # ---- Phase C: min-size filter + top-N-by-count selection ----
    survivors: List[Bbox] = []
    for lbl in range(n_labels_int):  # include label 0 (overflow catch-all)
        a = acc[lbl]
        if a[4] < min_component_pixels:
            continue
        if a[1] < a[0] or a[3] < a[2]:
            continue  # never updated
        survivors.append((a[0], a[1], a[2], a[3], a[4]))
    survivors.sort(key=lambda b: -b[4])
    top = survivors[:n_out]

    # Pad with None to n_out slots.
    out: List[Optional[Bbox]] = list(top) + [None] * (n_out - len(top))
    return out


def run_ccl(
    masks: List[np.ndarray],
    n_out: int = 32,
    n_labels_int: int = 64,
    min_component_pixels: int = 16,
    max_chain_depth: int = 8,
) -> List[List[Optional[Bbox]]]:
    """Run streaming CCL on a list of per-frame boolean masks.

    Returns a list with one entry per input frame. Each entry is a list of
    exactly `n_out` items — `Bbox` tuples (top-N by pixel count, descending)
    with `None` padding up to `n_out`.
    """
    return [
        _run_single_frame(m, n_out, n_labels_int, min_component_pixels, max_chain_depth)
        for m in masks
    ]
