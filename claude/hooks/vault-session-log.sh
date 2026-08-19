#!/usr/bin/env bash
# claude-config:vault-session-log — SessionEnd 훅. 매 세션 종료마다 Vault(90_Hermes/로그)에
#   "세션이 있었다"는 사실만 기계적으로 남기는 경량 브레드크럼(LLM 호출 없음, 비용 0).
#   OMC wiki(.omc/wiki/)의 session-end 캡처와 같은 설계: 여기엔 요약을 안 만들고, 나중에
#   사람 또는 Claude가 필요하면 이 스텁을 보고 원본 세션(transcript_path)을 찾아가서 승격한다.
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
# 세션 종료를 절대 막지 않는다 — 항상 exit 0.
set -u

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
safe_id=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')  # 레포 컨벤션(context-notify.sh/statusline.sh)과 동일 소독

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
project="${cwd##*/}"
[ -z "$project" ] && project="(알수없음)"
reason=$(printf '%s' "$input" | jq -r '.reason // "other"' 2>/dev/null || echo "other")
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
[ -z "$transcript" ] && transcript="~/.claude/projects/*/${session_id}.jsonl"  # stdin 에 없을 때만 추정치로 폴백

today="$(date +%Y-%m-%d 2>/dev/null || echo unknown-date)"
log_dir="$VAULT/90_Hermes/로그"
mkdir -p "$log_dir" 2>/dev/null || exit 0

# 오래된 스텁 정리(90일 초과) — Claude 는 못 하니 이 훅에서만 가능
find "$log_dir" -maxdepth 1 -name 'session-*.md' -type f -mtime +90 -delete 2>/dev/null || true

# 세션당 파일 1개(재실행돼도 안 겹침) — 짧은 세션ID 접미사로 같은 날 여러 세션 구분
short_id="${safe_id:0:8}"
target="$log_dir/session-${today}-${short_id}.md"
[ -f "$target" ] && exit 0  # 이미 기록됨(같은 세션의 재종료 이벤트 등) — 중복 방지

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$today")"
tmp="$target.tmp.$$"
{
  cat <<EOF
---
title: 세션 로그 ${today} (${project})
created: ${today}
updated: ${today}
category: 세션로그
status: raw
tags: [세션로그, 자동캡처]
related: []
source: vault-session-log.sh (SessionEnd, LLM 호출 없음)
---

# 세션 로그 ${today} — ${project}

자동 캡처된 세션 메타데이터. 요약이 아니라 브레드크럼입니다.

- session_id: ${session_id}
- 작업 디렉터리: ${cwd}
- 종료 사유: ${reason}
- 종료 시각(UTC): ${now_iso}

의미 있는 내용이 있으면 원본 세션(\`${transcript}\`)을 참고해 20_업무위키 또는 30_결정로그에 직접 승격하세요.
EOF
} 2>/dev/null > "$tmp"
mv -f "$tmp" "$target" 2>/dev/null || rm -f "$tmp" 2>/dev/null

exit 0
