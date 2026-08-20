#!/usr/bin/env bash
# claude-config 통합 온라인 복구 (macOS/Linux)
#
# 공개 claude-config를 먼저 설치한 뒤, 인증된 GitHub 계정의 비공개 Vault를
# 복구하고 Claude Code/Codex/Obsidian/Hermes를 같은 로컬 Vault에 연결한다.
# 토큰·키는 읽거나 출력하거나 공개 레포에 복사하지 않는다. 각 서비스 인증은
# 해당 공식 CLI의 대화형 로그인으로 넘긴다.
set -uo pipefail

BASE_BOOTSTRAP_URL="https://raw.githubusercontent.com/CSH1987/claude-config/main/bootstrap.sh"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/claude-config}"

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
info() { printf '  i %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

# curl | bash 진입점에서도 기존 bootstrap/install 구조를 그대로 재사용한다.
# pull로 online-bootstrap.sh 자체가 갱신될 수 있으므로, base 단계 뒤에는 로컬의
# 최신 파일을 새 프로세스로 다시 실행한다.
if [ "${ONLINE_BOOTSTRAP_SKIP_BASE:-0}" != "1" ] && [ "${1:-}" != "--post-base" ]; then
  say "기본 claude-config 설치/갱신"
  if [ -f "$CONFIG_DIR/bootstrap.sh" ]; then
    bash "$CONFIG_DIR/bootstrap.sh" || die "기본 bootstrap 실패"
  else
    command -v curl >/dev/null 2>&1 || die "curl이 필요합니다: $BASE_BOOTSTRAP_URL"
    _bootstrap_tmp="$(mktemp "${TMPDIR:-/tmp}/claude-config-bootstrap.XXXXXX")" || die "임시 파일 생성 실패"
    if ! curl -fsSL "$BASE_BOOTSTRAP_URL" -o "$_bootstrap_tmp"; then
      rm -f "$_bootstrap_tmp"
      die "기본 bootstrap 다운로드 실패"
    fi
    bash "$_bootstrap_tmp" || { _rc=$?; rm -f "$_bootstrap_tmp"; exit "$_rc"; }
    rm -f "$_bootstrap_tmp"
  fi
  [ -f "$CONFIG_DIR/online-bootstrap.sh" ] || die "갱신된 레포에 online-bootstrap.sh가 없습니다: $CONFIG_DIR"
  exec bash "$CONFIG_DIR/online-bootstrap.sh" --post-base "$@"
fi
[ "${1:-}" = "--post-base" ] && shift

VAULT_REPO="${ONLINE_VAULT_REPO:-}"
VAULT_REPO_NAME="${ONLINE_VAULT_REPO_NAME:-vault-backup}"
VAULT_DIR="${ONLINE_VAULT_PATH:-$HOME/Documents/Vault}"
INSTALL_MISSING=1
OPEN_OBSIDIAN=1
HERMES_MODE="${ONLINE_BOOTSTRAP_HERMES_MODE:-yes}"
OS="${ONLINE_BOOTSTRAP_OS_OVERRIDE:-$(uname -s)}"
INCOMPLETE=0

usage() {
  cat <<'EOF'
사용법: bash online-bootstrap.sh [옵션]

  --vault-repo OWNER/REPO  비공개 Vault 저장소. 기본값은 현재 gh 계정의 vault-backup
  --vault-path PATH        로컬 Vault 경로. 기본값은 ~/Documents/Vault
  --with-hermes            Hermes CLI를 설치/연결(기본값)
  --without-hermes         Hermes 설치/연결 생략
  --skip-install           누락 앱/CLI를 설치하지 않고 상태만 보고
  --no-open                완료 후 Obsidian을 열지 않음
  -h, --help               이 도움말

Windows는 기존 bootstrap.ps1을 사용한다. Hermes CLI와 공통 규칙은 이 머신에도
설치할 수 있지만 gateway/Telegram/cron 상시 운영은 Mac mini 한 곳에서만 한다.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --vault-repo)
      [ "$#" -ge 2 ] || die "--vault-repo 값이 필요합니다"
      VAULT_REPO="$2"; shift 2 ;;
    --vault-path)
      [ "$#" -ge 2 ] || die "--vault-path 값이 필요합니다"
      VAULT_DIR="$2"; shift 2 ;;
    --with-hermes) HERMES_MODE="yes"; shift ;;
    --without-hermes) HERMES_MODE="no"; shift ;;
    --skip-install) INSTALL_MISSING=0; shift ;;
    --no-open) OPEN_OBSIDIAN=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "알 수 없는 옵션: $1" ;;
  esac
