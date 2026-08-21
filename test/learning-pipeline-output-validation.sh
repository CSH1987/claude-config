#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/learning-output-validation.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd)"
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_HOME="$TEST_ROOT/private-user"
VAULT="$TEST_HOME/Documents/Vault"
BASELINE="$TEST_ROOT/baseline.json"
CURRENT="$TEST_ROOT/current.json"
OUTPUT="$TEST_ROOT/output.txt"
VALIDATOR="$REPO_DIR/claude/learning-pipeline/validate-vault-output.py"
CATALOG="$REPO_DIR/claude/hooks/vault-catalog.py"
PRIVATE_UUID='123e4567-e89b-12d3-a456-426614174000'
CANONICAL_PATH='10_컨텍스트/AI_협업_패턴.md'
AUDIT_PATH='90_Hermes/학습이력/2026-08-21_학습분.md'
ROUTING_PATH='90_Hermes/라우팅제안/2026-08-21_라우팅제안.md'

reset_vault() {
  rm -rf "$VAULT"
  mkdir -p \
    "$VAULT/10_컨텍스트" \
    "$VAULT/20_업무위키" \
    "$VAULT/90_Hermes/학습이력" \
    "$VAULT/90_Hermes/라우팅제안"
}

capture_state() {
  local destination="$1"
  rm -f "$destination"
  HOME="$TEST_HOME" python3 "$CATALOG" "$VAULT" --pending-state "$destination"
  [ -s "$destination" ]
  jq -e '.files | type == "object"' "$destination" >/dev/null
}

validate() {
  local mode="$1"
  shift
  HOME="$TEST_HOME" python3 "$VALIDATOR" \
    --vault-root "$VAULT" \
    --baseline-state "$BASELINE" \
    --current-state "$CURRENT" \
    --mode "$mode" \
    "$@"
}

expect_failure() {
  local mode="$1"
  shift
  if validate "$mode" "$@" > "$OUTPUT" 2>&1; then
    echo "expected $mode validation failure" >&2
    exit 1
  fi
}

# 정확히 허용한 정본 Markdown 수정은 전체 상태 차이 검사에 통과한다.
reset_vault
printf '# 협업 패턴\n\n기존 일반화 규칙.\n' > "$VAULT/10_컨텍스트/AI_협업_패턴.md"
capture_state "$BASELINE"
printf '# 협업 패턴\n\n수정된 일반화 규칙.\n' > "$VAULT/10_컨텍스트/AI_협업_패턴.md"
capture_state "$CURRENT"
validate workflow-output --allowed-path "$CANONICAL_PATH" > "$OUTPUT"
grep -q '검사 통과' "$OUTPUT"

# 실행 날짜와 이름이 정확한 감사·라우팅 파일은 각각 허용할 수 있다.
reset_vault
capture_state "$BASELINE"
printf '# 학습 이력\n' > "$VAULT/$AUDIT_PATH"
printf '# 라우팅 제안\n' > "$VAULT/$ROUTING_PATH"
capture_state "$CURRENT"
NFD_AUDIT_PATH="$(python3 -c 'import sys, unicodedata; print(unicodedata.normalize("NFD", sys.argv[1]))' "$AUDIT_PATH")"
validate workflow-output \
  --allowed-path "$NFD_AUDIT_PATH" \
  --allowed-path "$ROUTING_PATH" > "$OUTPUT"
grep -q '검사 통과' "$OUTPUT"

# 같은 폴더여도 이번 실행의 정확한 이름과 다르면 거부한다.
reset_vault
capture_state "$BASELINE"
WRONG_AUDIT_PATH='90_Hermes/학습이력/2026-08-20_학습분.md'
printf '# 잘못된 날짜의 학습 이력\n' > "$VAULT/$WRONG_AUDIT_PATH"
capture_state "$CURRENT"
expect_failure workflow-output --allowed-path "$AUDIT_PATH"
grep -q 'outside_allowed_scope' "$OUTPUT"

# 정본도 이번 실행 allowlist에 없으면 허용되지 않는다.
reset_vault
printf '# 협업 패턴\n\n기존.\n' > "$VAULT/$CANONICAL_PATH"
capture_state "$BASELINE"
printf '# 협업 패턴\n\nallowlist 밖 수정.\n' > "$VAULT/$CANONICAL_PATH"
capture_state "$CURRENT"
expect_failure workflow-output
grep -q 'outside_allowed_scope' "$OUTPUT"

