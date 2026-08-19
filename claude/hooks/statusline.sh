#!/usr/bin/env bash
# claude-config:statusline — 컨텍스트 사용률 상시 표시(공식 statusLine 기능).
#   used_percentage 는 Claude Code 가 이미 계산해 stdin 으로 넘겨줌(입력 토큰만 계산, 출력 미포함 — 공식 확인).
#   50/60/90% 색상 구간은 workload-optimization 스킬 §2 의 컨텍스트 임계치 문서와 일치시킴.
#   부수 효과: session_id 별 캐시 파일에 used_percentage 를 남겨 Stop 훅(context-notify.sh)이 재사용
#   (훅 입력에는 context_window 필드가 없어 — 공식 확인 — statusline 이 유일한 소스).
#   설계 원칙(기존 훅 계승): FAIL-OPEN — jq 없거나 stdin 파싱 실패해도 최소한의 줄은 출력.
set -u

input="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1 || [ -z "$input" ]; then
  echo "claude"
  exit 0
fi

model=$(printf '%s' "$input" | jq -r '.model.display_name // "claude"' 2>/dev/null || echo "claude")
dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // empty' 2>/dev/null || true)
dir_name="${dir##*/}"
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null || true)
cost=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null || true)

branch=""
if [ -n "$dir" ] && command -v git >/dev/null 2>&1; then
  branch=$(git -C "$dir" branch --show-current 2>/dev/null || true)
fi

# --- pct 수치 검증(캐시 기록보다 먼저 — 비수치면 캐시 자체를 안 남김) ---
pct_int=""
case "${pct%.*}" in ''|*[!0-9]*) pct_int="" ;; *) pct_int="${pct%.*}" ;; esac

# --- 캐시: Stop 훅이 같은 used_percentage 를 재사용(자체적으로는 context_window 를 못 받음) ---
if [ -n "$session_id" ] && [ -n "$pct_int" ]; then
  safe_id=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')  # 레포 컨벤션(edit-track.sh 등)과 동일 소독
  cache_dir="$HOME/.claude/state/context-pct"
  mkdir -p "$cache_dir" 2>/dev/null || true
  find "$cache_dir" -type f -mtime +3 -delete 2>/dev/null || true
  cache_file="$cache_dir/$safe_id.json"
  printf '{"used_percentage":%s}\n' "$pct" > "$cache_file.tmp.$$" 2>/dev/null \
    && mv -f "$cache_file.tmp.$$" "$cache_file" 2>/dev/null || true
fi

color="\033[32m"  # 기본: 초록(<50%)
if [ -n "$pct_int" ]; then
  if   [ "$pct_int" -ge 90 ]; then color="\033[1;31m"  # 굵은 빨강(90%+, 즉시 정리)
  elif [ "$pct_int" -ge 60 ]; then color="\033[33m"    # 주황(60%+, 정리 고려)
  elif [ "$pct_int" -ge 50 ]; then color="\033[93m"    # 노랑(50%+, 인지)
  fi
fi
reset="\033[0m"
# 색상 코드만 이스케이프 해석(printf %b), dir/branch 명은 %s 로 리터럴 취급(백슬래시 오해석 방지)
color_start=$(printf "$color")
color_reset=$(printf "$reset")

cost_disp="$cost"
if [ -n "$cost" ]; then
  cost_disp=$(printf '%.2f' "$cost" 2>/dev/null || printf '%s' "$cost")
fi

line="[$model] ${dir_name}"
[ -n "$branch" ] && line="$line (${branch})"
if [ -n "$pct" ]; then
  line="$line | ${color_start}${pct}% ctx${color_reset}"
else
  line="$line | ctx?"
fi
[ -n "$cost" ] && line="$line | \$${cost_disp}"

printf '%s\n' "$line"
