#!/usr/bin/env sh
# claude-config:test-edit-nudge — edit-nudge.sh 의 카운팅/리셋/1회발화/세션격리/FAIL-OPEN
#   로직을 격리된 임시 OMC_STATE_DIR 로 시뮬레이션 검증한다. 실제 훅 등록/settings.json 과 무관.
# 사용: sh claude/hooks/test-edit-nudge.sh
set -eu

HOOK="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/edit-nudge.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
pass=0

# call HOOK with a given tool_name + session_id, return raw stdout
call() {
  tool="$1"; sess="$2"
  printf '{"tool_name":"%s","session_id":"%s"}' "$tool" "$sess" \
    | OMC_STATE_DIR="$TMP" EDIT_NUDGE_THRESHOLD=6 "$HOOK"
}

# call HOOK N times with tool_name=Edit for the given session (last call's stdout kept in $out)
edit_times() {
  sess="$1"; n="$2"
  i=1
  out=""
  while [ "$i" -le "$n" ]; do
    out="$(call Edit "$sess")"
    i=$((i+1))
  done
}

assert_empty() {
  desc="$1"; out="$2"
  if [ -z "$out" ]; then
    echo "PASS: $desc"; pass=$((pass+1))
  else
    echo "FAIL: $desc (기대: 빈 출력, 실제: $out)"; fail=$((fail+1))
  fi
}

assert_nudge() {
  desc="$1"; out="$2"
  if printf '%s' "$out" | grep -q '"additionalContext"'; then
    echo "PASS: $desc"; pass=$((pass+1))
  else
    echo "FAIL: $desc (기대: additionalContext 포함 넛지, 실제: $out)"; fail=$((fail+1))
  fi
}

echo "=== 케이스1: 임계치 미만(5회 Edit) — 넛지 없어야 함 ==="
edit_times "case1-$$" 5
assert_empty "5회 Edit 후 무발화" "$out"

echo
echo "=== 케이스2: 임계치 이상(6회 Edit, Skill/Agent 없음) — 정확히 1회 발화 ==="
S2="case2-$$"
i=1
outs=""
while [ "$i" -le 8 ]; do
  o="$(call Edit "$S2")"
  outs="$outs|$o"
  if [ "$i" -eq 6 ]; then
    assert_nudge "6번째 Edit(임계치 도달)에서 발화" "$o"
  fi
  if [ "$i" -eq 7 ] || [ "$i" -eq 8 ]; then
    assert_empty "${i}번째 Edit(임계치 이후)에서 재발화 안 함(스팸 금지)" "$o"
  fi
  i=$((i+1))
done
nudge_count="$(printf '%s' "$outs" | grep -o 'additionalContext' | wc -l | tr -d ' ')"
if [ "$nudge_count" = "1" ]; then
  echo "PASS: 8회 Edit 동안 넛지 총 발화 횟수 = 1회"; pass=$((pass+1))
else
  echo "FAIL: 8회 Edit 동안 넛지 총 발화 횟수 = $nudge_count (기대: 1)"; fail=$((fail+1))
fi

echo
echo "=== 케이스3: Edit 도중 Skill 호출로 리셋 — 재발화 없이 카운트 리셋 ==="
S3="case3-$$"
edit_times "$S3" 5
out="$(call Skill "$S3")"
assert_empty "Skill 호출 자체는 넛지 없음" "$out"
# 리셋 후 5회 더 Edit 해도 (누적 5+5=10 이 아니라 리셋된 5 이므로) 아직 미도달
edit_times "$S3" 5
assert_empty "Skill 리셋 후 5회 Edit(리셋 안 됐으면 누적10으로 이미 발화했을 것) — 아직 미도달 확인" "$out"
out="$(call Edit "$S3")"
assert_nudge "리셋 후 6번째 Edit에서 정상 발화(리셋이 실제로 카운트를 0으로 되돌렸음을 증명)" "$out"

echo
echo "=== 케이스4: 세션 경계 — 새 세션은 이전 세션 카운트를 상속하지 않음 ==="
edit_times "case4a-$$" 6
# 위 세션은 이미 임계치 도달(6)해서 fired 상태. 이제 완전히 다른 session_id 로 1회만 Edit.
out="$(call Edit "case4b-$$")"
assert_empty "새 세션 첫 Edit에서 무발화(이전 세션 카운트 상속 안 됨)" "$out"

echo
echo "=== 케이스5: Skill/Agent/mcp__* 이외의 도구(Read/Grep/Bash)는 카운트 안 함 ==="
S5="case5-$$"
edit_times "$S5" 5
call Read "$S5" >/dev/null
call Grep "$S5" >/dev/null
call Bash "$S5" >/dev/null
out="$(cat "$TMP/edit-nudge/$S5.json" 2>/dev/null || echo "")"
if printf '%s' "$out" | grep -q '"count":5'; then
  echo "PASS: Read/Grep/Bash 3회 호출 후에도 count 는 여전히 5(조사성 도구 비카운트)"; pass=$((pass+1))
else
  echo "FAIL: Read/Grep/Bash 호출이 카운트에 영향을 줌 (상태: $out)"; fail=$((fail+1))
fi

echo
echo "=== 케이스6: FAIL-OPEN — 어떤 오류에도 세션을 막지 않음(exit 0, 크래시 없음) ==="
rc=0
printf 'not valid json{{{' | OMC_STATE_DIR="$TMP" "$HOOK" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "0" ]; then
  echo "PASS: 손상된 JSON payload에도 exit 0"; pass=$((pass+1))
else
  echo "FAIL: 손상된 JSON payload에서 비정상 종료(rc=$rc)"; fail=$((fail+1))
fi

rc=0
printf '' | OMC_STATE_DIR="$TMP" "$HOOK" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "0" ]; then
  echo "PASS: 빈 payload에도 exit 0"; pass=$((pass+1))
else
  echo "FAIL: 빈 payload에서 비정상 종료(rc=$rc)"; fail=$((fail+1))
fi

rc=0
printf '{"tool_name":"Edit","session_id":"failopen"}' \
  | PATH="/usr/bin:/bin" OMC_STATE_DIR="$TMP" "$HOOK" >/dev/null 2>&1 || rc=$?
# python3 가 PATH 에 없을 수도/있을 수도 있는 환경이라 결과와 무관하게 exit 0 만 확인.
if [ "$rc" = "0" ]; then
  echo "PASS: python3 미탐지 가능 환경에서도 exit 0"; pass=$((pass+1))
else
  echo "FAIL: python3 미탐지 환경에서 비정상 종료(rc=$rc)"; fail=$((fail+1))
fi

echo
echo "=== 요약: PASS=$pass FAIL=$fail ==="
[ "$fail" -eq 0 ]
