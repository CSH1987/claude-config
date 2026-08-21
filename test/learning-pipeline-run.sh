#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/learning-run-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_HOME="$TEST_ROOT/home"
PIPE_DIR="$TEST_HOME/.claude/learning-pipeline"
VAULT="$TEST_HOME/Documents/Vault"
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$PIPE_DIR" "$VAULT/10_컨텍스트" "$FAKE_BIN"

printf '# 패턴\n' > "$VAULT/10_컨텍스트/pattern.md"
printf '{"vaultPath":"%s","projects":[]}\n' "$VAULT" > "$TEST_HOME/.claude/vault-scope.json"
cp "$REPO_DIR/claude/learning-pipeline/commit-cursor.sh" "$PIPE_DIR/commit-cursor.sh"
printf 'export default {}\n' > "$PIPE_DIR/pipeline.workflow.js"

cat > "$PIPE_DIR/gather.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="$HOME/.claude/learning-pipeline"
if [ "${FAKE_GATHER_EMPTY:-0}" = '1' ]; then
  printf '[]\n' > "$DIR/gathered-utterances.json"
else
  printf '[{"source":"codex","session":"s","ts":"2026-08-21T00:00:00.000Z","text":"테스트"}]\n' > "$DIR/gathered-utterances.json"
fi
printf '{"version":1,"changes":[],"initialFullScan":false}\n' > "$DIR/gathered-vault-documents.json"
printf '{"version":2,"lastProcessed":"2026-08-21T00:00:00.000Z","sources":{"claude-code":"2026-08-21T00:00:00.000Z","hermes":"2026-08-21T00:00:00.000Z","codex":"2026-08-21T00:00:00.000Z"},"committedAt":null}\n' > "$DIR/pending-cursor.json"
if [ "${FAKE_GATHER_OMIT_VAULT_STATE:-0}" != '1' ]; then
  printf '{"version":1,"vaultFingerprint":"fixture","files":[]}\n' > "$DIR/pending-vault-state.json"
fi
EOF
chmod +x "$PIPE_DIR/gather.sh" "$PIPE_DIR/commit-cursor.sh"

cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-missing}" > "$HOME/.claude/learning-pipeline/received-wait-ceiling.txt"
printf '%s\n' "$@" > "$HOME/.claude/learning-pipeline/received-claude-args.txt"
case "${FAKE_CLAUDE_MODE:-success}" in
  logical-failure)
    printf '%s\n' 'Background tasks still running after 600s; terminating.'
    exit 0
    ;;
  cli-failure)
    exit 17
    ;;
  structured-failure)
    printf '%s\n' '{"structured_output":{"workflowCompleted":true,"agentsError":1,"lensResultCount":2,"summary":"fixture failure"}}'
    ;;
  success)
    printf '%s\n' '{"structured_output":{"workflowCompleted":true,"agentsError":0,"lensResultCount":3,"summary":"fixture success"}}'
    ;;
esac
EOF
chmod +x "$FAKE_BIN/claude"

RUN_ENV=(HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin")

# 같은 HOME에서 살아 있는 실행 잠금이 있으면 수집 전에 차단한다.
mkdir "$PIPE_DIR/run.lock"
printf '%s\n' "$$" > "$PIPE_DIR/run.lock/pid"
if env "${RUN_ENV[@]}" bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'concurrent run was accepted' >&2
  exit 1
fi
[ -e "$PIPE_DIR/run.lock/pid" ]
rm -f "$PIPE_DIR/run.lock/pid"
rmdir "$PIPE_DIR/run.lock"

# PID가 아직 기록되지 않은 잠금은 경쟁 구간일 수 있으므로 stale로 지우지 않는다.
mkdir "$PIPE_DIR/run.lock"
if env "${RUN_ENV[@]}" bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'pid-less lock was removed' >&2
  exit 1
fi
[ -d "$PIPE_DIR/run.lock" ]
rmdir "$PIPE_DIR/run.lock"

# 이전 실패의 stale pending은 지우고, 이번 gather가 상태를 못 만들면 분석 전에 멈춘다.
printf '{"version":1,"vaultFingerprint":"stale","files":[]}\n' > "$PIPE_DIR/pending-vault-state.json"
rm -f "$PIPE_DIR/received-wait-ceiling.txt" "$PIPE_DIR/received-claude-args.txt"
if env "${RUN_ENV[@]}" FAKE_GATHER_OMIT_VAULT_STATE=1 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'stale pending Vault state was accepted' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]
[ ! -e "$PIPE_DIR/pending-vault-state.json" ]

# Claude가 0으로 끝나도 구조화 완료 결과가 없으면 실패하고 커서는 전진하지 않는다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=logical-failure \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'logical failure was accepted' >&2
  exit 1
fi
[ "$(cat "$PIPE_DIR/received-wait-ceiling.txt")" = '3600000' ]
rg -q '^--output-format$' "$PIPE_DIR/received-claude-args.txt"
rg -q '^json$' "$PIPE_DIR/received-claude-args.txt"
rg -q '^--json-schema$' "$PIPE_DIR/received-claude-args.txt"
[ ! -e "$PIPE_DIR/cursor.json" ]
[ -e "$PIPE_DIR/pending-cursor.json" ]
rg -q 'Workflow 완료 검증 실패' "$PIPE_DIR/run.log"

# Claude 자체 실패도 같은 fail-closed 경로여야 한다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=cli-failure \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'Claude CLI failure was accepted' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/cursor.json" ]

# 형태가 맞는 JSON이어도 Workflow 오류나 렌즈 누락을 보고하면 커밋하지 않는다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=structured-failure \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'structured workflow failure was accepted' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/cursor.json" ]

# 성공은 쉘이 커서를 커밋하고 durable 상태를 전부 확인한 뒤에만 0으로 끝난다.
env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=success CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=7200000 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"
[ "$(cat "$PIPE_DIR/received-wait-ceiling.txt")" = '7200000' ]
jq -e '
  .version == 2
  and (.sources | keys | sort) == ["claude-code", "codex", "hermes"]
  and ((.committedAt | type) == "string")
' "$PIPE_DIR/cursor.json" >/dev/null
jq -e '.version == 1 and .vaultFingerprint == "fixture"' "$PIPE_DIR/vault-state.json" >/dev/null
[ ! -e "$PIPE_DIR/pending-cursor.json" ]
[ ! -e "$PIPE_DIR/pending-vault-state.json" ]
jq -e '.structured_output.agentsError == 0' "$PIPE_DIR/last-run-result.json" >/dev/null
rg -q '실행 종료\(status=0\)' "$PIPE_DIR/run.log"

# 신규 입력이 없으면 Claude를 호출하지 않고 기존 커서를 그대로 둔다.
CURSOR_BEFORE="$(shasum -a 256 "$PIPE_DIR/cursor.json" | awk '{print $1}')"
rm -f "$PIPE_DIR/received-wait-ceiling.txt" "$PIPE_DIR/received-claude-args.txt"
env "${RUN_ENV[@]}" FAKE_GATHER_EMPTY=1 bash "$REPO_DIR/claude/learning-pipeline/run.sh"
CURSOR_AFTER="$(shasum -a 256 "$PIPE_DIR/cursor.json" | awk '{print $1}')"
[ "$CURSOR_BEFORE" = "$CURSOR_AFTER" ]
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]

echo 'PASS: single-run lock/bounded wait/structured completion/shell-owned durable commit/fail-closed exit/no-change skip'
