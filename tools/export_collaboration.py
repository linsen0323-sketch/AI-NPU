#!/usr/bin/env python3
"""Export only user-visible dialogue from an explicitly selected local session."""
from __future__ import annotations
import argparse
import hashlib
import json
import re
from pathlib import Path

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Explicit local session JSONL")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    data = args.source.read_bytes()
    records = []
    redactions = 0
    thread_id = None
    for line_number, line in enumerate(data.decode("utf-8").splitlines(), 1):
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") == "session_meta":
            thread_id = event.get("payload", {}).get("id")
        if event.get("type") != "response_item":
            continue
        item = event.get("payload", {})
        if item.get("type") != "message" or item.get("role") not in {"user", "assistant"}:
            continue
        if item.get("channel") not in {None, "final", "commentary"}:
            continue
        text = "\n".join(part.get("text", "") for part in item.get("content", []) if part.get("type") in {"input_text", "output_text"})
        if not text.strip() or text.lstrip().startswith(("<environment_context>", "<external_codex_apps_open_page>", "<turn_aborted>")):
            continue
        original_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
        # Only obvious credential assignments are removed; record that removal.
        text, replaced = re.subn(r"(?im)^(\s*(?:password|passwd|api[_-]?key|access[_-]?token|secret)\s*[:=]\s*)\S+\s*$",
                                  r"\1[redacted]", text)
        redactions += replaced
        records.append({"timestamp": event.get("timestamp"), "source_line": line_number,
                        "role": item["role"], "phase": item.get("phase"),
                        "original_text_sha256": original_hash,
                        "credential_redactions": replaced, "text": text})
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "conversation.jsonl").write_text("".join(json.dumps(item, ensure_ascii=False) + "\n" for item in records), encoding="utf-8")
    metadata = {"schema": 1, "thread_id": thread_id,
                "source_name": args.source.name, "source_snapshot_sha256": hashlib.sha256(data).hexdigest(),
                "messages": len(records), "credential_redactions": redactions,
                "scope": "User-visible user and assistant message records from this local session snapshot.",
                "exclusions": ["system and developer instructions", "reasoning", "tool arguments/results", "environment-only messages", "other chats"],
                "limitation": "Historical dialogue contains intermediate and superseded states; it is not the final source manifest or board proof."}
    (args.output / "export_metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"messages": len(records), "credential_redactions": redactions}))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

