#!/usr/bin/env python3
"""Codex root 세션의 실제 사용자 발화만 증분 수집한다."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


INJECTED_PREFIXES = (
    "# AGENTS.md instructions for",
    "# Model Set Context",
    "<environment_context>",
)

SYNTHETIC_USER_PREFIXES = (
    "<task-notification>",
    "<local-command-stdout>",
    "<command-name>",
    "<command-message>",
    "<system-reminder>",
    (
        "This session is being continued from a previous conversation that ran out of context. "
        "The summary below covers the earlier portion of the conversation."
    ),
)

LEGACY_IMPORT_WINDOW = timedelta(seconds=5)
LEGACY_IMPORT_MIN_SESSIONS = 10
LEGACY_IMPORT_INITIAL_GRACE = timedelta(seconds=2)


class CollectionError(RuntimeError):
    """세션 파일 일부를 신뢰성 있게 읽지 못해 전체 수집을 재시도해야 함."""


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sessions-root", required=True)
    parser.add_argument("--cursor", required=True)
    parser.add_argument("--overlap-hours", type=int, default=24)
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
                if not line.strip():
                    continue
                try:
                    value = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise CollectionError("Codex 세션 JSONL을 완전히 읽지 못함") from exc
                if isinstance(value, dict):
                    objects.append(value)
    except (OSError, UnicodeError) as exc:
        raise CollectionError("Codex 세션 파일을 읽지 못함") from exc
    return objects


def root_session(objects: list[dict[str, Any]]) -> tuple[bool | None, str, dict[str, Any], str | None]:
    for item in objects:
        if item.get("type") != "session_meta" or not isinstance(item.get("payload"), dict):
            continue
        payload = item["payload"]
        is_child = bool(payload.get("parent_thread_id") or payload.get("agent_path") or payload.get("forked_from_id"))
        if payload.get("thread_source") == "subagent":
            is_child = True
        session_id = payload.get("session_id") or payload.get("id")
        if not isinstance(session_id, str) or not session_id.strip():
            raise CollectionError("Codex session_meta의 세션 식별자가 올바르지 않음")
        metadata_timestamp = payload.get("timestamp") or item.get("timestamp")
        if not isinstance(metadata_timestamp, str):
            metadata_timestamp = None
        return not is_child, str(session_id), payload, metadata_timestamp
    return None, "unknown", {}, None


def user_text(payload: dict[str, Any]) -> str:
    content = payload.get("content")
    if not isinstance(content, list):
        raise CollectionError("Codex 사용자 content가 배열이 아님")
    parts: list[str] = []
    for part in content:
        if not isinstance(part, dict) or not isinstance(part.get("type"), str):
            raise CollectionError("Codex 사용자 content part가 객체가 아님")
        part_type = part["type"]
        if part_type == "input_text":
            text = part.get("text")
            if not isinstance(text, str):
                raise CollectionError("Codex input_text.text가 문자열이 아님")
            parts.append(text)
        elif part_type in {"input_image", "input_audio", "image", "audio", "local_image", "local_audio"}:
            continue
        else:
            raise CollectionError("Codex 사용자 content part 형식을 인식하지 못함")
    return "\n".join(part for part in parts if part).strip()


def is_injected(text: str) -> bool:
    stripped = text.lstrip()
    if any(stripped.startswith(prefix) for prefix in INJECTED_PREFIXES):
        return True
    return "# AGENTS.md instructions for" in stripped and "<environment_context>" in stripped


def is_synthetic_user_message(text: str) -> bool:
    stripped = text.lstrip()
    return any(stripped.startswith(prefix) for prefix in SYNTHETIC_USER_PREFIXES)


def parse_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed


def is_legacy_desktop_session(metadata: dict[str, Any]) -> bool:
    return (
        metadata.get("originator") == "Codex Desktop"
        and metadata.get("source") == "vscode"
        and metadata.get("history_mode") == "legacy"
    )


def session_paths(root: Path) -> list[Path]:
    paths: list[Path] = []

    def traversal_error(exc: OSError) -> None:
        raise CollectionError("Codex 세션 폴더를 완전히 순회하지 못함") from exc

    try:
        for directory, dirnames, filenames in os.walk(root, followlinks=False, onerror=traversal_error):
            current = Path(directory)
            for dirname in dirnames:
                if (current / dirname).is_symlink():
                    raise CollectionError("Codex 세션 폴더에 symlink가 있어 순회를 중단함")
            dirnames.sort()
            for filename in sorted(filenames):
                candidate = current / filename
                if candidate.is_symlink():
                    raise CollectionError("Codex 세션 파일에 symlink가 있어 순회를 중단함")
                if filename.endswith(".jsonl"):
                    paths.append(candidate)
    except OSError as exc:
        raise CollectionError("Codex 세션 폴더를 완전히 순회하지 못함") from exc
    return sorted(paths)


def legacy_import_boundaries(
    sessions: list[tuple[Path, list[dict[str, Any]], str, dict[str, Any], str | None]],
) -> dict[Path, datetime]:
    """짧은 시간에 일괄 생성된 legacy 세션의 초기 스냅샷 경계를 계산한다."""
    candidates: list[tuple[datetime, Path]] = []
    for path, _objects, _session_id, metadata, metadata_timestamp in sessions:
        parsed = parse_timestamp(metadata_timestamp)
        if parsed is not None and is_legacy_desktop_session(metadata):
            candidates.append((parsed, path))
    candidates.sort(key=lambda candidate: candidate[0])

    boundaries: dict[Path, datetime] = {}
    for start, (start_time, _start_path) in enumerate(candidates):
        end = start
        while end < len(candidates) and candidates[end][0] - start_time <= LEGACY_IMPORT_WINDOW:
            end += 1
        burst = candidates[start:end]
        if len(burst) < LEGACY_IMPORT_MIN_SESSIONS:
            continue
        boundary = burst[-1][0] + LEGACY_IMPORT_INITIAL_GRACE
        for _metadata_time, path in burst:
            previous = boundaries.get(path)
            if previous is None or boundary > previous:
                boundaries[path] = boundary
    return boundaries


def collect(root: Path, cursor: str, overlap_hours: int = 24) -> list[dict[str, str]]:
    results: list[dict[str, str]] = []
    seen: set[str] = set()
    if not root.is_dir():
        return results
    cursor_timestamp = parse_timestamp(cursor)
    if cursor_timestamp is None:
        raise CollectionError("Codex 수집 커서 시각이 올바르지 않음")
    if overlap_hours < 1 or overlap_hours > 168:
        raise CollectionError("Codex overlap-hours는 1~168 범위여야 함")
    overlap_start = cursor_timestamp - timedelta(hours=overlap_hours)

    sessions: list[tuple[Path, list[dict[str, Any]], str, dict[str, Any], str | None]] = []
    for path in session_paths(root):
        objects = read_objects(path)
        is_root, session_id, metadata, metadata_timestamp = root_session(objects)
        if is_root is None:
            raise CollectionError("Codex 세션 파일에 session_meta가 아직 없음")
        if not is_root:
            continue
        sessions.append((path, objects, session_id, metadata, metadata_timestamp))

    import_boundaries = legacy_import_boundaries(sessions)
    for path, objects, session_id, _metadata, _metadata_timestamp in sessions:
        import_boundary = import_boundaries.get(path)
        for item in objects:
            timestamp = item.get("timestamp")
            payload = item.get("payload")
            if item.get("type") != "response_item":
                continue
            if not isinstance(payload, dict):
                raise CollectionError("Codex response_item payload가 객체가 아님")
            if payload.get("type") != "message" or payload.get("role") != "user":
                continue
            if not isinstance(timestamp, str):
                raise CollectionError("Codex 사용자 발화 시각이 문자열이 아님")
            parsed_timestamp = parse_timestamp(timestamp)
            if parsed_timestamp is None:
                raise CollectionError("Codex 사용자 발화 시각이 올바르지 않음")
            if parsed_timestamp < overlap_start:
                continue
            if import_boundary is not None and parsed_timestamp <= import_boundary:
                continue
            text = user_text(payload)
            if not text or is_injected(text) or is_synthetic_user_message(text):
                continue
            identity = hashlib.sha256(f"{session_id}\0{timestamp}\0{text}".encode("utf-8")).hexdigest()
            if identity in seen:
                continue
            seen.add(identity)
            results.append({"source": "codex", "session": session_id, "ts": timestamp, "text": text})
    return sorted(results, key=lambda item: (item["ts"], item["session"]))


def main() -> int:
    args = arguments()
    try:
        collected = collect(Path(args.sessions_root).expanduser(), args.cursor, args.overlap_hours)
    except CollectionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    atomic_json(Path(args.output).expanduser(), collected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
