#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/learning-run-test.XXXXXX")"
TEST_HOME="$TEST_ROOT/home"
PIPE_DIR="$TEST_HOME/.claude/learning-pipeline"
VAULT="$TEST_HOME/Documents/Vault"
FAKE_BIN="$TEST_ROOT/bin"
TODAY_LOCAL="$(date +%Y-%m-%d)"

cleanup_test() {
  local test_status=$?
  if [ "$test_status" -ne 0 ] && [ -f "$PIPE_DIR/run.log" ]; then
    tail -n 120 "$PIPE_DIR/run.log" >&2 || true
  fi
  if [ "$test_status" -ne 0 ] && [ "${KEEP_TEST_TMP:-0}" = '1' ]; then
    printf 'kept test fixture: %s\n' "$TEST_ROOT" >&2
    trap - EXIT
    exit "$test_status"
  fi
  rm -rf "$TEST_ROOT"
  trap - EXIT
  exit "$test_status"
}
trap cleanup_test EXIT
mkdir -p "$PIPE_DIR" "$VAULT/10_컨텍스트" "$FAKE_BIN"

printf '# 패턴\n' > "$VAULT/10_컨텍스트/pattern.md"
printf '{"vaultPath":"%s","projects":[]}\n' "$VAULT" > "$TEST_HOME/.claude/vault-scope.json"
cp "$REPO_DIR/claude/learning-pipeline/commit-cursor.sh" "$PIPE_DIR/commit-cursor-real.sh"
cp "$REPO_DIR/claude/learning-pipeline/validate-vault-output.py" "$PIPE_DIR/validate-vault-output.py"
cp "$REPO_DIR/claude/hooks/vault-catalog.py" "$PIPE_DIR/vault-catalog.py"
printf 'export default {}\n' > "$PIPE_DIR/pipeline.workflow.js"

cat > "$PIPE_DIR/commit-cursor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAKE_KILL_AFTER_VAULT_STATE:-0}" = '1' ]; then
  mv -f "$HOME/.claude/learning-pipeline/pending-vault-state.json" \
    "$HOME/.claude/learning-pipeline/vault-state.json"
  kill -TERM "$PPID"
  exit 143
fi
bash "$HOME/.claude/learning-pipeline/commit-cursor-real.sh"
if [ "${FAKE_DROP_BOUNDARY_IDS:-0}" = '1' ]; then
  cursor="$HOME/.claude/learning-pipeline/cursor.json"
  corrupted="$HOME/.claude/learning-pipeline/.cursor-without-boundary.json"
  jq 'del(.boundaryIds)' "$cursor" > "$corrupted"
  chmod 600 "$corrupted"
  mv -f "$corrupted" "$cursor"
fi
if [ "${FAKE_CORRUPT_BOUNDARY_STARTS:-0}" = '1' ]; then
  cursor="$HOME/.claude/learning-pipeline/cursor.json"
  corrupted="$HOME/.claude/learning-pipeline/.cursor-short-boundary.json"
  jq '.boundaryStarts = .sources' "$cursor" > "$corrupted"
  chmod 600 "$corrupted"
  mv -f "$corrupted" "$cursor"
fi
if [ "${FAKE_KILL_AFTER_COMMIT:-0}" = '1' ]; then
  kill -TERM "$PPID"
  exit 143
fi
EOF

cat > "$PIPE_DIR/gather.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="$HOME/.claude/learning-pipeline"
VAULT=$(jq -r '.vaultPath' "$HOME/.claude/vault-scope.json")
fixture_timestamp='2026-08-21T00:00:00.000000Z'
fixture_boundary_start='2026-08-20T00:00:00.000000Z'
if [ "${FAKE_FUTURE_TIMESTAMP:-0}" = '1' ]; then
  fixture_timestamp='2999-01-01T00:00:00.000000Z'
  fixture_boundary_start='2998-12-31T00:00:00.000000Z'
fi
[ "${FAKE_SHORT_BOUNDARY_WINDOW:-0}" = '1' ] && fixture_boundary_start="$fixture_timestamp"
if [ "${FAKE_GATHER_EMPTY:-0}" = '1' ] || [ "${FAKE_GATHER_GENERATED_ONLY:-0}" = '1' ]; then
  printf '[]\n' > "$DIR/gathered-utterances.json"
