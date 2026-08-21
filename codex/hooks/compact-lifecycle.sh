#!/usr/bin/env bash
# Codex PreCompact/PostCompact: 실제 보존·복구 담당 경로를 압축 경계에서 UI에 알린다.
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
            "압축 전 체크포인트: compact_prompt가 현재 상태와 다음 단계, 변경 파일, "
            "검증 결과, 사용자가 확정한 결정을 요약에 보존하도록 설정되어 있습니다."
        ),
        "suppressOutput": True,
    }, ensure_ascii=False))
else:
    print(json.dumps({
        "continue": True,
        "systemMessage": (
            "압축 후 복구 확인: SessionStart가 Vault 지도를 다시 넣습니다. "
            "압축 요약과 현재 파일이 다르면 관련 원문을 기준으로 작업을 이어가세요."
        ),
        "suppressOutput": True,
    }, ensure_ascii=False))
'
exit 0
