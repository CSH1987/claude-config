#!/usr/bin/env bash
# claude-config:learning-pipeline-setup — Claude·Hermes·Codex 대화와 Vault 전체 변경분에서
# 패턴을 학습해 10_컨텍스트를 갱신하는 파이프라인을 자동 설치/복구한다.
# 머신게이트: 맥미니 + vault-scope.json(볼트) 둘 다 있어야 설치(헤르메스는 선택 — gather.sh가
# 없으면 조용히 스킵). 다른 머신(윈도우 등)은 조용히 스킵 — 거기엔 이 전제가 없는 게 정상.
# 세션은 절대 막지 않는다 — 항상 exit 0. 끄려면 CLAUDE_LEARNING_PIPELINE_OFF=1.
set -u

[ "${CLAUDE_LEARNING_PIPELINE_OFF:-}" = "1" ] && exit 0

host="$(hostname 2>/dev/null || echo '')"
case "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" in
  *macmini*) : ;;
  *) exit 0 ;;
esac

emit() {
  python3 -c "
import json, sys
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': sys.argv[1]}}))
" "$1"
  exit 0
}

command -v python3 >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SCOPE_FILE="$HOME/.claude/vault-scope.json"
[ -f "$SCOPE_FILE" ] || emit "[학습파이프라인] 맥미니인데 vault-scope.json이 없습니다 — Vault Phase1 설치를 먼저 확인하세요(learning-pipeline은 볼트가 있어야 설치됩니다)."

VAULT_PATH=$(python3 -c "
import json
try:
    with open('$SCOPE_FILE') as f:
        print(json.load(f).get('vaultPath',''))
except Exception:
    print('')
" 2>/dev/null)
[ -n "$VAULT_PATH" ] && [ -d "$VAULT_PATH/10_컨텍스트" ] || emit "[학습파이프라인] vault-scope.json의 vaultPath가 비어있거나 10_컨텍스트 폴더가 없습니다."

# 레포 위치: $0 기반 dirname은 이 파일 자체가 심볼릭 링크로 호출될 때 링크 위치(~/.claude/hooks)
# 기준으로 계산돼 실제 레포를 못 찾는다(실측 확인) — config-sync.sh와 동일한, 검증된 방식을 쓴다.
REPO_DIR=""
PF="$HOME/.claude/.config-sync-path"
[ -f "$PF" ] && REPO_DIR="$(cat "$PF" 2>/dev/null)"
[ -z "$REPO_DIR" ] && REPO_DIR="$HOME/claude-config"
SRC="$REPO_DIR/claude/learning-pipeline"
[ -d "$SRC" ] || exit 0

DIR="$HOME/.claude/learning-pipeline"
mkdir -p "$DIR"

# 스크립트와 수집기는 심볼릭 링크(다른 훅과 동일 컨벤션) — 재실행해도 무해.
ln -sfn "$SRC/gather.sh" "$DIR/gather.sh"
ln -sfn "$SRC/commit-cursor.sh" "$DIR/commit-cursor.sh"
ln -sfn "$SRC/run.sh" "$DIR/run.sh"
ln -sfn "$SRC/pipeline.workflow.js" "$DIR/pipeline.workflow.js"
ln -sfn "$SRC/collect-codex-user-prompts.py" "$DIR/collect-codex-user-prompts.py"
ln -sfn "$SRC/finalize-gathered-prompts.py" "$DIR/finalize-gathered-prompts.py"
ln -sfn "$SRC/validate-vault-output.py" "$DIR/validate-vault-output.py"
ln -sfn "$REPO_DIR/claude/hooks/vault-catalog.py" "$DIR/vault-catalog.py"
chmod 700 "$DIR" 2>/dev/null || true
chmod +x "$SRC/gather.sh" "$SRC/commit-cursor.sh" "$SRC/run.sh" \
  "$SRC/collect-codex-user-prompts.py" "$SRC/finalize-gathered-prompts.py" \
  "$SRC/validate-vault-output.py" \
  "$REPO_DIR/claude/hooks/vault-catalog.py" 2>/dev/null

# 커서 없으면 최초 1회 초기화(7일 전부터 시작).
CURSOR_FILE="$DIR/cursor.json"
if [ ! -f "$CURSOR_FILE" ]; then
  DEFAULT_TS=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%S.000Z")
  python3 -c "
import json
json.dump({
        'version': 2,
        'lastProcessed': '$DEFAULT_TS',
        'sources': {'claude-code': '$DEFAULT_TS', 'hermes': '$DEFAULT_TS', 'codex': '$DEFAULT_TS'},
        'boundaryIds': {'claude-code': [], 'hermes': [], 'codex': []},
        'boundaryStarts': {'claude-code': '$DEFAULT_TS', 'hermes': '$DEFAULT_TS', 'codex': '$DEFAULT_TS'},
        'committedAt': None,
    }, open('$CURSOR_FILE', 'w'), indent=2)
" 2>/dev/null
fi

# launchd 등록은 아직 안 돼 있을 때만(idempotent) — 매번 재로드하지 않는다.
PLIST_DST="$HOME/Library/LaunchAgents/local.claude.vault-learning-pipeline.plist"
if [ ! -f "$PLIST_DST" ]; then
  sed "s#__HOME__#$HOME#g" "$SRC/vault-learning-pipeline.plist.template" > "$PLIST_DST" 2>/dev/null
  if [ -f "$PLIST_DST" ]; then
    launchctl load "$PLIST_DST" >/dev/null 2>&1
    emit "[학습파이프라인] 신규 설치 완료 — 매주 일요일 04:00 자동 실행 등록됨(launchd: local.claude.vault-learning-pipeline)."
  fi
fi

exit 0
