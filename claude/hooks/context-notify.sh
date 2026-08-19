#!/usr/bin/env bash
# claude-config:context-notify — Stop 훅. statusline.sh 가 남긴 캐시(session_id 별 used_percentage)를
#   읽어 50%/90% 를 "위로 통과"할 때만 1회성으로 사용자에게 systemMessage 를 보여준다.
#   훅 입력엔 context_window 필드가 없음(공식 확인) — statusline 캐시가 유일한 데이터 소스라
#   statusline 이 비활성/미배포면 캐시가 없어 조용히 종료(FAIL-OPEN).
#   상태기계: 저장된 등급(tier)이 항상 "직전에 계산된 등급"을 그대로 반영 — 등급이 오르면 그때만
#   알리고, 내리면(예: /compact 가 55%에 착지) 조용히 등급만 낮춰 다음에 다시 오를 때 재알림되게 한다.
#   (50% 밑으로 떨어졌을 때만 리암하면, 90%→(compact)→55%→92% 재상승 시 알림이 죽는 갭이 있었음 — 수정됨)
set -u
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$session_id" ] && exit 0
# 레포 컨벤션(edit-track.sh, stop-metrics.sh)과 동일하게 파일명 사용 전 소독
session_id=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')

cache_file="$HOME/.claude/state/context-pct/$session_id.json"
[ -f "$cache_file" ] || exit 0

pct=$(jq -r '.used_percentage // empty' "$cache_file" 2>/dev/null || true)
[ -z "$pct" ] && exit 0
pct_int="${pct%.*}"
case "$pct_int" in ''|*[!0-9]*) exit 0 ;; esac

state_dir="$HOME/.claude/state/context-notified"
mkdir -p "$state_dir" 2>/dev/null || true
find "$state_dir" -type f -mtime +3 -delete 2>/dev/null || true
state_file="$state_dir/$session_id"

last_tier=0
if [ -f "$state_file" ]; then
  last_tier="$(cat "$state_file" 2>/dev/null || echo 0)"
  case "$last_tier" in ''|*[!0-9]*) last_tier=0 ;; esac
fi

new_tier=0
if   [ "$pct_int" -ge 90 ]; then new_tier=90
elif [ "$pct_int" -ge 50 ]; then new_tier=50
fi

write_state() {
  # 원자적 쓰기(tmp+mv) — 레포 컨벤션(stop-metrics.sh 의 tmp+os.replace)과 대칭, torn read 방지
  printf '%s\n' "$1" > "$state_file.tmp.$$" 2>/dev/null && mv -f "$state_file.tmp.$$" "$state_file" 2>/dev/null || true
}

if [ "$new_tier" -lt "$last_tier" ]; then
  write_state "$new_tier"
  exit 0
fi

if [ "$new_tier" -gt "$last_tier" ]; then
  write_state "$new_tier"
  if [ "$new_tier" -eq 90 ]; then
    msg="컨텍스트 ${pct_int}% 사용 — 정확도 저하 구간입니다. 지금 /clear 또는 /compact 를 권장합니다."
  else
    msg="컨텍스트 ${pct_int}% 사용 — 다음 작업으로 넘어갈 때 /clear(또는 /compact)를 고려하세요."
  fi
  jq -n --arg m "$msg" '{systemMessage: $m}' 2>/dev/null
fi
exit 0