else
  printf '[{"source":"codex","session":"s","ts":"%s","text":"테스트"}]\n' "$fixture_timestamp" > "$DIR/gathered-utterances.json"
fi
if [ "${FAKE_GATHER_GENERATED_ONLY:-0}" = '1' ]; then
  mkdir -p "$VAULT/90_Hermes/로그"
  printf '# 생성 로그\n' > "$VAULT/90_Hermes/로그/generated.md"
fi
if [ "${FAKE_GATHER_GENERATED_ONLY:-0}" = '1' ]; then
  printf '{"version":1,"changes":[{"path":"90_Hermes/로그/generated.md","authorship":"generated","contentPolicy":"generated-metadata-only","text":""}],"initialFullScan":false}\n' > "$DIR/gathered-vault-documents.json"
else
  printf '{"version":1,"changes":[],"initialFullScan":false}\n' > "$DIR/gathered-vault-documents.json"
fi
printf '{"version":2,"lastProcessed":"%s","sources":{"claude-code":"%s","hermes":"%s","codex":"%s"},"boundaryIds":{"claude-code":[],"hermes":[],"codex":[]},"boundaryStarts":{"claude-code":"%s","hermes":"%s","codex":"%s"},"committedAt":null}\n' \
  "$fixture_timestamp" "$fixture_timestamp" "$fixture_timestamp" "$fixture_timestamp" \
  "$fixture_boundary_start" "$fixture_boundary_start" "$fixture_boundary_start" > "$DIR/pending-cursor.json"
if [ "${FAKE_GATHER_OMIT_VAULT_STATE:-0}" != '1' ]; then
  python3 "$DIR/vault-catalog.py" "$VAULT" --pending-state "$DIR/pending-vault-state.json"
fi
EOF
chmod +x "$PIPE_DIR/gather.sh" "$PIPE_DIR/commit-cursor.sh" "$PIPE_DIR/validate-vault-output.py" "$PIPE_DIR/vault-catalog.py"

cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-missing}" > "$HOME/.claude/learning-pipeline/received-wait-ceiling.txt"
printf '%s\n' "${CLAUDE_VAULT_SESSION_LOG_OFF:-missing}" > "$HOME/.claude/learning-pipeline/received-session-log-off.txt"
printf '%s\n' "$@" > "$HOME/.claude/learning-pipeline/received-claude-args.txt"
VAULT=$(jq -r '.vaultPath' "$HOME/.claude/vault-scope.json")
today=$(date +%Y-%m-%d)
write_routing() {
  mkdir -p "$VAULT/90_Hermes/라우팅제안"
  printf '# 라우팅 제안\n\n검증용 일반화 제안.\n' >> "$VAULT/90_Hermes/라우팅제안/${today}_라우팅제안.md"
}
write_audit() {
  mkdir -p "$VAULT/90_Hermes/학습이력"
  printf '# 학습 이력\n\n검증용 일반화 기록.\n' >> "$VAULT/90_Hermes/학습이력/${today}_학습분.md"
}
case "${FAKE_CLAUDE_MODE:-success}" in
  logical-failure)
    printf '%s\n' 'Background tasks still running after 600s; terminating.'
    exit 0
    ;;
  cli-failure)
    exit 17
    ;;
  structured-failure)
    if [ "${FAKE_WRITE_OUTSIDE:-0}" = '1' ]; then
      mkdir -p "$VAULT/20_업무위키"
      printf '# 허용 범위 밖 변경\n' > "$VAULT/20_업무위키/unexpected.md"
    fi
    printf '%s\n' '{"structured_output":{"workflowCompleted":true,"agentsError":1,"agentsEmptyResult":0,"agentsSkipped":0,"lensResultCount":2,"synthesisRequired":false,"synthesisCompleted":false,"auditRequired":false,"auditReported":false,"routingRequired":true,"routingCompleted":false,"summary":"fixture failure"}}'
    ;;
  empty-result)
    printf '%s\n' '{"structured_output":{"workflowCompleted":true,"agentsError":0,"agentsEmptyResult":1,"agentsSkipped":0,"lensResultCount":3,"synthesisRequired":false,"synthesisCompleted":false,"auditRequired":false,"auditReported":false,"routingRequired":true,"routingCompleted":true,"summary":"empty result"}}'
    ;;
  skipped-agent)
    printf '%s\n' '{"structured_output":{"workflowCompleted":true,"agentsError":0,"agentsEmptyResult":0,"agentsSkipped":1,"lensResultCount":3,"synthesisRequired":false,"synthesisCompleted":false,"auditRequired":false,"auditReported":false,"routingRequired":true,"routingCompleted":true,"summary":"skipped agent"}}'
    ;;
  synthesis-no-write)
    write_routing
    printf '%s\n' '{"structured_output":{"workflowCompleted":true,"agentsError":0,"agentsEmptyResult":0,"agentsSkipped":0,"lensResultCount":3,"synthesisRequired":true,"synthesisCompleted":true,"auditRequired":true,"auditReported":true,"routingRequired":true,"routingCompleted":true,"summary":"missing audit write"}}'
    ;;
  unexpected-canonical)
    write_routing
    printf '# 패턴\n\n허용되지 않은 캐노니컬 변경.\n' > "$VAULT/10_컨텍스트/AI_협업_패턴.md"
    printf '%s\n' '{"structured_output":{"workflowCompleted":true,"agentsError":0,"agentsEmptyResult":0,"agentsSkipped":0,"lensResultCount":3,"synthesisRequired":false,"synthesisCompleted":false,"auditRequired":false,"auditReported":false,"routingRequired":true,"routingCompleted":true,"summary":"unexpected canonical write"}}'
    ;;
  wrong-routing-name)
    mkdir -p "$VAULT/90_Hermes/라우팅제안"
    printf '# 잘못된 이름\n' > "$VAULT/90_Hermes/라우팅제안/wrong.md"
    printf '%s\n' '{"structured_output":{"workflowCompleted":true,"agentsError":0,"agentsEmptyResult":0,"agentsSkipped":0,"lensResultCount":3,"synthesisRequired":false,"synthesisCompleted":false,"auditRequired":false,"auditReported":false,"routingRequired":true,"routingCompleted":true,"summary":"wrong routing filename"}}'
    ;;
  success-with-synthesis)
    write_routing
    write_audit
    printf '%s\n' '{"structured_output":{"workflowCompleted":true,"agentsError":0,"agentsEmptyResult":0,"agentsSkipped":0,"lensResultCount":3,"synthesisRequired":true,"synthesisCompleted":true,"auditRequired":true,"auditReported":true,"routingRequired":true,"routingCompleted":true,"summary":"fixture synthesis success"}}'
    ;;
  success)
    write_routing
    printf '%s\n' '{"structured_output":{"workflowCompleted":true,"agentsError":0,"agentsEmptyResult":0,"agentsSkipped":0,"lensResultCount":3,"synthesisRequired":false,"synthesisCompleted":false,"auditRequired":false,"auditReported":false,"routingRequired":true,"routingCompleted":true,"summary":"fixture success"}}'
    ;;
esac
EOF
chmod +x "$FAKE_BIN/claude"

cat > "$FAKE_BIN/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
last="${!#}"
if [ "${FAKE_MV_FAIL_RESULT:-0}" = '1' ] && [[ "$last" == */last-run-result.json ]]; then
  exit 19
fi
if [ "${FAKE_KILL_AFTER_VERIFIED_MARKER:-0}" = '1' ] \
  && [[ "$last" == */workflow-state-marker.json ]] \
  && jq -e '.phase == "verified_post"' "${2:-}" >/dev/null 2>&1; then
  /bin/mv "$@"
  kill -TERM "$PPID"
  exit 143
fi
exec /bin/mv "$@"
EOF
chmod +x "$FAKE_BIN/mv"

