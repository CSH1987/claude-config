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
POST_VAULT_STATE="$DIR/.workflow-post-vault-state.json.tmp.$$"
VERIFY_VAULT_STATE="$DIR/.workflow-verify-vault-state.json.tmp.$$"
EMPTY_VAULT_STATE="$DIR/.empty-vault-state.json.tmp.$$"
RECOVERY_VAULT_STATE="$DIR/.workflow-recovery-vault-state.json.tmp.$$"
RECOVERY_PENDING_VAULT_STATE="$DIR/.workflow-recovery-pending-vault-state.json.tmp.$$"
WORKFLOW_BASELINE_STATE="$DIR/workflow-baseline-vault-state.json"
WORKFLOW_STATE_MARKER="$DIR/workflow-state-marker.json"
WORKFLOW_BASELINE_TMP="$DIR/.workflow-baseline-vault-state.json.tmp.$$"
WORKFLOW_MARKER_TMP="$DIR/.workflow-state-marker.json.tmp.$$"
TOKENIZED_CURSOR_TMP="$DIR/.pending-cursor-tokenized.json.tmp.$$"
LOCK_DIR="$DIR/run.lock"
LOCK_ACQUIRED=0
PIPELINE_STATUS=0

cleanup() {
  rm -f "$RESULT_TMP" "$POST_VAULT_STATE" "$VERIFY_VAULT_STATE" "$EMPTY_VAULT_STATE" \
    "$RECOVERY_VAULT_STATE" "$RECOVERY_PENDING_VAULT_STATE" "$WORKFLOW_BASELINE_TMP" \
    "$WORKFLOW_MARKER_TMP" "$TOKENIZED_CURSOR_TMP"
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
  if ! [[ "$LOCK_PID" =~ ^[0-9]+$ ]]; then
    LOCK_MTIME="$(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || true)"
    NOW_EPOCH="$(date +%s 2>/dev/null || true)"
    if [ ! -e "$LOCK_DIR/pid" ] \
      && [[ "$LOCK_MTIME" =~ ^[0-9]+$ ]] \
      && [[ "$NOW_EPOCH" =~ ^[0-9]+$ ]] \
      && [ $((NOW_EPOCH - LOCK_MTIME)) -ge 60 ] \
      && rmdir "$LOCK_DIR" 2>/dev/null \
      && mkdir "$LOCK_DIR" 2>/dev/null; then
      : # PID 기록 전 종료된 지 60초가 지난 빈 잠금만 회수한다.
    else
      printf 'ERROR: 실행 잠금의 PID를 확인할 수 없음 — 경쟁 실행을 막기 위해 중단\n' >> "$LOG"
      exit 1
    fi
  fi
  if [[ "$LOCK_PID" =~ ^[0-9]+$ ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
    printf 'ERROR: 학습 파이프라인이 이미 실행 중(pid=%s) — 중복 실행 차단\n' "$LOCK_PID" >> "$LOG"
    exit 1
  fi
  if [[ "$LOCK_PID" =~ ^[0-9]+$ ]]; then
    rm -f "$LOCK_DIR/pid"
    if ! rmdir "$LOCK_DIR" 2>/dev/null || ! mkdir "$LOCK_DIR" 2>/dev/null; then
      printf 'ERROR: 오래된 실행 잠금을 안전하게 교체하지 못함 — 실행 중단\n' >> "$LOG"
      exit 1
    fi
  fi
fi
LOCK_ACQUIRED=1
if ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
  printf 'ERROR: 실행 잠금 PID 기록 실패 — 실행 중단\n' >> "$LOG"
  exit 1
fi
chmod 600 "$LOCK_DIR/pid" 2>/dev/null || true

if ! exec >> "$LOG" 2>&1; then
  printf 'ERROR: 학습 파이프라인 로그를 열 수 없음 — 실행 중단\n' >&2
  exit 1
fi

{
  PIPELINE_STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
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
  CATALOGER="$DIR/vault-catalog.py"
  OUTPUT_DATE_LOCAL="$(date +%Y-%m-%d)"

  # 실패·강제 종료된 Workflow가 Vault를 바꾼 흔적을 다음 실행의 정상 입력으로
  # 흡수하지 않는다. 미쓰기 실패 또는 커밋 직후 종료임이 상태로 증명될 때만 해제한다.
  if [ -e "$WORKFLOW_STATE_MARKER" ] || [ -e "$WORKFLOW_BASELINE_STATE" ]; then
    RECOVERY_SAFE=0
    RECOVERY_VERIFIED_POST=0
    if [ -f "$CATALOGER" ] \
      && python3 "$CATALOGER" "$VAULT_PATH" --strict --pending-state "$RECOVERY_VAULT_STATE" \
      && [ -s "$RECOVERY_VAULT_STATE" ]; then
      LIVE_FINGERPRINT=$(jq -er '.vaultFingerprint | select(type == "string" and length > 0)' "$RECOVERY_VAULT_STATE" 2>/dev/null || true)
      if [ -s "$WORKFLOW_BASELINE_STATE" ]; then
        BASELINE_FINGERPRINT=$(jq -er '.vaultFingerprint | select(type == "string" and length > 0)' "$WORKFLOW_BASELINE_STATE" 2>/dev/null || true)
        MARKER_PRE_MATCHES_BASELINE=0
        if [ ! -e "$WORKFLOW_STATE_MARKER" ]; then
          # baseline을 원자 이동한 직후 marker 생성 전에 종료된 경우다.
          MARKER_PRE_MATCHES_BASELINE=1
        elif jq -e --arg pre "$BASELINE_FINGERPRINT" '
          .version == 1
          and ((.phase == "in_progress") or (.phase == "verified_post"))
          and .preVaultFingerprint == $pre
        ' "$WORKFLOW_STATE_MARKER" >/dev/null 2>&1; then
          MARKER_PRE_MATCHES_BASELINE=1
        fi
        if [ -n "$BASELINE_FINGERPRINT" ] \
          && [ "$MARKER_PRE_MATCHES_BASELINE" -eq 1 ] \
          && [ "$LIVE_FINGERPRINT" = "$BASELINE_FINGERPRINT" ]; then
          RECOVERY_SAFE=1
        elif [ -s "$WORKFLOW_STATE_MARKER" ] \
          && [ "$MARKER_PRE_MATCHES_BASELINE" -eq 1 ]; then
          RECOVERY_VERIFIED_POST=1
        fi
      elif [ ! -e "$WORKFLOW_BASELINE_STATE" ] \
        && [ -s "$WORKFLOW_STATE_MARKER" ]; then
        # 성공 정리 중 baseline을 먼저 지운 직후 종료된 marker-only 상태다.
        if jq -e --arg live "$LIVE_FINGERPRINT" '
          .version == 1 and .phase == "in_progress"
          and .preVaultFingerprint == $live
        ' "$WORKFLOW_STATE_MARKER" >/dev/null 2>&1; then
          RECOVERY_SAFE=1
        else
          RECOVERY_VERIFIED_POST=1
        fi
      fi

      if [ "$RECOVERY_SAFE" -ne 1 ] \
        && [ "$RECOVERY_VERIFIED_POST" -eq 1 ] \
        && jq -e --arg live "$LIVE_FINGERPRINT" '
          .version == 1 and .phase == "verified_post"
          and ((.preVaultFingerprint | type) == "string")
          and ((.postVaultFingerprint | type) == "string")
          and .postVaultFingerprint == $live
          and ((.expectedCursorWatermark | type) == "object")
          and ((.expectedCommitToken | type) == "string" and (.expectedCommitToken | length) >= 16)
          and ((.startedAt | type) == "string")
        ' "$WORKFLOW_STATE_MARKER" >/dev/null 2>&1; then
        # 완전 커밋 뒤 종료됐으면 상태만 확인한다. vault-state 이동 뒤 cursor 이동 전
        # 종료됐으면 검증된 post 상태와 tokenized pending cursor로 커밋을 안전하게 완성한다.
        if [ -s "$DIR/vault-state.json" ] \
          && [ -s "$DIR/cursor.json" ] \
          && jq -e --slurpfile marker "$WORKFLOW_STATE_MARKER" '
            .version == 1 and .vaultFingerprint == $marker[0].postVaultFingerprint
          ' "$DIR/vault-state.json" >/dev/null 2>&1 \
          && jq -e --slurpfile marker "$WORKFLOW_STATE_MARKER" '
            .version == 2
            and ({lastProcessed,sources,boundaryIds,boundaryStarts} == $marker[0].expectedCursorWatermark)
            and .workflowCommitToken == $marker[0].expectedCommitToken
            and ((.committedAt | type) == "string")
            and .committedAt >= $marker[0].startedAt
          ' "$DIR/cursor.json" >/dev/null 2>&1; then
          RECOVERY_SAFE=1
        elif [ -s "$DIR/pending-cursor.json" ] \
          && jq -e --slurpfile marker "$WORKFLOW_STATE_MARKER" '
            .version == 2
            and ({lastProcessed,sources,boundaryIds,boundaryStarts} == $marker[0].expectedCursorWatermark)
            and .workflowCommitToken == $marker[0].expectedCommitToken
          ' "$DIR/pending-cursor.json" >/dev/null 2>&1; then
          RECOVERY_POST_STATE_READY=0
          if [ -s "$DIR/pending-vault-state.json" ] \
            && jq -e --slurpfile marker "$WORKFLOW_STATE_MARKER" '
              .version == 1 and .vaultFingerprint == $marker[0].postVaultFingerprint
            ' "$DIR/pending-vault-state.json" >/dev/null 2>&1; then
            RECOVERY_POST_STATE_READY=1
          elif [ -s "$DIR/vault-state.json" ] \
            && jq -e --slurpfile marker "$WORKFLOW_STATE_MARKER" '
              .version == 1 and .vaultFingerprint == $marker[0].postVaultFingerprint
            ' "$DIR/vault-state.json" >/dev/null 2>&1 \
            && cp "$DIR/vault-state.json" "$RECOVERY_PENDING_VAULT_STATE" \
            && chmod 600 "$RECOVERY_PENDING_VAULT_STATE" \
            && mv -f "$RECOVERY_PENDING_VAULT_STATE" "$DIR/pending-vault-state.json"; then
            RECOVERY_POST_STATE_READY=1
          elif jq -e --slurpfile marker "$WORKFLOW_STATE_MARKER" '
              .version == 1 and .vaultFingerprint == $marker[0].postVaultFingerprint
            ' "$RECOVERY_VAULT_STATE" >/dev/null 2>&1 \
            && cp "$RECOVERY_VAULT_STATE" "$RECOVERY_PENDING_VAULT_STATE" \
            && chmod 600 "$RECOVERY_PENDING_VAULT_STATE" \
            && mv -f "$RECOVERY_PENDING_VAULT_STATE" "$DIR/pending-vault-state.json"; then
            RECOVERY_POST_STATE_READY=1
          fi
          if [ "$RECOVERY_POST_STATE_READY" -eq 1 ] \
            && bash "$DIR/commit-cursor.sh" \
            && jq -e --slurpfile marker "$WORKFLOW_STATE_MARKER" '
              .version == 1 and .vaultFingerprint == $marker[0].postVaultFingerprint
            ' "$DIR/vault-state.json" >/dev/null 2>&1 \
            && jq -e --slurpfile marker "$WORKFLOW_STATE_MARKER" '
              .version == 2
              and ({lastProcessed,sources,boundaryIds,boundaryStarts} == $marker[0].expectedCursorWatermark)
              and .workflowCommitToken == $marker[0].expectedCommitToken
              and ((.committedAt | type) == "string")
              and .committedAt >= $marker[0].startedAt
            ' "$DIR/cursor.json" >/dev/null 2>&1; then
            RECOVERY_SAFE=1
          fi
        fi
      fi
    fi
    if [ "$RECOVERY_SAFE" -ne 1 ]; then
      echo "ERROR: 이전 실패 실행 뒤 Vault 변경이 남아 있음 — 자동 흡수하지 않고 로컬 격리 상태 보존"
      echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(status=1) ====="
      exit 1
    fi
    # baseline을 먼저 지운다. 둘 사이에 종료되면 marker-only 상태를 위 분기가 검증한다.
    if ! rm -f "$WORKFLOW_BASELINE_STATE" \
      || ! rm -f "$WORKFLOW_STATE_MARKER" "$RECOVERY_VAULT_STATE"; then
      echo "ERROR: 검증된 이전 실행의 격리 상태를 정리하지 못함"
      echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(status=1) ====="
      exit 1
    fi
    echo "이전 실행 상태가 안전함을 확인 — 격리 표식 해제 후 재시도"
  fi

  # 이전 실패의 staging 결과를 이번 수집으로 오인하지 않도록 확정 상태(cursor.json,
  # vault-state.json)는 보존하고 재생성 가능한 pending/출력만 비운다.
  if ! rm -f \
      "$DIR/gathered-utterances.json" \
      "$DIR/gathered-vault-documents.json" \
      "$DIR/pending-cursor.json" \
      "$DIR/pending-vault-state.json"; then
    echo "ERROR: 이전 staging 정리 실패 — 기존 커서를 유지하고 종료"
    echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(status=1) ====="
    exit 1
  fi
  if ! bash "$DIR/gather.sh"; then
    echo "ERROR: 수집 단계 실패 — 기존 커서를 유지하고 종료"
    echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(status=1) ====="
    exit 1
  fi
  FUTURE_TIMESTAMP_LIMIT="$(date -u -v+5M +"%Y-%m-%dT%H:%M:%S.000000Z" 2>/dev/null || date -u -d '5 minutes' +"%Y-%m-%dT%H:%M:%S.000000Z")"
  if ! TALK_COUNT=$(jq -e --arg future "$FUTURE_TIMESTAMP_LIMIT" '
      select(type == "array")
      | select(all(.[];
          ((.source == "claude-code") or (.source == "hermes") or (.source == "codex"))
          and ((.session | type) == "string")
          and ((.text | type) == "string")
          and ((.ts | type) == "string")
          and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3,6})?Z$"))
          and (.ts <= $future)))
      | length
    ' "$DIR/gathered-utterances.json" 2>/dev/null) \
    || ! VAULT_COUNT=$(jq -e '[.changes[] | select(.authorship != "generated" and .contentPolicy != "canonical-read-separately")] | length' "$DIR/gathered-vault-documents.json" 2>/dev/null); then
    echo "ERROR: 수집 결과 검증 실패 — 기존 커서를 유지하고 종료"
    echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(status=1) ====="
    exit 1
  fi
  COUNT=$(( ${TALK_COUNT:-0} + ${VAULT_COUNT:-0} ))

  if ! EXPECTED_CURSOR_WATERMARK=$(jq -ce '
      def epoch: sub("\\.[0-9]{6}Z$"; "Z") | fromdateiso8601;
      select(
        .version == 2
        and ((.sources | type) == "object")
        and (.sources | has("claude-code"))
        and (.sources | has("hermes"))
        and (.sources | has("codex"))
        and ((.boundaryIds | type) == "object")
        and ((.boundaryIds | keys | sort) == ["claude-code", "codex", "hermes"])
        and ([.boundaryIds["claude-code"][], .boundaryIds.hermes[], .boundaryIds.codex[]]
          | all(.[]; (type == "string") and test("^[0-9a-f]{64}$")))
        and ((.boundaryStarts | type) == "object")
        and ((.boundaryStarts | keys | sort) == ["claude-code", "codex", "hermes"])
        and ([.boundaryStarts["claude-code"], .boundaryStarts.hermes, .boundaryStarts.codex]
          | all(.[];
              (type == "string")
              and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{6}Z$")))
        and (.boundaryStarts["claude-code"] <= .sources["claude-code"])
        and (.boundaryStarts.hermes <= .sources.hermes)
        and (.boundaryStarts.codex <= .sources.codex)
        and ([
          ((.sources["claude-code"] | epoch) - (.boundaryStarts["claude-code"] | epoch)),
          ((.sources.hermes | epoch) - (.boundaryStarts.hermes | epoch)),
          ((.sources.codex | epoch) - (.boundaryStarts.codex | epoch))
        ] | all(.[]; . == 86400))
        and (.lastProcessed == ([.sources["claude-code"], .sources.hermes, .sources.codex] | max))
        and ([.sources["claude-code"], .sources.hermes, .sources.codex]
          | all(.[];
              (type == "string")
              and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{6}Z$")
              and (. <= $future)))
      )
      | {lastProcessed,sources,boundaryIds,boundaryStarts}
    ' --arg future "$FUTURE_TIMESTAMP_LIMIT" "$DIR/pending-cursor.json" 2>/dev/null) \
    || ! EXPECTED_VAULT_FINGERPRINT=$(jq -er '.vaultFingerprint | select(type == "string" and length > 0)' "$DIR/pending-vault-state.json" 2>/dev/null); then
    echo "ERROR: pending 커서·Vault 상태 검증 실패 — 분석을 시작하지 않음"
    echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(status=1) ====="
    exit 1
  fi
  VALIDATION_BASELINE="$DIR/vault-state.json"
  if [ ! -s "$VALIDATION_BASELINE" ]; then
    printf '{"version":1,"vaultFingerprint":"","files":{}}\n' > "$EMPTY_VAULT_STATE"
    VALIDATION_BASELINE="$EMPTY_VAULT_STATE"
  fi
  if ! python3 "$DIR/validate-vault-output.py" \
      --mode input \
      --vault-root "$VAULT_PATH" \
      --baseline-state "$VALIDATION_BASELINE" \
      --current-state "$DIR/pending-vault-state.json" \
      --guard-path "10_컨텍스트/AI_협업_패턴.md" \
      --guard-path "10_컨텍스트/업무_원칙_방법론.md" \
      --guard-path "10_컨텍스트/강점_약점_보완.md" \
      --guard-path "90_Hermes/학습이력/${OUTPUT_DATE_LOCAL}_학습분.md" \
      --guard-path "90_Hermes/라우팅제안/${OUTPUT_DATE_LOCAL}_라우팅제안.md"; then
    echo "ERROR: Workflow 입력 식별정보 검증 실패 — 분석을 시작하지 않고 커서 유지"
    echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(status=1) ====="
    exit 1
  fi

  if [ "${COUNT:-0}" -eq 0 ] 2>/dev/null; then
    if bash "$DIR/commit-cursor.sh" \
      && jq -e --arg started "$PIPELINE_STARTED_AT" --argjson expectedWatermark "$EXPECTED_CURSOR_WATERMARK" '
        .version == 2
        and ({lastProcessed,sources,boundaryIds,boundaryStarts} == $expectedWatermark)
        and ((.committedAt | type) == "string") and .committedAt >= $started
      ' "$DIR/cursor.json" >/dev/null 2>&1 \
      && jq -e --arg expectedFingerprint "$EXPECTED_VAULT_FINGERPRINT" \
        '.version == 1 and .vaultFingerprint == $expectedFingerprint' \
        "$DIR/vault-state.json" >/dev/null 2>&1 \
      && [ ! -e "$DIR/pending-cursor.json" ] \
      && [ ! -e "$DIR/pending-vault-state.json" ]; then
      echo "신규 대화·학습 대상 Vault 본문 없음 — 워크플로 스킵, 현재 상태만 안전하게 확정"
    else
      echo "ERROR: 워크플로 스킵 상태의 커서·Vault 상태 확정 실패"
      PIPELINE_STATUS=1
    fi
  else
    echo "신규 대화 ${TALK_COUNT}건 + Vault 변경 문서 ${VAULT_COUNT}건 감지 — 파이프라인 실행"
    CLAUDE_STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
    COMMIT_TOKEN=$(printf '%s' "$$:${RANDOM}:${CLAUDE_STARTED_AT}" | shasum -a 256 | awk '{print $1}')
    # gather와 실제 Workflow 호출 사이에 사람이 Vault를 바꿨다면 그 변경을 AI 출력으로
    # 오인할 수 있다. 호출 직전에 다시 스캔해 같은 지문일 때만 복구 기준으로 확정한다.
    if [ -z "$COMMIT_TOKEN" ] \
      || ! jq --arg token "$COMMIT_TOKEN" '.workflowCommitToken = $token' \
        "$DIR/pending-cursor.json" > "$TOKENIZED_CURSOR_TMP" \
      || ! chmod 600 "$TOKENIZED_CURSOR_TMP" \
      || ! mv -f "$TOKENIZED_CURSOR_TMP" "$DIR/pending-cursor.json" \
      || ! python3 "$CATALOGER" "$VAULT_PATH" --strict --pending-state "$WORKFLOW_BASELINE_TMP" \
      || ! jq -e --arg expected "$EXPECTED_VAULT_FINGERPRINT" '
        .version == 1 and .vaultFingerprint == $expected and ((.files | type) == "object")
      ' "$WORKFLOW_BASELINE_TMP" >/dev/null 2>&1 \
      || ! chmod 600 "$WORKFLOW_BASELINE_TMP" \
      || ! mv -f "$WORKFLOW_BASELINE_TMP" "$WORKFLOW_BASELINE_STATE" \
      || ! jq -n \
        --arg phase "in_progress" \
        --arg preVaultFingerprint "$EXPECTED_VAULT_FINGERPRINT" \
        --arg startedAt "$CLAUDE_STARTED_AT" \
        --arg expectedCommitToken "$COMMIT_TOKEN" \
        --argjson expectedCursorWatermark "$EXPECTED_CURSOR_WATERMARK" \
        '{version:1,phase:$phase,preVaultFingerprint:$preVaultFingerprint,postVaultFingerprint:null,startedAt:$startedAt,expectedCursorWatermark:$expectedCursorWatermark,expectedCommitToken:$expectedCommitToken}' \
        > "$WORKFLOW_MARKER_TMP" \
      || ! chmod 600 "$WORKFLOW_MARKER_TMP" \
      || ! mv -f "$WORKFLOW_MARKER_TMP" "$WORKFLOW_STATE_MARKER"; then
      echo "ERROR: Workflow 호출 직전 Vault 상태가 달라졌거나 복구 기준 기록에 실패함 — 분석 중단"
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
      --arg outputDate "$OUTPUT_DATE_LOCAL" \
      '{vault10Path: $vault10Path, utterancesPath: $utterancesPath, vaultDocumentsPath: $vaultDocumentsPath, memoryDirPath: $memoryDirPath, vault90HermesPath: $vault90HermesPath, outputDate: $outputDate}')
    RESULT_SCHEMA='{"type":"object","properties":{"workflowCompleted":{"type":"boolean"},"agentsError":{"type":"integer"},"agentsEmptyResult":{"type":"integer"},"agentsSkipped":{"type":"integer"},"lensResultCount":{"type":"integer"},"synthesisRequired":{"type":"boolean"},"synthesisCompleted":{"type":"boolean"},"auditRequired":{"type":"boolean"},"auditReported":{"type":"boolean"},"routingRequired":{"type":"boolean"},"routingCompleted":{"type":"boolean"},"summary":{"type":"string"}},"required":["workflowCompleted","agentsError","agentsEmptyResult","agentsSkipped","lensResultCount","synthesisRequired","synthesisCompleted","auditRequired","auditReported","routingRequired","routingCompleted","summary"],"additionalProperties":false}'

    # Claude Code 2.1.182+의 비대화형 background 기본 상한은 10분이다. 초기 전체
    # 스캔은 이를 넘을 수 있으므로 기본 1시간으로 늘리되, 멈춤을 영구 점유하지 않게
    # 무한대(0)는 기본값으로 쓰지 않는다. 감독 실행은 외부 환경변수로 재정의할 수 있다.
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-3600000}" \
    CLAUDE_EVENTS_OFF=1 CLAUDE_AUTOSYNC_OFF=1 CLAUDE_CONFIG_NO_SYNC=1 \
    CLAUDE_VAULT_SESSION_LOG_OFF=1 \
      "$CLAUDE_BIN" -p --output-format json --json-schema "$RESULT_SCHEMA" "$(cat <<PROMPT
[claude-config:learning-pipeline-internal]
Workflow 도구로 $HOME/.claude/learning-pipeline/pipeline.workflow.js 를 scriptPath로, 다음 args와 함께 실행해라:
$ARGS_JSON
Workflow 도구가 최종 결과를 실제로 반환할 때까지 기다려라. 반환 뒤 도구 알림의 usage와 Workflow 반환 객체를 그대로 읽어서 구조화 응답으로 내라.
- workflowCompleted: Workflow 도구가 최종 결과를 실제로 반환한 경우만 true
- agentsError / agentsEmptyResult / agentsSkipped: 도구 알림 usage의 agents_error / agents_empty_result / agents_skipped 정수(완료하지 못했으면 -1)
- lensResultCount: 결과의 lensResults 배열 길이(완료하지 못했으면 0)
- synthesisRequired / synthesisCompleted / auditRequired / auditReported / routingRequired / routingCompleted: Workflow 반환 객체의 같은 이름 값을 그대로 사용(완료하지 못했으면 required는 true, completed/reported는 false)
- summary: 한국어 두세 문장 요약
커서·Vault 분석 상태 파일을 직접 수정하거나 commit-cursor.sh를 실행하지 마라. 최종 구조화 결과를 확인한 바깥 쉘이 성공시에만 커밋한다.
PROMPT
)" > "$RESULT_TMP"
    CLAUDE_STATUS=$?

    RESULT_READY=0
    if [ -s "$RESULT_TMP" ] && jq empty "$RESULT_TMP" >/dev/null 2>&1; then
      chmod 600 "$RESULT_TMP" 2>/dev/null || true
      if mv -f "$RESULT_TMP" "$RESULT_FILE"; then
        RESULT_READY=1
      fi
    fi

    if [ "$CLAUDE_STATUS" -eq 0 ] \
      && [ "$RESULT_READY" -eq 1 ] \
      && jq -e '
        .structured_output.workflowCompleted == true
        and .structured_output.agentsError == 0
        and .structured_output.agentsEmptyResult == 0
        and .structured_output.agentsSkipped == 0
        and .structured_output.lensResultCount == 3
        and (.structured_output.synthesisCompleted == .structured_output.synthesisRequired)
        and (.structured_output.auditRequired == .structured_output.synthesisRequired)
        and (.structured_output.auditReported == .structured_output.auditRequired)
        and .structured_output.routingRequired == true
        and .structured_output.routingCompleted == true
      ' "$RESULT_FILE" >/dev/null 2>&1; then
      AUDIT_RELATIVE_PATH="90_Hermes/학습이력/${OUTPUT_DATE_LOCAL}_학습분.md"
      ROUTING_RELATIVE_PATH="90_Hermes/라우팅제안/${OUTPUT_DATE_LOCAL}_라우팅제안.md"
      WORKFLOW_OUTPUT_VALIDATOR_ARGS=(
        --mode workflow-output
        --vault-root "$VAULT_PATH"
        --baseline-state "$DIR/pending-vault-state.json"
        --current-state "$POST_VAULT_STATE"
      )
      if jq -e '.structured_output.synthesisRequired == true' "$RESULT_FILE" >/dev/null 2>&1; then
        WORKFLOW_OUTPUT_VALIDATOR_ARGS+=(
          --allowed-path "10_컨텍스트/AI_협업_패턴.md"
          --allowed-path "10_컨텍스트/업무_원칙_방법론.md"
          --allowed-path "10_컨텍스트/강점_약점_보완.md"
        )
      fi
      if jq -e '.structured_output.auditRequired == true' "$RESULT_FILE" >/dev/null 2>&1; then
        WORKFLOW_OUTPUT_VALIDATOR_ARGS+=(--allowed-path "$AUDIT_RELATIVE_PATH")
      fi
      if jq -e '.structured_output.routingRequired == true' "$RESULT_FILE" >/dev/null 2>&1; then
        WORKFLOW_OUTPUT_VALIDATOR_ARGS+=(--allowed-path "$ROUTING_RELATIVE_PATH")
      fi
      if [ ! -f "$CATALOGER" ] \
        || ! python3 "$CATALOGER" "$VAULT_PATH" --strict --pending-state "$POST_VAULT_STATE" \
        || [ ! -s "$POST_VAULT_STATE" ] \
        || ! jq -e '.version == 1 and ((.vaultFingerprint | type) == "string") and ((.files | type) == "object")' "$POST_VAULT_STATE" >/dev/null 2>&1; then
        echo "ERROR: Workflow 이후 Vault 상태 스캔 실패 — 커서를 유지하고 재시도"
        PIPELINE_STATUS=1
      elif ! python3 "$DIR/validate-vault-output.py" "${WORKFLOW_OUTPUT_VALIDATOR_ARGS[@]}"; then
        echo "ERROR: Workflow 출력 범위·식별정보 검증 실패 — 커서를 유지하고 수정 후 재시도"
        PIPELINE_STATUS=1
      elif jq -e '.structured_output.auditRequired == true' "$RESULT_FILE" >/dev/null 2>&1 \
        && ! jq -ne --arg path "$AUDIT_RELATIVE_PATH" --slurpfile before "$DIR/pending-vault-state.json" --slurpfile after "$POST_VAULT_STATE" '
          ($before[0].files // {}) as $b | ($after[0].files // {}) as $a
          | ($a | has($path)) and ($a[$path].sha256 != ($b[$path].sha256 // null))
        ' >/dev/null 2>&1; then
        echo "ERROR: 필수 학습이력 파일의 실제 변경을 확인하지 못함 — 커서를 유지"
        PIPELINE_STATUS=1
      elif jq -e '.structured_output.routingRequired == true' "$RESULT_FILE" >/dev/null 2>&1 \
        && ! jq -ne --arg path "$ROUTING_RELATIVE_PATH" --slurpfile before "$DIR/pending-vault-state.json" --slurpfile after "$POST_VAULT_STATE" '
          ($before[0].files // {}) as $b | ($after[0].files // {}) as $a
          | ($a | has($path)) and ($a[$path].sha256 != ($b[$path].sha256 // null))
        ' >/dev/null 2>&1; then
        echo "ERROR: 필수 라우팅 제안 파일의 실제 변경을 확인하지 못함 — 커서를 유지"
        PIPELINE_STATUS=1
      elif ! python3 "$CATALOGER" "$VAULT_PATH" --strict --pending-state "$VERIFY_VAULT_STATE" \
        || [ ! -s "$VERIFY_VAULT_STATE" ] \
        || ! jq -ne --slurpfile post "$POST_VAULT_STATE" --slurpfile verify "$VERIFY_VAULT_STATE" \
          '($post[0].vaultFingerprint | type) == "string" and $post[0].vaultFingerprint == $verify[0].vaultFingerprint' \
          >/dev/null 2>&1; then
        echo "ERROR: 검증 중 Vault가 다시 변경됨 — 혼합 상태 커밋을 막고 재시도"
        PIPELINE_STATUS=1
      elif ! POST_FINGERPRINT=$(jq -er '.vaultFingerprint | select(type == "string" and length > 0)' "$POST_VAULT_STATE") \
        || ! jq -n \
          --arg phase "verified_post" \
          --arg preVaultFingerprint "$EXPECTED_VAULT_FINGERPRINT" \
          --arg postVaultFingerprint "$POST_FINGERPRINT" \
          --arg startedAt "$CLAUDE_STARTED_AT" \
          --arg expectedCommitToken "$COMMIT_TOKEN" \
          --argjson expectedCursorWatermark "$EXPECTED_CURSOR_WATERMARK" \
          '{version:1,phase:$phase,preVaultFingerprint:$preVaultFingerprint,postVaultFingerprint:$postVaultFingerprint,startedAt:$startedAt,expectedCursorWatermark:$expectedCursorWatermark,expectedCommitToken:$expectedCommitToken}' \
          > "$WORKFLOW_MARKER_TMP" \
        || ! chmod 600 "$WORKFLOW_MARKER_TMP" \
        || ! mv -f "$WORKFLOW_MARKER_TMP" "$WORKFLOW_STATE_MARKER"; then
        echo "ERROR: 검증된 Workflow 이후 상태를 복구 표식에 기록하지 못함"
        PIPELINE_STATUS=1
      elif ! mv -f "$POST_VAULT_STATE" "$DIR/pending-vault-state.json"; then
        echo "ERROR: 검증된 Workflow 이후 Vault 상태를 staging에 반영하지 못함"
        PIPELINE_STATUS=1
      elif ! bash "$DIR/commit-cursor.sh"; then
        echo "ERROR: Workflow는 성공했지만 커서 커밋 실패"
        PIPELINE_STATUS=1
      else
        EXPECTED_VAULT_FINGERPRINT=$(jq -er '.vaultFingerprint' "$DIR/vault-state.json")
      fi
    else
      echo "ERROR: Workflow 완료 검증 실패 — claude_exit=$CLAUDE_STATUS, structured_result=$RESULT_READY"
      PIPELINE_STATUS=1
    fi

    if [ "$PIPELINE_STATUS" -eq 0 ] \
      && jq -e --arg started "$CLAUDE_STARTED_AT" --arg token "$COMMIT_TOKEN" --argjson expectedWatermark "$EXPECTED_CURSOR_WATERMARK" '
        .version == 2
        and ((.sources | type) == "object")
        and (.sources | has("claude-code"))
        and (.sources | has("hermes"))
        and (.sources | has("codex"))
        and ({lastProcessed,sources,boundaryIds,boundaryStarts} == $expectedWatermark)
        and (.workflowCommitToken == $token)
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
      # baseline을 먼저 지우면 정리 중 종료돼도 marker-only 복구가 가능하다.
      if rm -f "$WORKFLOW_BASELINE_STATE" && rm -f "$WORKFLOW_STATE_MARKER"; then
        echo "파이프라인 성공 — 구조화 결과와 대화 커서·Vault 상태 커밋 확인"
      else
        echo "ERROR: 성공 커밋 뒤 Workflow 격리 표식 정리 실패"
        PIPELINE_STATUS=1
      fi
    else
      echo "ERROR: durable commit 사후조건 실패 — 기존 또는 pending 상태를 확인해야 함"
      PIPELINE_STATUS=1
    fi
  fi

  echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료(status=$PIPELINE_STATUS) ====="
  echo
}

exit "$PIPELINE_STATUS"
