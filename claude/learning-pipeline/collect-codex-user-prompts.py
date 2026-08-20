#!/usr/bin/env python3
"""Codex root 세션의 실제 사용자 발화만 증분 수집한다."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path
from typing import Any


INJECTED_PREFIXES = (
    "# AGENTS.md instructions for",
    "# Model Set Context",
    "<environment_context>",
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sessions-root", required=True)
    parser.add_argument("--cursor", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False)
            stream.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def read_objects(path: Path) -> list[dict[str, Any]]:
    objects: list[dict[str, Any]] = []
    try:
        with path.open(encoding="utf-8") as stream:
            for line in stream:
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(value, dict):
                    objects.append(value)
    except OSError:
        return []
    return objects


def root_session(objects: list[dict[str, Any]]) -> tuple[bool, str]:
    for item in objects:
        if item.get("type") != "session_meta" or not isinstance(item.get("payload"), dict):
            continue
        payload = item["payload"]
        is_child = bool(payload.get("parent_thread_id") or payload.get("agent_path") or payload.get("forked_from_id"))
        if payload.get("thread_source") == "subagent":
            is_child = True
        session_id = payload.get("session_id") or payload.get("id") or "unknown"
        return not is_child, str(session_id)
    return False, "unknown"


def user_text(payload: dict[str, Any]) -> str:
    content = payload.get("content")
    if not isinstance(content, list):
        return ""
    parts = [
        part.get("text", "")
        for part in content
        if isinstance(part, dict) and part.get("type") == "input_text" and isinstance(part.get("text"), str)
    ]
    return "\n".join(part for part in parts if part).strip()


def is_injected(text: str) -> bool:
    stripped = text.lstrip()
    if any(stripped.startswith(prefix) for prefix in INJECTED_PREFIXES):
        return True
    return "# AGENTS.md instructions for" in stripped and "<environment_context>" in stripped


def collect(root: Path, cursor: str) -> list[dict[str, str]]:
    results: list[dict[str, str]] = []
    seen: set[str] = set()
    if not root.is_dir():
        return results
    for path in sorted(root.rglob("*.jsonl")):
        objects = read_objects(path)
        is_root, session_id = root_session(objects)
        if not is_root:
            continue
        for item in objects:
            timestamp = item.get("timestamp")
            payload = item.get("payload")
            if not isinstance(timestamp, str) or timestamp <= cursor or not isinstance(payload, dict):
                continue
            if item.get("type") != "response_item" or payload.get("type") != "message" or payload.get("role") != "user":
                continue
            text = user_text(payload)
            if not text or is_injected(text):
                continue
            identity = hashlib.sha256(f"{session_id}\0{timestamp}\0{text}".encode("utf-8")).hexdigest()
            if identity in seen:
                continue
            seen.add(identity)
            results.append({"source": "codex", "session": session_id, "ts": timestamp, "text": text})
    return sorted(results, key=lambda item: (item["ts"], item["session"]))


def main() -> int:
    args = arguments()
    atomic_json(Path(args.output).expanduser(), collect(Path(args.sessions_root).expanduser(), args.cursor))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
