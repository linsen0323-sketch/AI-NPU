#!/usr/bin/env python3
"""Read-only SHA256 manifest validation; does not invoke FPGA tools."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path, PureWindowsPath


def verify(root: Path, manifest: Path) -> dict:
    root = root.resolve()
    checked = entries = 0
    issues = []
    seen = set()
    if not root.is_dir():
        return {"passed": False, "checked_files": 0, "manifest_entries": 0,
                "issues": [{"reason": "root_not_directory"}]}
    try:
        lines = manifest.read_text(encoding="utf-8-sig").splitlines()
    except (OSError, UnicodeError):
        return {"passed": False, "checked_files": 0, "manifest_entries": 0,
                "issues": [{"reason": "manifest_unreadable"}]}
    for number, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"([0-9a-fA-F]{64})  (.+)", line)
        if not match:
            issues.append({"line": number, "reason": "invalid_manifest_line"})
            continue
        entries += 1
        expected, relative = match.groups()
        relative = relative.replace("\\", "/")
        candidate = Path(relative)
        try:
            path = (root / candidate).resolve()
        except (OSError, ValueError):
            issues.append({"line": number, "path": relative, "reason": "invalid_path"})
            continue
        if (candidate.is_absolute() or PureWindowsPath(relative).drive
                or ".." in candidate.parts or root not in path.parents):
            issues.append({"line": number, "path": relative, "reason": "outside_root"})
            continue
        key = str(path).casefold() if os.name == "nt" else str(path)
        if key in seen:
            issues.append({"line": number, "path": relative, "reason": "duplicate_path"})
            continue
        seen.add(key)
        if not path.is_file():
            issues.append({"line": number, "path": relative, "reason": "missing"})
            continue
        digest = hashlib.sha256()
        try:
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
        except OSError:
            issues.append({"line": number, "path": relative, "reason": "file_unreadable"})
            continue
        checked += 1
        if digest.hexdigest() != expected.lower():
            issues.append({"line": number, "path": relative, "reason": "hash_mismatch"})
    if not entries:
        issues.append({"reason": "empty_manifest"})
    return {"passed": not issues, "checked_files": checked,
            "manifest_entries": entries, "issues": issues}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.root, args.manifest)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
