"""Unit tests for the ViBe + persistence-based FG demotion (B') path.

Companion design: docs/plans/2026-05-12-vibe-demote-python-design.md
"""
from __future__ import annotations

import numpy as np
import pytest

from models.ops.vibe import ViBe


def _random_frames(n: int, h: int = 16, w: int = 16, seed: int = 0) -> list[np.ndarray]:
    rng = np.random.default_rng(seed)
    return [rng.integers(0, 256, (h, w), dtype=np.uint8) for _ in range(n)]


def _const_frame(val: int, h: int = 8, w: int = 8) -> np.ndarray:
    return np.full((h, w), val, dtype=np.uint8)


def test_demote_disabled_bit_exact_canonical_vibe():
    """With demote_en=False, ViBe.process_frame() is byte-for-byte equal
    to a parallel ViBe instance with no demote kwargs at all. This is the
    core regression gate — if any code path leaks under demote_en=False,
    every existing profile bit-exactly regresses."""
    frames = _random_frames(40, seed=0)
    a = ViBe(K=8, R=20, min_match=2, prng_seed=0xDEADBEEF)
    a.init_from_frame(frames[0])
    masks_a = [a.process_frame(f) for f in frames[1:]]

    b = ViBe(
        K=8, R=20, min_match=2, prng_seed=0xDEADBEEF,
        demote_en=False, demote_K_persist=30, demote_kernel=3,
        demote_consistency_thresh=1,
    )
    b.init_from_frame(frames[0])
    masks_b = [b.process_frame(f) for f in frames[1:]]

    for ma, mb in zip(masks_a, masks_b):
        assert np.array_equal(ma, mb), "demote_en=False must be bit-exact ViBe"
    assert np.array_equal(a.samples, b.samples), "bank state must be identical"


def test_fg_count_increments_and_resets():
    """fg_count increments while FG-classified, resets to 0 on BG-classified,
    saturates at 255. Drive a known FG/BG sequence at one pixel and inspect.
    """
    # Use scheme 'b' (degenerate stack: all K slots = current pixel value)
    # so we can predict classification deterministically.
    v = ViBe(K=4, R=10, min_match=2, init_scheme="b",
             phi_update=16, phi_diffuse=16, prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=4, demote_kernel=3,
             demote_consistency_thresh=1)
    bg_frame = _const_frame(128, h=8, w=8)
    v.init_from_frame(bg_frame)            # bank = 128 everywhere
    # Drive a FG frame (value far from bank) — every pixel classifies FG.
    fg_frame = _const_frame(0, h=8, w=8)   # |0-128|=128 > R=10, no match
    m1 = v.process_frame(fg_frame)
    assert m1.all(), "all pixels should be FG on first FG frame"
    assert (v.fg_count == 1).all(), "fg_count should be 1 everywhere"
    m2 = v.process_frame(fg_frame)
    # The fg_count[r,c] reflects post-frame state — it counted this frame's classification.
    # Need to inspect a pixel that did NOT demote. Demotion requires a previously-BG
    # neighbor; after frame 1, prev_final_bg = canonical_FG OR demote_fire ... but
    # demote needs fg_count >= K_persist=4 to fire on frame 2, so all pixels still
    # FG-only and prev_final_bg = False everywhere → no demote can fire on frame 2.
    assert (v.fg_count == 2).all()
    m3 = v.process_frame(bg_frame)         # back to bg → fg_count resets
    assert (~m3).all(), "all pixels should be BG on bg frame"
    assert (v.fg_count == 0).all(), "fg_count should reset on BG classification"


def test_fg_count_saturates_at_255():
    """fg_count is uint8 and saturates at 255 without wrapping."""
    v = ViBe(K=4, R=10, min_match=2, init_scheme="b",
             phi_update=16, phi_diffuse=16, prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=300, demote_kernel=3,
             demote_consistency_thresh=1)  # K_persist > 255 to keep demote off
    bg_frame = _const_frame(128, h=4, w=4)
    v.init_from_frame(bg_frame)
    fg_frame = _const_frame(0, h=4, w=4)
    for _ in range(260):
        v.process_frame(fg_frame)
    # 260 FG frames → fg_count saturates at 255 (uint8).
    assert (v.fg_count == 255).all()


