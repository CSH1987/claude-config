#!/usr/bin/env bash
# vault-learning-pipeline: launchd가 주기 호출하는 진입점.
# 1) gather.sh로 신규 발화+Vault 변경 문서 수집 2) 둘 다 없으면 스킵(비용 절약)
# 3) 있으면 claude -p로 Workflow 실행(경로는 이 머신 기준으로 매번 계산해 args로 전달)
# 4) 성공시에만 commit-cursor.sh로 커서 커밋
# 전부 $HOME/vault-scope.json 기준 — 계정명·볼트경로 하드코딩 없음.
set -uo pipefail
DIR="$HOME/.claude/learning-pipeline"
LOG="$DIR/run.log"
SCOPE_FILE="$HOME/.claude/vault-scope.json"

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

  bash "$DIR/gather.sh"
  TALK_COUNT=$(jq 'length' "$DIR/gathered-utterances.json" 2>/dev/null || echo 0)
  VAULT_COUNT=$(jq '.changes | length' "$DIR/gathered-vault-documents.json" 2>/dev/null || echo 0)
  COUNT=$(( ${TALK_COUNT:-0} + ${VAULT_COUNT:-0} ))

  if [ "${COUNT:-0}" -eq 0 ] 2>/dev/null; then
    echo "신규 대화·Vault 변경 문서 없음 — 워크플로 스킵"
  else
    echo "신규 대화 ${TALK_COUNT}건 + Vault 변경 문서 ${VAULT_COUNT}건 감지 — 파이프라인 실행"
    CLAUDE_BIN="$(command -v claude || echo "$HOME/.local/bin/claude")"
    MEMORY_DIR="$HOME/.claude/projects/$(printf '%s' "$HOME" | sed 's#/#-#g')/memory"
    ARGS_JSON=$(jq -n \
      --arg vault10Path "$VAULT_PATH/10_컨텍스트" \
      --arg utterancesPath "$DIR/gathered-utterances.json" \
      --arg vaultDocumentsPath "$DIR/gathered-vault-documents.json" \
      --arg memoryDirPath "$MEMORY_DIR" \
      --arg vault90HermesPath "$VAULT_PATH/90_Hermes" \
      '{vault10Path: $vault10Path, utterancesPath: $utterancesPath, vaultDocumentsPath: $vaultDocumentsPath, memoryDirPath: $memoryDirPath, vault90HermesPath: $vault90HermesPath}')

    CLAUDE_EVENTS_OFF=1 CLAUDE_AUTOSYNC_OFF=1 CLAUDE_CONFIG_NO_SYNC=1 "$CLAUDE_BIN" -p "$(cat <<PROMPT
Workflow 도구로 $HOME/.claude/learning-pipeline/pipeline.workflow.js 를 scriptPath로, 다음 args와 함께 실행해라:
$ARGS_JSON
완료 후 결과의 agents_error가 0이면 성공이다 — Bash로 "bash $HOME/.claude/learning-pipeline/commit-cursor.sh"를 실행해서 커서를 커밋해라.
agents_error가 0보다 크면 절대 커밋하지 말고, 무엇이 실패했는지 한국어 두세 문장으로 보고하고 끝내라.
PROMPT
)"
  fi

  echo "===== $(date -u +"%Y-%m-%dT%H:%M:%SZ") 실행 종료 ====="
  echo
} >> "$LOG" 2>&1
