#!/usr/bin/env python3
"""Classify reported stages in saved logs; performs no hardware operation."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

MARKERS = {
    "BOOT_DT_PASS": "boot_dt",
    "DRIVER_CHECK_OK": "driver_preflight",
    "DRIVER_INFO_PASS": "driver_info",
    "DRIVER_LOAD_PASS": "driver_loaded",
}
JSON_RESULTS = {"PL_ABI_PASS": "pl_abi", "MODEL_PRELOAD_PASS": "model_preload",
                "USERSPACE_RUNTIME_PASS": "userspace_runtime"}


def json_objects(text: str):
    decoder = json.JSONDecoder()
    position = 0
    while True:
        start = text.find("{", position)
        if start < 0:
            return
        try:
            value, end = decoder.raw_decode(text, start)
        except ValueError:
            position = start + 1
            continue
        position = end
        if isinstance(value, dict):
            yield start, value


def classify(text: str) -> dict:
    stages = {key: [] for key in [*MARKERS.values(), *JSON_RESULTS.values()]}
    for number, line in enumerate(text.splitlines(), 1):
        found = re.match(r"^\s*(BOOT_DT_PASS|DRIVER_CHECK_OK|DRIVER_INFO_PASS|DRIVER_LOAD_PASS):", line)
        if found:
            stages[MARKERS[found.group(1)]].append({"line": number, "marker": found.group(1)})
    for offset, record in json_objects(text):
        result = record.get("result")
        if result not in JSON_RESULTS:
            continue
        item = {"line": text.count("\n", 0, offset) + 1, "marker": result}
        for field in ["scope", "models_loaded", "inference_tested", "inference_started",
                      "camera_start_requested", "model_switch_called"]:
            if field in record:
                item[field] = record[field]
        stages[JSON_RESULTS[result]].append(item)
    errors = []
    for number, line in enumerate(text.splitlines(), 1):
        if re.search(r"^\s*ERROR:|probe .*failed with error -?\d+", line):
            errors.append({"line": number, "text": line.strip()})
    return {"scope": "OFFLINE_LOG_CLASSIFICATION_NO_HARDWARE_ACCESS",
            "stages": {name: {"status": "reported_pass" if records else "not_found", "records": records}
                       for name, records in stages.items()},
            "errors_retained": errors, "inference_and_video": "requires_separate_manual_evidence",
            "limitations": ["Markers are reports, not independent verification.",
                            "Historical failures and later passes may coexist across boots.",
                            "No hardware, timing or end-to-end correctness is tested."]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    try:
        data = args.log.read_bytes()
        text = data.decode("utf-8-sig")
    except (OSError, UnicodeError) as error:
        print(json.dumps({"error": "log_unreadable", "detail": type(error).__name__}))
        return 2
    result = classify(text)
    result["input_sha256"] = hashlib.sha256(data).hexdigest()
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