cat > "$FAKE_BIN/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAKE_CATALOG_MUTATE_ON_VERIFY:-0}" = '1' ] && [[ "${1:-}" == */vault-catalog.py ]]; then
  count_file="$HOME/.claude/learning-pipeline/fake-catalog-count"
  count=0
  [ -f "$count_file" ] && count=$(cat "$count_file")
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq "${FAKE_CATALOG_MUTATE_AT:-3}" ]; then
    vault=$(jq -r '.vaultPath' "$HOME/.claude/vault-scope.json")
    mkdir -p "$vault/20_업무위키"
    printf '# 검증 중 동시 변경\n' > "$vault/20_업무위키/concurrent.md"
  fi
fi
exec "$REAL_PYTHON_BIN" "$@"
EOF
chmod +x "$FAKE_BIN/python3"

RUN_ENV=(HOME="$TEST_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" REAL_PYTHON_BIN="$(command -v python3)")

# 로그 경로를 열 수 없으면 작업을 시작하지 않고 nonzero로 끝나며 잠금도 정리한다.
mkdir "$PIPE_DIR/run.log"
if env "${RUN_ENV[@]}" bash "$REPO_DIR/claude/learning-pipeline/run.sh" >/dev/null 2>&1; then
  echo 'log open failure returned success' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/run.lock" ]
rmdir "$PIPE_DIR/run.log"

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
# PID 기록 전 종료된 빈 잠금이 60초 이상 지났으면 다음 실행이 회수할 수 있다.
touch -t 202001010000 "$PIPE_DIR/run.lock"

# 이전 실패의 stale pending은 지우고, 이번 gather가 상태를 못 만들면 분석 전에 멈춘다.
printf '{"version":1,"vaultFingerprint":"stale","files":{}}\n' > "$PIPE_DIR/pending-vault-state.json"
rm -f "$PIPE_DIR/received-wait-ceiling.txt" "$PIPE_DIR/received-claude-args.txt"
if env "${RUN_ENV[@]}" FAKE_GATHER_OMIT_VAULT_STATE=1 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'stale pending Vault state was accepted' >&2
  exit 1
fi
[ ! -d "$PIPE_DIR/run.lock" ]
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]
[ ! -e "$PIPE_DIR/pending-vault-state.json" ]

# 미래 시각 하나가 소스 커서를 영구히 앞으로 밀지 않도록 Claude 호출 전에 거부한다.
if env "${RUN_ENV[@]}" FAKE_FUTURE_TIMESTAMP=1 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'future source timestamp was accepted' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]
[ ! -e "$PIPE_DIR/cursor.json" ]
rg -q '수집 결과 검증 실패|pending 커서·Vault 상태 검증 실패' "$PIPE_DIR/run.log"

# overlap 시작점은 소스 커서보다 정확히 24시간 앞이어야 한다.
if env "${RUN_ENV[@]}" FAKE_SHORT_BOUNDARY_WINDOW=1 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'short cursor overlap window was accepted' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]
[ ! -e "$PIPE_DIR/cursor.json" ]
rg -q 'pending 커서·Vault 상태 검증 실패' "$PIPE_DIR/run.log"

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
# 안전한 marker 정리 중 baseline 삭제 직후 종료된 in-progress marker-only도 복구한다.
rm -f "$PIPE_DIR/workflow-baseline-vault-state.json"

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

# 실패한 Workflow가 허용 범위 밖 파일을 남기면 다음 실행이 그것을 새 입력으로 흡수하지 않는다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=structured-failure FAKE_WRITE_OUTSIDE=1 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'workflow failure with out-of-scope write was accepted' >&2
  exit 1
fi
[ -e "$PIPE_DIR/workflow-state-marker.json" ]
[ -e "$PIPE_DIR/workflow-baseline-vault-state.json" ]
rm -f "$PIPE_DIR/received-wait-ceiling.txt" "$PIPE_DIR/received-claude-args.txt"
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=success \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'quarantined out-of-scope write was absorbed on retry' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]
rg -q '자동 흡수하지 않고 로컬 격리 상태 보존' "$PIPE_DIR/run.log"
rm -f "$VAULT/20_업무위키/unexpected.md"
rmdir "$VAULT/20_업무위키" 2>/dev/null || true