done

case "$HERMES_MODE" in
  yes|no) ;;
  *) die "ONLINE_BOOTSTRAP_HERMES_MODE는 yes 또는 no여야 합니다: $HERMES_MODE" ;;
esac

case "$OS" in
  Darwin|Linux) ;;
  MINGW*|MSYS*|CYGWIN*)
    die "Windows에서는 bootstrap.ps1을 사용하세요. Hermes는 Windows에 설치하지 않는 기존 원칙을 유지합니다." ;;
  *) die "지원하지 않는 운영체제입니다: $OS" ;;
esac

# 호출자가 지정한 PATH(테스트 스텁·가상환경 포함)를 우선 보존하고, 표준 설치
# 경로만 뒤에 보강한다.
export PATH="$PATH:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin"

has_tty() {
  [ "${ONLINE_BOOTSTRAP_NONINTERACTIVE:-0}" != "1" ] && [ -r /dev/tty ] && [ -w /dev/tty ]
}

# 로그인 명령은 비밀을 인자로 받지 않는다. 공식 CLI가 브라우저/TTY에서 직접
# 인증하고 자기 전용 저장소에 보관한다.
interactive_handoff() {
  _label="$1"; _hint="$2"; shift 2
  if ! has_tty; then
    warn "$_label 필요 — 대화형 터미널에서 실행: $_hint"
    return 1
  fi
  say "$_label"
  info "공식 대화형 인증으로 전환합니다. 비밀값은 이 스크립트가 읽지 않습니다."
  "$@" </dev/tty >/dev/tty 2>&1
}

install_cli_if_missing() {
  _cmd="$1"; _label="$2"; _installer="$3"
  if command -v "$_cmd" >/dev/null 2>&1; then
    ok "$_label 설치됨"
    return 0
  fi
  if [ "$INSTALL_MISSING" -ne 1 ]; then
    warn "$_label 미설치 (--skip-install)"
    return 1
  fi
  say "$_label 설치"
  case "$_installer" in
    claude)
      command -v npm >/dev/null 2>&1 || { warn "npm이 없어 Claude Code를 설치할 수 없습니다"; return 1; }
      npm install -g @anthropic-ai/claude-code || return 1 ;;
    codex)
      command -v curl >/dev/null 2>&1 || { warn "curl이 없어 Codex를 설치할 수 없습니다"; return 1; }
      curl -fsSL https://chatgpt.com/codex/install.sh | sh || return 1 ;;
    hermes)
      command -v curl >/dev/null 2>&1 || { warn "curl이 없어 Hermes를 설치할 수 없습니다"; return 1; }
      curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash || return 1 ;;
    *) return 1 ;;
  esac
  hash -r 2>/dev/null || true
  command -v "$_cmd" >/dev/null 2>&1
}

say "GitHub 인증 및 Git 전송 설정"
command -v git >/dev/null 2>&1 || die "git이 없습니다. 기본 bootstrap 결과를 확인하세요."
command -v gh >/dev/null 2>&1 || die "gh가 없습니다. 기본 bootstrap 결과를 확인하세요."
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  interactive_handoff "GitHub 로그인" \
    "gh auth login --hostname github.com --web --git-protocol https" \
    gh auth login --hostname github.com --web --git-protocol https \
    || die "GitHub 인증이 완료되지 않아 비공개 Vault를 복구할 수 없습니다."
fi
gh auth status --hostname github.com >/dev/null 2>&1 || die "GitHub 인증 확인 실패"
gh auth setup-git >/dev/null 2>&1 || die "Git HTTPS 인증 도우미 설정 실패: gh auth setup-git"