# 본문 식별정보는 탐지하되 실제 값은 오류에 다시 출력하지 않는다.
reset_vault
printf '# 협업 패턴\n\n기존.\n' > "$VAULT/$CANONICAL_PATH"
capture_state "$BASELINE"
printf '# 협업 패턴\n\n로컬 위치: %s/private\n세션: %s\n' \
  "$TEST_HOME" "$PRIVATE_UUID" > "$VAULT/10_컨텍스트/AI_협업_패턴.md"
capture_state "$CURRENT"
expect_failure workflow-output --allowed-path "$CANONICAL_PATH"
grep -q 'configured_home_absolute' "$OUTPUT"
grep -q 'uuid' "$OUTPUT"
! grep -q "$TEST_HOME\|$PRIVATE_UUID" "$OUTPUT"

# workflow-output은 Vault 전체 차이를 보고 허용 범위 밖 변경을 거부한다.
reset_vault
printf '# 업무\n\n기존 내용.\n' > "$VAULT/20_업무위키/업무.md"
capture_state "$BASELINE"
printf '# 업무\n\n범위 밖 수정.\n' > "$VAULT/20_업무위키/업무.md"
capture_state "$CURRENT"
expect_failure workflow-output --allowed-path "$CANONICAL_PATH"
grep -q 'outside_allowed_scope' "$OUTPUT"

# 허용된 정본 파일이어도 삭제는 거부한다.
reset_vault
printf '# 협업 패턴\n' > "$VAULT/10_컨텍스트/AI_협업_패턴.md"
capture_state "$BASELINE"
rm -f "$VAULT/10_컨텍스트/AI_협업_패턴.md"
capture_state "$CURRENT"
expect_failure workflow-output --allowed-path "$CANONICAL_PATH"
grep -q 'deletion_not_allowed' "$OUTPUT"

# 파일명 자체의 식별정보도 탐지하며 민감한 파일명을 출력하지 않는다.
reset_vault
capture_state "$BASELINE"
PRIVATE_FILENAME="${PRIVATE_UUID}.md"
printf '# 학습 이력\n' > "$VAULT/90_Hermes/학습이력/$PRIVATE_FILENAME"
capture_state "$CURRENT"
expect_failure workflow-output \
  --allowed-path "90_Hermes/학습이력/$PRIVATE_FILENAME"
grep -q 'uuid@파일명' "$OUTPUT"
grep -q '문서#[0-9a-f]\{12\}' "$OUTPUT"
! grep -q "$PRIVATE_FILENAME\|$PRIVATE_UUID" "$OUTPUT"

# 허용 폴더 안에서도 Markdown 이외 파일과 symlink는 거부한다.
reset_vault
capture_state "$BASELINE"
printf 'metadata\n' > "$VAULT/90_Hermes/학습이력/결과.txt"
capture_state "$CURRENT"
expect_failure workflow-output
grep -q 'non_markdown_not_allowed' "$OUTPUT"

reset_vault
printf '# 원본\n' > "$VAULT/10_컨텍스트/AI_협업_패턴.md"
capture_state "$BASELINE"
ln -s '../../10_컨텍스트/AI_협업_패턴.md' "$VAULT/90_Hermes/학습이력/링크.md"
capture_state "$CURRENT"
expect_failure workflow-output \
  --allowed-path '90_Hermes/학습이력/링크.md'
grep -q 'symlink_not_allowed' "$OUTPUT"

# 허용 파일의 중간 디렉터리가 Vault 밖 symlink면 catalog diff가 0이어도 거부한다.
reset_vault
OUTSIDE_CONTEXT="$TEST_ROOT/outside-context"
mkdir -p "$OUTSIDE_CONTEXT"
printf '# 외부 정본\n\n기존.\n' > "$OUTSIDE_CONTEXT/AI_협업_패턴.md"
rm -rf "$VAULT/10_컨텍스트"
ln -s "$OUTSIDE_CONTEXT" "$VAULT/10_컨텍스트"
capture_state "$BASELINE"
printf '# 외부 정본\n\n수정.\n' > "$OUTSIDE_CONTEXT/AI_협업_패턴.md"
capture_state "$CURRENT"
expect_failure workflow-output --allowed-path "$CANONICAL_PATH"
grep -q 'symlink_or_unsafe_path_component' "$OUTPUT"