def test_demote_fires_after_K_persist_at_ghost_edge():
    """Construct a synthetic frame-0 ghost: a small object region whose bank
    holds the OBJECT's pixel value (200), surrounded by real-bg pixels whose
    bank holds the bg value (50). The current frame shows real bg everywhere
    (object has moved away). After K_persist frames, the outermost ghost
    ring's bank should receive a deterministic write of the real-bg value.
    """
    H, W = 8, 8
    K_persist = 4
    # Scheme 'b' so the bank is exactly the seed frame.
    v = ViBe(K=4, R=20, min_match=2, init_scheme="b",
             phi_update=1 << 30, phi_diffuse=1 << 30,  # disable canonical update writes
             prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=K_persist, demote_kernel=3,
             demote_consistency_thresh=1)
    # Seed bank: ghost region (rows 2-5, cols 2-5) holds OBJECT value 200,
    # everywhere else holds bg value 50.
    seed = np.full((H, W), 50, np.uint8)
    seed[2:6, 2:6] = 200
    v.init_from_frame(seed)
    # Now drive K_persist real-bg frames.
    bg_frame = np.full((H, W), 50, np.uint8)
    for _ in range(K_persist):
        v.process_frame(bg_frame)
    # After K_persist frames, outermost ghost ring (rows 2/5, cols 2/5) has
    # fg_count >= K_persist AND adjacent BG neighbors → demote should fire.
    # Check a specific ring pixel: (2, 2) — neighbors (1, 1), (1, 2), (1, 3),
    # (2, 1), (3, 1) are all bg-classified canonically (bank=50, frame=50).
    # Demote fires → samples[2,2,*] receives at least one '50' slot.
    assert 50 in v.samples[2, 2], \
        f"expected demote-write of real-bg value at ghost edge, got {v.samples[2,2]}"


def test_wavefront_propagates_one_ring_per_frame():
    """A large ghost region dissolves outside-in at one ring per frame after
    K_persist (consistency_thresh=1).

    Per design spec §3.4 (1-indexed against process_frame call count):
      - Ring 0 first-fires on the K_persist-th call (call index K_persist).
      - Ring i first-fires on call index K_persist + i.

    This test verifies BOTH directions:
      (positive) each ring HAS a real-bg slot at its first-fire frame, AND
      (negative) each ring has NO real-bg slot BEFORE its first-fire frame.
    A buggy implementation that dissolved the entire ghost on frame K_persist,
    or one that uncovered some pixels in a ring late, would now fail.
    """
    H, W = 16, 16
    K_persist = 3
    # phi_diffuse=0 disables canonical ViBe neighbor diffusion. With a large
    # phi (e.g. 1<<30) it is technically rare-but-nonzero, and the fixed PRNG
    # deterministically hits the rare-fire window for a few ghost-edge pixels
    # on early frames — those bg-classified BG-neighbors seed a real-bg sample
    # into the adjacent ghost bank before demote runs, breaking the
    # K_persist + i timing prediction. The cfg under test is the demote path;
    # disabling diffusion isolates it.
    v = ViBe(K=4, R=20, min_match=2, init_scheme="b",
             phi_update=1 << 30, phi_diffuse=0,
             prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=K_persist, demote_kernel=3,
             demote_consistency_thresh=1)
    # Ghost = 6x6 region: rows 5..10, cols 5..10
    r0, r1 = 5, 10
    c0, c1 = 5, 10
    seed = np.full((H, W), 50, np.uint8)
    seed[r0:r1 + 1, c0:c1 + 1] = 200
    v.init_from_frame(seed)
    bg_frame = np.full((H, W), 50, np.uint8)

    # Define rings algorithmically using L-infinity (Chebyshev) distance from
    # the ghost's outer boundary. Ring d is the set of pixels at exactly L-inf
    # distance d from the boundary. For a 6x6 ghost:
    #   ring 0 = outermost perimeter (20 px)
    #   ring 1 = inner perimeter of 4x4 region (12 px)
    #   ring 2 = innermost 2x2 (4 px)
    rings: list[list[tuple[int, int]]] = []
    max_d = min(r1 - r0, c1 - c0) // 2
    for d in range(max_d + 1):
        ring = [
            (r, c)
            for r in range(r0, r1 + 1)
            for c in range(c0, c1 + 1)
            if min(r - r0, r1 - r, c - c0, c1 - c) == d
        ]
        rings.append(ring)
    # Sanity: 6x6 ghost should yield ring sizes 20, 12, 4.
    assert [len(r) for r in rings] == [20, 12, 4]

    # Track, per ring pixel, the first call index at which v.samples[r,c]
    # first contains a real-bg (50) slot. None until that happens.
    n_calls = K_persist + len(rings) + 2  # a couple of extra calls for slack
    first_seen: dict[tuple[int, int], int] = {}
    for call_idx in range(1, n_calls + 1):
        v.process_frame(bg_frame)
        for ring in rings:
            for (r, c) in ring:
                if (r, c) in first_seen:
                    continue
                if 50 in v.samples[r, c]:
                    first_seen[(r, c)] = call_idx

    # Spec: ring i first-fires on call index K_persist + i (1-based).
    for ring_idx, ring in enumerate(rings):
        expected_first = K_persist + ring_idx
        for (r, c) in ring:
            assert (r, c) in first_seen, (
                f"ring {ring_idx} pixel ({r},{c}) never demoted in {n_calls} frames"
            )
            actual = first_seen[(r, c)]
            assert actual == expected_first, (
                f"ring {ring_idx} pixel ({r},{c}) first-fired on call "
                f"{actual}, expected {expected_first} (K_persist={K_persist}, "
                f"ring_idx={ring_idx})"
            )


