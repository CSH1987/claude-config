#!/usr/bin/env bash
# claude-config:config-sync — claude-config 레포를 GitHub(클라우드)와 자동 동기화 (설정-전용).
#   start (SessionStart) → git pull --rebase   : 매 세션 최신 설정 수신
#   end   (SessionEnd)   → commit + push       : 변경분을 클라우드에 백업
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

pull() {
  $TO git pull --rebase --autostash --quiet >/dev/null 2>&1 \
    || git rebase --abort >/dev/null 2>&1 || true
}

case "$mode" in
  start)
    pull
    ;;
  end)
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      git add -A >/dev/null 2>&1 || true
      git commit -m "auto-sync: $(hostname 2>/dev/null || echo unknown) $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1 || true
    fi
    pull
    $TO git push --quiet >/dev/null 2>&1 || true
    ;;
esac
exit 0