# 빈 결과나 스킵된 핵심 에이전트도 오류 수가 0이어도 성공이 아니다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=empty-result \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'empty core result was accepted' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/cursor.json" ]
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=skipped-agent \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'skipped core agent was accepted' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/cursor.json" ]

# synthesis가 성공했다고 복창해도 실제 학습이력 파일이 바뀌지 않으면 커밋하지 않는다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=synthesis-no-write \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'missing synthesis audit write was accepted' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/cursor.json" ]
rg -q '필수 학습이력 파일의 실제 변경을 확인하지 못함' "$PIPE_DIR/run.log"
rm -f "$VAULT/90_Hermes/라우팅제안/${TODAY_LOCAL}_라우팅제안.md"
rmdir "$VAULT/90_Hermes/라우팅제안" 2>/dev/null || true
rmdir "$VAULT/90_Hermes" 2>/dev/null || true

# 구조화 플래그가 synthesis 불필요라고 하면 캐노니컬 3종은 이번 실행 허용 대상이 아니다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=unexpected-canonical \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'canonical write without synthesis requirement was accepted' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/cursor.json" ]
rg -q 'Workflow 출력 범위·식별정보 검증 실패' "$PIPE_DIR/run.log"
rm -f "$VAULT/10_컨텍스트/AI_협업_패턴.md"
rm -f "$VAULT/90_Hermes/라우팅제안/${TODAY_LOCAL}_라우팅제안.md"
rmdir "$VAULT/90_Hermes/라우팅제안" "$VAULT/90_Hermes" 2>/dev/null || true

# 라우팅 산출물은 해당 실행 날짜의 정확한 파일명 하나만 허용한다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=wrong-routing-name \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'wrong routing filename was accepted' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/cursor.json" ]
rg -q 'Workflow 출력 범위·식별정보 검증 실패' "$PIPE_DIR/run.log"
rm -f "$VAULT/90_Hermes/라우팅제안/wrong.md"
rmdir "$VAULT/90_Hermes/라우팅제안" "$VAULT/90_Hermes" 2>/dev/null || true

# 새 결과 이동이 실패하면 이전의 정상 형태 결과를 재사용하지 않는다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=success FAKE_MV_FAIL_RESULT=1 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'stale structured result was reused after mv failure' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/cursor.json" ]
rm -f "$VAULT/90_Hermes/라우팅제안/${TODAY_LOCAL}_라우팅제안.md"
rmdir "$VAULT/90_Hermes/라우팅제안" 2>/dev/null || true
rmdir "$VAULT/90_Hermes" 2>/dev/null || true

# post-scan과 검증 재스캔 사이의 동시 Vault 변경도 실패하며 다음 실행에 흡수되지 않는다.
rm -f "$PIPE_DIR/fake-catalog-count"
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=success FAKE_CATALOG_MUTATE_ON_VERIFY=1 FAKE_CATALOG_MUTATE_AT=5 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'concurrent Vault mutation was accepted' >&2
  exit 1
fi
[ -e "$PIPE_DIR/workflow-state-marker.json" ]
rg -q '검증 중 Vault가 다시 변경됨' "$PIPE_DIR/run.log"
rm -f "$VAULT/90_Hermes/라우팅제안/${TODAY_LOCAL}_라우팅제안.md" "$VAULT/20_업무위키/concurrent.md"
rmdir "$VAULT/90_Hermes/라우팅제안" "$VAULT/90_Hermes" "$VAULT/20_업무위키" 2>/dev/null || true
rm -f "$PIPE_DIR/fake-catalog-count"

# 실패 실행이 남긴 Vault 변경을 원복한 뒤에는 marker를 자동 해제할 수 있어야 한다.
rm -f "$PIPE_DIR/received-wait-ceiling.txt" "$PIPE_DIR/received-claude-args.txt"
env "${RUN_ENV[@]}" FAKE_GATHER_EMPTY=1 bash "$REPO_DIR/claude/learning-pipeline/run.sh"
[ ! -e "$PIPE_DIR/workflow-state-marker.json" ]
[ ! -e "$PIPE_DIR/workflow-baseline-vault-state.json" ]
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]

