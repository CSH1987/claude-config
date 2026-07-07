#!/bin/bash
# PreToolUse(Bash) 훅: 테스트 실행 명령의 출력을 실패·요약 라인만 남기도록 재작성해 컨텍스트를 절약
# 근거: code.claude.com/docs/en/costs "Offload processing to hooks" 공식 예제 기반
input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && { echo "{}"; exit 0; }

# 이미 필터가 적용된 명령이면 이중 적용 방지
case "$cmd" in *"grep -A 3 -E '(FAIL"*) echo "{}"; exit 0;; esac

# 테스트 러너 명령만 대상 (전체 실행 형태). 특정 테스트 지정 실행은 원문 출력 유지
if echo "$cmd" | grep -qE '^[[:space:]]*(npm test|npx vitest run|pytest|python -m pytest|go test)([[:space:]]|$)'; then
  filtered_cmd="$cmd 2>&1 | grep -A 3 -E '(FAIL|FAILED|ERROR|error:|passed|failed)' | head -100"
  jq -cn --arg cmd "$filtered_cmd" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:{command:$cmd}}}'
else
  echo "{}"
fi
exit 0