def test_no_demotion_when_no_BG_neighbor():
    """A pixel surrounded entirely by FG-classified pixels never demotes,
    even if fg_count >> K_persist."""
    H, W = 8, 8
    # All pixels are 'object' (200) but bank seeded everywhere with 200,
    # so the current bg frame (50) is FG everywhere — every neighbor is FG.
    v = ViBe(K=4, R=20, min_match=2, init_scheme="b",
             phi_update=1 << 30, phi_diffuse=1 << 30, prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=3, demote_kernel=3,
             demote_consistency_thresh=1)
    seed = np.full((H, W), 200, np.uint8)
    v.init_from_frame(seed)
    bg_frame = np.full((H, W), 50, np.uint8)
    for _ in range(10):  # 10 frames, K_persist=3 → counter saturates
        v.process_frame(bg_frame)
    # No demote should have fired anywhere — bank is still all-200.
    assert (v.samples == 200).all(), \
        f"expected no demote firing (all FG neighbors); bank min={v.samples.min()}"


def test_slow_moving_uniform_object_not_demoted():
    """A uniform-color object interior whose color is far from the
    surrounding bg should NOT demote, even after K_persist FG frames,
    because BG neighbors' banks don't have slots matching the object color.
    """
    H, W = 12, 12
    K_persist = 3
    v = ViBe(K=4, R=10, min_match=2, init_scheme="b",
             phi_update=1 << 30, phi_diffuse=1 << 30, prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=K_persist, demote_kernel=3,
             demote_consistency_thresh=1)
    # Bank seeded everywhere with bg=50.
    v.init_from_frame(np.full((H, W), 50, np.uint8))
    # Drive frames with a stationary 4x4 OBJECT region at (4..7, 4..7).
    obj_frame = np.full((H, W), 50, np.uint8)
    obj_frame[4:8, 4:8] = 200
    for _ in range(K_persist + 5):
        v.process_frame(obj_frame)
    # Object interior pixel (5,5): neighbors include (4,4)..(6,6). Of those,
    # (4,4)/(4,5)/(5,4) are object pixels (FG), (3,3)..(3,5)/(5,3) are bg pixels.
    # The bg neighbors have bank value 50; current Y at (5,5) is 200 → |50-200|=150 > R=10.
    # No consistency match → no demote. Verify NO slot was written to the
    # object color — a stale check of slots 0/1 only would silently miss a
    # demote-write that landed on slot 2 or 3.
    assert (v.samples[5, 5] == 50).all(), \
        f"object interior should not demote; got {v.samples[5,5]}"
    # Note: the OBJECT-EDGE pixels (e.g., (4,4)) DO have bg-classified neighbors
    # whose banks match each other's bg values. But (4,4)'s OWN current Y is 200,
    # and those bg neighbors' banks hold 50, so |50-200|>R → no fire there either.