GH_LOGIN="$(gh api user --jq '.login' 2>/dev/null || true)"
GH_ID="$(gh api user --jq '.id' 2>/dev/null || true)"
[ -n "$GH_LOGIN" ] || die "인증된 GitHub 사용자명을 확인할 수 없습니다."
[ -n "$VAULT_REPO" ] || VAULT_REPO="$GH_LOGIN/$VAULT_REPO_NAME"
case "$VAULT_REPO" in
  */*) ;;
  *) VAULT_REPO="$GH_LOGIN/$VAULT_REPO" ;;
esac

_repo_info="$(gh repo view "$VAULT_REPO" --json nameWithOwner,visibility,viewerPermission --jq '.nameWithOwner + "|" + .visibility + "|" + .viewerPermission' 2>/dev/null || true)"
_repo_name="${_repo_info%%|*}"
_repo_remainder="${_repo_info#*|}"
_repo_visibility="${_repo_remainder%%|*}"
_repo_permission="${_repo_remainder#*|}"
[ -n "$_repo_info" ] && [ "$_repo_info" != "$_repo_remainder" ] && [ "$_repo_remainder" != "$_repo_permission" ] \
  || die "Vault 저장소를 찾거나 읽을 수 없습니다: $VAULT_REPO"
[ "$_repo_visibility" = "PRIVATE" ] \
  || die "Vault 저장소는 PRIVATE여야 합니다(현재: $_repo_visibility). 공개 저장소에는 Vault를 연결하지 않습니다."
case "$_repo_permission" in
  ADMIN|MAINTAIN|WRITE) ;;
  *) die "Vault 저장소에 push 가능한 권한이 없습니다(현재: $_repo_permission)." ;;
esac
VAULT_REPO="$_repo_name"
ok "비공개 Vault 저장소와 push 권한 확인: $VAULT_REPO"

# 공개 설정 저장소도 새 장치에서 수정사항을 되돌려 보낼 수 있어야 온라인 연속성이 완성된다.
CONFIG_ORIGIN="$(git -C "$CONFIG_DIR" remote get-url origin 2>/dev/null || true)"
[ -n "$CONFIG_ORIGIN" ] || die "claude-config 저장소에 origin이 없습니다: $CONFIG_DIR"
CONFIG_PERMISSION="$(gh repo view "$CONFIG_ORIGIN" --json viewerPermission --jq '.viewerPermission' 2>/dev/null || true)"
case "$CONFIG_PERMISSION" in
  ADMIN|MAINTAIN|WRITE) ;;
  *) die "claude-config 저장소에 push 가능한 권한이 없습니다(현재: ${CONFIG_PERMISSION:-확인 실패})." ;;
esac
ok "claude-config push 권한 확인"

configure_git_identity() {
  _dir="$1"
  [ -d "$_dir/.git" ] || return 0
  if [ -z "$(git -C "$_dir" config --local --get user.name 2>/dev/null || true)" ]; then
    git -C "$_dir" config --local user.name "$GH_LOGIN" || return 1
  fi
  if [ -n "$GH_ID" ] && [ -z "$(git -C "$_dir" config --local --get user.email 2>/dev/null || true)" ]; then
    git -C "$_dir" config --local user.email "${GH_ID}+${GH_LOGIN}@users.noreply.github.com" || return 1
  fi
}

configure_git_identity "$CONFIG_DIR" || warn "claude-config의 repo-local Git 작성자 설정 실패"

say "비공개 Obsidian Vault 복구"
if [ -d "$VAULT_DIR/.git" ]; then
  _origin="$(git -C "$VAULT_DIR" remote get-url origin 2>/dev/null || true)"
  [ -n "$_origin" ] || die "기존 Vault Git 저장소에 origin이 없습니다: $VAULT_DIR"
  _origin_info="$(gh repo view "$_origin" --json nameWithOwner,visibility,viewerPermission --jq '.nameWithOwner + "|" + .visibility + "|" + .viewerPermission' 2>/dev/null || true)"
  _origin_name="${_origin_info%%|*}"
  _origin_remainder="${_origin_info#*|}"
  _origin_visibility="${_origin_remainder%%|*}"
  _origin_permission="${_origin_remainder#*|}"
  [ "$_origin_name" = "$VAULT_REPO" ] || die "기존 Vault origin($_origin_name)이 요청 저장소($VAULT_REPO)와 다릅니다."
  [ "$_origin_visibility" = "PRIVATE" ] || die "기존 Vault origin이 PRIVATE가 아닙니다."
  case "$_origin_permission" in
    ADMIN|MAINTAIN|WRITE) ;;
    *) die "기존 Vault origin에 push 가능한 권한이 없습니다(현재: $_origin_permission)." ;;
  esac
  if [ -n "$(git -C "$VAULT_DIR" status --porcelain 2>/dev/null || true)" ]; then
    warn "Vault에 커밋되지 않은 로컬 변경이 있어 pull은 생략했습니다. 데이터는 변경하지 않았습니다."
    INCOMPLETE=1
  elif git -C "$VAULT_DIR" pull --ff-only; then
    ok "기존 Vault fast-forward 갱신"
  else
    warn "Vault pull 실패 — 충돌/네트워크를 확인하세요."
    INCOMPLETE=1
  fi
elif [ -e "$VAULT_DIR" ] && [ -n "$(find "$VAULT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  die "Vault 대상 경로가 비어 있지 않고 Git 저장소도 아닙니다: $VAULT_DIR"
else
  mkdir -p "$(dirname "$VAULT_DIR")" || die "Vault 상위 폴더 생성 실패"
  gh repo clone "$VAULT_REPO" "$VAULT_DIR" || die "비공개 Vault clone 실패"
  ok "Vault clone 완료"
fi
[ -d "$VAULT_DIR/.git" ] || die "Vault Git 저장소 검증 실패: $VAULT_DIR"
[ -f "$VAULT_DIR/00_홈.md" ] || die "Vault 센티널이 없습니다. 잘못된 저장소일 수 있습니다."
[ -d "$VAULT_DIR/10_컨텍스트" ] || die "Vault 공통 정본 폴더(10_컨텍스트)가 없습니다. 잘못된 저장소일 수 있습니다."
configure_git_identity "$VAULT_DIR" || { warn "Vault의 repo-local Git 작성자 설정 실패"; INCOMPLETE=1; }

say "Vault 로컬 경로 연결"
command -v python3 >/dev/null 2>&1 || die "vault-scope.json 갱신에 python3가 필요합니다."
SCOPE_FILE="$HOME/.claude/vault-scope.json"
python3 - "$SCOPE_FILE" "$VAULT_DIR" <<'PY' || die "vault-scope.json 원자적 갱신 실패"
import json
import os
import sys
import tempfile

scope_path, vault_path = sys.argv[1:]
os.makedirs(os.path.dirname(scope_path), exist_ok=True)
data = {}
if os.path.exists(scope_path):
    try:
        with open(scope_path, encoding="utf-8") as source:
            loaded = json.load(source)
        if isinstance(loaded, dict):
            data = loaded
    except (OSError, ValueError):
        pass
data["vaultPath"] = os.path.abspath(vault_path)
fd, temporary_path = tempfile.mkstemp(prefix=".vault-scope.", dir=os.path.dirname(scope_path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as destination:
        json.dump(data, destination, ensure_ascii=False, indent=2)
        destination.write("\n")
    os.chmod(temporary_path, 0o600)
    os.replace(temporary_path, scope_path)
finally:
    if os.path.exists(temporary_path):
        os.unlink(temporary_path)
PY
chmod 600 "$SCOPE_FILE" 2>/dev/null || true
ok "Claude/Codex Vault 경로 기록(로컬 전용)"

if [ "$OS" = "Darwin" ]; then
  OBSIDIAN_APP="${OBSIDIAN_APP_PATH_OVERRIDE:-/Applications/Obsidian.app}"
  if [ ! -d "$OBSIDIAN_APP" ] && [ -d "$HOME/Applications/Obsidian.app" ]; then
    OBSIDIAN_APP="$HOME/Applications/Obsidian.app"
  fi
  if [ ! -d "$OBSIDIAN_APP" ] && [ "$INSTALL_MISSING" -eq 1 ] && command -v brew >/dev/null 2>&1; then
    say "Obsidian 설치"
    brew install --cask obsidian || true
  fi
  if [ -d "$OBSIDIAN_APP" ] || [ -d /Applications/Obsidian.app ] || [ -d "$HOME/Applications/Obsidian.app" ]; then
    ok "Obsidian 설치됨"
  else
    warn "Obsidian 미설치 — Homebrew 설치 후: brew install --cask obsidian (공식: https://obsidian.md/download)"
    INCOMPLETE=1
  fi
else
  if command -v obsidian >/dev/null 2>&1; then
    ok "Obsidian 실행 파일 설치됨"
  else
    warn "Linux Obsidian 설치는 배포판별 공식 패키지를 사용하세요: https://obsidian.md/download"
    INCOMPLETE=1
  fi
fi

for _obsidian_plugin in obsidian-git obsidian-local-rest-api; do
  if [ -f "$VAULT_DIR/.obsidian/plugins/$_obsidian_plugin/manifest.json" ]; then
    ok "Obsidian plugin payload 확인: $_obsidian_plugin"
  else
    warn "Vault에 $_obsidian_plugin payload가 없습니다. Obsidian에서 장치별로 설치해야 합니다."
    INCOMPLETE=1
  fi
done

say "AI 클라이언트 설치 및 대화형 인증"
CLAUDE_JUST_INSTALLED=0
command -v claude >/dev/null 2>&1 || CLAUDE_JUST_INSTALLED=1
CLAUDE_AUTHENTICATED=0
if ! install_cli_if_missing claude "Claude Code" claude; then
  warn "Claude Code 설치 실패"
  INCOMPLETE=1
elif ! claude auth status >/dev/null 2>&1; then
  interactive_handoff "Claude Code 로그인" "claude auth login" claude auth login \
    || { warn "Claude Code 인증 미완료"; INCOMPLETE=1; }
  claude auth status >/dev/null 2>&1 && CLAUDE_AUTHENTICATED=1
else
  CLAUDE_AUTHENTICATED=1
fi
if [ "$CLAUDE_JUST_INSTALLED" -eq 1 ] && [ "$CLAUDE_AUTHENTICATED" -eq 1 ]; then
  say "Claude Code 설치 후 설정 재배포"
  bash "$CONFIG_DIR/install.sh" \
    || { warn "새로 설치한 Claude Code의 플러그인/설정 재배포 실패"; INCOMPLETE=1; }
fi

if ! install_cli_if_missing codex "OpenAI Codex CLI" codex; then
  warn "Codex 설치 실패"
  INCOMPLETE=1
elif ! codex login status >/dev/null 2>&1; then
  interactive_handoff "Codex 로그인" "codex login" codex login \
    || { warn "Codex 인증 미완료"; INCOMPLETE=1; }
fi
if command -v codex >/dev/null 2>&1; then
  say "Codex 네이티브 컨텍스트·학습 구조 재배포"
  CLAUDE_INSTALL_DEPLOY_ONLY=1 bash "$CONFIG_DIR/install.sh" \
    || { warn "Codex 훅·메모리·스킬 설정 배포 실패"; INCOMPLETE=1; }
fi

if [ "$HERMES_MODE" = "yes" ]; then
  if ! install_cli_if_missing hermes "Hermes Agent" hermes; then
    warn "Hermes 설치 실패"
    INCOMPLETE=1
  else
    mkdir -p "$HOME/.hermes"
    HERMES_ENV="$HOME/.hermes/.env"
    python3 - "$HERMES_ENV" "$VAULT_DIR" <<'PY' || die "Hermes .env의 Vault 경로 갱신 실패"
import os
import sys
import tempfile

env_path, vault_path = sys.argv[1:]
os.makedirs(os.path.dirname(env_path), exist_ok=True)
lines = []
if os.path.exists(env_path):
    with open(env_path, encoding="utf-8") as source:
        lines = source.readlines()
escaped_path = os.path.abspath(vault_path).replace("\\", "\\\\").replace('"', '\\"')
replacement = f'OBSIDIAN_VAULT_PATH="{escaped_path}"\n'
result = []
replaced = False
for line in lines:
    normalized = line.lstrip()
    if normalized.startswith("OBSIDIAN_VAULT_PATH=") or normalized.startswith("export OBSIDIAN_VAULT_PATH="):
        if not replaced:
            result.append(replacement)
            replaced = True
        continue
    result.append(line)
if not replaced:
    if result and not result[-1].endswith("\n"):
        result[-1] += "\n"
    result.append(replacement)
fd, temporary_path = tempfile.mkstemp(prefix=".hermes-env.", dir=os.path.dirname(env_path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as destination:
        destination.writelines(result)
    os.chmod(temporary_path, 0o600)
    os.replace(temporary_path, env_path)
finally:
    if os.path.exists(temporary_path):
        os.unlink(temporary_path)
PY
    chmod 600 "$HERMES_ENV" 2>/dev/null || true
    ok "Hermes Vault 경로 연결(.env 값은 출력하지 않음)"
    if [ ! -f "$HOME/.hermes/config.yaml" ]; then
      interactive_handoff "Hermes provider/model 설정" "hermes setup" hermes setup \
        || { warn "Hermes provider 인증/모델 설정 미완료"; INCOMPLETE=1; }
    else
      ok "Hermes 설정 파일 존재(기존 provider/인증 보존)"
    fi
  fi
else
  info "Hermes CLI는 이 머신에서 생략했습니다(--without-hermes)."
fi

say "연동 시스템 전체 규칙 동기화"
if [ -f "$CONFIG_DIR/claude/hooks/codex-sync.sh" ] && [ -d "$HOME/.codex" ]; then
  bash "$CONFIG_DIR/claude/hooks/codex-sync.sh" "$HOME/.codex" "$CONFIG_DIR/claude" \
    || { warn "Codex 규칙 동기화 실패"; INCOMPLETE=1; }
fi
if [ "$HERMES_MODE" = "yes" ] && [ -f "$CONFIG_DIR/claude/hooks/hermes-sync.sh" ] && [ -d "$HOME/.hermes" ]; then
  bash "$CONFIG_DIR/claude/hooks/hermes-sync.sh" "$HOME/.hermes" "$CONFIG_DIR/claude" \
    || { warn "Hermes 규칙 동기화 실패"; INCOMPLETE=1; }
fi

if [ "$OS" = "Darwin" ] && [ "$OPEN_OBSIDIAN" -eq 1 ] && command -v open >/dev/null 2>&1; then
  if [ -d /Applications/Obsidian.app ] || [ -d "$HOME/Applications/Obsidian.app" ] || [ -d "${OBSIDIAN_APP_PATH_OVERRIDE:-/Applications/Obsidian.app}" ]; then
    open -a Obsidian "$VAULT_DIR" >/dev/null 2>&1 \
      || warn "Obsidian 자동 열기 실패 — 앱에서 'Open folder as vault'로 선택하세요: $VAULT_DIR"
  fi
fi

say "최종 검증"
_upstream_counts="$(git -C "$VAULT_DIR" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null || true)"
_behind="$(printf '%s\n' "$_upstream_counts" | awk '{print $1}')"
_ahead="$(printf '%s\n' "$_upstream_counts" | awk '{print $2}')"
if [ "$_behind" = "0" ] && [ "$_ahead" = "0" ]; then
  ok "Vault Git 원격과 동기화됨(behind/ahead 0/0)"
elif [ -n "$_upstream_counts" ]; then
  warn "Vault Git 원격 차이(behind/ahead): $_upstream_counts"
  INCOMPLETE=1
else
  warn "Vault upstream 상태를 확인할 수 없습니다."
  INCOMPLETE=1
fi

if command -v codex >/dev/null 2>&1 && codex login status >/dev/null 2>&1; then
  ok "Codex 인증 확인"
else
  warn "Codex 인증 확인 실패"
  INCOMPLETE=1
fi
if command -v claude >/dev/null 2>&1 && claude auth status >/dev/null 2>&1; then
  ok "Claude Code 인증 확인"
else
  warn "Claude Code 인증 확인 실패"
  INCOMPLETE=1
fi
if [ "$HERMES_MODE" = "yes" ]; then
  HERMES_STATUS="$(hermes status 2>/dev/null || true)"
  if command -v hermes >/dev/null 2>&1 \
    && [ -f "$HOME/.hermes/config.yaml" ] \
    && printf '%s\n' "$HERMES_STATUS" | awk '
      function normalized(value) {
        gsub(/[^[:alnum:]]/, "", value)
        return tolower(value)
      }
      /^[[:space:]]*Provider:[[:space:]]*/ {
        active=$0
        sub(/^[[:space:]]*Provider:[[:space:]]*/, "", active)
        active=normalized(active)
        next
      }
      /API Keys|Auth Providers|API-Key Providers/ { credentials=1; next }
      /^[^[:space:]]*◆/ { credentials=0 }
      credentials && /✓[[:space:]]+(logged in|set|configured)/ {
        label=$0
        sub(/✓.*/, "", label)
        if (active != "" && normalized(label) == active) ready=1
      }
      END { exit(ready ? 0 : 1) }
    '; then
    ok "Hermes provider/인증 설정 확인"
  else
    warn "Hermes provider/인증 설정 확인 실패 — hermes setup 또는 hermes model을 완료하세요."
    INCOMPLETE=1
  fi
