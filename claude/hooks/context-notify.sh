#!/usr/bin/env bash
# claude-config:context-notify — Stop 훅. statusline.sh 가 남긴 캐시(session_id 별 used_percentage)를
#   읽어 30%/90% 를 "위로 통과"할 때만 1회성으로 사용자에게 systemMessage 를 보여준다.
#   30%는 workload-optimization 스킬의 "20~40% 저하 체감 시작" 기준과 일치(2026-08-20 보정 — 이전엔 50).
#   훅 입력엔 context_window 필드가 없음(공식 확인) — statusline 캐시가 유일한 데이터 소스라
#   statusline 이 비활성/미배포면 캐시가 없어 조용히 종료(FAIL-OPEN).
#   상태기계: 저장된 등급(tier)이 항상 "직전에 계산된 등급"을 그대로 반영 — 등급이 오르면 그때만
#   알리고, 내리면(예: /compact 가 55%에 착지) 조용히 등급만 낮춰 다음에 다시 오를 때 재알림되게 한다.
#   (밑으로 떨어졌을 때만 리암하면, 90%→(compact)→중간→92% 재상승 시 알림이 죽는 갭이 있었음 — 수정됨)
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
elif [ "$pct_int" -ge 30 ]; then new_tier=30
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
  # 판단 기준을 명시: "같은 작업 계속=compact / 다른 작업 전환=clear", clear 전 rename 팁까지.
  # systemMessage=사용자에게만 표시, additionalContext=Claude 에게만 전달 — 후자 덕에 다음 응답에서
  # Claude 가 먼저 말을 걸고 계속/전환 의향을 물어볼 수 있다(정적 팝업이 아니라 대화형 안내가 됨).
  if [ "$new_tier" -eq 90 ]; then
    msg="컨텍스트 ${pct_int}% 사용 — 정확도 저하 구간입니다. 지금 작업을 계속 이어갈 거면 /compact(요약 압축 후 계속), 다른 작업으로 넘어갈 거면 /clear(완전 초기화)를 지금 실행하세요. 나중에 이 대화로 돌아올 수도 있다면 /clear 전에 먼저 /rename 이름 을 해두면 나중에 /resume 이름 으로 복구할 수 있습니다."
  else
    msg="컨텍스트 ${pct_int}% 사용 — 지금 작업을 계속 이어갈 거면 /compact(요약 압축, 이어서 작업), 다른 작업으로 넘어갈 거면 /clear(완전 초기화)를 고려하세요. 나중에 이 대화로 돌아올 수도 있다면 /clear 전에 먼저 /rename 이름 을 해두면 /resume 이름 으로 복구할 수 있습니다."
  fi
  ctx="[컨텍스트 알림] 방금 사용률이 ${pct_int}%에 도달해 사용자에게 시스템 메시지로 안내됨. 다음 응답 서두에서 자연스럽게 이를 언급하고, 지금 작업을 계속할지(/compact) 다른 작업으로 넘어갈지(/clear, 필요시 /rename 먼저)를 사용자에게 직접 확인하라. 메시지를 그대로 복사해서 보여주지 말고 대화 맥락에 맞게 짧게."
  jq -n --arg m "$msg" --arg c "$ctx" '{systemMessage: $m, additionalContext: $c}' 2>/dev/null
fi
exit 0
