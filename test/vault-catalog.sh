#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vault-catalog-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
VAULT="$TEST_ROOT/Vault"
STATE="$TEST_ROOT/state.json"
PENDING="$TEST_ROOT/pending.json"
DOCUMENTS="$TEST_ROOT/documents.json"
CATALOG="$TEST_ROOT/catalog.json"
OVERVIEW="$TEST_ROOT/overview.txt"

mkdir -p "$VAULT/10_컨텍스트" "$VAULT/20_업무위키/프로세스" "$VAULT/30_결정로그" \
  "$VAULT/90_Hermes/데이터" "$VAULT/.obsidian/plugins/obsidian-local-rest-api" "$VAULT/.git"
printf '# 에버스 위키 홈\n' > "$VAULT/00_홈.md"
printf '# 원칙\n\n전체 원문을 확인한다.\n' > "$VAULT/10_컨텍스트/원칙.md"
printf '# 프로세스\n\n단계별로 처리한다.\n' > "$VAULT/20_업무위키/프로세스/처리.md"
printf '# 결정\n\n확정했다.\n' > "$VAULT/30_결정로그/결정.md"
printf 'name,value\n테스트,1\n' > "$VAULT/90_Hermes/데이터/표.csv"
printf '{"rows":[{"name":"테스트"}]}\n' > "$VAULT/90_Hermes/데이터/표.json"
printf '{"apiKey":"test-only-local-key","crypto":{"privateKey":"test-only-private"}}\n' \
  > "$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json"
printf 'git internals\n' > "$VAULT/.git/config"
printf 'outside must not be read\n' > "$TEST_ROOT/outside.md"
ln -s "$TEST_ROOT/outside.md" "$VAULT/outside-link.md"

python3 "$REPO_DIR/claude/hooks/vault-catalog.py" "$VAULT" \
  --state "$STATE" --pending-state "$PENDING" --documents-out "$DOCUMENTS" \
  --catalog-out "$CATALOG" --overview > "$OVERVIEW"

jq -e '.version == 1 and .counts.files == 8 and .counts.semanticDocuments == 4' "$CATALOG" >/dev/null
jq -e '.files[".obsidian/plugins/obsidian-local-rest-api/data.json"].kind == "sensitive"' "$CATALOG" >/dev/null
jq -e '.files["outside-link.md"].kind == "link" and (.files[".git/config"] == null)' "$CATALOG" >/dev/null
jq -e '.changes | length == 4' "$DOCUMENTS" >/dev/null
! grep -q 'test-only-local-key\|test-only-private\|outside must not be read' "$DOCUMENTS" "$OVERVIEW"
grep -q 'Vault 전체 파악' "$OVERVIEW"

cp "$PENDING" "$STATE"
python3 "$REPO_DIR/claude/hooks/vault-catalog.py" "$VAULT" \
  --state "$STATE" --pending-state "$PENDING" --documents-out "$DOCUMENTS" >/dev/null
jq -e '.changes | length == 0' "$DOCUMENTS" >/dev/null

printf '# 프로세스\n\n개선된 단계로 처리한다.\n' > "$VAULT/20_업무위키/프로세스/처리.md"
rm "$VAULT/30_결정로그/결정.md"
python3 "$REPO_DIR/claude/hooks/vault-catalog.py" "$VAULT" \
  --state "$STATE" --pending-state "$PENDING" --documents-out "$DOCUMENTS" >/dev/null
jq -e '[.changes[].status] | sort == ["changed","deleted"]' "$DOCUMENTS" >/dev/null

echo 'PASS: full inventory/semantic changes/secret metadata/symlink boundary/idempotency'
