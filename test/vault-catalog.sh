#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vault-catalog-test.XXXXXX")"
trap 'chmod -R u+rwx "$TEST_ROOT" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT
VAULT="$TEST_ROOT/Vault"
STATE="$TEST_ROOT/state.json"
PENDING="$TEST_ROOT/pending.json"
DOCUMENTS="$TEST_ROOT/documents.json"
CATALOG="$TEST_ROOT/catalog.json"
OVERVIEW="$TEST_ROOT/overview.txt"

mkdir -p "$VAULT/10_컨텍스트" "$VAULT/20_업무위키/프로세스" "$VAULT/30_결정로그" \
  "$VAULT/90_Hermes/데이터" "$VAULT/90_Hermes/학습이력" \
  "$VAULT/.obsidian/plugins/obsidian-local-rest-api" "$VAULT/.git"
printf '# 에버스 위키 홈\n' > "$VAULT/00_홈.md"
printf '# 원칙\n\n전체 원문을 확인한다.\n' > "$VAULT/10_컨텍스트/원칙.md"
printf '# AI 협업 패턴\n\n렌즈가 별도 원문으로 읽는다.\n' > "$VAULT/10_컨텍스트/AI_협업_패턴.md"
printf '# 프로세스\n\n단계별로 처리한다.\n' > "$VAULT/20_업무위키/프로세스/처리.md"
printf '# 토큰 최적화\n\n대화 비용을 줄인다.\n' > "$VAULT/20_업무위키/token-optimization.md"
printf '# 비밀 관리 원칙\n\n민감값은 문서에 복사하지 않는다.\n' > "$VAULT/20_업무위키/secret-management.md"
printf '# 환경 설명\n\n일반 업무 환경 문서다.\n' > "$VAULT/20_업무위키/.environment.md"
printf '# 결정\n\n확정했다.\n' > "$VAULT/30_결정로그/결정.md"
printf 'name,value\n테스트,1\n' > "$VAULT/90_Hermes/데이터/표.csv"
printf '{"rows":[{"name":"테스트"}]}\n' > "$VAULT/90_Hermes/데이터/표.json"
printf '# 자동 학습 기록\n\n다시 학습하면 안 되는 생성 본문.\n' > "$VAULT/90_Hermes/학습이력/자동.md"
printf '{"apiKey":"test-only-local-key","crypto":{"privateKey":"test-only-private"}}\n' \
  > "$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json"
printf 'git internals\n' > "$VAULT/.git/config"
printf 'outside must not be read\n' > "$TEST_ROOT/outside.md"
ln -s "$TEST_ROOT/outside.md" "$VAULT/outside-link.md"

python3 "$REPO_DIR/claude/hooks/vault-catalog.py" "$VAULT" \
  --state "$STATE" --pending-state "$PENDING" --documents-out "$DOCUMENTS" \
  --catalog-out "$CATALOG" --overview > "$OVERVIEW"

jq -e '.version == 1 and .counts.files == 13 and .counts.semanticDocuments == 9' "$CATALOG" >/dev/null
jq -e '.files[".obsidian/plugins/obsidian-local-rest-api/data.json"].kind == "sensitive"' "$CATALOG" >/dev/null
jq -e '.files["outside-link.md"].kind == "link" and (.files[".git/config"] == null)' "$CATALOG" >/dev/null
jq -e '.changes | length == 9' "$DOCUMENTS" >/dev/null
jq -e '
  .files["20_업무위키/token-optimization.md"].authorship == "human"
  and .files["20_업무위키/token-optimization.md"].semantic == true
  and .files["20_업무위키/secret-management.md"].semantic == true
  and .files["20_업무위키/.environment.md"].semantic == true
' "$CATALOG" >/dev/null
jq -e '.changes[] | select(.path == "90_Hermes/학습이력/자동.md") | .authorship == "generated" and .contentPolicy == "generated-metadata-only" and .text == ""' "$DOCUMENTS" >/dev/null
jq -e '.changes[] | select(.path == "10_컨텍스트/AI_협업_패턴.md") | .contentPolicy == "canonical-read-separately" and .text == ""' "$DOCUMENTS" >/dev/null
! grep -q 'test-only-local-key\|test-only-private\|outside must not be read' "$DOCUMENTS" "$OVERVIEW"
! grep -q '다시 학습하면 안 되는 생성 본문' "$DOCUMENTS"
! grep -q '렌즈가 별도 원문으로 읽는다' "$DOCUMENTS"
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

# 사람이 쓴 문서를 UTF-8로 완전히 읽지 못하면 state만 앞서 교체하지 않는다.
PENDING_HASH="$(shasum -a 256 "$PENDING" | awk '{print $1}')"
DOCUMENTS_HASH="$(shasum -a 256 "$DOCUMENTS" | awk '{print $1}')"
printf '\377\376' > "$VAULT/20_업무위키/읽기실패.md"
if python3 "$REPO_DIR/claude/hooks/vault-catalog.py" "$VAULT" --strict \
  --state "$STATE" --pending-state "$PENDING" --documents-out "$DOCUMENTS" >/dev/null 2>&1; then
  echo 'invalid UTF-8 human document was silently accepted' >&2
  exit 1
fi
[ "$PENDING_HASH" = "$(shasum -a 256 "$PENDING" | awk '{print $1}')" ]
[ "$DOCUMENTS_HASH" = "$(shasum -a 256 "$DOCUMENTS" | awk '{print $1}')" ]
rm "$VAULT/20_업무위키/읽기실패.md"

# 하위 폴더를 순회하지 못하면 열린 폴더만으로 불완전한 스냅샷을 확정하지 않는다.
mkdir -p "$VAULT/20_업무위키/읽기불가"
printf '# 숨은 문서\n' > "$VAULT/20_업무위키/읽기불가/숨은문서.md"
chmod 000 "$VAULT/20_업무위키/읽기불가"
if [ ! -r "$VAULT/20_업무위키/읽기불가/숨은문서.md" ]; then
  if python3 "$REPO_DIR/claude/hooks/vault-catalog.py" "$VAULT" --strict \
    --state "$STATE" --pending-state "$PENDING" --documents-out "$DOCUMENTS" >/dev/null 2>&1; then
    echo 'unreadable Vault directory was silently skipped' >&2
    exit 1
  fi
  [ "$PENDING_HASH" = "$(shasum -a 256 "$PENDING" | awk '{print $1}')" ]
  [ "$DOCUMENTS_HASH" = "$(shasum -a 256 "$DOCUMENTS" | awk '{print $1}')" ]
fi
chmod 700 "$VAULT/20_업무위키/읽기불가"

echo 'PASS: full inventory/semantic changes/secret metadata/symlink boundary/idempotency'
