#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-prompt-collector-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
SESSIONS="$TEST_ROOT/sessions"
OUTPUT="$TEST_ROOT/output.json"
mkdir -p "$SESSIONS"

cat > "$SESSIONS/root.jsonl" <<'EOF'
{"timestamp":"2026-08-20T00:00:00.000Z","type":"session_meta","payload":{"session_id":"normal-root","thread_source":"user"}}
{"timestamp":"2026-08-20T00:00:01.000Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-08-20T00:00:01.100Z","type":"event_msg","payload":{"type":"user_message","message":"정상 사용자 입력","text_elements":[],"local_images":[],"local_audio":[]}}
{"timestamp":"2026-08-20T00:00:01.100Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"정상 사용자 입력"}]}}
{"timestamp":"2026-08-20T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"## Memory\n주입 메모리"}]}}
{"timestamp":"2026-08-20T00:00:03.000Z","type":"response_item","payload":{"type":"function_call_output","output":"도구 결과"}}
{"timestamp":"2026-08-20T00:00:04.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","output":"커스텀 도구 결과"}}
{"timestamp":"2026-08-20T00:00:05.000Z","type":"compacted","payload":{"replacement_history":[{"type":"message","role":"user","content":[{"type":"input_text","text":"압축 교체 기록"}]}]}}
{"timestamp":"2026-08-20T00:00:06.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /tmp\n<environment_context>test</environment_context>"}]}}
{"timestamp":"2026-08-20T00:00:07.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<task-notification>\n<status>completed</status>\n</task-notification>"}]}}
{"timestamp":"2026-08-20T00:00:08.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<command-name>example</command-name>\n<command-message>expanded</command-message>"}]}}
{"timestamp":"2026-08-20T00:00:09.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<command-message>expanded</command-message>"}]}}
{"timestamp":"2026-08-20T00:00:10.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<local-command-stdout>generated</local-command-stdout>"}]}}
{"timestamp":"2026-08-20T00:00:11.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<system-reminder>generated</system-reminder>"}]}}
{"timestamp":"2026-08-20T00:00:12.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"설명 중 <task-notification> 문자열은 보존"}]}}
{"timestamp":"2026-08-20T00:00:13.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.\n자동 압축 요약"}]}}
{"timestamp":"2026-08-20T00:00:14.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"설명 중 This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation. 문구는 보존"}]}}
{"timestamp":"2026-08-20T00:00:15.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"/compact"}]}}
{"timestamp":"2026-08-20T00:00:16.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_image","image_url":"fixture-only"}]}}
EOF

