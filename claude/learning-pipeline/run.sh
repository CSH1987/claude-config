#!/usr/bin/env bash
# vault-learning-pipeline: launchd가 주기 호출하는 진입점.
# 1) gather.sh로 신규 발화+Vault 변경 문서 수집 2) 둘 다 없으면 스킵(비용 절약)
# 3) 있으면 claude -p로 Workflow 실행(경로는 이 머신 기준으로 매번 계산해 args로 전달)
# 4) 구조화 결과와 durable 상태를 쉘이 검증하고, 성공시에만 커서를 커밋
# 전부 $HOME/vault-scope.json 기준 — 계정명·볼트경로 하드코딩 없음.
set -uo pipefail
DIR="$HOME/.claude/learning-pipeline"
LOG="$DIR/run.log"
SCOPE_FILE="$HOME/.claude/vault-scope.json"
RESULT_FILE="$DIR/last-run-result.json"
RESULT_TMP="$DIR/.last-run-result.json.tmp.$$"
LOCK_DIR="$DIR/run.lock"
LOCK_ACQUIRED=0
PIPELINE_STATUS=0

cleanup() {
  rm -f "$RESULT_TMP"
  if [ "$LOCK_ACQUIRED" -eq 1 ]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ "$LOCK_PID" =~ ^[0-9]+$ ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
    printf 'ERROR: 학습 파이프라인이 이미 실행 중(pid=%s) — 중복 실행 차단\n' "$LOCK_PID" >> "$LOG"
    exit 1
  fi
  rm -f "$LOCK_DIR/pid"
  if ! rmdir "$LOCK_DIR" 2>/dev/null || ! mkdir "$LOCK_DIR" 2>/dev/null; then
    printf 'ERROR: 오래된 실행 잠금을 안전하게 교체하지 못함 — 실행 중단\n' >> "$LOG"
    exit 1
  fi
fi
LOCK_ACQUIRED=1
printf '%s\n' "$$" > "$LOCK_DIR/pid"
chmod 600 "$LOCK_DIR/pid" 2>/dev/null || true

{
  echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 시작 ====="

  if [ ! -f "$SCOPE_FILE" ]; then
    echo "vault-scope.json 없음 — 이 머신엔 볼트가 설치 안 된 것으로 보임, 실행 중단"
    echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(스킵) ====="
    exit 0
  fi
  VAULT_PATH=$(jq -r '.vaultPath // empty' "$SCOPE_FILE" 2>/dev/null)
  if [ -z "$VAULT_PATH" ] || [ ! -d "$VAULT_PATH/10_컨텍스트" ]; then
    echo "vault-scope.json의 vaultPath가 비어있거나 10_컨텍스트 폴더가 없음 — 실행 중단"
    echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(스킵) ====="
    exit 0
  fi

  # 이전 실패의 staging 결과를 이번 수집으로 오인하지 않도록 확정 상태(cursor.json,
  # vault-state.json)는 보존하고 재생성 가능한 pending/출력만 비운다.
  rm -f \
    "$DIR/gathered-utterances.json" \
    "$DIR/gathered-vault-documents.json" \
    "$DIR/pending-cursor.json" \
    "$DIR/pending-vault-state.json"
  if ! bash "$DIR/gather.sh"; then
    echo "ERROR: 수집 단계 실패 — 기존 커서를 유지하고 종료"
    echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(status=1) ====="
    exit 1
  fi
  if ! TALK_COUNT=$(jq -e 'length' "$DIR/gathered-utterances.json" 2>/dev/null) \
    || ! VAULT_COUNT=$(jq -e '.changes | length' "$DIR/gathered-vault-documents.json" 2>/dev/null); then
    echo "ERROR: 수집 결과 검증 실패 — 기존 커서를 유지하고 종료"
    echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(status=1) ====="
    exit 1
  fi
  COUNT=$(( ${TALK_COUNT:-0} + ${VAULT_COUNT:-0} ))

  if [ "${COUNT:-0}" -eq 0 ] 2>/dev/null; then
    echo "신규 대화·Vault 변경 문서 없음 — 워크플로 스킵"
  else
    echo "신규 대화 ${TALK_COUNT}건 + Vault 변경 문서 ${VAULT_COUNT}건 감지 — 파이프라인 실행"
    if ! EXPECTED_CURSOR_SOURCES=$(jq -ce '
        select(
          .version == 2
          and ((.sources | type) == "object")
          and (.sources | has("claude-code"))
          and (.sources | has("hermes"))
          and (.sources | has("codex"))
        )
        | .sources
      ' "$DIR/pending-cursor.json" 2>/dev/null) \
      || ! EXPECTED_VAULT_FINGERPRINT=$(jq -er '.vaultFingerprint | select(type == "string" and length > 0)' "$DIR/pending-vault-state.json" 2>/dev/null); then
      echo "ERROR: pending 커서·Vault 상태 검증 실패 — 분석을 시작하지 않음"
      echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(status=1) ====="
      exit 1
    fi
    CLAUDE_BIN="$(command -v claude || echo "$HOME/.local/bin/claude")"
    MEMORY_DIR="$HOME/.claude/projects/$(printf '%s' "$HOME" | sed 's#/#-#g')/memory"
    ARGS_JSON=$(jq -n \
      --arg vault10Path "$VAULT_PATH/10_컨텍스트" \
      --arg utterancesPath "$DIR/gathered-utterances.json" \
      --arg vaultDocumentsPath "$DIR/gathered-vault-documents.json" \
      --arg memoryDirPath "$MEMORY_DIR" \
      --arg vault90HermesPath "$VAULT_PATH/90_Hermes" \
      '{vault10Path: $vault10Path, utterancesPath: $utterancesPath, vaultDocumentsPath: $vaultDocumentsPath, memoryDirPath: $memoryDirPath, vault90HermesPath: $vault90HermesPath}')
    CLAUDE_STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
    RESULT_SCHEMA='{"type":"object","properties":{"workflowCompleted":{"type":"boolean"},"agentsError":{"type":"integer"},"lensResultCount":{"type":"integer"},"summary":{"type":"string"}},"required":["workflowCompleted","agentsError","lensResultCount","summary"],"additionalProperties":false}'

    # Claude Code 2.1.182+의 비대화형 background 기본 상한은 10분이다. 초기 전체
    # 스캔은 이를 넘을 수 있으므로 기본 1시간으로 늘리되, 멈춤을 영구 점유하지 않게
    # 무한대(0)는 기본값으로 쓰지 않는다. 감독 실행은 외부 환경변수로 재정의할 수 있다.
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-3600000}" \
    CLAUDE_EVENTS_OFF=1 CLAUDE_AUTOSYNC_OFF=1 CLAUDE_CONFIG_NO_SYNC=1 \
      "$CLAUDE_BIN" -p --output-format json --json-schema "$RESULT_SCHEMA" "$(cat <<PROMPT
Workflow 도구로 $HOME/.claude/learning-pipeline/pipeline.workflow.js 를 scriptPath로, 다음 args와 함께 실행해라:
$ARGS_JSON
Workflow 도구가 최종 결과를 실제로 반환할 때까지 기다려라. 반환 뒤 결과의 agents_error와 lensResults 길이를 그대로 읽어서 구조화 응답으로 내라.
- workflowCompleted: Workflow 도구가 최종 결과를 실제로 반환한 경우만 true
- agentsError: 결과의 agents_error 정수(완료하지 못했으면 -1)
- lensResultCount: 결과의 lensResults 배열 길이(완료하지 못했으면 0)
- summary: 한국어 두세 문장 요약
커서·Vault 분석 상태 파일을 직접 수정하거나 commit-cursor.sh를 실행하지 마라. 최종 구조화 결과를 확인한 바깥 쉘이 성공시에만 커밋한다.
PROMPT
)" > "$RESULT_TMP"
    CLAUDE_STATUS=$?

    RESULT_READY=0
    if [ -s "$RESULT_TMP" ] && jq empty "$RESULT_TMP" >/dev/null 2>&1; then
      chmod 600 "$RESULT_TMP" 2>/dev/null || true
      mv -f "$RESULT_TMP" "$RESULT_FILE"
      RESULT_READY=1
    fi

    if [ "$CLAUDE_STATUS" -eq 0 ] \
      && [ "$RESULT_READY" -eq 1 ] \
      && jq -e '
        .structured_output.workflowCompleted == true
        and .structured_output.agentsError == 0
        and .structured_output.lensResultCount == 3
      ' "$RESULT_FILE" >/dev/null 2>&1; then
      if ! bash "$DIR/commit-cursor.sh"; then
        echo "ERROR: Workflow는 성공했지만 커서 커밋 실패"
        PIPELINE_STATUS=1
      fi
    else
      echo "ERROR: Workflow 완료 검증 실패 — claude_exit=$CLAUDE_STATUS, structured_result=$RESULT_READY"
      PIPELINE_STATUS=1
    fi

    if [ "$PIPELINE_STATUS" -eq 0 ] \
      && jq -e --arg started "$CLAUDE_STARTED_AT" --argjson expectedSources "$EXPECTED_CURSOR_SOURCES" '
        .version == 2
        and ((.sources | type) == "object")
        and (.sources | has("claude-code"))
        and (.sources | has("hermes"))
        and (.sources | has("codex"))
        and (.sources == $expectedSources)
        and ((.committedAt | type) == "string")
        and (.committedAt >= $started)
      ' "$DIR/cursor.json" >/dev/null 2>&1 \
      && jq -e --arg expectedFingerprint "$EXPECTED_VAULT_FINGERPRINT" '
        (.version | type) == "number"
        and ((.vaultFingerprint | type) == "string")
        and (.vaultFingerprint == $expectedFingerprint)
      ' "$DIR/vault-state.json" >/dev/null 2>&1 \
      && [ ! -e "$DIR/pending-cursor.json" ] \
      && [ ! -e "$DIR/pending-vault-state.json" ]; then
      echo "파이프라인 성공 — 구조화 결과와 대화 커서·Vault 상태 커밋 확인"
    else
      echo "ERROR: durable commit 사후조건 실패 — 기존 또는 pending 상태를 확인해야 함"
      PIPELINE_STATUS=1
    fi
  fi

  echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(status=$PIPELINE_STATUS) ====="
  echo
} >> "$LOG" 2>&1

exit "$PIPELINE_STATUS"
