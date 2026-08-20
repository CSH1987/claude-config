#!/usr/bin/env bash
# Codex SessionStart: 공통 규칙을 최신화하고 Vault 전체 지도+패턴 정본을 주입한다.
# 실패해도 Codex 세션을 막지 않는다.
set -u

command -v python3 >/dev/null 2>&1 || exit 0

repo_dir=""
pointer="$HOME/.claude/.config-sync-path"
[ -f "$pointer" ] && repo_dir="$(cat "$pointer" 2>/dev/null || true)"
[ -z "$repo_dir" ] && repo_dir="$HOME/claude-config"

codex_dir="${CODEX_HOME:-$HOME/.codex}"
sync_script="$repo_dir/claude/hooks/codex-sync.sh"
indexer="$repo_dir/claude/hooks/vault-index.py"
catalog="$repo_dir/claude/hooks/vault-catalog.py"
scope_file="$HOME/.claude/vault-scope.json"
learning_state="$HOME/.claude/learning-pipeline/vault-state.json"

[ -x "$sync_script" ] && "$sync_script" "$codex_dir" "$repo_dir/claude" >/dev/null 2>&1 || true
[ -f "$scope_file" ] && [ -f "$indexer" ] && [ -f "$catalog" ] || exit 0

vault="$(python3 - "$scope_file" <<'PY' 2>/dev/null || true
import json, os, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8")).get("vaultPath", "")
    print(os.path.expanduser(value) if isinstance(value, str) else "")
except Exception:
    pass
PY
)"
case "$vault" in /*) : ;; *) exit 0 ;; esac
[ -f "$vault/00_홈.md" ] && [ -d "$vault/10_컨텍스트" ] || exit 0

overview="$(python3 "$catalog" "$vault" --overview --state "$learning_state" 2>/dev/null || true)"
patterns="$(python3 "$indexer" "$vault/10_컨텍스트" 2>/dev/null || true)"
[ -n "$overview$patterns" ] || exit 0

printf '%s\n\n%s\n\n%s\n' \
  "$overview" \
  "$patterns" \
  '[Codex Vault 선행 절차] 패턴 요약만으로 단정하지 말고, 비자명한 요청은 답변 전에 Vault 전체를 검색해 관련 원문을 읽으세요. 새 지속 패턴은 현재 턴에 10_컨텍스트에 반영하세요.'
exit 0
