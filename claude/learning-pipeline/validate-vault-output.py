#!/usr/bin/env python3
"""Vault 학습 파이프라인의 입력과 생성 결과를 상태 차이로 검증한다.

오류에는 실제 경로와 일치한 값을 출력하지 않는다. 문서는 상대 경로의 SHA-256
별칭으로만 표시해, 파일명 자체에 식별정보가 있어도 로그에 다시 남지 않게 한다.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import unicodedata
from pathlib import Path, PurePosixPath
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vault-root", required=True)
    parser.add_argument("--baseline-state", required=True)
    parser.add_argument("--current-state", required=True)
    parser.add_argument("--mode", required=True, choices=("input", "workflow-output"))
    parser.add_argument("--allowed-path", action="append", default=[])
    parser.add_argument("--guard-path", action="append", default=[])
    return parser.parse_args()


def load_state(path: Path, label: str) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"{label} Vault 상태를 읽을 수 없음") from exc
    files = data.get("files") if isinstance(data, dict) else None
    if not isinstance(files, dict):
        raise ValueError(f"{label} Vault 상태의 files가 객체가 아님")
    normalized_files: dict[str, Any] = {}
    for relative, record in files.items():
        if not isinstance(relative, str):
            raise ValueError(f"{label} Vault 상태의 파일 경로가 문자열이 아님")
        normalized = unicodedata.normalize("NFC", relative)
        if normalized in normalized_files:
            raise ValueError(f"{label} Vault 상태에 정규화 충돌 경로가 있음")
        normalized_files[normalized] = record
    return normalized_files


def record_signature(record: Any) -> tuple[Any, Any, Any] | None:
    if not isinstance(record, dict):
        return None
    return record.get("sha256"), record.get("kind"), record.get("suffix")


def state_diff(
    baseline: dict[str, Any], current: dict[str, Any]
) -> tuple[list[str], list[str]]:
    changed = sorted(
        relative
        for relative, record in current.items()
        if relative not in baseline
        or record_signature(record) != record_signature(baseline.get(relative))
    )
    deleted = sorted(set(baseline) - set(current))
    return changed, deleted


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def document_alias(relative: str) -> str:
    digest = hashlib.sha256(relative.encode("utf-8", errors="replace")).hexdigest()
    return f"문서#{digest[:12]}"


def safe_vault_path(root: Path, relative: str) -> Path | None:
    candidate = PurePosixPath(relative)
    if candidate.is_absolute() or not candidate.parts or any(part in {"", ".", ".."} for part in candidate.parts):
        return None
    path = root.joinpath(*candidate.parts)
    current = root
    for part in candidate.parts[:-1]:
        current = current / part
        if current.is_symlink():
            return None
    try:
        path.relative_to(root)
    except ValueError:
        return None
    return path


def has_symlink_component(root: Path, relative: str) -> bool:
    candidate = PurePosixPath(relative)
    current = root
    for part in candidate.parts:
        current = current / part
        if current.is_symlink():
            return True
    return False


def normalize_allowed_paths(values: list[str]) -> set[str]:
    allowed: set[str] = set()
    for value in values:
        normalized = unicodedata.normalize("NFC", value)
        candidate = PurePosixPath(normalized)
        if (
            not normalized
            or "\\" in normalized
            or candidate.is_absolute()
            or not candidate.parts
            or any(part in {"", ".", ".."} for part in candidate.parts)
            or candidate.as_posix() != normalized
            or candidate.suffix.lower() != ".md"
        ):
            raise ValueError("허용 경로가 안전한 Vault 상대 Markdown 경로가 아님")
        allowed.add(normalized)
    return allowed


def is_semantic_record(record: Any) -> bool:
    return isinstance(record, dict) and record.get("semantic") is True


def rules() -> list[tuple[str, re.Pattern[str]]]:
    account = Path.home().name
    home = str(Path.home())
    patterns: list[tuple[str, re.Pattern[str]]] = [
        ("configured_home_absolute", re.compile(rf"{re.escape(home)}(?=/|\b)")),
        ("mac_home_absolute", re.compile(r"/Users/[^/\s`\"')\]]+")),
        ("linux_home_absolute", re.compile(r"/home/[^/\s`\"')\]]+")),
        ("windows_home_absolute", re.compile(r"[A-Za-z]:\\Users\\[^\\\s`\"')\]]+", re.IGNORECASE)),
        ("encoded_home_path", re.compile(r"-(?:Users|home)-[A-Za-z0-9._-]+", re.IGNORECASE)),
        ("uuid", re.compile(r"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b", re.IGNORECASE)),
        ("workflow_or_agent_id", re.compile(r"\b(?:wf_|agent-)[A-Za-z0-9-]{8,}\b", re.IGNORECASE)),
        ("session_id_field", re.compile(r"\bsession[_ -]?id\s*:", re.IGNORECASE)),
        ("email", re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")),
        ("phone", re.compile(r"(?<!\d)01[016789][ -]?\d{3,4}[ -]?\d{4}(?!\d)")),
        ("resident_id", re.compile(r"(?<!\d)\d{6}[ -]?[1-4]\d{6}(?!\d)")),
        (
            "known_secret_prefix",
            re.compile(
                r"\b(?:sk-(?:ant-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|"
                r"AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|xox[baprs]-[A-Za-z0-9-]{20,})\b"
            ),
        ),
    ]
    if account and account.lower() not in {"home", "user", "root", "tmp"}:
        patterns.append(
            (
                "local_account_name",
                re.compile(
                    rf"(?<![A-Za-z0-9._-]){re.escape(account)}(?![A-Za-z0-9._-])",
                    re.IGNORECASE,
                ),
            )
        )
    return patterns


def add_finding(
    findings: dict[str, dict[str, set[str]]],
    relative: str,
    rule_name: str,
    location: str = "상태",
) -> None:
    alias = document_alias(relative)
    findings.setdefault(alias, {}).setdefault(rule_name, set()).add(location)


def inspect_identifiers(
    findings: dict[str, dict[str, set[str]]],
    relative: str,
    path: Path,
    compiled_rules: list[tuple[str, re.Pattern[str]]],
    inspect_body: bool,
) -> None:
    for rule_name, pattern in compiled_rules:
        if pattern.search(relative):
            add_finding(findings, relative, rule_name, "파일명")
    if not inspect_body:
        return
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        add_finding(findings, relative, "unreadable_text")
        return
    for line_number, line in enumerate(lines, start=1):
        for rule_name, pattern in compiled_rules:
            if pattern.search(line):
                add_finding(findings, relative, rule_name, str(line_number))


def validate_changed_file(
    root: Path,
    relative: str,
    record: Any,
    mode: str,
    allowed_paths: set[str],
    findings: dict[str, dict[str, set[str]]],
    compiled_rules: list[tuple[str, re.Pattern[str]]],
) -> None:
    if mode == "workflow-output" and relative not in allowed_paths:
        add_finding(findings, relative, "outside_allowed_scope")

    path = safe_vault_path(root, relative)
    if path is None:
        add_finding(findings, relative, "unsafe_relative_path")
        return
    if not isinstance(record, dict):
        add_finding(findings, relative, "invalid_current_state_record")
        return

    expected_hash = record.get("sha256")
    if not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
        add_finding(findings, relative, "invalid_current_state_hash")
        return

    if path.is_symlink() or record.get("kind") == "link":
        add_finding(findings, relative, "symlink_not_allowed")
        return
    if not path.is_file():
        add_finding(findings, relative, "current_file_missing")
        return

    try:
        actual_hash = sha256(path)
    except OSError:
        add_finding(findings, relative, "current_file_unreadable")
        return
    if actual_hash != expected_hash:
        add_finding(findings, relative, "state_hash_mismatch")
        return

    suffix = PurePosixPath(relative).suffix.lower()
    if mode == "workflow-output" and suffix != ".md":
        add_finding(findings, relative, "non_markdown_not_allowed")
        return

    # input에서 generated 문서는 경로·변경 사실만 전달되므로 파일명만 검사한다.
    # human semantic 문서(.md/.txt/.canvas)와 canonical 3종은 본문까지 LLM이 읽는다.
    inspect_body = mode == "workflow-output" or record.get("authorship") != "generated"
    inspect_identifiers(findings, relative, path, compiled_rules, inspect_body)


def main() -> int:
    args = parse_args()
    root = Path(args.vault_root).expanduser().resolve()
    if not root.is_dir():
        print("ERROR: Vault 루트를 찾을 수 없음", file=sys.stderr)
        return 2

    try:
        baseline = load_state(Path(args.baseline_state).expanduser().resolve(), "기준")
        current = load_state(Path(args.current_state).expanduser().resolve(), "현재")
        allowed_paths = normalize_allowed_paths(args.allowed_path) if args.mode == "workflow-output" else set()
        guard_paths = normalize_allowed_paths(args.guard_path) | allowed_paths
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    changed, deleted = state_diff(baseline, current)
    if args.mode == "input":
        selected_changed = [relative for relative in changed if is_semantic_record(current.get(relative))]
        selected_deleted = [relative for relative in deleted if is_semantic_record(baseline.get(relative))]
    else:
        selected_changed = changed
        selected_deleted = deleted

    findings: dict[str, dict[str, set[str]]] = {}
    compiled_rules = rules()
    for relative in sorted(guard_paths):
        if safe_vault_path(root, relative) is None or has_symlink_component(root, relative):
            add_finding(findings, relative, "symlink_or_unsafe_path_component")
    for relative in selected_changed:
        validate_changed_file(
            root,
            relative,
            current.get(relative),
            args.mode,
            allowed_paths,
            findings,
            compiled_rules,
        )

    if args.mode == "workflow-output":
        for relative in selected_deleted:
            add_finding(findings, relative, "deletion_not_allowed")
            if relative not in allowed_paths:
                add_finding(findings, relative, "outside_allowed_scope")
    else:
        # 삭제된 semantic 문서는 본문이 없지만 경로는 입력 데이터셋에 포함된다.
        for relative in selected_deleted:
            for rule_name, pattern in compiled_rules:
                if pattern.search(relative):
                    add_finding(findings, relative, rule_name, "파일명")

    if findings:
        print(
            f"ERROR: Vault {args.mode} 검사 실패 — 변경 문서 {len(findings)}개",
            file=sys.stderr,
        )
        for alias, matches in sorted(findings.items()):
            summary = ", ".join(
                f"{name}@{','.join(sorted(locations, key=lambda value: (not value.isdigit(), value)))}"
                for name, locations in sorted(matches.items())
            )
            print(f"- {alias}: {summary}", file=sys.stderr)
        return 1

    print(
        f"Vault {args.mode} 검사 통과 — 상태 변경 {len(changed) + len(deleted)}개, 검사 문서 {len(selected_changed)}개"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