# 현재 상태를 만든 뒤 파일이 다시 바뀌면 상태-실파일 해시 불일치로 거부한다.
reset_vault
printf '# 협업 패턴\n\n기존.\n' > "$VAULT/10_컨텍스트/AI_협업_패턴.md"
capture_state "$BASELINE"
printf '# 협업 패턴\n\n상태에 기록된 수정.\n' > "$VAULT/10_컨텍스트/AI_협업_패턴.md"
capture_state "$CURRENT"
printf '# 협업 패턴\n\n상태 생성 뒤 동시 수정.\n' > "$VAULT/10_컨텍스트/AI_협업_패턴.md"
expect_failure workflow-output --allowed-path "$CANONICAL_PATH"
grep -q 'state_hash_mismatch' "$OUTPUT"

# 허용 경로 자체도 안전한 Vault 상대 Markdown 경로여야 한다.
expect_failure workflow-output --allowed-path '../outside.md'
grep -q '허용 경로가 안전한 Vault 상대 Markdown 경로가 아님' "$OUTPUT"
! grep -q '\.\./outside\.md' "$OUTPUT"
expect_failure workflow-output --allowed-path '90_Hermes/학습이력/결과.txt'
grep -q '허용 경로가 안전한 Vault 상대 Markdown 경로가 아님' "$OUTPUT"

# input은 실제 LLM에 전달되는 모든 human semantic 문서를 폴더와 확장자에 관계없이 검사한다.
reset_vault
printf '# 업무\n\n기존.\n' > "$VAULT/20_업무위키/업무.md"
capture_state "$BASELINE"
printf '# 업무\n\n로컬 위치: %s/private\n' "$TEST_HOME" > "$VAULT/20_업무위키/업무.md"
capture_state "$CURRENT"
expect_failure input
grep -q 'configured_home_absolute' "$OUTPUT"

reset_vault
printf '기존 텍스트\n' > "$VAULT/20_업무위키/업무.txt"
printf '{"nodes":[]}' > "$VAULT/20_업무위키/업무.canvas"
capture_state "$BASELINE"
printf '세션 %s\n' "$PRIVATE_UUID" > "$VAULT/20_업무위키/업무.txt"
printf '{"path":"%s/private"}' "$TEST_HOME" > "$VAULT/20_업무위키/업무.canvas"
capture_state "$CURRENT"
expect_failure input
grep -q 'uuid\|configured_home_absolute' "$OUTPUT"

# generated 본문은 입력 데이터에 포함되지 않으므로 본문 값은 재검사하지 않되,
# 전송되는 파일명과 삭제 경로의 식별정보는 막는다.
reset_vault
mkdir -p "$VAULT/90_Hermes/로그"
capture_state "$BASELINE"
printf '# 생성 로그\n\n%s/private\n' "$TEST_HOME" > "$VAULT/90_Hermes/로그/일반.md"
capture_state "$CURRENT"
validate input > "$OUTPUT"
grep -q '검사 통과' "$OUTPUT"

reset_vault
PRIVATE_DELETED_PATH="20_업무위키/${PRIVATE_UUID}.md"
printf '# 삭제 예정\n' > "$VAULT/$PRIVATE_DELETED_PATH"
capture_state "$BASELINE"
rm -f "$VAULT/$PRIVATE_DELETED_PATH"
capture_state "$CURRENT"
expect_failure input
grep -q 'uuid@파일명' "$OUTPUT"
! grep -q "$PRIVATE_UUID" "$OUTPUT"

# input은 10_컨텍스트의 일반 human 문서도 본문까지 검사한다.
reset_vault
printf '# 기록\n\n기존.\n' > "$VAULT/10_컨텍스트/기록.md"
capture_state "$BASELINE"
printf '# 기록\n\n세션: %s\n' "$PRIVATE_UUID" > "$VAULT/10_컨텍스트/기록.md"
capture_state "$CURRENT"
expect_failure input
grep -q 'uuid' "$OUTPUT"
! grep -q "$PRIVATE_UUID" "$OUTPUT"

echo 'PASS: full-state Vault input/output validation fails closed without identifier echoes'
