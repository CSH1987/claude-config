#!/usr/bin/env bash
# claude-config:vault-session-log — SessionEnd 훅. 매 세션 종료마다 Vault(90_Hermes/로그)에
#   "세션이 있었다"는 사실만 기계적으로 남기는 경량 브레드크럼(LLM 호출 없음, 비용 0).
#   OMC wiki(.omc/wiki/)의 session-end 캡처와 같은 설계: 여기엔 요약을 안 만들고, 나중에
#   사람 또는 Claude가 필요하면 이 스텁의 종료시각으로 기기 로컬 원본 세션을 찾아 승격한다.
#   깊은 패턴 분석은 이 훅의 역할이 아니다 — 그건 이미 있는 주간 학습파이프라인이 한다
#   (learning-pipeline-setup.sh). 이 훅은 "매 세션마다 즉시" 축을, 파이프라인은 "주 1회 깊게"
#   축을 맡아 서로 보완한다.
# 머신게이트: vault-context.sh와 동일 컨벤션(맥미니 아니면 조용히 스킵 — fail-silent).
# 절대경로·센티널 검증도 vault-context.sh/guardrails.py의 _ev_config()와 동일 기준을 따른다
# (단 SessionEnd 엔 경고 주입 채널이 없어 emit 대신 조용히 exit 0 — fail-loud 대신 fail-silent,
#  코드리뷰로 확인된 올바른 선택).
# 자동 정리: guardrails.py 의 볼트 전역 delete 차단 때문에 Claude 는 이 로그를 영구히 못 지운다
# (실측 확인됨) — 이 훅 자체는 그 감시 범위 밖(Claude 대화형 Bash 호출이 아님)이라 여기서만
# 오래된 스텁을 정리할 수 있다. 90일 초과분만 정리(승격 검토할 시간은 충분히 줌).
# 세션 종료를 절대 막지 않는다 — 항상 exit 0. 헤드리스 내부 실행은
# CLAUDE_VAULT_SESSION_LOG_OFF=1로 자기참조 로그를 만들지 않는다.
set -u

[ "${CLAUDE_VAULT_SESSION_LOG_OFF:-}" = "1" ] && exit 0

ai_system="${1:-claude-code}"
case "$ai_system" in
  codex|claude-code) : ;;
  *) ai_system="claude-code" ;;
esac

host="$(hostname 2>/dev/null || echo '')"
case "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" in
  *macmini*) : ;;
  *) exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SCOPE_FILE="$HOME/.claude/vault-scope.json"
[ -f "$SCOPE_FILE" ] || exit 0

VAULT="$(python3 -c "
import json, os, sys
try:
    cfg = json.load(open(sys.argv[1], encoding='utf-8'))
    v = cfg.get('vaultPath', '')
    print(os.path.expanduser(v) if v else '')
except Exception:
    print('')
" "$SCOPE_FILE" 2>/dev/null)"
[ -n "$VAULT" ] && [ -d "$VAULT" ] || exit 0

# 절대경로만 허용(상대경로면 cwd 기준으로 비결정적 참조 — vault-context.sh와 동일 이유)
case "$VAULT" in
  /*) : ;;
  *) exit 0 ;;
esac

# 센티널(00_홈.md H1) 확인 — 우연히 같은 이름의 무관 디렉터리를 볼트로 오인하지 않도록
SENTINEL="$VAULT/00_홈.md"
[ -f "$SENTINEL" ] && head -1 "$SENTINEL" 2>/dev/null | grep -qE '^#[[:space:]].*에버스 위키 홈' || exit 0

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$session_id" ] && exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
reason=$(printf '%s' "$input" | jq -r '.reason // "other"' 2>/dev/null || echo "other")

# Vault에 로컬 계정명·프로젝트명·절대 홈 경로·전체 세션 UUID를 복사하지 않는다.
# 위치는 범주만 남기고, 종료 사유도 Claude Code가 정의한 값만 허용한다.
case "$cwd" in
  "$HOME") work_location="홈" ;;
  "$HOME"/*) work_location="홈 내부 작업공간" ;;
  "") work_location="(알 수 없음)" ;;
  *) work_location="홈 외부 작업공간" ;;
esac
case "$reason" in
  clear|logout|prompt_input_exit|other) : ;;
  *) reason="other" ;;
esac
if [ "$ai_system" = "codex" ]; then
  transcript_hint="~/.codex/sessions/YYYY/MM/DD/*.jsonl"
else
  transcript_hint="~/.claude/projects/*/*.jsonl"
