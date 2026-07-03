#!/usr/bin/env bash
# claude-config:config-sync — claude-config 레포를 GitHub(클라우드)와 자동 동기화 (설정-전용).
#   start (SessionStart) → git pull + 미푸시 백로그 push + (변경 시) deploy-only 자동 반영
#   end   (SessionEnd)   → commit + 즉시 push (실패 시에만 pull 후 재시도) : 클라우드 백업
# push 를 commit 직후에 두는 이유: SessionEnd 훅은 세션 종료와 함께 중도 킬될 수 있어,
# 네트워크 단계(pull)가 push 보다 앞에 있으면 백업이 원격에 도달하지 못한다. 그래도 놓친
# 백로그는 프로세스 생존이 안정적인 다음 SessionStart 에서 밀어 올린다(자가치유).
# 원칙: 세션을 절대 막지 않는다.
#   · GIT_TERMINAL_PROMPT=0 → 자격증명 프롬프트로 멈추지 않고 즉시 실패(행 방지).
#   · lock → 한 번에 하나만(설치 중 hook 다발 발화 시 git 경쟁 방지).
#   · 오프라인·충돌·미설치는 조용히 스킵(충돌은 rebase abort). 끄려면 CLAUDE_CONFIG_NO_SYNC=1.
# 비밀은 레포에 없고 .omc 는 gitignore 이므로 add -A 안전.
set -uo pipefail
mode="${1:-}"

[ "${CLAUDE_CONFIG_NO_SYNC:-}" = "1" ] && exit 0

# 레포 위치: 인자 > path 파일(설치 시 기록) > 기본값
repo="${2:-}"
if [ -z "$repo" ]; then
  pf="$HOME/.claude/.config-sync-path"
  [ -f "$pf" ] && repo="$(cat "$pf" 2>/dev/null)"
fi
[ -z "$repo" ] && repo="$HOME/claude-config"

command -v git >/dev/null 2>&1 || exit 0
[ -d "$repo/.git" ] || exit 0
cd "$repo" 2>/dev/null || exit 0

# leak-guard self-heal (security): route hooks to the versioned guard BEFORE the upstream gate,
# so a fresh clone / no-upstream repo still activates the guard (core.hooksPath is .git-local and
# not carried by clone). Idempotent; 가드 '활성화'일 뿐 가드 로직은 githooks 에 있음(본문 무수정 유지).
[ -d "$repo/claude/githooks" ] && git config core.hooksPath claude/githooks 2>/dev/null || true

git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || exit 0

export GIT_TERMINAL_PROMPT=0   # 자격증명 없으면 행 대신 즉시 실패

# lock (atomic mkdir). 이미 돌고 있으면 스킵. 10분 이상 묵은 락은 회수.
lock="$repo/.git/.config-sync.lock"
if ! mkdir "$lock" 2>/dev/null; then
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$lock" 2>/dev/null || true
    mkdir "$lock" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

# timeout: macOS 기본엔 없음 → 있으면만 사용
TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout 30"

# $TO(timeout) 는 macOS 기본엔 없으므로, git lowSpeed 로도 느린/끊긴 네트워크 pull 을 중단(20초간 1KB/s 미만).
pull() {
  $TO git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 pull --rebase --autostash --quiet >/dev/null 2>&1 \
    || git rebase --abort >/dev/null 2>&1 || true
}

# push 도 lowSpeed 가드로 행 방지. 실패(비FF·오프라인)를 반환해 재시도 판단에 쓴다.
push_now() {
  $TO git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 push --quiet >/dev/null 2>&1
}

# pull 로 새 커밋이 들어오면 deploy-only 로 ~/.claude 에 자동 반영(멱등·부작용 없음).
# deploy-only = 파일 배치만(settings·CLAUDE.md·hooks·ultracode.json), 플러그인/PATH/프로필 스킵.
# 실패해도 세션 안 막음. 적용은 다음 세션부터(settings·CLAUDE.md 는 세션 시작 시 로드).
apply_if_changed() {
  before="$1"
  after="$(git rev-parse HEAD 2>/dev/null)"
  [ -z "$after" ] && return 0
  [ "$before" = "$after" ] && return 0          # pull 로 변경 없으면 스킵
  [ -f "$repo/install.sh" ] || return 0
  CLAUDE_INSTALL_DEPLOY_ONLY=1 $TO bash "$repo/install.sh" >/dev/null 2>&1 || true
  echo "claude-config: 새 설정을 받아 반영했습니다 (다음 세션부터 적용)." >&2
}

case "$mode" in
  start)
    head_before="$(git rev-parse HEAD 2>/dev/null)"
    pull
    # 백로그 자가치유: 지난 SessionEnd 가 push 전에 죽어 남은 미푸시 커밋을 밀어 올린다.
    ahead="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    if [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then
      push_now || { pull; push_now || true; }
    fi
    apply_if_changed "$head_before"
    ;;
  end)
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      git add -A >/dev/null 2>&1 || true
      git commit -m "auto-sync: $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1 || true
    fi
    push_now || { pull; push_now || true; }
    ;;
esac
exit 0