# gather 뒤 Workflow 호출 직전에 생긴 동시 변경은 Claude를 부르기 전에 재시도로 돌린다.
rm -f "$PIPE_DIR/fake-catalog-count" "$PIPE_DIR/received-wait-ceiling.txt" "$PIPE_DIR/received-claude-args.txt"
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=success FAKE_CATALOG_MUTATE_ON_VERIFY=1 FAKE_CATALOG_MUTATE_AT=2 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'pre-workflow concurrent Vault mutation was accepted' >&2
  exit 1
fi
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]
[ ! -e "$PIPE_DIR/workflow-state-marker.json" ]
rg -q 'Workflow 호출 직전 Vault 상태가 달라졌거나' "$PIPE_DIR/run.log"
rm -f "$VAULT/20_업무위키/concurrent.md" "$PIPE_DIR/fake-catalog-count"
rmdir "$VAULT/20_업무위키" 2>/dev/null || true

# 성공은 쉘이 커서를 커밋하고 durable 상태를 전부 확인한 뒤에만 0으로 끝난다.
PRIVACY_CURSOR_BEFORE="$(cat "$PIPE_DIR/cursor.json")"
printf '# 패턴\n\n%s/private/file\n' "$TEST_HOME" > "$VAULT/10_컨텍스트/pattern.md"
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=success \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'privacy validation failure was accepted' >&2
  exit 1
fi
[ "$PRIVACY_CURSOR_BEFORE" = "$(cat "$PIPE_DIR/cursor.json")" ]
rg -q 'Workflow 입력 식별정보 검증 실패' "$PIPE_DIR/run.log"

printf '# 패턴\n\n식별정보 없는 일반화 규칙.\n' > "$VAULT/10_컨텍스트/pattern.md"

# verified_post marker 직후 post state 이동 전에 종료돼도 live 재스캔으로 커밋을 완성한다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=success FAKE_KILL_AFTER_VERIFIED_MARKER=1 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'verified marker kill fixture unexpectedly returned success' >&2
  exit 1
fi
[ -e "$PIPE_DIR/workflow-state-marker.json" ]
jq -e '.phase == "verified_post"' "$PIPE_DIR/workflow-state-marker.json" >/dev/null
[ -e "$PIPE_DIR/pending-cursor.json" ]
rm -f "$PIPE_DIR/received-wait-ceiling.txt" "$PIPE_DIR/received-claude-args.txt"
env "${RUN_ENV[@]}" FAKE_GATHER_EMPTY=1 bash "$REPO_DIR/claude/learning-pipeline/run.sh"
[ ! -e "$PIPE_DIR/workflow-state-marker.json" ]
[ ! -e "$PIPE_DIR/workflow-baseline-vault-state.json" ]
[ ! -e "$PIPE_DIR/pending-cursor.json" ]
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]

# vault-state를 옮긴 직후 cursor 전진 전에 종료돼도 검증된 post 상태로 커밋을 완성한다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=success FAKE_KILL_AFTER_VAULT_STATE=1 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'partial commit kill fixture unexpectedly returned success' >&2
  exit 1
fi
[ -e "$PIPE_DIR/workflow-state-marker.json" ]
jq -e '.phase == "verified_post" and ((.expectedCommitToken | type) == "string")' \
  "$PIPE_DIR/workflow-state-marker.json" >/dev/null
[ -e "$PIPE_DIR/pending-cursor.json" ]
[ ! -e "$PIPE_DIR/pending-vault-state.json" ]
rm -f "$PIPE_DIR/received-wait-ceiling.txt" "$PIPE_DIR/received-claude-args.txt"
env "${RUN_ENV[@]}" FAKE_GATHER_EMPTY=1 bash "$REPO_DIR/claude/learning-pipeline/run.sh"
[ ! -e "$PIPE_DIR/workflow-state-marker.json" ]
[ ! -e "$PIPE_DIR/workflow-baseline-vault-state.json" ]
[ ! -e "$PIPE_DIR/pending-cursor.json" ]
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]

# 커서·post 상태 커밋 직후 프로세스가 종료돼도 2단계 marker로 정상 성공을 복구한다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=success FAKE_KILL_AFTER_COMMIT=1 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'post-commit kill fixture unexpectedly returned success' >&2
  exit 1
