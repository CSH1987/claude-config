#!/usr/bin/env python3
"""세 소스 발화를 익명화하고 같은 timestamp 경계까지 누락 없이 커서화한다."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


SOURCES = ("claude-code", "hermes", "codex")
ISO_UTC = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{3,6})?Z$")
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--claude-file", required=True)
    parser.add_argument("--hermes-file", required=True)
    parser.add_argument("--codex-file", required=True)
    parser.add_argument("--cursor-file", required=True)
    parser.add_argument("--claude-cursor", required=True)
    parser.add_argument("--hermes-cursor", required=True)
    parser.add_argument("--codex-cursor", required=True)
    parser.add_argument("--future-limit", required=True)
    parser.add_argument("--overlap-hours", type=int, default=24)
    parser.add_argument("--output", required=True)
    parser.add_argument("--pending-cursor", required=True)
    return parser.parse_args()


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, separators=(",", ":"))
            stream.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def load_array(path: Path) -> list[dict[str, Any]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("대화 소스 배열을 읽지 못함") from exc
    if not isinstance(value, list) or not all(isinstance(row, dict) for row in value):
        raise ValueError("대화 소스가 객체 배열이 아님")
    return value


def load_boundary_state(path: Path) -> tuple[dict[str, set[str]], dict[str, str | None]]:
    if not path.is_file():
        return ({source: set() for source in SOURCES}, {source: None for source in SOURCES})
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("확정 커서를 읽지 못함") from exc
    if not isinstance(value, dict):
        raise ValueError("확정 커서가 객체가 아님")
    raw = value.get("boundaryIds", {})
    raw_starts = value.get("boundaryStarts", {})
    if not isinstance(raw, dict) or not isinstance(raw_starts, dict):
        raise ValueError("확정 커서의 boundaryIds가 객체가 아님")
    result: dict[str, set[str]] = {}
    starts: dict[str, str | None] = {}
    for source in SOURCES:
        items = raw.get(source, [])
        if not isinstance(items, list) or not all(
            isinstance(item, str) and SHA256_HEX.fullmatch(item) for item in items
        ):
            raise ValueError("확정 커서의 source boundaryIds가 SHA-256 배열이 아님")
        result[source] = set(items)
        start = raw_starts.get(source)
        if start is not None and not isinstance(start, str):
            raise ValueError("확정 커서의 boundaryStarts가 문자열 객체가 아님")
        starts[source] = start
    return result, starts


def canonical_timestamp(value: Any) -> str:
    """UTC 시각을 비교 가능한 고정 6자리 정밀도로 정규화한다."""
    if not isinstance(value, str) or not ISO_UTC.fullmatch(value):
        raise ValueError("시각 형식이 올바르지 않음")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("시각 값이 올바르지 않음") from exc
    return parsed.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def row_identity(row: dict[str, str]) -> str:
    material = "\0".join((row["source"], row["session"], row["ts"], row["text"]))
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def main() -> int:
    args = arguments()
    if args.overlap_hours < 1 or args.overlap_hours > 168:
        raise ValueError("overlap-hours는 1~168 범위여야 함")
    overlap = timedelta(hours=args.overlap_hours)
    future_limit = canonical_timestamp(args.future_limit)

    cursors = {
        "claude-code": canonical_timestamp(args.claude_cursor),
        "hermes": canonical_timestamp(args.hermes_cursor),
        "codex": canonical_timestamp(args.codex_cursor),
    }
    for cursor in cursors.values():
        if cursor > future_limit:
            raise ValueError("소스 커서가 미래 상한보다 늦음")

    rows_by_source = {
        "claude-code": load_array(Path(args.claude_file)),
        "hermes": load_array(Path(args.hermes_file)),
        "codex": load_array(Path(args.codex_file)),
    }
    previous_boundary_ids, raw_boundary_starts = load_boundary_state(Path(args.cursor_file))
    previous_boundary_starts: dict[str, str] = {}
    for source, cursor in cursors.items():
        start = canonical_timestamp(raw_boundary_starts[source]) if raw_boundary_starts[source] else cursor
        cursor_time = datetime.fromisoformat(cursor.replace("Z", "+00:00"))
        minimum_start = (cursor_time - overlap).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        if start < minimum_start or start > cursor:
            raise ValueError("확정 커서의 boundaryStarts가 허용 구간 밖임")
        previous_boundary_starts[source] = start
    selected: list[dict[str, str]] = []
    next_cursors = dict(cursors)
    next_boundary_ids: dict[str, list[str]] = {}
    next_boundary_starts: dict[str, str] = {}

    for source in SOURCES:
        normalized: list[tuple[dict[str, str], str]] = []
        seen: set[str] = set()
        for raw in rows_by_source[source]:
            if raw.get("source") != source or not all(isinstance(raw.get(key), str) for key in ("session", "text")):
                raise ValueError("대화 소스 행의 필드가 올바르지 않음")
            timestamp = canonical_timestamp(raw.get("ts"))
            if timestamp > future_limit:
                raise ValueError("대화 소스 행의 시각이 미래 상한보다 늦음")
            row = {
                "source": source,
                "session": raw["session"],
                "ts": timestamp,
                "text": raw["text"],
            }
            identity = row_identity(row)
            if identity in seen:
                continue
            seen.add(identity)
            normalized.append((row, identity))

        cursor = cursors[source]
        for row, identity in normalized:
            if row["ts"] > cursor or (
                row["ts"] >= previous_boundary_starts[source]
                and identity not in previous_boundary_ids[source]
            ):
                selected.append(row)

        maximum = max((row["ts"] for row, _identity in normalized), default=cursor)
        if maximum < cursor:
            maximum = cursor
        next_cursors[source] = maximum
        maximum_time = datetime.fromisoformat(maximum.replace("Z", "+00:00"))
        boundary_start = (maximum_time - overlap).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        next_boundary_starts[source] = boundary_start
        ids_at_maximum = {identity for row, identity in normalized if row["ts"] >= boundary_start}
        if maximum == cursor:
            ids_at_maximum |= previous_boundary_ids[source]
        next_boundary_ids[source] = sorted(ids_at_maximum)

    selected.sort(key=lambda row: (row["ts"], row["source"], row["session"], row["text"]))
    session_keys = sorted({(row["source"], row["session"]) for row in selected})
    session_aliases = {key: f"{key[0]}-session-{index + 1}" for index, key in enumerate(session_keys)}
    output = [
        {
            "source": row["source"],
            "session": session_aliases[(row["source"], row["session"])],
            "ts": row["ts"],
            "text": row["text"],
        }
        for row in selected
    ]
    pending_cursor = {
        "version": 2,
        "lastProcessed": max(next_cursors.values()),
        "sources": next_cursors,
        "boundaryIds": next_boundary_ids,
        "boundaryStarts": next_boundary_starts,
        "committedAt": None,
    }
    atomic_json(Path(args.output), output)
    atomic_json(Path(args.pending_cursor), pending_cursor)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
