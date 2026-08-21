#!/usr/bin/env bash
# Codex PreCompact/PostCompact: compact_prompt의 보존 계약을 압축 경계에서 재확인한다.
# transcript나 세션 식별자는 읽거나 저장하지 않는다. 실패해도 압축을 막지 않는다.
set -u

command -v python3 >/dev/null 2>&1 || {
  printf '%s\n' '{"continue":true,"suppressOutput":true}'
  exit 0
}

python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    payload = {}

event = payload.get("hook_event_name")
trigger = payload.get("trigger")
if event not in {"PreCompact", "PostCompact"} or trigger not in {"manual", "auto"}:
    print(json.dumps({"continue": True, "suppressOutput": True}))
elif event == "PreCompact":
    print(json.dumps({
        "continue": True,
        "systemMessage": (
            "압축 체크포인트: 현재 상태와 다음 단계, 변경 파일과 핵심 내용, "
            "테스트 결과와 실패 원문 경로, 사용자가 확정한 결정과 이유를 반드시 보존하세요."
        ),
        "suppressOutput": True,
    }, ensure_ascii=False))
else:
    print(json.dumps({
        "continue": True,
        "systemMessage": (
            "압축 복구 확인: 압축 요약을 현재 파일보다 우선하지 말고, "
            "SessionStart가 다시 넣은 Vault 지도에서 관련 원문을 확인한 뒤 작업을 이어가세요."
        ),
        "suppressOutput": True,
    }, ensure_ascii=False))
'
exit 0
