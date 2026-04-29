#!/usr/bin/env python3
"""PreToolUse hook: when Edit/Write touches a project file that has a
matching skill, emit a system reminder telling the model to invoke
that skill before proceeding.

stdin: JSON hook payload (see Claude Code hook docs).
stdout (on match): JSON with hookSpecificOutput.additionalContext.
stdout (no match): nothing — exit 0.
"""

import json
import sys
from fnmatch import fnmatchcase


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    f = (payload.get("tool_input") or {}).get("file_path", "") or ""

    skill = None
    if fnmatchcase(f, "*/docs/specs/*-arch.md"):
        skill = "hardware-arch-doc"
    elif fnmatchcase(f, "*/hw/*/tb/*.sv") or fnmatchcase(f, "*/dv/sv/*.sv"):
        skill = "hardware-testing"
    elif fnmatchcase(f, "*/hw/*/rtl/*.sv") or fnmatchcase(f, "*/hw/top/*.sv"):
        skill = "rtl-writing"

    if skill is None:
        return 0

    msg = (
        f"About to modify {f}. Invoke the `{skill}` skill first if you "
        f"have not already invoked it this turn — it carries the "
        f"project-specific rules for this kind of file."
    )
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": msg,
        }
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