fi
[ -e "$PIPE_DIR/workflow-state-marker.json" ]
jq -e '.phase == "verified_post"' "$PIPE_DIR/workflow-state-marker.json" >/dev/null
[ -e "$PIPE_DIR/cursor.json" ]
[ -e "$PIPE_DIR/vault-state.json" ]
# 성공 정리에서 baseline 삭제와 marker 삭제 사이에 종료된 상태를 재현한다.
rm -f "$PIPE_DIR/workflow-baseline-vault-state.json"
rm -f "$PIPE_DIR/received-wait-ceiling.txt" "$PIPE_DIR/received-claude-args.txt"
env "${RUN_ENV[@]}" FAKE_GATHER_EMPTY=1 bash "$REPO_DIR/claude/learning-pipeline/run.sh"
[ ! -e "$PIPE_DIR/workflow-state-marker.json" ]
[ ! -e "$PIPE_DIR/workflow-baseline-vault-state.json" ]
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]

# 커밋 결과에서 같은 timestamp 경계 ID가 사라지면 sources가 같아도 성공으로 인정하지 않는다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=success FAKE_DROP_BOUNDARY_IDS=1 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'cursor without boundary identities was accepted' >&2
  exit 1
fi
[ -e "$PIPE_DIR/workflow-state-marker.json" ]
jq -e '
  .phase == "verified_post"
  and ((.expectedCursorWatermark.boundaryIds | type) == "object")
  and ((.expectedCursorWatermark.boundaryStarts | type) == "object")
' "$PIPE_DIR/workflow-state-marker.json" >/dev/null
CURSOR_RESTORE_TMP="$PIPE_DIR/.cursor-restore-boundary.json"
jq --slurpfile marker "$PIPE_DIR/workflow-state-marker.json" \
  '.boundaryIds = $marker[0].expectedCursorWatermark.boundaryIds
   | .boundaryStarts = $marker[0].expectedCursorWatermark.boundaryStarts' \
  "$PIPE_DIR/cursor.json" > "$CURSOR_RESTORE_TMP"
chmod 600 "$CURSOR_RESTORE_TMP"
mv -f "$CURSOR_RESTORE_TMP" "$PIPE_DIR/cursor.json"
rm -f "$PIPE_DIR/received-wait-ceiling.txt" "$PIPE_DIR/received-claude-args.txt"
env "${RUN_ENV[@]}" FAKE_GATHER_EMPTY=1 bash "$REPO_DIR/claude/learning-pipeline/run.sh"
[ ! -e "$PIPE_DIR/workflow-state-marker.json" ]
[ ! -e "$PIPE_DIR/workflow-baseline-vault-state.json" ]
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]

# 커밋 뒤 overlap 시작점이 짧아져도 full watermark 불일치로 격리한다.
if env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=success FAKE_CORRUPT_BOUNDARY_STARTS=1 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"; then
  echo 'cursor with corrupted boundary starts was accepted' >&2
  exit 1
fi
[ -e "$PIPE_DIR/workflow-state-marker.json" ]
CURSOR_RESTORE_TMP="$PIPE_DIR/.cursor-restore-starts.json"
jq --slurpfile marker "$PIPE_DIR/workflow-state-marker.json" \
  '.boundaryStarts = $marker[0].expectedCursorWatermark.boundaryStarts' \
  "$PIPE_DIR/cursor.json" > "$CURSOR_RESTORE_TMP"
chmod 600 "$CURSOR_RESTORE_TMP"
mv -f "$CURSOR_RESTORE_TMP" "$PIPE_DIR/cursor.json"
rm -f "$PIPE_DIR/received-wait-ceiling.txt" "$PIPE_DIR/received-claude-args.txt"
env "${RUN_ENV[@]}" FAKE_GATHER_EMPTY=1 bash "$REPO_DIR/claude/learning-pipeline/run.sh"
[ ! -e "$PIPE_DIR/workflow-state-marker.json" ]
[ ! -e "$PIPE_DIR/workflow-baseline-vault-state.json" ]
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]

