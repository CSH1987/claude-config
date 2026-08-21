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
cat > "$SESSIONS/subagent.jsonl" <<'EOF'
{"timestamp":"2026-08-20T00:00:00.000Z","type":"session_meta","payload":{"session_id":"child","parent_thread_id":"root-session","agent_path":"/root/test","thread_source":"subagent"}}
{"timestamp":"2026-08-20T00:00:04.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"하위 에이전트 작업"}]}}
EOF
printf '{broken json\n' > "$SESSIONS/broken.jsonl"

OUT="$TEST_ROOT/out.json"
python3 "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" \
  --sessions-root "$SESSIONS" --cursor '2026-08-19T00:00:00.000Z' --output "$OUT"
jq -e 'length == 1 and .[0].source == "codex" and .[0].session == "root-session" and .[0].text == "실제 사용자 요청"' "$OUT" >/dev/null

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
jq -e '
  .version == 2
  and .committedAt == null
  and (.sources | keys | sort) == ["claude-code", "codex", "hermes"]
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
mkdir -p "$PIPE_DIR" "$PIPE_HOME/.claude/projects/project" "$PIPE_HOME/.codex/sessions" "$VAULT/10_컨텍스트"
cp "$SESSIONS/root.jsonl" "$PIPE_HOME/.codex/sessions/root.jsonl"
cp "$SESSIONS/subagent.jsonl" "$PIPE_HOME/.codex/sessions/subagent.jsonl"
cat > "$PIPE_HOME/.claude/projects/project/root.jsonl" <<'EOF'
{"type":"user","origin":{"kind":"human"},"isSidechain":false,"timestamp":"2026-08-20T00:00:05.000Z","sessionId":"claude-root","message":{"content":"Claude 실제 요청"}}
EOF
printf '# 에버스 위키 홈\n' > "$VAULT/00_홈.md"
printf '# 전체 패턴\n\n변경분을 분석한다.\n' > "$VAULT/10_컨텍스트/pattern.md"
printf '{"vaultPath":"%s","projects":[]}\n' "$VAULT" > "$PIPE_HOME/.claude/vault-scope.json"
ln -s "$REPO_DIR/claude/learning-pipeline/collect-codex-user-prompts.py" "$PIPE_DIR/collect-codex-user-prompts.py"
ln -s "$REPO_DIR/claude/hooks/vault-catalog.py" "$PIPE_DIR/vault-catalog.py"

HOME="$PIPE_HOME" PATH="/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null
jq -e 'length == 2 and ([.[].source] | sort) == ["claude-code","codex"]' "$PIPE_DIR/gathered-utterances.json" >/dev/null
jq -e '(.changes | length) == 2 and .initialFullScan == true' "$PIPE_DIR/gathered-vault-documents.json" >/dev/null
[ -f "$PIPE_DIR/pending-cursor.json" ]
[ -f "$PIPE_DIR/pending-vault-state.json" ]

HOME="$PIPE_HOME" PATH="/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/commit-cursor.sh" >/dev/null
[ -f "$PIPE_DIR/cursor.json" ]
[ -f "$PIPE_DIR/vault-state.json" ]
HOME="$PIPE_HOME" PATH="/usr/bin:/bin" bash "$REPO_DIR/claude/learning-pipeline/gather.sh" >/dev/null
jq -e 'length == 0' "$PIPE_DIR/gathered-utterances.json" >/dev/null
jq -e '(.changes | length) == 0 and .initialFullScan == false' "$PIPE_DIR/gathered-vault-documents.json" >/dev/null

echo 'PASS: fresh cursor init/existing cursor preservation/three-source incremental gather/Vault state commit'
