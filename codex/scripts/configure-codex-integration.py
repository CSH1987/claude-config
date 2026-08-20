#!/usr/bin/env python3
"""claude-config의 Codex 네이티브 설정을 사용자 설정과 병합한다.

공개 저장소에는 비밀을 넣지 않는다. Obsidian Local REST API 키는 이 장치의
플러그인 data.json에서 읽어 이 장치의 mode 600 config.toml에만 쓴다.
stdout에는 키·Authorization·URL을 출력하지 않는다.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # Python 3.10 설치도 지원하는 레포 계약
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except ModuleNotFoundError:
        tomllib = None  # type: ignore[assignment]


COMPACT_PROMPT = (
    "압축할 때 다음 네 항목을 우선 보존한다: "
    "1) 진행 중 작업의 현재 상태와 다음 단계, "
    "2) 변경한 파일과 핵심 내용, "
    "3) 테스트 결과와 실패 원문 경로, "
    "4) 사용자가 확정한 결정과 이유. "
    "중간 탐색과 중복 출력은 줄이고, Vault 전체 지도와 10_컨텍스트는 compact 뒤 SessionStart 훅이 다시 넣는다."
)
MANAGED_HOOK_COMMANDS = {
    'bash "$HOME/.codex/hooks/session-context.sh"',
    'bash "$HOME/.codex/hooks/session-end.sh"',
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-home", default=os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    parser.add_argument("--repo-dir", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--vault-scope", default=str(Path.home() / ".claude" / "vault-scope.json"))
    parser.add_argument("--no-backup", action="store_true")
    return parser.parse_args()


def read_text(path: Path, default: str = "") -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return default


def atomic_text(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def section_bounds(lines: list[str], section: str) -> tuple[int, int] | None:
    header = f"[{section}]"
    start = None
    for index, line in enumerate(lines):
        if line.strip() == header:
            start = index
            break
    if start is None:
        return None
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if re.match(r"^\s*\[.+\]\s*(?:#.*)?$", lines[index]):
            end = index
            break
    return start, end


def upsert_section_keys(text: str, section: str, values: dict[str, str]) -> str:
    lines = text.splitlines()
    bounds = section_bounds(lines, section)
    if bounds is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.append(f"[{section}]")
        lines.extend(f"{key} = {value}" for key, value in values.items())
        return "\n".join(lines).rstrip() + "\n"

    start, end = bounds
    for key, value in values.items():
        pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
        matches = [index for index in range(start + 1, end) if pattern.match(lines[index])]
        replacement = f"{key} = {value}"
        if matches:
            lines[matches[0]] = replacement
            for index in reversed(matches[1:]):
                del lines[index]
                end -= 1
        else:
            lines.insert(end, replacement)
            end += 1
    return "\n".join(lines).rstrip() + "\n"


def upsert_top_level_key(text: str, key: str, value: str) -> str:
    lines = text.splitlines()
    first_section = next((i for i, line in enumerate(lines) if re.match(r"^\s*\[.+\]", line)), len(lines))
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
    matches = [index for index in range(first_section) if pattern.match(lines[index])]
    replacement = f"{key} = {value}"
    if matches:
        lines[matches[0]] = replacement
        for index in reversed(matches[1:]):
            del lines[index]
    else:
        insertion = first_section
        if insertion and lines[insertion - 1].strip():
            lines.insert(insertion, "")
            insertion += 1
        lines.insert(insertion, replacement)
    return "\n".join(lines).rstrip() + "\n"


def remove_mcp_section(text: str, name: str) -> str:
    lines = text.splitlines()
    prefix = f"mcp_servers.{name}"
    kept: list[str] = []
    skipping = False
    for line in lines:
        match = re.match(r"^\s*\[([^]]+)\]\s*(?:#.*)?$", line)
        if match:
            section = match.group(1).strip()
            skipping = section == prefix or section.startswith(prefix + ".")
        if not skipping:
            kept.append(line)
    return "\n".join(kept).rstrip() + "\n"


def load_vault_path(scope_path: Path) -> Path | None:
    try:
        data = json.loads(scope_path.read_text(encoding="utf-8"))
        value = data.get("vaultPath")
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None
    if not isinstance(value, str) or not value:
        return None
    path = Path(value).expanduser()
    if not path.is_absolute() or not (path / "00_홈.md").is_file():
        return None
    return path


def obsidian_mcp_settings(vault_path: Path | None) -> tuple[str, str] | None:
    if vault_path is None:
        return None
    data_path = vault_path / ".obsidian" / "plugins" / "obsidian-local-rest-api" / "data.json"
    try:
        data = json.loads(data_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None
    api_key = data.get("apiKey")
    if not isinstance(api_key, str) or not api_key.strip():
        return None
    if data.get("enableInsecureServer") is True:
        port = data.get("insecurePort", 27123)
        if isinstance(port, int) and 1 <= port <= 65535:
            return f"http://127.0.0.1:{port}/mcp/", api_key.strip()
    port = data.get("port", 27124)
    if isinstance(port, int) and 1 <= port <= 65535:
        return f"https://127.0.0.1:{port}/mcp/", api_key.strip()
    return None


def build_config(existing: str, mcp: tuple[str, str] | None) -> tuple[str, str]:
    text = existing
    text = upsert_top_level_key(text, "compact_prompt", json.dumps(COMPACT_PROMPT, ensure_ascii=False))
    text = upsert_section_keys(text, "features", {"hooks": "true", "memories": "true"})
    text = upsert_section_keys(
        text,
        "memories",
        {
            "generate": "true",
            "use": "true",
            "disable_on_external_context": "false",
            "min_rate_limit_remaining_percent": "25",
        },
    )
    mcp_status = "preserved"
    if mcp is not None:
        url, api_key = mcp
        text = remove_mcp_section(text, "vault-obsidian")
        if text and not text.endswith("\n\n"):
            text = text.rstrip() + "\n\n"
        authorization = "Bearer " + api_key
        text += "\n".join(
            [
                "[mcp_servers.vault-obsidian]",
                f"url = {json.dumps(url)}",
                f"http_headers = {{ Authorization = {json.dumps(authorization)} }}",
                "enabled = true",
                "required = false",
                "startup_timeout_sec = 10",
                "tool_timeout_sec = 60",
                "",
            ]
        )
        mcp_status = "configured"
    if tomllib is not None:
        tomllib.loads(text)
    return text, mcp_status


def handler_commands(group: Any) -> set[str]:
    if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
        return set()
    return {
        handler.get("command")
        for handler in group["hooks"]
        if isinstance(handler, dict) and isinstance(handler.get("command"), str)
    }


def build_hooks(existing: str, template_path: Path) -> str:
    try:
        current = json.loads(existing) if existing.strip() else {}
    except json.JSONDecodeError as error:
        raise ValueError(f"기존 hooks.json 파싱 실패: {error}") from error
    template = json.loads(template_path.read_text(encoding="utf-8"))
    if not isinstance(current, dict):
        current = {}
    current_hooks = current.setdefault("hooks", {})
    if not isinstance(current_hooks, dict):
        current_hooks = {}
        current["hooks"] = current_hooks

    for event, managed_groups in template.get("hooks", {}).items():
        existing_groups = current_hooks.get(event, [])
        if not isinstance(existing_groups, list):
            existing_groups = []
        preserved = [group for group in existing_groups if not (handler_commands(group) & MANAGED_HOOK_COMMANDS)]
        preserved.extend(managed_groups)
        current_hooks[event] = preserved
    current.setdefault("description", "claude-config가 관리하는 Codex lifecycle hooks")
    return json.dumps(current, ensure_ascii=False, indent=2) + "\n"


def backup_changed(paths: list[Path], codex_home: Path, disabled: bool) -> Path | None:
    existing = [path for path in paths if path.is_file()]
    if disabled or not existing:
        return None
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_dir = codex_home / "backups" / f"{stamp}-before-context-port"
    suffix = 0
    while backup_dir.exists():
        suffix += 1
        backup_dir = codex_home / "backups" / f"{stamp}-before-context-port-{suffix}"
    backup_dir.mkdir(parents=True, exist_ok=False)
    os.chmod(backup_dir, 0o700)
    for path in existing:
        destination = backup_dir / path.name
        shutil.copy2(path, destination)
        os.chmod(destination, 0o600)
    return backup_dir


def main() -> int:
    args = parse_args()
    codex_home = Path(args.codex_home).expanduser().resolve()
    repo_dir = Path(args.repo_dir).expanduser().resolve()
    config_path = codex_home / "config.toml"
    hooks_path = codex_home / "hooks.json"
    template_path = repo_dir / "codex" / "hooks.json"
    codex_home.mkdir(parents=True, exist_ok=True)

    existing_config = read_text(config_path)
    existing_hooks = read_text(hooks_path)
    vault_path = load_vault_path(Path(args.vault_scope).expanduser())
    mcp = obsidian_mcp_settings(vault_path)
    new_config, mcp_status = build_config(existing_config, mcp)
    new_hooks = build_hooks(existing_hooks, template_path)

    changed_paths = []
    if new_config != existing_config:
        changed_paths.append(config_path)
    if new_hooks != existing_hooks:
        changed_paths.append(hooks_path)
    backup_dir = backup_changed(changed_paths, codex_home, args.no_backup)

    if new_config != existing_config:
        atomic_text(config_path, new_config)
    elif config_path.exists():
        os.chmod(config_path, 0o600)
    if new_hooks != existing_hooks:
        atomic_text(hooks_path, new_hooks)
    elif hooks_path.exists():
        os.chmod(hooks_path, 0o600)

    print(f"codex-config={'updated' if new_config != existing_config else 'unchanged'}")
    print(f"codex-hooks={'updated' if new_hooks != existing_hooks else 'unchanged'}")
    print(f"vault-mcp={mcp_status if mcp is not None else 'waiting-for-obsidian'}")
    print(f"backup={'created' if backup_dir is not None else 'not-needed'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
