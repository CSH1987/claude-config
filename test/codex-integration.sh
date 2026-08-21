#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-integration-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_HOME="$TEST_ROOT/home"
CODEX_HOME="$TEST_HOME/.codex"
VAULT="$TEST_HOME/Documents/Vault"
mkdir -p "$CODEX_HOME" "$VAULT/10_컨텍스트" "$VAULT/.obsidian/plugins/obsidian-local-rest-api" "$TEST_HOME/.claude"
printf '# 에버스 위키 홈\n' > "$VAULT/00_홈.md"
printf '# 테스트 패턴\n\n원문 확인 규칙.\n' > "$VAULT/10_컨텍스트/test.md"
printf '{"apiKey":"test-only-local-key","enableInsecureServer":true,"insecurePort":27123}\n' \
  > "$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json"
printf '{"vaultPath":"%s","projects":[]}\n' "$VAULT" > "$TEST_HOME/.claude/vault-scope.json"
printf '%s' "$REPO_DIR" > "$TEST_HOME/.claude/.config-sync-path"

cat > "$CODEX_HOME/config.toml" <<'EOF'
model = "gpt-5.6-sol"
model_reasoning_effort = "ultra"
default_permissions = ":workspace"

[features]
memories = false
chronicle = true

[tui]
status_line = ["current-dir"]

[memories]
generate = false
use = false

[mcp_servers.keep-me]
command = "keep-command"
EOF
cat > "$CODEX_HOME/hooks.json" <<'EOF'
{
  "description": "keep description",
  "hooks": {
    "SessionStart": [{"matcher":"startup","hooks":[{"type":"command","command":"keep-user-hook"}]}]
  }
}
EOF

OUTPUT="$TEST_ROOT/configure-output.txt"
HOME="$TEST_HOME" python3 "$REPO_DIR/codex/scripts/configure-codex-integration.py" \
  --codex-home "$CODEX_HOME" --repo-dir "$REPO_DIR" --vault-scope "$TEST_HOME/.claude/vault-scope.json" \
  --no-backup > "$OUTPUT"
! grep -q 'test-only-local-key\|Authorization\|127.0.0.1' "$OUTPUT"
python3 - "$CODEX_HOME/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], 'rb') as stream:
    data = tomllib.load(stream)
assert data['model'] == 'gpt-5.6-sol'
assert data['model_reasoning_effort'] == 'ultra'
assert data['approval_policy'] == 'never'
assert data['sandbox_mode'] == 'danger-full-access'
assert data['model_verbosity'] == 'low'
assert 'default_permissions' not in data
assert data['features']['hooks'] is True
assert data['features']['memories'] is True
assert data['features']['chronicle'] is True
assert data['memories']['generate_memories'] is True
assert data['memories']['use_memories'] is True
assert 'generate' not in data['memories']
assert 'use' not in data['memories']
assert data['mcp_servers']['keep-me']['command'] == 'keep-command'
assert data['mcp_servers']['vault-obsidian']['http_headers']['Authorization'] == 'Bearer test-only-local-key'
assert data['agents']['max_concurrent_threads_per_session'] == 3
assert data['agents']['default_subagent_model'] == 'gpt-5.6-terra'
assert data['agents']['default_subagent_reasoning_effort'] == 'high'
assert data['tui']['status_line'][0] == 'current-dir'
for item in ('model-with-reasoning', 'context-used', 'five-hour-limit', 'weekly-limit', 'used-tokens', 'estimated-thread-cost', 'git-branch'):
    assert data['tui']['status_line'].count(item) == 1
assert data['notice']['hide_full_access_warning'] is True
PY
python3 - "$CODEX_HOME/hooks.json" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
commands=[h['command'] for groups in data['hooks'].values() for group in groups for h in group['hooks']]
assert commands.count('keep-user-hook') == 1
assert commands.count('bash "$HOME/.codex/hooks/session-context.sh"') == 1
assert commands.count('bash "$HOME/.codex/hooks/session-end.sh"') == 1
assert commands.count('bash "$HOME/.codex/hooks/compact-lifecycle.sh"') == 2
PY
python3 - "$CODEX_HOME/config.toml" "$CODEX_HOME/hooks.json" <<'PY'
import os, stat, sys
for path in sys.argv[1:]:
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
PY