def test_consistency_thresh_slows_propagation():
    """Per design spec §3.4: with consistency_thresh=N, ring propagation
    requires N matching slots accumulated in the prior ring's bank before
    the next ring can fire. This slows the wavefront vs thresh=1.

    For a 3x3 ghost (rows/cols 3..5), pixel (4,4) is the sole interior cell,
    i.e. Ring 1.

      thresh=1: Ring 0 first-fires on call K_persist (=3). Ring 1 then needs
                one matching real-bg slot in a Ring 0 neighbor's bank → fires
                on call K_persist + 1 = 4. Expected t1 = 4.

      thresh=2: Ring 0 fires on call K_persist (=3) writing 1 real-bg slot.
                Ring 0 fires again on call K_persist + 1 (=4), writing a 2nd
                slot. Ring 1 can now pass consistency check (≥2 matching
                slots in a Ring 0 neighbor) on call K_persist + 2 = 5.
                Expected t2 = 5.

    So `t2 - t1 == 1` for a 3x3 ghost / thresh ∈ {1,2}. (The "doubled" framing
    used in the prior name was a misread of the spec: thresh adds N-1 frames
    *per ring*, it does not multiply total latency by N for a depth-1 ghost.)
    """
    H, W = 10, 10
    K_persist = 3

    def run(thresh: int) -> int:
        """Return the smallest call index at which Ring 1 pixel (4,4) has
        a real-bg (50) sample in its bank."""
        # phi_diffuse=0 fully disables diffusion (ablation path). Using a large
        # phi (e.g. 1<<30) is NOT equivalent: the fixed PRNG seed deterministically
        # hits the rare-fire window for some early pixels, seeding bg samples into
        # ghost banks before demote runs. That contamination collapses the
        # thresh=1 vs thresh=2 latency gap. phi_update can remain large since
        # self-update never fires on motion-classified ghost pixels.
        v = ViBe(K=4, R=20, min_match=2, init_scheme="b",
                 phi_update=1 << 30, phi_diffuse=0, prng_seed=0xDEADBEEF,
                 demote_en=True, demote_K_persist=K_persist, demote_kernel=3,
                 demote_consistency_thresh=thresh)
        seed = np.full((H, W), 50, np.uint8)
        seed[3:6, 3:6] = 200  # 3x3 ghost
        v.init_from_frame(seed)
        bg = np.full((H, W), 50, np.uint8)
        # Watch the center pixel (4,4) — wait until at least one slot becomes 50.
        for i in range(30):
            v.process_frame(bg)
            if 50 in v.samples[4, 4]:
                return i + 1   # 1-based call index
        return -1

    t1 = run(1)
    t2 = run(2)
    # Sanity bounds: both must fire, and t1 must be in the spec window
    # (after K_persist, well under 2*K_persist).
    assert t1 > 0, "Ring 1 must demote at thresh=1"
    assert t2 > 0, "Ring 1 must demote at thresh=2"
    assert K_persist < t1 < 2 * K_persist, \
        f"t1 outside spec window (K_persist={K_persist}, 2*K_persist={2*K_persist}); got t1={t1}"
    # Exact spec relationship for a 3x3 ghost at this configuration:
    # thresh=2 needs exactly one extra frame in Ring 0 before Ring 1 may fire.
    assert t2 == t1 + 1, \
        f"thresh=2 should add exactly 1 frame for a 3x3 ghost; got t1={t1}, t2={t2}"


def test_demote_deterministic_under_fixed_seed():
    """Two runs of vibe_demote with the same seed produce bit-identical
    masks AND bank state. Ensures the demote code path didn't introduce
    non-determinism."""
    frames = _random_frames(40, seed=0)
    a = ViBe(K=4, R=20, min_match=2, prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=5, demote_kernel=3,
             demote_consistency_thresh=1)
    a.init_from_frame(frames[0])
    masks_a = [a.process_frame(f) for f in frames[1:]]
    b = ViBe(K=4, R=20, min_match=2, prng_seed=0xDEADBEEF,
             demote_en=True, demote_K_persist=5, demote_kernel=3,
             demote_consistency_thresh=1)
    b.init_from_frame(frames[0])
    masks_b = [b.process_frame(f) for f in frames[1:]]
    for ma, mb in zip(masks_a, masks_b):
        assert np.array_equal(ma, mb)
    assert np.array_equal(a.samples, b.samples)
    assert np.array_equal(a.fg_count, b.fg_count)


