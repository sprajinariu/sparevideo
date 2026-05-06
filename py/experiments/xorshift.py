"""Compatibility shim — Xorshift32 lives in py/models/ops/xorshift.py.

Kept so existing scripts under py/experiments/ (capture_upstream.py,
run_phase0.py, run_lookahead_init.py, motion_vibe.py legacy callers)
keep working without import-path churn. New code must import from
`models.ops.xorshift`.
"""
from models.ops.xorshift import xorshift32  # noqa: F401