CONFIG_HASH="$(shasum -a 256 "$CODEX_HOME/config.toml" "$CODEX_HOME/hooks.json")"
HOME="$TEST_HOME" python3 "$REPO_DIR/codex/scripts/configure-codex-integration.py" \
  --codex-home "$CODEX_HOME" --repo-dir "$REPO_DIR" --vault-scope "$TEST_HOME/.claude/vault-scope.json" \
  --no-backup > "$OUTPUT"
[ "$CONFIG_HASH" = "$(shasum -a 256 "$CODEX_HOME/config.toml" "$CODEX_HOME/hooks.json")" ]

mkdir -p "$CODEX_HOME/hooks"
ln -s "$REPO_DIR/codex/hooks/session-context.sh" "$CODEX_HOME/hooks/session-context.sh"
ln -s "$REPO_DIR/codex/hooks/compact-lifecycle.sh" "$CODEX_HOME/hooks/compact-lifecycle.sh"
CONTEXT_OUTPUT="$TEST_ROOT/context-output.txt"
printf '{"source":"startup","session_id":"test"}\n' | \
  HOME="$TEST_HOME" CODEX_HOME="$CODEX_HOME" bash "$CODEX_HOME/hooks/session-context.sh" > "$CONTEXT_OUTPUT"
grep -q 'Vault 전체 파악' "$CONTEXT_OUTPUT"
grep -q '테스트 패턴' "$CONTEXT_OUTPUT"
! grep -q 'test-only-local-key' "$CONTEXT_OUTPUT" "$CODEX_HOME/AGENTS.md" "$TEST_HOME/.claude/vault-state/full-vault-index.json"

for event in PreCompact PostCompact; do
  COMPACT_OUTPUT="$TEST_ROOT/${event}.json"
  printf '{"hook_event_name":"%s","trigger":"auto","turn_id":"do-not-persist"}\n' "$event" | \
    HOME="$TEST_HOME" CODEX_HOME="$CODEX_HOME" bash "$CODEX_HOME/hooks/compact-lifecycle.sh" > "$COMPACT_OUTPUT"
  python3 - "$COMPACT_OUTPUT" "$event" <<'PY'
import json, sys
data=json.load(open(sys.argv[1], encoding='utf-8'))
assert data['continue'] is True
assert data['suppressOutput'] is True
assert isinstance(data['systemMessage'], str) and data['systemMessage']
assert 'do-not-persist' not in open(sys.argv[1], encoding='utf-8').read()
PY
done
printf 'not-json\n' | bash "$CODEX_HOME/hooks/compact-lifecycle.sh" | \
  python3 -c 'import json,sys; data=json.load(sys.stdin); assert data == {"continue": True, "suppressOutput": True}'

python3 - "$REPO_DIR" <<'PY'
import sys, tomllib
from pathlib import Path
root=Path(sys.argv[1])
profiles={p.name: tomllib.loads(p.read_text(encoding='utf-8')) for p in (root/'codex/profiles').glob('*.config.toml')}
assert profiles['safe.config.toml']['approval_policy'] == 'on-request'
assert profiles['safe.config.toml']['sandbox_mode'] == 'workspace-write'
assert profiles['routine.config.toml']['model'] == 'gpt-5.6-terra'
assert profiles['explore.config.toml']['model'] == 'gpt-5.6-luna'
for path in (root/'codex/agents').glob('*.toml'):
    data=tomllib.loads(path.read_text(encoding='utf-8'))
    assert all(isinstance(data[key], str) and data[key] for key in ('name', 'description', 'developer_instructions'))
PY

if command -v codex >/dev/null 2>&1; then
  PROMPT_INPUT="$TEST_ROOT/prompt-input.json"
  HOME="$TEST_HOME" CODEX_HOME="$CODEX_HOME" codex --strict-config features list >/dev/null
  # `codex debug` 자체는 --strict-config를 지원하지 않는다. 실제 strict exec는
  # 배포 후 acceptance에서 별도로 실행하고, 여기서는 공식 prompt-input 경로를 검증한다.
  HOME="$TEST_HOME" CODEX_HOME="$CODEX_HOME" codex --dangerously-bypass-hook-trust \
    debug prompt-input '격리 훅 검증' > "$PROMPT_INPUT"
  grep -q 'Vault 전체 파악' "$PROMPT_INPUT"
  ! grep -q 'test-only-local-key' "$PROMPT_INPUT"
fi

echo 'PASS: config preservation/full bypass/status line/agents/profiles/compact hooks/idempotency/local MCP secrecy/session context/official prompt-input'