def test_produce_masks_vibe_demote_profile_smoke():
    """End-to-end: a profile with vibe_demote_en=True must flow through
    _vibe_mask.produce_masks_vibe and produce per-frame boolean masks."""
    from models._vibe_mask import produce_masks_vibe
    rng = np.random.default_rng(0)
    frames = [rng.integers(0, 256, (16, 16, 3), dtype=np.uint8) for _ in range(40)]
    masks = produce_masks_vibe(
        frames,
        # canonical ViBe args
        vibe_K=8, vibe_R=20, vibe_min_match=2,
        vibe_phi_update=16, vibe_phi_diffuse=16,
        vibe_init_scheme=2, vibe_prng_seed=0xDEADBEEF,
        vibe_coupled_rolls=True,
        vibe_bg_init_external=0, vibe_bg_init_lookahead_n=0,
        # NEW demote args
        vibe_demote_en=True,
        vibe_demote_K_persist=5,
        vibe_demote_kernel=3,
        vibe_demote_consistency_thresh=1,
        gauss_en=False,
    )
    assert len(masks) == 40
    for m in masks:
        assert m.dtype == bool
        assert m.shape == (16, 16)


def test_produce_masks_vibe_demote_disabled_bit_exact():
    """With vibe_demote_en=False the adapter MUST produce byte-identical
    masks to today's canonical ViBe path (the regression gate at the
    adapter boundary)."""
    from models._vibe_mask import produce_masks_vibe
    rng = np.random.default_rng(1)
    frames = [rng.integers(0, 256, (16, 16, 3), dtype=np.uint8) for _ in range(30)]
    common = dict(
        vibe_K=8, vibe_R=20, vibe_min_match=2,
        vibe_phi_update=16, vibe_phi_diffuse=16,
        vibe_init_scheme=2, vibe_prng_seed=0xDEADBEEF,
        vibe_coupled_rolls=True,
        vibe_bg_init_external=0, vibe_bg_init_lookahead_n=0,
        gauss_en=False,
    )
    masks_a = produce_masks_vibe(
        frames, **common,
        vibe_demote_en=False,
        vibe_demote_K_persist=30, vibe_demote_kernel=3,
        vibe_demote_consistency_thresh=1,
    )
    masks_b = produce_masks_vibe(frames, **common)  # no demote kwargs at all
    for ma, mb in zip(masks_a, masks_b):
        assert np.array_equal(ma, mb)


def test_produce_masks_vibe_demote_changes_output_when_enabled():
    """Positive plumbing test: vibe_demote_en=True through the adapter MUST
    actually enable demotion. Constructs a synthetic frame-0 ghost (object
    present in frame 0, then disappears) and verifies that the demote-on
    mask stream has STRICTLY lower asymptotic FG-pixel count than the
    demote-off stream. Fails loud if plumbing silently drops the kwargs.
    """
    from models._vibe_mask import produce_masks_vibe
    # Build 60 RGB frames: frame 0 has an object (white square on dark bg),
    # frames 1+ are all-dark (the object has 'left' — frame-0 ghost forms).
    H, W = 24, 24
    frames = []
    bg = np.full((H, W, 3), 30, dtype=np.uint8)   # dark bg
    f0 = bg.copy()
    f0[8:16, 8:16] = 200                          # object in frame 0
    frames.append(f0)
    for _ in range(59):
        frames.append(bg.copy())                  # object gone — ghost forms
    common = dict(
        vibe_K=4, vibe_R=20, vibe_min_match=2,
        vibe_phi_update=16, vibe_phi_diffuse=16,
        vibe_init_scheme=1,                       # scheme 'b' (degenerate) for determinism
        vibe_prng_seed=0xDEADBEEF,
        vibe_coupled_rolls=True,
        vibe_bg_init_external=0, vibe_bg_init_lookahead_n=0,
        gauss_en=False,
    )
    masks_off = produce_masks_vibe(
        frames, **common,
        vibe_demote_en=False,
        vibe_demote_K_persist=5, vibe_demote_kernel=3,
        vibe_demote_consistency_thresh=1,
    )
    masks_on = produce_masks_vibe(
        frames, **common,
        vibe_demote_en=True,
        vibe_demote_K_persist=5, vibe_demote_kernel=3,
        vibe_demote_consistency_thresh=1,
    )
    assert len(masks_off) == len(masks_on) == 60
    # The frame-0 ghost (8x8 block) should dissolve faster with demote on.
    # Compare asymptotic FG-pixel count (mean over last 10 frames).
    fg_off = float(np.mean([m.sum() for m in masks_off[-10:]]))
    fg_on  = float(np.mean([m.sum() for m in masks_on[-10:]]))
    assert fg_on < fg_off, (
        f"demote-on should have fewer asymptotic FG pixels than demote-off; "
        f"got fg_on={fg_on}, fg_off={fg_off}"
    )
