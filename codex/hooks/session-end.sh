#!/usr/bin/env bash
# Codex SessionEnd 입력을 공용 Vault 브레드크럼 로거로 전달한다.
set -u

repo_dir=""
pointer="$HOME/.claude/.config-sync-path"
[ -f "$pointer" ] && repo_dir="$(cat "$pointer" 2>/dev/null || true)"
[ -z "$repo_dir" ] && repo_dir="$HOME/claude-config"
logger="$repo_dir/claude/hooks/vault-session-log.sh"

[ -x "$logger" ] || exit 0
"$logger" codex
exit 0
