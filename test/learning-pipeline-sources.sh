#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/learning-sources-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
SESSIONS="$TEST_ROOT/sessions"
mkdir -p "$SESSIONS"

cat > "$SESSIONS/root.jsonl" <<'EOF'
{"timestamp":"2026-08-20T00:00:00.000Z","type":"session_meta","payload":{"session_id":"root-session","thread_source":"user"}}
{"timestamp":"2026-08-20T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /tmp\\n<environment_context>test</environment_context>"}]}}
{"timestamp":"2026-08-20T00:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"실제 사용자 요청"}]}}
{"timestamp":"2026-08-20T00:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"assistant"}]}}
EOF
# macOS exec 인자 한도보다 큰 발화도 셸 변수/--argjson 없이 파일로 병합돼야 한다.
printf '%s' '{"timestamp":"2026-08-20T00:00:04.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"' >> "$SESSIONS/root.jsonl"
head -c 400000 /dev/zero | tr '\0' 'x' >> "$SESSIONS/root.jsonl"
printf '%s\n' '"}]}}' >> "$SESSIONS/root.jsonl"
cat > "$SESSIONS/subagent.jsonl" <<'EOF'
{"timestamp":"2026-08-20T00:00:00.000Z","type":"session_meta","payload":{"session_id":"child","parent_thread_id":"root-session","agent_path":"/root/test","thread_source":"subagent"}}
{"timestamp":"2026-08-20T00:00:04.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"하위 에이전트 작업"}]}}
EOF
OUT="$TEST_ROOT/out.json"
python3 "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" \
  --sessions-root "$SESSIONS" --cursor '2026-08-19T00:00:00.000Z' --output "$OUT"
jq -e 'length == 2 and .[0].source == "codex" and .[0].session == "root-session" and .[0].text == "실제 사용자 요청" and (.[1].text | length) == 400000' "$OUT" >/dev/null

# 한 세션 파일이라도 쓰이는 중이거나 깨졌으면 더 늦은 정상 발화로 커서를 넘기지
# 않도록 전체 수집을 실패시키고 이전 출력도 그대로 보존한다.
OUT_HASH="$(shasum -a 256 "$OUT" | awk '{print $1}')"
printf '{broken json\n' > "$SESSIONS/broken.jsonl"
if python3 "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" \
  --sessions-root "$SESSIONS" --cursor '2026-08-19T00:00:00.000Z' --output "$OUT" >/dev/null 2>&1; then
  echo 'malformed Codex JSONL was silently accepted' >&2
  exit 1
fi
[ "$OUT_HASH" = "$(shasum -a 256 "$OUT" | awk '{print $1}')" ]
rm -f "$SESSIONS/broken.jsonl"

# 초 단위/밀리초/마이크로초가 섞여도 실제 시간순으로 비교하고 같은 순간은 중복 제거한다.
FINALIZER_TEST="$TEST_ROOT/finalizer"
mkdir -p "$FINALIZER_TEST"
cat > "$FINALIZER_TEST/claude.json" <<'EOF'
[
  {"source":"claude-code","session":"mixed","ts":"2026-08-20T00:00:00.123Z","text":"같은 순간"},
  {"source":"claude-code","session":"mixed","ts":"2026-08-20T00:00:00.123000Z","text":"같은 순간"},
  {"source":"claude-code","session":"mixed","ts":"2026-08-20T00:00:00.500Z","text":"더 늦은 순간"}
]
EOF
printf '[]\n' > "$FINALIZER_TEST/hermes.json"
printf '[]\n' > "$FINALIZER_TEST/codex.json"
python3 "$REPO_DIR/claude/learning-pipeline/finalize-gathered-prompts.py" \
  --claude-file "$FINALIZER_TEST/claude.json" \
  --hermes-file "$FINALIZER_TEST/hermes.json" \
  --codex-file "$FINALIZER_TEST/codex.json" \
  --cursor-file "$FINALIZER_TEST/missing-cursor.json" \
  --claude-cursor '2026-08-20T00:00:00Z' \
  --hermes-cursor '2026-08-20T00:00:00.000Z' \
  --codex-cursor '2026-08-20T00:00:00.000000Z' \
  --future-limit '2026-08-20T00:00:01Z' \
  --output "$FINALIZER_TEST/output.json" \
  --pending-cursor "$FINALIZER_TEST/pending.json"
jq -e '
  length == 2
  and ([.[].ts] | sort) == ["2026-08-20T00:00:00.123000Z","2026-08-20T00:00:00.500000Z"]
' "$FINALIZER_TEST/output.json" >/dev/null
jq -e '
  .sources["claude-code"] == "2026-08-20T00:00:00.500000Z"
  and .sources.hermes == "2026-08-20T00:00:00.000000Z"
  and .lastProcessed == "2026-08-20T00:00:00.500000Z"
' "$FINALIZER_TEST/pending.json" >/dev/null

# 신규 장치처럼 cursor.json이 없는 격리 HOME에서 setup 훅의 최초 초기화를 검증한다.
SETUP_HOME="$TEST_ROOT/setup-home"
SETUP_VAULT="$SETUP_HOME/Documents/Vault"
SETUP_FAKE_BIN="$TEST_ROOT/setup-bin"
SETUP_REPO="$TEST_ROOT/setup-repo"
mkdir -p "$SETUP_HOME/.claude" "$SETUP_HOME/Library/LaunchAgents" \
  "$SETUP_VAULT/10_컨텍스트" "$SETUP_FAKE_BIN" "$SETUP_REPO/claude/hooks"
cp -R "$REPO_DIR/claude/learning-pipeline" "$SETUP_REPO/claude/learning-pipeline"
cp "$REPO_DIR/claude/hooks/vault-catalog.py" "$SETUP_REPO/claude/hooks/vault-catalog.py"
printf '{"vaultPath":"%s","projects":[]}\n' "$SETUP_VAULT" > "$SETUP_HOME/.claude/vault-scope.json"
printf '%s\n' "$SETUP_REPO" > "$SETUP_HOME/.claude/.config-sync-path"
cat > "$SETUP_FAKE_BIN/hostname" <<'EOF'
#!/bin/sh
printf '%s\n' 'test-macmini'
EOF
cat > "$SETUP_FAKE_BIN/launchctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$SETUP_FAKE_BIN/hostname" "$SETUP_FAKE_BIN/launchctl"

HOME="$SETUP_HOME" PATH="$SETUP_FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_DIR/claude/hooks/learning-pipeline-setup.sh" >/dev/null
SETUP_CURSOR="$SETUP_HOME/.claude/learning-pipeline/cursor.json"
[ -L "$SETUP_HOME/.claude/learning-pipeline/validate-vault-output.py" ]
[ -L "$SETUP_HOME/.claude/learning-pipeline/finalize-gathered-prompts.py" ]
jq -e '
  .version == 2
  and .committedAt == null
  and (.sources | keys | sort) == ["claude-code", "codex", "hermes"]
  and (.boundaryIds == {"claude-code":[],hermes:[],codex:[]})
  and (.boundaryStarts == .sources)
  and .lastProcessed == .sources["claude-code"]
  and .lastProcessed == .sources.codex
  and .lastProcessed == .sources.hermes
' "$SETUP_CURSOR" >/dev/null

# 기존 사용자 커서는 setup을 다시 실행해도 바뀌지 않아야 한다.
printf '{"sentinel":"preserve-existing-cursor"}\n' > "$SETUP_CURSOR"
CURSOR_BEFORE="$(shasum -a 256 "$SETUP_CURSOR" | awk '{print $1}')"
HOME="$SETUP_HOME" PATH="$SETUP_FAKE_BIN:/usr/bin:/bin" \
  bash "$REPO_DIR/claude/hooks/learning-pipeline-setup.sh" >/dev/null
CURSOR_AFTER="$(shasum -a 256 "$SETUP_CURSOR" | awk '{print $1}')"
[ "$CURSOR_BEFORE" = "$CURSOR_AFTER" ]

PIPE_HOME="$TEST_ROOT/home"
PIPE_DIR="$PIPE_HOME/.claude/learning-pipeline"
VAULT="$PIPE_HOME/Documents/Vault"
PIPE_BIN="$TEST_ROOT/pipe-bin"
mkdir -p "$PIPE_DIR" "$PIPE_HOME/.claude/projects/project" "$PIPE_HOME/.codex/sessions" "$VAULT/10_컨텍스트" "$PIPE_BIN"
cp "$SESSIONS/root.jsonl" "$PIPE_HOME/.codex/sessions/root.jsonl"
cp "$SESSIONS/subagent.jsonl" "$PIPE_HOME/.codex/sessions/subagent.jsonl"
cat > "$PIPE_HOME/.claude/projects/project/root.jsonl" <<'EOF'
{"type":"user","origin":{"kind":"human"},"isSidechain":false,"timestamp":"2026-08-20T00:00:05.000Z","sessionId":"claude-root","message":{"content":"Claude 실제 요청"}}
{"type":"user","origin":{"kind":"human"},"isSidechain":false,"timestamp":"2026-08-20T00:00:06.000Z","sessionId":"claude-internal","message":{"content":"[claude-config:learning-pipeline-internal]\n내부 실행 프롬프트"}}
EOF
printf '# 에버스 위키 홈\n' > "$VAULT/00_홈.md"
printf '# 전체 패턴\n\n변경분을 분석한다.\n' > "$VAULT/10_컨텍스트/pattern.md"
printf '{"vaultPath":"%s","projects":[]}\n' "$VAULT" > "$PIPE_HOME/.claude/vault-scope.json"
ln -s "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" "$PIPE_DIR/collect-codex-user-prompts.py"
ln -s "$REPO_DIR/claude/learning-pipeline/finalize-gathered-prompts.py" "$PIPE_DIR/finalize-gathered-prompts.py"
ln -s "$REPO_DIR/claude/hooks/vault-catalog.py" "$PIPE_DIR/vault-catalog.py"
cat > "$PIPE_BIN/hermes" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${HERMES_EXPORT_FAIL:-0}" = '1' ] && exit 9
destination="${!#}"
printf '%s\n' '{"created_at":"2026-08-20T00:00:07.000Z","session_id":"hermes-root","text":"[대괄호] Hermes 실제 요청"}' > "$destination"
EOF
chmod +x "$PIPE_BIN/hermes"

HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null
jq -e 'length == 4 and ([.[].source] | sort) == ["claude-code","codex","codex","hermes"]' "$PIPE_DIR/gathered-utterances.json" >/dev/null
jq -e 'all(.[]; (.session | test("^(claude-code|codex|hermes)-session-[0-9]+$")))' "$PIPE_DIR/gathered-utterances.json" >/dev/null
jq -e '([.[] | select(.source == "codex") | .session] | unique | length) == 1' "$PIPE_DIR/gathered-utterances.json" >/dev/null
! grep -q 'root-session\|claude-root\|claude-internal\|내부 실행 프롬프트' "$PIPE_DIR/gathered-utterances.json"
grep -q '\[대괄호\] Hermes 실제 요청' "$PIPE_DIR/gathered-utterances.json"
jq -e '.sources == {"claude-code":"ok",hermes:"ok",codex:"ok"}' "$PIPE_DIR/gather-source-status.json" >/dev/null
jq -e '(.changes | length) == 2 and .initialFullScan == true' "$PIPE_DIR/gathered-vault-documents.json" >/dev/null
[ -f "$PIPE_DIR/pending-cursor.json" ]
[ -f "$PIPE_DIR/pending-vault-state.json" ]

HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/commit-cursor.sh" >/dev/null
[ -f "$PIPE_DIR/cursor.json" ]
[ -f "$PIPE_DIR/vault-state.json" ]
HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null
jq -e 'length == 0' "$PIPE_DIR/gathered-utterances.json" >/dev/null
jq -e '(.changes | length) == 0 and .initialFullScan == false' "$PIPE_DIR/gathered-vault-documents.json" >/dev/null

# 이미 확정한 최대 timestamp와 같은 시각의 발화가 나중에 추가돼도 boundary hash로 수집한다.
printf '%s\n' '{"timestamp":"2026-08-20T00:00:04.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"늦게 저장된 동일시각 요청"}]}}' \
  >> "$PIPE_HOME/.codex/sessions/root.jsonl"
HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null
jq -e 'length == 1 and .[0].source == "codex" and .[0].text == "늦게 저장된 동일시각 요청"' \
  "$PIPE_DIR/gathered-utterances.json" >/dev/null
jq -e '.boundaryIds.codex | length >= 2' "$PIPE_DIR/pending-cursor.json" >/dev/null
HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/commit-cursor.sh" >/dev/null
HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null
jq -e 'length == 0' "$PIPE_DIR/gathered-utterances.json" >/dev/null

# 더 최신 시각을 확정한 뒤 그보다 조금 이른 발화가 늦게 나타나도 24시간 overlap ID로 수집한다.
cat > "$PIPE_HOME/.codex/sessions/later.jsonl" <<'EOF'
{"timestamp":"2026-08-20T00:00:00.000Z","type":"session_meta","payload":{"session_id":"later-session","thread_source":"user"}}
{"timestamp":"2026-08-20T00:00:10.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"먼저 발견된 더 최신 요청"}]}}
EOF
HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null
jq -e 'length == 1 and .[0].text == "먼저 발견된 더 최신 요청"' "$PIPE_DIR/gathered-utterances.json" >/dev/null
HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/commit-cursor.sh" >/dev/null
printf '%s\n' '{"timestamp":"2026-08-20T00:00:09.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"나중에 저장된 조금 이른 요청"}]}}' \
  >> "$PIPE_HOME/.codex/sessions/root.jsonl"
HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null
jq -e 'length == 1 and .[0].text == "나중에 저장된 조금 이른 요청"' "$PIPE_DIR/gathered-utterances.json" >/dev/null
jq -e '.boundaryStarts.codex < .sources.codex and (.boundaryIds.codex | length) >= 4' "$PIPE_DIR/pending-cursor.json" >/dev/null
HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/commit-cursor.sh" >/dev/null
HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null
jq -e 'length == 0' "$PIPE_DIR/gathered-utterances.json" >/dev/null

# 설치된 한 소스라도 실패하면 0건으로 숨기지 않고 전체 gather를 실패시킨다. 확정 커서는 유지된다.
CURSOR_HASH="$(shasum -a 256 "$PIPE_DIR/cursor.json" | awk '{print $1}')"
rm -f "$PIPE_DIR/collect-codex-user-prompts.py"
ln -s "$TEST_ROOT/missing-collector.py" "$PIPE_DIR/collect-codex-user-prompts.py"
if HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null 2>&1; then
  echo 'missing installed Codex collector was hidden as zero results' >&2
  exit 1
fi
jq -e '.sources.codex == "error"' "$PIPE_DIR/gather-source-status.json" >/dev/null
[ "$CURSOR_HASH" = "$(shasum -a 256 "$PIPE_DIR/cursor.json" | awk '{print $1}')" ]
rm -f "$PIPE_DIR/collect-codex-user-prompts.py"
ln -s "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" "$PIPE_DIR/collect-codex-user-prompts.py"

printf '{unterminated json' > "$PIPE_HOME/.codex/sessions/broken.jsonl"
if HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" \
  bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null 2>&1; then
  echo 'malformed installed Codex session was hidden as zero results' >&2
  exit 1
fi
jq -e '.sources.codex == "error"' "$PIPE_DIR/gather-source-status.json" >/dev/null
[ "$CURSOR_HASH" = "$(shasum -a 256 "$PIPE_DIR/cursor.json" | awk '{print $1}')" ]
rm -f "$PIPE_HOME/.codex/sessions/broken.jsonl"

if HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" HERMES_EXPORT_FAIL=1 \
  bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null 2>&1; then
  echo 'Hermes export failure was hidden as zero results' >&2
  exit 1
fi
jq -e '.sources.hermes == "error"' "$PIPE_DIR/gather-source-status.json" >/dev/null

printf '{broken json\n' > "$PIPE_HOME/.claude/projects/project/broken.jsonl"
if HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null 2>&1; then
  echo 'Claude parse failure was hidden as zero results' >&2
  exit 1
fi
jq -e '.sources["claude-code"] == "error"' "$PIPE_DIR/gather-source-status.json" >/dev/null
[ "$CURSOR_HASH" = "$(shasum -a 256 "$PIPE_DIR/cursor.json" | awk '{print $1}')" ]

rm -f "$PIPE_HOME/.claude/projects/project/broken.jsonl"
cat > "$PIPE_HOME/.claude/projects/project/invalid-time.jsonl" <<'EOF'
{"type":"user","origin":{"kind":"human"},"isSidechain":false,"timestamp":"not-a-time","sessionId":"invalid-time","message":{"content":"잘못된 시각의 실제 요청"}}
{"type":"user","origin":{"kind":"human"},"isSidechain":false,"timestamp":"2026-08-20T00:00:09.000Z","sessionId":"later-valid","message":{"content":"더 늦은 정상 요청"}}
EOF
if HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null 2>&1; then
  echo 'invalid old Claude timestamp was hidden by a later valid record' >&2
  exit 1
fi
jq -e '.sources["claude-code"] == "error"' "$PIPE_DIR/gather-source-status.json" >/dev/null
[ "$CURSOR_HASH" = "$(shasum -a 256 "$PIPE_DIR/cursor.json" | awk '{print $1}')" ]
rm -f "$PIPE_HOME/.claude/projects/project/invalid-time.jsonl"

mkdir -p "$TEST_ROOT/outside-claude-project"
ln -s "$TEST_ROOT/outside-claude-project" "$PIPE_HOME/.claude/projects/linked-project"
if HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null 2>&1; then
  echo 'Claude project symlink was silently skipped' >&2
  exit 1
fi
jq -e '.sources["claude-code"] == "error"' "$PIPE_DIR/gather-source-status.json" >/dev/null
[ "$CURSOR_HASH" = "$(shasum -a 256 "$PIPE_DIR/cursor.json" | awk '{print $1}')" ]
rm "$PIPE_HOME/.claude/projects/linked-project"

mkdir -p "$PIPE_HOME/.claude/projects/unreadable-project"
printf '%s\n' '{"type":"user","origin":{"kind":"human"},"isSidechain":false,"timestamp":"2026-08-20T00:00:08.000Z","sessionId":"hidden","message":{"content":"숨은 요청"}}' \
  > "$PIPE_HOME/.claude/projects/unreadable-project/hidden.jsonl"
chmod 000 "$PIPE_HOME/.claude/projects/unreadable-project"
if [ ! -r "$PIPE_HOME/.claude/projects/unreadable-project/hidden.jsonl" ]; then
  if HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null 2>&1; then
    echo 'unreadable Claude project directory was silently skipped' >&2
    exit 1
  fi
  jq -e '.sources["claude-code"] == "error"' "$PIPE_DIR/gather-source-status.json" >/dev/null
  [ "$CURSOR_HASH" = "$(shasum -a 256 "$PIPE_DIR/cursor.json" | awk '{print $1}')" ]
fi
chmod 700 "$PIPE_HOME/.claude/projects/unreadable-project"

rm -f "$PIPE_DIR/vault-catalog.py"
ln -s "$TEST_ROOT/missing-vault-catalog.py" "$PIPE_DIR/vault-catalog.py"
if HOME="$PIPE_HOME" PATH="$PIPE_BIN:/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null 2>&1; then
  echo 'missing Vault catalog reused stale staging outputs' >&2
  exit 1
fi
[ "$CURSOR_HASH" = "$(shasum -a 256 "$PIPE_DIR/cursor.json" | awk '{print $1}')" ]
[ ! -e "$PIPE_DIR/pending-cursor.json" ]
[ ! -e "$PIPE_DIR/pending-vault-state.json" ]
rm -f "$PIPE_DIR/vault-catalog.py"
ln -s "$REPO_DIR/claude/hooks/vault-catalog.py" "$PIPE_DIR/vault-catalog.py"

echo 'PASS: cursor preservation/three-source gather/bracketed Hermes input/source failure status/Vault state commit'
