"""ViBe (Visual Background Extractor) — Python re-implementation.

A deterministic, integer-only port of Barnich & Van Droogenbroeck (IEEE TIP 2011)
suitable for bit-exact verification against the future SV RTL. Uses Xorshift32
for all randomness; same seed and same advance order produce identical output
across runs.

Three frame-0 init schemes are supported:
  (a) 3×3 neighborhood draws (paper-canonical)
  (b) Degenerate stack (all K slots = current pixel value; cheapest)
  (c) Current ± noise (upstream C/Python reference; default — see Doc B §6.5)

Decision rule:  count = sum(|x - sample_i| < R for i in 0..K); mask = count < min_match
Update rule (only on bg-classified pixels):
  - With prob 1/phi_update: replace random slot of *this* pixel.
  - With prob 1/phi_diffuse: replace random slot of one random spatial neighbor
    (8-neighbor, excluding center).

Companion design doc: docs/plans/2026-05-01-vibe-motion-design.md
"""

from typing import Optional

import numpy as np

from experiments.xorshift import xorshift32


class ViBe:
    """Deterministic ViBe re-implementation."""

    def __init__(
        self,
        K: int = 8,
        R: int = 20,
        min_match: int = 2,
        phi_update: int = 16,
        phi_diffuse: int = 16,
        init_scheme: str = "c",
        prng_seed: int = 0xDEADBEEF,
        coupled_rolls: bool = False,
    ):
        # Validate constraints from design doc
        assert K > 0, "K must be a positive integer"
        assert phi_update & (phi_update - 1) == 0, "phi_update must be a power of 2"
        # phi_diffuse=0 disables diffusion entirely (negative-control ablation)
        if phi_diffuse != 0:
            assert phi_diffuse & (phi_diffuse - 1) == 0, "phi_diffuse must be a power of 2 or 0"
        assert init_scheme in ("a", "b", "c"), "init_scheme must be 'a', 'b', or 'c'"
        assert prng_seed != 0, "prng_seed must be non-zero (0 is Xorshift32 fixed point)"

        self.K = K
        self.R = R
        self.min_match = min_match
        self.phi_update = phi_update
        self.phi_diffuse = phi_diffuse
        self.init_scheme = init_scheme
        self.prng_state = prng_seed
        # When True: self-update + diffusion fire together on the same pixel under
        # one shared phi (phi_update). Mirrors upstream's coupled-rolls behavior.
        # When False: independent rolls per Doc B §2 generalization.
        # phi_diffuse is unused when coupled_rolls=True.
        self.coupled_rolls = coupled_rolls

        self.samples: Optional[np.ndarray] = None  # shape (H, W, K), uint8
        self.H = 0
        self.W = 0

    def _next_prng(self) -> int:
        """Advance PRNG and return the new 32-bit state."""
        self.prng_state = xorshift32(self.prng_state)
        return self.prng_state

    def init_from_frame(self, frame_0: np.ndarray) -> None:
        """Seed the sample bank from frame 0 using the configured init scheme."""
        assert frame_0.ndim == 2 and frame_0.dtype == np.uint8, \
            "frame_0 must be a 2-D uint8 Y frame"
        self.H, self.W = frame_0.shape
        self.samples = np.zeros((self.H, self.W, self.K), dtype=np.uint8)
        if   self.init_scheme == "a": self._init_scheme_a(frame_0)
        elif self.init_scheme == "b": self._init_scheme_b(frame_0)
        elif self.init_scheme == "c": self._init_scheme_c(frame_0)
        else:
            raise ValueError(f"unknown init_scheme {self.init_scheme!r}")

    def init_from_frames(
        self,
        frames: np.ndarray,
        lookahead_n: Optional[int] = None,
    ) -> None:
        """Seed the sample bank from a temporal median over the first
        `lookahead_n` frames of `frames`. When `lookahead_n` is None, use
        all frames in the stack.

        Equivalent to `init_from_frame(median(frames[:lookahead_n], axis=0))`
        but routes through the configured init_scheme so noise structure
        and PRNG advance count match the canonical frame-0 path.

        Args:
            frames: (N, H, W) uint8 stack of Y frames, N >= 1.
            lookahead_n: number of leading frames to median over. None ⇒ all.
        """
        assert frames.ndim == 3 and frames.dtype == np.uint8, \
            "frames must be a (N, H, W) uint8 stack"
        n_total = frames.shape[0]
        assert n_total >= 1, "frames must have at least 1 frame"
        n = n_total if lookahead_n is None else int(lookahead_n)
        assert 1 <= n <= n_total, \
            f"lookahead_n={lookahead_n} out of range [1, {n_total}]"
        bg_est = np.median(frames[:n], axis=0).astype(np.uint8)
        # Reuse the configured init scheme to seed the bank around bg_est.
        self.init_from_frame(bg_est)

    def _init_scheme_c(self, frame_0: np.ndarray) -> None:
        """Scheme (c): each slot = clamp(y + noise, 0, 255), noise ∈ [-20, +20].

        8-bit lanes (one byte per slot) sliced from N PRNG state words, where
        N = ceil(K / 4). Each byte produces a noise via `(byte % 41) - 20`,
        matching upstream's `randint(-20, 20)` range. The modulo-41 introduces
        a small (~5.9%) non-uniformity below the K-slot smoothing threshold.

        K=20 specifically uses 5 PRNG advances per pixel during init; K=8 uses
        2; K=4 uses 1. This eliminates the prior latent slot-degenerate bug in
        which slots k≥8 collapsed to `clamp(y - 8, 0, 255)` because
        `(state >> (4*k)) & 0xF == 0` for any k ≥ 8 on a 32-bit state.

        Companion design doc: docs/plans/2026-05-05-vibe-phase-0-redo-design.md
        """
        n_advances = (self.K + 3) // 4
        for r in range(self.H):
            for c in range(self.W):
                states = [self._next_prng() for _ in range(n_advances)]
                y = int(frame_0[r, c])
                for k in range(self.K):
                    word = states[k // 4]
                    byte = (word >> (8 * (k % 4))) & 0xFF
                    noise = (byte % 41) - 20
                    val = y + noise
                    val = 0 if val < 0 else (255 if val > 255 else val)
                    self.samples[r, c, k] = val

    def _init_scheme_a(self, frame_0: np.ndarray) -> None:
        """Scheme (a): 3×3 neighborhood draws (paper-canonical).

        For each pixel, fill K slots by drawing from random cells of its 3×3
        neighborhood. Out-of-bounds offsets are clipped to the boundary.
        """
        H, W = self.H, self.W
        for r in range(H):
            for c in range(W):
                state = self._next_prng()
                for k in range(self.K):
                    # Each draw needs 4 bits: 2 for dr, 2 for dc (both in [-1, +1]).
                    dr_raw = (state >> (4 * k)) & 0x3
                    dc_raw = (state >> (4 * k + 2)) & 0x3
                    dr = (dr_raw % 3) - 1
                    dc = (dc_raw % 3) - 1
                    nr = max(0, min(H - 1, r + dr))
                    nc = max(0, min(W - 1, c + dc))
                    self.samples[r, c, k] = frame_0[nr, nc]

    def _init_scheme_b(self, frame_0: np.ndarray) -> None:
        """Scheme (b): degenerate stack — all K slots = current pixel value."""
        self.samples[:] = frame_0[..., None]

    def compute_mask(self, frame: np.ndarray) -> np.ndarray:
        """Compute the per-pixel motion mask for the given frame.

        Args:
            frame: (H, W) uint8 Y frame.

        Returns:
            (H, W) bool mask. True = motion, False = bg.
        """
        assert frame.shape == (self.H, self.W), \
            f"frame shape {frame.shape} != model {(self.H, self.W)}"
        # Broadcast: (H, W, 1) - (H, W, K) → (H, W, K) absolute diff
        diff = np.abs(frame.astype(np.int16)[..., None]
                      - self.samples.astype(np.int16))
        matches = diff < self.R          # strict less-than, per Doc B §2
        count = matches.sum(axis=2)      # (H, W) int
        return count < self.min_match    # bool: True = motion

    def _apply_self_update(self, frame: np.ndarray, mask: np.ndarray) -> None:
        """Self-update: with prob 1/phi_update, overwrite a random slot of bg pixels.

        Mutates self.samples in place. Advances PRNG once per pixel (raster order).
        """
        log2_phi_self = (self.phi_update - 1).bit_length()
        update_mask = (1 << log2_phi_self) - 1  # low bits to check zero
        for r in range(self.H):
            for c in range(self.W):
                state = self._next_prng()
                if mask[r, c]:
                    continue  # motion pixel — no update
                # Self-update fires when low log2(phi_update) bits of state == 0
                fires = (state & update_mask) == 0
                if not fires:
                    continue
                # Slot index = next bits, masked via modulo to handle any K > 0
                slot = ((state >> log2_phi_self)) % self.K
                self.samples[r, c, slot] = frame[r, c]

    # 8-neighbor offsets (excluding center), indexed 0..7.
    # Order matches the Doc B §3.2 PRNG bit-slicing convention:
    # neighbor_idx = 0 → NW, 1 → N, 2 → NE, 3 → W, 4 → E, 5 → SW, 6 → S, 7 → SE.
    _NEIGHBOR_OFFSETS = (
        (-1, -1), (-1, 0), (-1, +1),
        ( 0, -1),          ( 0, +1),
        (+1, -1), (+1, 0), (+1, +1),
    )

    def _apply_diffusion(self, frame: np.ndarray, mask: np.ndarray) -> None:
        """Diffusion: with prob 1/phi_diffuse, write current value to a random
        neighbor's random slot. 8-neighbor (excluding center).

        Mutates self.samples in place. Advances PRNG once per pixel (raster order).
        Out-of-image neighbor targets are silently skipped (no clamping).
        """
        if self.phi_diffuse == 0:
            return  # ablation: no diffusion
        log2_phi_self = (self.phi_update - 1).bit_length()
        log2_K = (self.K - 1).bit_length()
        log2_phi_diff = (self.phi_diffuse - 1).bit_length()
        diffuse_mask = (1 << log2_phi_diff) - 1
        for r in range(self.H):
            for c in range(self.W):
                state = self._next_prng()
                if mask[r, c]:
                    continue
                # Diffusion fire-bits: same offset budget as Doc B §3.2 / §7.2 SV.
                #   [phi_update bits | K bits | phi_diffuse bits | 3 nbr bits | K bits]
                fire_bits = (state >> (log2_phi_self + log2_K)) & diffuse_mask
                if fire_bits != 0:
                    continue
                nbr_offset = (state >> (log2_phi_self + log2_K + log2_phi_diff)) & 0x7
                slot = ((state >> (log2_phi_self + log2_K + log2_phi_diff + 3))) % self.K
                dr, dc = self._NEIGHBOR_OFFSETS[nbr_offset]
                nr, nc = r + dr, c + dc
                if not (0 <= nr < self.H and 0 <= nc < self.W):
                    continue  # out-of-image: skip (boundary handling)
                self.samples[nr, nc, slot] = frame[r, c]

    def _apply_update_coupled(self, frame: np.ndarray, mask: np.ndarray) -> None:
        """Coupled update: self-update and diffusion fire TOGETHER on the same
        bg-classified pixel under a single shared probability 1/phi_update.
        Mirrors upstream's behavior. phi_diffuse is unused in this mode.

        Per pixel, one PRNG advance:
          - if low log2(phi_update) bits == 0  → fire
          - own slot = next log2(K) bits ⇒ %K
          - neighbor index = next 3 bits (0..7, excludes center)
          - neighbor slot = next log2(K) bits ⇒ %K
        Both writes use the current pixel value at (r, c).

        Mutates self.samples in place. Out-of-image neighbor targets are skipped.
        """
        log2_phi_self = (self.phi_update - 1).bit_length()
        log2_K = (self.K - 1).bit_length()
        update_mask = (1 << log2_phi_self) - 1
        for r in range(self.H):
            for c in range(self.W):
                state = self._next_prng()
                if mask[r, c]:
                    continue  # motion pixel: no update fires
                if (state & update_mask) != 0:
                    continue  # didn't fire
                # Self-update at (r, c)
                slot_self = ((state >> log2_phi_self)) % self.K
                self.samples[r, c, slot_self] = frame[r, c]
                # Coupled diffusion: pick a neighbor + slot, write same value
                nbr_offset = (state >> (log2_phi_self + log2_K)) & 0x7
                slot_nbr = ((state >> (log2_phi_self + log2_K + 3))) % self.K
                dr, dc = self._NEIGHBOR_OFFSETS[nbr_offset]
                nr, nc = r + dr, c + dc
                if 0 <= nr < self.H and 0 <= nc < self.W:
                    self.samples[nr, nc, slot_nbr] = frame[r, c]

    def process_frame(self, frame: np.ndarray) -> np.ndarray:
        """Process one frame: compute mask, then apply update.

        With coupled_rolls=True (upstream-canonical): one PRNG advance per
        pixel, both self-update and diffusion fire together at rate 1/phi_update.

        With coupled_rolls=False (Doc B §2 two-phi generalization): two
        independent PRNG advances per pixel, self-update at 1/phi_update and
        diffusion at 1/phi_diffuse independently.

        Args:
            frame: (H, W) uint8 Y frame.

        Returns:
            (H, W) bool mask. True = motion, False = bg.
        """
        mask = self.compute_mask(frame)
        if self.coupled_rolls:
            self._apply_update_coupled(frame, mask)
        else:
            # Order matters for PRNG-state determinism: self-update first, diffusion second.
            # Each helper advances PRNG once per pixel; both passes see independent state words.
            self._apply_self_update(frame, mask)
            self._apply_diffusion(frame, mask)
        return mask