cat > "$SESSIONS/subagent.jsonl" <<'EOF'
{"timestamp":"2026-08-20T00:00:00.000Z","type":"session_meta","payload":{"session_id":"child","parent_thread_id":"normal-root","agent_path":"/root/test","thread_source":"subagent"}}
{"timestamp":"2026-08-20T00:00:12.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"하위 에이전트 입력"}]}}
EOF

# 5초 안에 10개 생성된 Desktop legacy 세션은 초기 스냅샷만 제외한다.
for index in $(seq 0 9); do
  milliseconds="$(printf '%03d' "$((index * 100))")"
  session_file="$SESSIONS/legacy-burst-$index.jsonl"
  printf '%s\n' \
    "{\"timestamp\":\"2026-08-20T00:10:00.${milliseconds}Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"legacy-burst-$index\",\"timestamp\":\"2026-08-20T00:10:00.${milliseconds}Z\",\"originator\":\"Codex Desktop\",\"source\":\"vscode\",\"history_mode\":\"legacy\"}}" \
    "{\"timestamp\":\"2026-08-20T00:10:01.${milliseconds}Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"legacy 초기 입력 $index\"}]}}" \
    > "$session_file"
done

# 같은 legacy 세션이라도 import 경계 뒤에 추가된 실제 입력은 보존한다.
printf '%s\n' \
  '{"timestamp":"2026-08-20T00:10:10.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"legacy 이후 실제 입력"}]}}' \
  >> "$SESSIONS/legacy-burst-0.jsonl"

# 단독으로 새로 만든 Desktop legacy 세션의 첫 입력은 import로 오인하면 안 된다.
cat > "$SESSIONS/legacy-single.jsonl" <<'EOF'
{"timestamp":"2026-08-20T00:20:00.000Z","type":"session_meta","payload":{"session_id":"legacy-single","timestamp":"2026-08-20T00:20:00.000Z","originator":"Codex Desktop","source":"vscode","history_mode":"legacy"}}
{"timestamp":"2026-08-20T00:20:00.100Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"단일 legacy 실제 입력"}]}}
EOF

python3 "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" \
  --sessions-root "$SESSIONS" \
  --cursor '2026-08-19T00:00:00.000Z' \
  --output "$OUTPUT"

jq -e '
  length == 6
  and ([.[].text] | sort) == (["/compact", "legacy 이후 실제 입력", "단일 legacy 실제 입력", "설명 중 <task-notification> 문자열은 보존", "설명 중 This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation. 문구는 보존", "정상 사용자 입력"] | sort)
  and all(.[]; .source == "codex")
' "$OUTPUT" >/dev/null

OUTPUT_HASH="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"

# 사용자 발화의 시각이 깨졌으면 더 늦은 정상 행만으로 커서를 넘기지 않는다.
cat >> "$SESSIONS/root.jsonl" <<'EOF'
{"timestamp":"not-a-time","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"깨진 시각 입력"}]}}
EOF
if python3 "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" \
  --sessions-root "$SESSIONS" --cursor '2026-08-19T00:00:00.000Z' --output "$OUTPUT" >/dev/null 2>&1; then
  echo 'invalid Codex user timestamp was silently skipped' >&2
  exit 1
fi
[ "$OUTPUT_HASH" = "$(shasum -a 256 "$OUTPUT" | awk '{print $1}')" ]
sed -i '' '$d' "$SESSIONS/root.jsonl" 2>/dev/null || sed -i '$d' "$SESSIONS/root.jsonl"

cat >> "$SESSIONS/root.jsonl" <<'EOF'
{"timestamp":"2026-08-20T00:00:17.000Z","type":"response_item","payload":{"type":"message","role":"user","content":"실제 입력인데 배열이 아님"}}
EOF
if python3 "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" \
  --sessions-root "$SESSIONS" --cursor '2026-08-19T00:00:00.000Z' --output "$OUTPUT" >/dev/null 2>&1; then
  echo 'malformed Codex user content was silently skipped' >&2
  exit 1
fi
[ "$OUTPUT_HASH" = "$(shasum -a 256 "$OUTPUT" | awk '{print $1}')" ]
sed -i '' '$d' "$SESSIONS/root.jsonl" 2>/dev/null || sed -i '$d' "$SESSIONS/root.jsonl"

cat >> "$SESSIONS/root.jsonl" <<'EOF'
{"timestamp":"2026-08-20T00:00:17.500Z","type":"response_item","payload":"사용자 응답 payload가 객체가 아님"}
EOF
if python3 "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" \
  --sessions-root "$SESSIONS" --cursor '2026-08-19T00:00:00.000Z' --output "$OUTPUT" >/dev/null 2>&1; then
  echo 'malformed Codex response_item payload was silently skipped' >&2
  exit 1
fi
[ "$OUTPUT_HASH" = "$(shasum -a 256 "$OUTPUT" | awk '{print $1}')" ]
sed -i '' '$d' "$SESSIONS/root.jsonl" 2>/dev/null || sed -i '$d' "$SESSIONS/root.jsonl"

cat > "$SESSIONS/missing-session-id.jsonl" <<'EOF'
{"timestamp":"2026-08-20T00:40:00.000Z","type":"session_meta","payload":{"thread_source":"user"}}
{"timestamp":"2026-08-20T00:40:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"세션 식별자 없는 입력"}]}}
EOF
if python3 "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" \
  --sessions-root "$SESSIONS" --cursor '2026-08-19T00:00:00.000Z' --output "$OUTPUT" >/dev/null 2>&1; then
  echo 'Codex root session without an ID was silently accepted' >&2
  exit 1
fi
[ "$OUTPUT_HASH" = "$(shasum -a 256 "$OUTPUT" | awk '{print $1}')" ]
rm "$SESSIONS/missing-session-id.jsonl"

cat >> "$SESSIONS/root.jsonl" <<'EOF'
{"timestamp":null,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"시각 타입 오류 입력"}]}}
EOF
if python3 "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" \
  --sessions-root "$SESSIONS" --cursor '2026-08-19T00:00:00.000Z' --output "$OUTPUT" >/dev/null 2>&1; then
  echo 'non-string Codex user timestamp was silently skipped' >&2
  exit 1
fi
[ "$OUTPUT_HASH" = "$(shasum -a 256 "$OUTPUT" | awk '{print $1}')" ]
sed -i '' '$d' "$SESSIONS/root.jsonl" 2>/dev/null || sed -i '$d' "$SESSIONS/root.jsonl"

# 세션 트리 안의 링크나 읽을 수 없는 폴더는 일부만 수집하지 않고 전체 재시도로 돌린다.
mkdir -p "$TEST_ROOT/outside-sessions"
ln -s "$TEST_ROOT/outside-sessions" "$SESSIONS/linked-sessions"
if python3 "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" \
  --sessions-root "$SESSIONS" --cursor '2026-08-19T00:00:00.000Z' --output "$OUTPUT" >/dev/null 2>&1; then
  echo 'Codex session directory symlink was silently skipped' >&2
  exit 1
fi
[ "$OUTPUT_HASH" = "$(shasum -a 256 "$OUTPUT" | awk '{print $1}')" ]
rm "$SESSIONS/linked-sessions"

printf '%s\n' '{"timestamp":"2026-08-20T00:25:00.000Z","type":"session_meta","payload":{"session_id":"outside"}}' \
  > "$TEST_ROOT/outside-session.jsonl"
ln -s "$TEST_ROOT/outside-session.jsonl" "$SESSIONS/linked-file.jsonl"
if python3 "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" \
  --sessions-root "$SESSIONS" --cursor '2026-08-19T00:00:00.000Z' --output "$OUTPUT" >/dev/null 2>&1; then
  echo 'Codex session file symlink was silently followed' >&2
  exit 1
fi
[ "$OUTPUT_HASH" = "$(shasum -a 256 "$OUTPUT" | awk '{print $1}')" ]
rm "$SESSIONS/linked-file.jsonl"

touch "$SESSIONS/not-ready.jsonl"
if python3 "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" \
  --sessions-root "$SESSIONS" --cursor '2026-08-19T00:00:00.000Z' --output "$OUTPUT" >/dev/null 2>&1; then
  echo 'Codex session without session_meta was silently skipped' >&2
  exit 1
fi
[ "$OUTPUT_HASH" = "$(shasum -a 256 "$OUTPUT" | awk '{print $1}')" ]
rm "$SESSIONS/not-ready.jsonl"

mkdir -p "$SESSIONS/unreadable"
printf '%s\n' '{"timestamp":"2026-08-20T00:30:00.000Z","type":"session_meta","payload":{"session_id":"hidden"}}' \
  > "$SESSIONS/unreadable/hidden.jsonl"
chmod 000 "$SESSIONS/unreadable"
if [ ! -r "$SESSIONS/unreadable/hidden.jsonl" ]; then
  if python3 "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" \
    --sessions-root "$SESSIONS" --cursor '2026-08-19T00:00:00.000Z' --output "$OUTPUT" >/dev/null 2>&1; then
    echo 'unreadable Codex session directory was silently skipped' >&2
    exit 1
  fi
  [ "$OUTPUT_HASH" = "$(shasum -a 256 "$OUTPUT" | awk '{print $1}')" ]
fi
chmod 700 "$SESSIONS/unreadable"

echo 'PASS: Codex 실제 사용자 입력/합성 envelope/legacy import/compaction summary 경계'
