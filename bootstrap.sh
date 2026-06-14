#!/usr/bin/env bash
# claude-config 부트스트랩 (Mac/Linux) — "짧은 한 줄"의 진입점.
#   curl -fsSL https://raw.githubusercontent.com/CSH1987/claude-config/main/bootstrap.sh | bash
# 하는 일: git·gh·node 없으면 설치 → (public 레포라 인증 없이) clone/update → install.sh 실행.
# Claude Code CLI 자체와 `gh auth login` 은 사용자가 먼저(설치+로그인). gh 인증은 github MCP 토큰용이라
# 없어도 설정은 진행됨(안내만).
set -uo pipefail
REPO_URL="https://github.com/CSH1987/claude-config.git"
DEST="$HOME/claude-config"
OS="$(uname -s)"
say(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

say "claude-config bootstrap ($OS)"

# 패키지 매니저로 누락 도구 설치 (best-effort). 인자: <명령> <brew/win 포뮬러> <apt 패키지>
ensure(){
  local cmd="$1" brewf="$2" aptp="$3"
  command -v "$cmd" >/dev/null 2>&1 && { echo "  ✓ $cmd"; return 0; }
  echo "  · installing $cmd ..."
  if [ "$OS" = "Darwin" ]; then
    if command -v brew >/dev/null 2>&1; then brew install "$brewf" >/dev/null 2>&1 || true
    else echo "  ! Homebrew 없음 → https://brew.sh 설치 후 재실행 (또는 $cmd 수동 설치)"; fi
  elif command -v apt-get >/dev/null 2>&1; then sudo apt-get update -y >/dev/null 2>&1 && sudo apt-get install -y "$aptp" >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y "$aptp" >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then sudo pacman -S --noconfirm "$aptp" >/dev/null 2>&1 || true
  else echo "  ! 패키지 매니저 없음 → $cmd 수동 설치 필요"; fi
  command -v "$cmd" >/dev/null 2>&1 && echo "  ✓ $cmd" || echo "  ! $cmd 설치 실패(수동 설치 필요)"
}
ensure git  git  git
ensure gh   gh   gh
# node: brew=node, apt=nodejs(+npm). playwright/context7 MCP 용.
if command -v node >/dev/null 2>&1; then echo "  ✓ node"
else
  echo "  · installing node ..."
  if [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then brew install node >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y nodejs npm >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y nodejs >/dev/null 2>&1 || true
  else echo "  ! node 미설치 — nodejs LTS 권장(일부 MCP용)"; fi
fi

command -v claude >/dev/null 2>&1 || echo "  ! Claude Code CLI 미설치 — 먼저 설치하세요 (예: npm i -g @anthropic-ai/claude-code)"
if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 || echo "  i github MCP 토큰을 쓰려면 한 번: gh auth login  (지금 안 해도 설정은 진행됨)"
fi

# public 레포 → 인증 없이 clone/update
if [ -d "$DEST/.git" ]; then
  say "update $DEST"; git -C "$DEST" pull --ff-only || git -C "$DEST" pull --rebase --autostash || true
else
  say "clone → $DEST"; git clone "$REPO_URL" "$DEST" || { echo "  ! clone 실패 (git 설치 확인)"; exit 1; }
fi

say "run install.sh"
bash "$DEST/install.sh"
say "완료 — 새 터미널을 열고  claude  입력"
