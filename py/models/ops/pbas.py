"""PBAS (Pixel-Based Adaptive Segmenter) — Python reference operator.

Faithful port of Hofmann, Tiefenbacher & Rigoll (CVPRW 2012):
"Background Segmentation with Feedback: The Pixel-Based Adaptive Segmenter."
Reference impl mirrored:
  https://github.com/andrewssobral/simple_vehicle_counting/blob/master/package_bgs/PBAS/PBAS.cpp

Y + gradient feature variant. Companion design:
docs/plans/2026-05-11-pbas-python-design.md
"""
from __future__ import annotations

from typing import Optional

import numpy as np

# Precomputed random table size — matches the reference impl's countOfRandomNumb.
_RANDOM_TABLE_LEN = 1000


class PBAS:
    """Deterministic Y + gradient PBAS re-implementation."""

    def __init__(
        self,
        N: int = 20,
        R_lower: int = 18,
        R_scale: int = 5,
        Raute_min: int = 2,
        T_lower: int = 2,
        T_upper: int = 200,
        T_init: int = 18,
        R_incdec: float = 0.05,
        T_inc: float = 1.0,
        T_dec: float = 0.05,
        alpha: int = 7,
        beta: int = 1,
        mean_mag_min: float = 20.0,
        prng_seed: int = 0xDEADBEEF,
        R_upper: int = 0,
    ):
        assert N > 0
        assert R_lower > 0
        assert R_scale > 0
        assert Raute_min > 0
        assert T_lower > 0 and T_upper > T_lower
        assert 0 <= R_incdec <= 1.0
        assert prng_seed != 0
        # R_upper=0 is the "disabled" sentinel; when non-zero it must exceed R_lower.
        assert R_upper == 0 or R_upper > R_lower, \
            "R_upper must be 0 (disabled) or > R_lower"
        self.N = N
        self.R_lower = R_lower
        self.R_upper = R_upper
        self.R_scale = R_scale
        self.Raute_min = Raute_min
        self.T_lower = T_lower
        self.T_upper = T_upper
        self.T_init = T_init
        self.R_incdec = R_incdec
        self.T_inc = T_inc
        self.T_dec = T_dec
        self.alpha = alpha
        self.beta = beta
        self.mean_mag_min = mean_mag_min
        self.prng_seed = prng_seed
        # Per-pixel state — allocated by init_from_frames.
        self.H: int = 0
        self.W: int = 0
        self.samples_y: Optional[np.ndarray] = None   # (H, W, N) uint8
        self.samples_g: Optional[np.ndarray] = None   # (H, W, N) uint8
        self.R: Optional[np.ndarray] = None           # (H, W) float32
        self.T: Optional[np.ndarray] = None           # (H, W) float32
        self.meanMinDist: Optional[np.ndarray] = None # (H, W) float32
        # Per-frame scalar state.
        self.formerMeanMag: float = float(mean_mag_min)
        # Precomputed PRNG tables (mirror reference impl pattern).
        rng = np.random.default_rng(prng_seed)
        self._rand_T = rng.integers(0, T_upper, _RANDOM_TABLE_LEN, dtype=np.int32)
        self._rand_TN = rng.integers(0, T_upper, _RANDOM_TABLE_LEN, dtype=np.int32)
        self._rand_N = rng.integers(0, N, _RANDOM_TABLE_LEN, dtype=np.int32)
        self._rand_X = rng.integers(-1, 2, _RANDOM_TABLE_LEN, dtype=np.int32)
        self._rand_Y = rng.integers(-1, 2, _RANDOM_TABLE_LEN, dtype=np.int32)
        self._rand_idx = 0

    def _next_random_entry(self) -> int:
        """Return current random-table index, then advance with wrap."""
        idx = self._rand_idx
        self._rand_idx = (self._rand_idx + 1) % _RANDOM_TABLE_LEN
        return idx

    def _sobel_magnitude(self, frame: np.ndarray) -> np.ndarray:
        """Compute 3x3 Sobel gradient magnitude, clipped to uint8.

        Uses OpenCV Sobel for speed and faithfulness to the reference impl.
        Replicate-border so the result has the same shape as the input.
        """
        import cv2  # local import — only this method needs it
        gx = cv2.Sobel(frame, cv2.CV_32F, 1, 0, ksize=3, borderType=cv2.BORDER_REPLICATE)
        gy = cv2.Sobel(frame, cv2.CV_32F, 0, 1, ksize=3, borderType=cv2.BORDER_REPLICATE)
        mag = np.hypot(gx, gy)
        return np.clip(mag, 0, 255).astype(np.uint8)

    def _update_formerMeanMag(self, g: np.ndarray, mask_fg: np.ndarray) -> None:
        """End-of-frame update: formerMeanMag = max(mean(g over fg pixels), mean_mag_min)."""
        if mask_fg.any():
            mean_mag = float(g[mask_fg].mean())
        else:
            mean_mag = 0.0
        self.formerMeanMag = max(mean_mag, self.mean_mag_min)

    def _compute_min_dist(self, y: np.ndarray, g: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Compute per-pixel (count, minDist) against the bank.

        For each pixel, sweep through N bank slots; distance is
        alpha*|g - sample_g|/formerMeanMag + beta*|y - sample_y|.
        Count = number of slots with distance < R(x). minDist = min over k.

        Returns:
            count:    (H, W) int32, number of matching slots
            minDist:  (H, W) float32, minimum distance to any slot
        """
        # Broadcast: (H,W,1) vs (H,W,N) → (H,W,N) distances
        dy = np.abs(y.astype(np.int16)[..., None] - self.samples_y.astype(np.int16))
        dg = np.abs(g.astype(np.int16)[..., None] - self.samples_g.astype(np.int16))
        dist = (self.alpha * dg / self.formerMeanMag) + (self.beta * dy)
        matches = dist < self.R[..., None]
        count = matches.sum(axis=2)
        minDist = dist.min(axis=2)
        return count.astype(np.int32), minDist.astype(np.float32)

    def _apply_bank_update(self, y: np.ndarray, g: np.ndarray, mask_bg: np.ndarray) -> None:
        """Per-pixel: with probability ratio/T_upper, write current (y, g) to own
        bank slot AND to a random 3x3 neighbor's bank slot. Only fires on bg.

        Uses precomputed _rand_* tables indexed by _rand_idx (advances per pixel).
        """
        H, W = y.shape
        for r in range(H):
            for c in range(W):
                if not mask_bg[r, c]:
                    self._next_random_entry()  # still advance, to keep determinism
                    continue
                entry = self._next_random_entry()
                ratio_int = int(np.ceil(self.T_upper / self.T[r, c]))
                # Own bank update
                if int(self._rand_T[entry]) < ratio_int:
                    k = int(self._rand_N[(entry + 1) % _RANDOM_TABLE_LEN])
                    self.samples_y[r, c, k] = y[r, c]
                    self.samples_g[r, c, k] = g[r, c]
                # Neighbor bank update
                if int(self._rand_TN[entry]) < ratio_int:
                    dx = int(self._rand_X[entry])
                    dy_off = int(self._rand_Y[entry])
                    nr = max(0, min(H - 1, r + dy_off))
                    nc = max(0, min(W - 1, c + dx))
                    k = int(self._rand_N[(entry + 2) % _RANDOM_TABLE_LEN])
                    self.samples_y[nr, nc, k] = y[r, c]
                    self.samples_g[nr, nc, k] = g[r, c]

    def _apply_R_regulator(self) -> None:
        """R(x) *= (1 ± R_incdec) toward meanMinDist*R_scale. Clamp to [R_lower, R_upper].

        R_upper=0 is the disabled sentinel; when non-zero the cap is applied after
        the lower-bound clamp. This is an engineering knob, NOT a published PBAS
        parameter — see docs/plans for rationale.
        """
        ratio = self.meanMinDist * self.R_scale
        # If R > meanMinDist*R_scale → shrink, else grow
        grow_mask = self.R <= ratio
        self.R = np.where(grow_mask, self.R * (1.0 + self.R_incdec),
                                       self.R * (1.0 - self.R_incdec))
        self.R = np.maximum(self.R, float(self.R_lower))
        if self.R_upper > 0:
            self.R = np.minimum(self.R, float(self.R_upper))

    def _apply_T_regulator(self, mask_fg: np.ndarray) -> None:
        """T(x) increment / decrement based on classification; clamp to bounds."""
        denom = self.meanMinDist + 1.0
        delta_bg = self.T_inc / denom   # subtract on bg
        delta_fg = self.T_dec / denom   # add on fg
        self.T = np.where(mask_fg, self.T + delta_fg, self.T - delta_bg)
        self.T = np.clip(self.T, float(self.T_lower), float(self.T_upper))

    def init_from_frames(self, frames: list[np.ndarray], mode: str = "paper_default") -> None:
        """Seed the sample bank from a stack of frames.

        Args:
            frames: list of (H, W) uint8 Y frames. For paper_default mode,
                len(frames) must be >= N (uses first N). For lookahead_median
                mode, uses all frames to compute a per-pixel temporal median.
            mode: "paper_default" or "lookahead_median".
        """
        assert mode in ("paper_default", "lookahead_median"), f"unknown mode {mode!r}"
        assert len(frames) > 0
        f0 = frames[0]
        assert f0.ndim == 2 and f0.dtype == np.uint8
        self.H, self.W = f0.shape
        self.samples_y = np.zeros((self.H, self.W, self.N), dtype=np.uint8)
        self.samples_g = np.zeros((self.H, self.W, self.N), dtype=np.uint8)
        self.R = np.full((self.H, self.W), float(self.R_lower), dtype=np.float32)
        self.T = np.full((self.H, self.W), float(self.T_init), dtype=np.float32)
        self.meanMinDist = np.zeros((self.H, self.W), dtype=np.float32)
        if mode == "paper_default":
            assert len(frames) >= self.N, \
                f"paper_default needs >= N={self.N} frames; got {len(frames)}"
            mean_mag_sum = 0.0
            for k in range(self.N):
                fk = frames[k]
                self.samples_y[:, :, k] = fk
                g = self._sobel_magnitude(fk)
                self.samples_g[:, :, k] = g
                mean_mag_sum += float(g.mean())
            self.formerMeanMag = max(mean_mag_sum / self.N, self.mean_mag_min)
        else:  # lookahead_median
            stack = np.stack(frames, axis=0)
            median = np.median(stack, axis=0).astype(np.uint8)
            g_median = self._sobel_magnitude(median)
            for k in range(self.N):
                self.samples_y[:, :, k] = median
                self.samples_g[:, :, k] = g_median
            self.formerMeanMag = max(float(g_median.mean()), self.mean_mag_min)

    def process_frame(self, frame: np.ndarray) -> np.ndarray:
        """Process one Y frame, return its mask.

        Procedure (per pixel):
          1. Compute Sobel gradient magnitude g for the whole frame.
          2. For each pixel, compute count and minDist against the bank.
          3. Classify bg (count >= Raute_min) vs fg.
          4. Update meanMinDist (IIR running mean).
          5. Bank update on bg pixels (own + neighbor) with prob ratio/T_upper.
          6. Adapt R and T per pixel.
          7. End-of-frame: update formerMeanMag.
        """
        assert frame.shape == (self.H, self.W), \
            f"frame shape {frame.shape} != model {(self.H, self.W)}"
        g = self._sobel_magnitude(frame)
        count, minDist = self._compute_min_dist(frame, g)
        mask_fg = count < self.Raute_min  # True = motion
        mask_bg = ~mask_fg
        # Running mean of minDist
        self.meanMinDist = ((self.N - 1) * self.meanMinDist + minDist) / float(self.N)
        # Bank update (bg only)
        self._apply_bank_update(frame, g, mask_bg)
        # R / T regulators
        self._apply_R_regulator()
        self._apply_T_regulator(mask_fg)
        # End-of-frame
        self._update_formerMeanMag(g, mask_fg)
        return mask_fg
