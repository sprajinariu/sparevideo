"""Compatibility shim — the ViBe class now lives in py/models/ops/vibe.py.

Kept so existing experiment scripts (run_phase0.py, run_lookahead_init.py,
run_lookahead_init_pipeline.py, capture_upstream.py) keep working. New code
must import `from models.ops.vibe import ViBe`.
"""
from models.ops.vibe import ViBe  # noqa: F401
