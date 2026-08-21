#!/usr/bin/env python3
"""Vault 전체 파일을 빠짐없이 목록화하고, 패턴 학습용 변경분을 만든다.

원칙:
- `.git`은 전송 장치의 내부 자료라 Vault 내용에서 제외한다.
- 나머지 파일은 모두 인벤토리에 넣는다.
- 사람이 작성한 텍스트는 본문까지 변경분에 넣는다. AI 생성 폴더는 목록·변경 사실만
  넣고 본문은 다시 학습시키지 않아 자기복제와 토큰 낭비를 막는다.
- Obsidian 설정·플러그인·시크릿 후보·바이너리는 메타데이터만 기록한다.
- stdout의 overview에는 파일명·본문·시크릿을 내보내지 않는다.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
import unicodedata
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STATE_VERSION = 1
TEXT_SUFFIXES = {".md", ".txt", ".canvas"}
GENERATED_PREFIXES = (
    "90_Hermes/로그/",
    "90_Hermes/보고서/",
    "90_Hermes/라우팅제안/",
    "90_Hermes/일일요약/",
    "90_Hermes/학습이력/",
)
CANONICAL_CONTEXT_PATHS = {
    "10_컨텍스트/AI_협업_패턴.md",
    "10_컨텍스트/업무_원칙_방법론.md",
    "10_컨텍스트/강점_약점_보완.md",
}
SENSITIVE_EXACT_PATHS = {".obsidian/plugins/obsidian-local-rest-api/data.json"}
SENSITIVE_DIRECTORIES = {"credentials", "secrets", ".secrets"}
SENSITIVE_BASENAMES = {
    "credential.json",
    "credentials.json",
    "credentials.yaml",
    "credentials.yml",
    "credentials.toml",
    "secret.json",
    "secrets.json",
    "token.json",
    "api-key.json",
    "apikey.json",
}


def utc_iso(timestamp: float | None = None) -> str:
    value = datetime.fromtimestamp(timestamp, timezone.utc) if timestamp is not None else datetime.now(timezone.utc)
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def normalized_relative(path: Path, root: Path) -> str:
    return unicodedata.normalize("NFC", path.relative_to(root).as_posix())


def is_sensitive(relative_path: str) -> bool:
    lowered = relative_path.lower()
    parts = lowered.split("/")
    basename = parts[-1]
    return (
        lowered in SENSITIVE_EXACT_PATHS
        or any(part in SENSITIVE_DIRECTORIES for part in parts[:-1])
        or basename in SENSITIVE_BASENAMES
        or basename == ".env"
        or basename.startswith(".env.")
    )


def classify(relative_path: str, suffix: str) -> tuple[str, str]:
    if is_sensitive(relative_path):
        return "sensitive", "system"
    if relative_path.startswith(".obsidian/"):
        return "environment", "system"
    if suffix in TEXT_SUFFIXES:
        authorship = "generated" if relative_path.startswith(GENERATED_PREFIXES) else "human"
        return "knowledge", authorship
    return "attachment", "human"


def read_bytes_and_hash(path: Path) -> tuple[bytes, str]:
    content = path.read_bytes()
    return content, hashlib.sha256(content).hexdigest()


def vault_entries(root: Path, strict: bool = False) -> list[Path]:
    """`.git`은 순회 자체를 하지 않고, symlink는 링크 항목으로만 돌려준다."""
    entries: list[Path] = []

    def traversal_error(error: OSError) -> None:
        if strict:
            raise error

    for directory, dirnames, filenames in os.walk(root, followlinks=False, onerror=traversal_error):
        current = Path(directory)
        kept_directories: list[str] = []
        for name in sorted(dirnames):
            if name == ".git":
                continue
            candidate = current / name
            if candidate.is_symlink():
                entries.append(candidate)
            else:
                kept_directories.append(name)
        dirnames[:] = kept_directories
        entries.extend(current / name for name in sorted(filenames))
    return sorted(entries, key=lambda item: unicodedata.normalize("NFC", item.as_posix()))


def scan_once(root: Path, strict: bool = False) -> dict[str, Any]:
    files: dict[str, dict[str, Any]] = {}
    section_counts: Counter[str] = Counter()
    kind_counts: Counter[str] = Counter()
    semantic_count = 0
    fingerprint = hashlib.sha256()

    for path in vault_entries(root, strict=strict):
        if path.is_symlink():
            relative_path = normalized_relative(path, root)
            try:
                link_target = os.readlink(path)
                stat = path.lstat()
            except OSError:
                if strict:
                    raise
                continue
            digest = hashlib.sha256(link_target.encode("utf-8", errors="replace")).hexdigest()
            section = relative_path.split("/", 1)[0]
            section_counts[section] += 1
            kind_counts["link"] += 1
            files[relative_path] = {
                "sha256": digest,
                "size": stat.st_size,
                "mtime": utc_iso(stat.st_mtime),
                "suffix": path.suffix.lower() or "[none]",
                "kind": "link",
                "authorship": "system",
                "semantic": False,
            }
            fingerprint.update(relative_path.encode("utf-8"))
            fingerprint.update(b"\0")
            fingerprint.update(digest.encode("ascii"))
            fingerprint.update(b"\0")
            continue
        if not path.is_file():
            continue
        relative_path = normalized_relative(path, root)
        if relative_path == ".git" or relative_path.startswith(".git/"):
            continue
        try:
            content, digest = read_bytes_and_hash(path)
            stat = path.stat()
        except OSError:
            if strict:
                raise
            continue
        suffix = path.suffix.lower()
        kind, authorship = classify(relative_path, suffix)
        semantic = kind == "knowledge" and suffix in TEXT_SUFFIXES
        section = relative_path.split("/", 1)[0]
        section_counts[section] += 1
        kind_counts[kind] += 1
        semantic_count += int(semantic)
        record = {
            "sha256": digest,
            "size": len(content),
            "mtime": utc_iso(stat.st_mtime),
            "suffix": suffix or "[none]",
            "kind": kind,
            "authorship": authorship,
            "semantic": semantic,
        }
        files[relative_path] = record
        fingerprint.update(relative_path.encode("utf-8"))
        fingerprint.update(b"\0")
        fingerprint.update(digest.encode("ascii"))
        fingerprint.update(b"\0")

    return {
        "version": STATE_VERSION,
        "generatedAt": utc_iso(),
        "vaultFingerprint": fingerprint.hexdigest(),
        "counts": {
            "files": len(files),
            "semanticDocuments": semantic_count,
            "byKind": dict(sorted(kind_counts.items())),
            "bySection": dict(sorted(section_counts.items())),
        },
        "files": files,
    }


def scan(root: Path, strict: bool = False) -> dict[str, Any]:
    """Obsidian/Git 동기화 중간 상태를 피하려고 안정된 두 스캔을 찾는다."""
    previous = scan_once(root, strict=strict)
    for _ in range(2):
        current = scan_once(root, strict=strict)
        if current.get("vaultFingerprint") == previous.get("vaultFingerprint"):
            return current
        previous = current
    if strict:
        raise RuntimeError("Vault snapshot did not stabilize")
    return previous


def load_state(path: Path | None) -> dict[str, Any]:
    if path is None or not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def atomic_json(path: Path, value: Any, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def changed_paths(current: dict[str, Any], previous: dict[str, Any]) -> tuple[list[str], list[str]]:
    current_files = current.get("files", {}) if isinstance(current.get("files"), dict) else {}
    previous_files = previous.get("files", {}) if isinstance(previous.get("files"), dict) else {}
    changed = [
        path
        for path, record in current_files.items()
        if not isinstance(previous_files.get(path), dict)
        or previous_files[path].get("sha256") != record.get("sha256")
    ]
    deleted = sorted(set(previous_files) - set(current_files))
    return sorted(changed), deleted


def decode_semantic_document(path: Path, expected_hash: str) -> str | None:
    try:
        content = path.read_bytes()
        if hashlib.sha256(content).hexdigest() != expected_hash:
            return None
        return content.decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def make_changes(root: Path, current: dict[str, Any], previous: dict[str, Any]) -> dict[str, Any]:
    changed, deleted = changed_paths(current, previous)
    previous_files = previous.get("files", {}) if isinstance(previous.get("files"), dict) else {}
    current_files = current.get("files", {}) if isinstance(current.get("files"), dict) else {}
    documents: list[dict[str, Any]] = []
    metadata_only = 0

    for relative_path in changed:
        record = current_files[relative_path]
        if not record.get("semantic"):
            metadata_only += 1
            continue
        authorship = record.get("authorship", "human")
        if authorship == "generated" or relative_path in CANONICAL_CONTEXT_PATHS:
            text = ""
        else:
            text = decode_semantic_document(root / relative_path, str(record.get("sha256", "")))
            if text is None:
                raise RuntimeError("human semantic document decode failed")
        if authorship == "generated":
            content_policy = "generated-metadata-only"
        elif relative_path in CANONICAL_CONTEXT_PATHS:
            content_policy = "canonical-read-separately"
        else:
            content_policy = "full-text"
        documents.append(
            {
                "source": "vault-document",
                "path": relative_path,
                "ts": record.get("mtime"),
                "status": "changed" if relative_path in previous_files else "added",
                "authorship": authorship,
                "text": text,
                "contentPolicy": content_policy,
            }
        )

    for relative_path in deleted:
        old = previous_files.get(relative_path, {})
        if old.get("semantic"):
            documents.append(
                {
                    "source": "vault-document",
                    "path": relative_path,
                    "ts": current.get("generatedAt"),
                    "status": "deleted",
                    "authorship": old.get("authorship", "human"),
                    "text": "",
                }
            )
        else:
            metadata_only += 1

    return {
        "version": STATE_VERSION,
        "initialFullScan": not bool(previous),
        "inventory": current.get("counts", {}),
        "vaultFingerprint": current.get("vaultFingerprint", ""),
        "metadataOnlyChanges": metadata_only,
        "changes": documents,
    }


def overview(current: dict[str, Any], analyzed: dict[str, Any]) -> str:
    counts = current.get("counts", {})
    kinds = counts.get("byKind", {}) if isinstance(counts.get("byKind"), dict) else {}
    sections = counts.get("bySection", {}) if isinstance(counts.get("bySection"), dict) else {}
    changed, deleted = changed_paths(current, analyzed)
    status = "분석 완료 상태와 일치" if not changed and not deleted and analyzed else f"미분석 변경 {len(changed) + len(deleted)}개"
    if not analyzed:
        status = "최초 전체 패턴 분석 대기"
    section_text = ", ".join(f"{name} {count}" for name, count in sections.items()) or "없음"
    fingerprint = str(current.get("vaultFingerprint", ""))[:12]
    return "\n".join(
        [
            f"[Vault 전체 파악] 파일 {counts.get('files', 0)}개 · 본문 분석 문서 {counts.get('semanticDocuments', 0)}개 · 환경설정 {kinds.get('environment', 0)}개 · 비밀 메타데이터 {kinds.get('sensitive', 0)}개 · 첨부/기타 {kinds.get('attachment', 0)}개",
            f"- 전체 범위: {section_text}",
            f"- 내용 지문: {fingerprint or '없음'} · 패턴 상태: {status}",
            "- 모든 원문은 동기화·검색 범위다. 아래 패턴 요약을 먼저 적용하고, 비자명한 답변 전에는 Vault 전체에서 관련 원문을 검색해 직접 읽는다.",
        ]
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("vault_root")
    parser.add_argument("--state")
    parser.add_argument("--pending-state")
    parser.add_argument("--documents-out")
    parser.add_argument("--catalog-out")
    parser.add_argument("--overview", action="store_true")
    parser.add_argument("--strict", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(args.vault_root).expanduser().resolve()
    if not root.is_dir():
        return 0
    current = scan(root, strict=args.strict)
    state_path = Path(args.state).expanduser() if args.state else None
    previous = load_state(state_path)
    # decode 같은 후속 검증이 실패해도 state/documents 한쪽만 교체되지 않도록 모든
    # 산출물을 메모리에서 먼저 완성한 뒤 원자적으로 기록한다.
    documents = make_changes(root, current, previous) if args.documents_out else None

    if args.catalog_out:
        atomic_json(Path(args.catalog_out).expanduser(), current)
    if args.pending_state:
        atomic_json(Path(args.pending_state).expanduser(), current)
    if args.documents_out and documents is not None:
        atomic_json(Path(args.documents_out).expanduser(), documents)
    if args.overview:
        print(overview(current, previous))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        # SessionStart 지도는 fail-open, 커서가 걸린 학습 수집은 --strict로 fail-closed.
        if "--strict" in sys.argv:
            print("ERROR: Vault 카탈로그를 완전하게 생성하지 못함", file=sys.stderr)
            raise SystemExit(1)
        raise SystemExit(0)
