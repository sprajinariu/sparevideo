"""Allow invocation as `python -m demo` (with PYTHONPATH=py)."""
from demo import main

if __name__ == "__main__":
    raise SystemExit(main())
