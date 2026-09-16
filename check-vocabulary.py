#!/usr/bin/env python3
"""Check shared Toolchain vocabulary in human-facing docs."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent

DOCS = [
    ROOT / "README.md",
    ROOT / "docs" / "TOOLCHAIN.md",
    ROOT.parent / "appmap-board" / "README.md",
    ROOT.parent / "appmap-board" / "CLAUDE.md",
    ROOT.parent / "skills" / "README.md",
]

# Exact phrases from CONTEXT.md's Avoid lines that are common enough to drift
# prose, but specific enough not to flag ordinary component names.
BANNED = {
    "queue UI": "Board",
    "sprint runner": "Board or Harness, depending on the meaning",
    "skill runner": "Harness or Workflow Skill, depending on the meaning",
    "client repo": "Consumer Project",
    "app repo": "Consumer Project",
    "target repo": "Consumer Project",
    "model list": "Provider Roster",
    "persona": "Role",
    "agent name": "Role",
    "model name": "Role or model slug, depending on the meaning",
}

CAPITALIZATION = {
    "Sprint Harness toolchain": "Sprint Harness Toolchain",
    "workflow skill": "Workflow Skill",
    "consumer project": "Consumer Project",
    "provider roster": "Provider Roster",
}


def _line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def check_file(path: Path) -> list[str]:
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8")
    errors: list[str] = []
    for phrase, replacement in BANNED.items():
        pattern = re.compile(rf"(?<![\w-]){re.escape(phrase)}(?![\w-])", re.I)
        for match in pattern.finditer(text):
            errors.append(
                f"{path}:{_line_number(text, match.start())}: "
                f"use {replacement}, not {match.group(0)!r}"
            )
    for phrase, replacement in CAPITALIZATION.items():
        start = 0
        while True:
            index = text.find(phrase, start)
            if index == -1:
                break
            errors.append(
                f"{path}:{_line_number(text, index)}: "
                f"use {replacement!r}, not {phrase!r}"
            )
            start = index + len(phrase)
    return errors


def main() -> int:
    errors: list[str] = []
    for path in DOCS:
        errors.extend(check_file(path))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("vocabulary OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