fi

verify_sync_markers() {
  _target="$1"; shift
  for _marker in "$@"; do
    [ "$(grep -cF "$_marker" "$_target" 2>/dev/null || true)" = "1" ] || return 1
  done
}

if [ -f "$HOME/.codex/AGENTS.md" ] && verify_sync_markers "$HOME/.codex/AGENTS.md" \
  '<!-- claude-config:portable-rules:start -->' \
  '<!-- claude-config:codex-vault-rules:start -->' \
  '<!-- claude-config:vault-context:start -->' \
  '<!-- claude-config:vault-catalog:start -->'; then
  ok "Codex 공통 지침·Vault 전체 지도·컨텍스트 마커 확인"
else
  warn "Codex 공통 지침·Vault 규칙·컨텍스트 마커 검증 실패"
  INCOMPLETE=1
fi
if [ "$HERMES_MODE" = "yes" ]; then
  if [ -f "$HOME/.hermes/AGENTS.md" ] && verify_sync_markers "$HOME/.hermes/AGENTS.md" \
    '<!-- claude-config:portable-rules:start -->' \
    '<!-- claude-config:hermes-vault-rules:start -->' \
    '<!-- claude-config:vault-context:start -->' \
    '<!-- claude-config:vault-catalog:start -->'; then
    ok "Hermes 공통 지침·Vault 전체 지도·컨텍스트 마커 확인"
  else
    warn "Hermes 공통 지침·Vault 규칙·컨텍스트 마커 검증 실패"
    INCOMPLETE=1
  fi