fi

today="$(date +%Y-%m-%d 2>/dev/null || echo unknown-date)"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$today")"
now_compact="$(date -u +%H%M%S 2>/dev/null || echo unknown-time)"
log_dir="$VAULT/90_Hermes/로그"
mkdir -p "$log_dir" 2>/dev/null || exit 0

# 원본 session ID는 로컬 전용 중복 방지 키의 해시로만 쓴다. Vault/Git에는 이 값도
# 남기지 않는다. 같은 세션의 지연 재호출은 차단하고 서로 다른 동시 세션은 모두 보존한다.
dedup_root="$HOME/.claude/vault-session-log-state"
mkdir -p "$dedup_root" 2>/dev/null || exit 0
chmod 700 "$dedup_root" 2>/dev/null || true
session_digest=$(printf '%s' "${ai_system}\0${session_id}" | shasum -a 256 2>/dev/null | awk '{print $1}')
[ -n "$session_digest" ] || exit 0
find "$dedup_root" -mindepth 1 -maxdepth 1 -type d -mtime +90 -exec rmdir {} \; 2>/dev/null || true
dedup_marker="$dedup_root/$session_digest"
mkdir "$dedup_marker" 2>/dev/null || exit 0
chmod 700 "$dedup_marker" 2>/dev/null || true

# 오래된 스텁 정리(90일 초과) — Claude 는 못 하니 이 훅에서만 가능
find "$log_dir" -maxdepth 1 -name 'session-*.md' -type f -mtime +90 -delete 2>/dev/null || true

# UTC 종료시각과 무작위 로컬 nonce로 서로 다른 동시 세션을 충돌 없이 구분한다.
# nonce는 세션 ID에서 파생하지 않으므로 교차 추적 식별자가 아니다.
prefix="session"
[ "$ai_system" = "codex" ] && prefix="session-codex"
tmp=$(mktemp "$log_dir/${prefix}-${today}-${now_compact}.XXXXXX" 2>/dev/null) || {
  rmdir "$dedup_marker" 2>/dev/null || true
  exit 0
}
target="$tmp.md"
{
  cat <<EOF
---
title: 세션 로그 ${today} (${ai_system})
created: ${today}
updated: ${today}
category: 세션로그
status: raw
tags: [세션로그, 자동캡처]
related: []
source: vault-session-log.sh (SessionEnd, LLM 호출 없음)
ai_system: ${ai_system}
---

# 세션 로그 ${today} — ${ai_system}

자동 캡처된 세션 메타데이터. 요약이 아니라 브레드크럼입니다.

- AI 시스템: ${ai_system}
- 작업 위치: ${work_location}
- 종료 사유: ${reason}
- 종료 시각(UTC): ${now_iso}

의미 있는 내용이 있으면 로컬 원본 세션(\`${transcript_hint}\`)을 찾아 20_업무위키 또는 30_결정로그에 직접 승격하세요.
EOF
} 2>/dev/null > "$tmp" || {
  rm -f "$tmp" 2>/dev/null
  rmdir "$dedup_marker" 2>/dev/null || true
  exit 0
}
chmod 600 "$tmp" 2>/dev/null || true
if ! mv -f "$tmp" "$target" 2>/dev/null; then
  rm -f "$tmp" 2>/dev/null
  rmdir "$dedup_marker" 2>/dev/null || true
fi

exit 0
