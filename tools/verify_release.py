#!/usr/bin/env python3
"""Run the existing release/model static checks without FPGA tools or hardware."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


IGNORED_PARTS = {".git", "__pycache__", ".Xil", "work", "tmp", ".venv"}
LFS_POINTER = re.compile(
    rb"version https://git-lfs.github.com/spec/v1\r?\n"
    rb"(?:ext-[^\r\n]+\r?\n)*"
    rb"oid sha256:[0-9a-f]{64}\r?\nsize [0-9]+(?:\r?\n)?"
)
REQUIRED = (
    "tools/release_manifest.py",
    "build/scripts/models/verify_models.py",
    "skill/fpga-release-integrity/scripts/verify_manifest.py",
    "manifests/files.json",
    "manifests/files.sha256",
    "data/models/runtime/bundle/manifest.json",
)
SUCCESS_FIELDS = {
    "release_manifest_and_python_syntax": {"integrity_pass": True, "python_syntax_pass": True},
    "independent_sha256_manifest": {"passed": True},
    "model_identities_and_runtime_contracts": {"status": "PASS"},
}


def preflight(root: Path) -> dict:
    issues = []
    checked = 0
    for relative in REQUIRED:
        if not (root / relative).is_file():
            issues.append({"path": relative, "reason": "required_file_missing"})
    for directory, directories, filenames in os.walk(root):
        directories[:] = sorted(name for name in directories if name not in IGNORED_PARTS)
        for name in sorted(filenames):
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            try:
                if not path.resolve().is_relative_to(root):
                    issues.append({"path": relative, "reason": "file_outside_root"})
                    continue
                with path.open("rb") as stream:
                    header = stream.read(1025)
                checked += 1
                if len(header) <= 1024 and LFS_POINTER.fullmatch(header):
                    issues.append({"path": relative, "reason": "git_lfs_pointer_not_downloaded"})
            except OSError as exc:
                issues.append({"path": relative, "reason": "file_unreadable", "error": str(exc)})
    return {"name": "release_preflight", "passed": not issues,
            "checked_files": checked, "issues": issues}


def run_check(root: Path, name: str, relative: str, *arguments: str) -> dict:
    command = [sys.executable, "-B", str(root / relative), *arguments]
    environment = dict(os.environ, PYTHONUTF8="1", PYTHONDONTWRITEBYTECODE="1")
    try:
        completed = subprocess.run(command, cwd=root, env=environment, check=False,
                                   capture_output=True, text=True, encoding="utf-8",
                                   errors="replace")
    except OSError as exc:
        return {"name": name, "passed": False, "error": str(exc)}
    result = {"name": name, "passed": completed.returncode == 0,
              "returncode": completed.returncode}
    try:
        details = json.loads(completed.stdout)
        if not isinstance(details, dict):
            raise ValueError("Checker result must be a JSON object")
        result["details"] = details
        expected = SUCCESS_FIELDS.get(name, {})
        if any(details.get(key) != value for key, value in expected.items()):
            result["passed"] = False
            result["error"] = "Checker result does not confirm all required success fields"
    except (json.JSONDecodeError, ValueError) as exc:
        result["passed"] = False
        result["error"] = "Checker did not emit a valid JSON object: " + str(exc)
        if completed.stdout.strip():
            result["stdout"] = completed.stdout[-6000:]
    if completed.stderr.strip():
        result["stderr"] = completed.stderr[-6000:]
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1],
                        help="Release repository root (default: this script's repository)")
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    result = {
        "scope": "local_release_integrity_and_model_binary_contracts_only",
        "hardware_accessed": False,
        "inference_executed": False,
        "rtl_simulation_executed": False,
        "synthesis_or_implementation_executed": False,
        "metadata_files_may_update": ["evidence/packaging/package_validation.json"],
        "checks": [],
    }
    if sys.version_info < (3, 11):
        result["checks"].append({"name": "python_version", "passed": False,
                                 "error": "Python 3.11 or later is required"})
    elif not root.is_dir():
        result["checks"].append({"name": "release_preflight", "passed": False,
                                 "error": "Repository root is not a directory"})
    else:
        result["checks"].append(preflight(root))
        if result["checks"][-1]["passed"]:
            commands = (
                ("release_manifest_and_python_syntax", "tools/release_manifest.py",
                 "--root", str(root), "--check"),
                ("independent_sha256_manifest", "skill/fpga-release-integrity/scripts/verify_manifest.py",
                 "--root", str(root), "--manifest", str(root / "manifests/files.sha256")),
                ("model_identities_and_runtime_contracts", "build/scripts/models/verify_models.py"),
            )
            for name, script, *check_arguments in commands:
                result["checks"].append(run_check(root, name, script, *check_arguments))
    result["passed"] = all(check["passed"] for check in result["checks"])
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