fi

CONFIG_COUNTS="$(git -C "$CONFIG_DIR" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null || true)"
CONFIG_DIRTY="$(git -C "$CONFIG_DIR" status --porcelain 2>/dev/null || true)"
if { [ "$CONFIG_COUNTS" = $'0\t0' ] || [ "$CONFIG_COUNTS" = '0 0' ]; } && [ -z "$CONFIG_DIRTY" ]; then
  ok "claude-config Git 원격과 동기화됨(behind/ahead 0/0)"
else
  warn "claude-config Git 원격 또는 작업트리 불일치(behind/ahead: ${CONFIG_COUNTS:-확인 실패})"
  INCOMPLETE=1
fi

if [ "$INCOMPLETE" -eq 0 ]; then
  say "완료"
  _hermes_label=""
  [ "$HERMES_MODE" = "yes" ] && _hermes_label="·Hermes"
  info "GitHub private Vault가 Obsidian·Claude Code·Codex${_hermes_label}의 공통 정본으로 연결됐습니다."
  info "현재 Vault 전송 경로는 private GitHub + Obsidian Git입니다."
  info "Obsidian native Sync를 도입하면 양방향 동기화를 겹치지 말고, Mac mini의 Git을 backup-only로 전환한 뒤 사용하세요."
  info "새 장치에서 Obsidian 첫 실행 시 community plugins 신뢰/활성화를 직접 승인해야 합니다."
  info "Local REST API 키는 저장소에 복사하지 않습니다. Obsidian 플러그인 활성화 뒤 install.sh를 다시 실행하면 이 장치의 Codex MCP 로컬 설정에만 연결됩니다(Claude MCP는 기존 장치별 설정 유지)."
  info "Codex CLI에서 /hooks를 한 번 열어 새 lifecycle hooks의 내용을 검토·신뢰한 뒤 새 세션을 시작하세요."
  info "Hermes CLI는 여러 장치에서 쓸 수 있지만 gateway/Telegram/cron 상시 운영은 Mac mini 한 곳만 사용하세요."
  exit 0
fi

say "부분 완료"
warn "안전하게 자동 처리할 수 없는 항목이 남았습니다. 위의 ! 항목을 처리한 뒤 같은 명령을 다시 실행하세요."
exit 2
