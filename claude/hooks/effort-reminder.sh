#!/usr/bin/env bash
# SessionStart 훅 (Mac/Linux) — 매 세션 effort/ultracode 상태를 Claude 컨텍스트에 주입(리마인더).
# 훅은 /effort 를 실행할 수 없으므로 '안내'만 한다. stdout 의 additionalContext 가
# 매 세션 system-reminder 로 주입된다(공식 hooks 문서 확인).
# 리마인더 본문은 같은 폴더의 effort-reminder.txt(UTF-8)에서 읽어 단일 소스로 관리한다.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="$(cat "$DIR/effort-reminder.txt")"
# CTX 에는 큰따옴표/역슬래시/개행이 없어 그대로 JSON 문자열에 넣어도 안전.
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$CTX"
exit 0
