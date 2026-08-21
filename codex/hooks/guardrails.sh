#!/usr/bin/env bash
# Codex PreToolUse guardrail. 오류나 의존성 누락은 도구를 막지 않는 fail-open 계약이다.
set -u

command -v python3 >/dev/null 2>&1 || exit 0
script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[ -n "$script_dir" ] && [ -f "$script_dir/guardrails.py" ] || exit 0
python3 "$script_dir/guardrails.py" 2>/dev/null || true
exit 0