env "${RUN_ENV[@]}" FAKE_CLAUDE_MODE=success-with-synthesis CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=7200000 \
  bash "$REPO_DIR/claude/learning-pipeline/run.sh"
[ "$(cat "$PIPE_DIR/received-wait-ceiling.txt")" = '7200000' ]
[ "$(cat "$PIPE_DIR/received-session-log-off.txt")" = '1' ]
rg -q '^\[claude-config:learning-pipeline-internal\]$' "$PIPE_DIR/received-claude-args.txt"
rg -q '"outputDate": "'"${TODAY_LOCAL}"'"' "$PIPE_DIR/received-claude-args.txt"
jq -e '
  .version == 2
  and (.sources | keys | sort) == ["claude-code", "codex", "hermes"]
  and (.boundaryStarts | keys | sort) == ["claude-code", "codex", "hermes"]
  and ((.committedAt | type) == "string")
' "$PIPE_DIR/cursor.json" >/dev/null
POST_CHECK_STATE="$TEST_ROOT/post-check-state.json"
python3 "$PIPE_DIR/vault-catalog.py" "$VAULT" --pending-state "$POST_CHECK_STATE"
jq -ne --slurpfile committed "$PIPE_DIR/vault-state.json" --slurpfile current "$POST_CHECK_STATE" \
  '$committed[0].version == 1 and $committed[0].vaultFingerprint == $current[0].vaultFingerprint' >/dev/null
[ ! -e "$PIPE_DIR/pending-cursor.json" ]
[ ! -e "$PIPE_DIR/pending-vault-state.json" ]
jq -e '
  .structured_output.agentsError == 0
  and .structured_output.agentsEmptyResult == 0
  and .structured_output.agentsSkipped == 0
  and .structured_output.synthesisCompleted == true
  and .structured_output.auditReported == true
' "$PIPE_DIR/last-run-result.json" >/dev/null
rg -q '실행 종료\(status=0\)' "$PIPE_DIR/run.log"

# 신규 입력이 없으면 Claude를 호출하지 않고 source 위치와 Vault 현재 상태만 확정한다.
CURSOR_SOURCES_BEFORE="$(jq -c '.sources' "$PIPE_DIR/cursor.json")"
VAULT_FINGERPRINT_BEFORE="$(jq -r '.vaultFingerprint' "$PIPE_DIR/vault-state.json")"
rm -f "$PIPE_DIR/received-wait-ceiling.txt" "$PIPE_DIR/received-claude-args.txt"
env "${RUN_ENV[@]}" FAKE_GATHER_EMPTY=1 bash "$REPO_DIR/claude/learning-pipeline/run.sh"
[ "$CURSOR_SOURCES_BEFORE" = "$(jq -c '.sources' "$PIPE_DIR/cursor.json")" ]
[ "$VAULT_FINGERPRINT_BEFORE" = "$(jq -r '.vaultFingerprint' "$PIPE_DIR/vault-state.json")" ]
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]
[ ! -e "$PIPE_DIR/pending-cursor.json" ]
[ ! -e "$PIPE_DIR/pending-vault-state.json" ]

# AI 생성물 메타데이터만 바뀐 경우 비싼 학습은 건너뛰되 새 Vault 지문은 확정한다.
VAULT_FINGERPRINT_BEFORE="$(jq -r '.vaultFingerprint' "$PIPE_DIR/vault-state.json")"
env "${RUN_ENV[@]}" FAKE_GATHER_GENERATED_ONLY=1 bash "$REPO_DIR/claude/learning-pipeline/run.sh"
[ "$VAULT_FINGERPRINT_BEFORE" != "$(jq -r '.vaultFingerprint' "$PIPE_DIR/vault-state.json")" ]
[ ! -e "$PIPE_DIR/received-wait-ceiling.txt" ]
[ ! -e "$PIPE_DIR/pending-cursor.json" ]
[ ! -e "$PIPE_DIR/pending-vault-state.json" ]

echo 'PASS: lock/bounded wait/empty-skipped/synthesis-write/post-state/stale-result/no-change/generated-only fail-closed contract'
